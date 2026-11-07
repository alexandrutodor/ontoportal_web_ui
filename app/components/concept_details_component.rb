# frozen_string_literal: true

class ConceptDetailsComponent < ViewComponent::Base
  include ApplicationHelper
  include OntologiesHelper
  include MultiLanguagesHelper

  renders_one :header, TableComponent
  renders_many :sections, TableRowComponent

  PROPERTY_LABEL_CACHE_ENV_KEY = 'ontoportal.property_labels_cache'
  PROPERTY_LABEL_MISS_ENV_KEY = 'ontoportal.property_labels_miss_count'
  MAX_PROPERTY_LABEL_MISSES_PER_REQUEST = 20

  attr_reader :concept_properties

  def initialize(id:, acronym:, concept_id: nil, properties: nil, top_keys: [], bottom_keys: [], exclude_keys: [])
    @acronym = acronym
    @properties = properties
    @top_keys = top_keys
    @bottom_keys = bottom_keys
    @exclude_keys = exclude_keys
    @id = id
    @concept_id = concept_id

    @concept_properties = concept_properties2hash(@properties) if @properties
  end

  def add_sections(keys, &block)
    scheme_set = properties_set_by_keys(keys, prefix_properties(concept_properties))
    rows = row_hash_properties(scheme_set, concept_properties, &block)

    rows.each do |row|
      section do |table_row|
        table_row.create(*row)
      end
    end

  end

  def row_hash_properties(properties_set, ontology_acronym, &block)
    out = []
    properties_set&.each do |key, data|
      display_label = (data.is_a?(Hash) && data[:label]) || key
      next if exclude_relation?(key) || exclude_relation?(display_label) || !data[:values]

      values = data[:values]
      url = data[:key]

      ajax_links = Array(values).map do |v|
        if block_given?
          block.call(v)
        else
          if v.is_a?(String)
            get_link_for_cls_ajax(v, ontology_acronym, '_blank')
          else
            display_in_multiple_languages([v].to_h)
          end
        end
      end

      out << [
        { th: content_tag(:span, remove_owl_notation(display_label), title: url, 'data-controller': 'tooltip') },
        { td: list_items_component(max_items: 5) { |r| ajax_links.map { |val| r.container { val.html_safe } } } }
      ]
    end
    out
  end

  def properties_set_by_keys(keys, concept_properties, exclude_keys = [])
    concept_properties&.select do |k, v|
      label = (v.is_a?(Hash) && v[:label]) || k
      (keys.include?(k) || keys.include?(label) || !keys.select { |key| v[:key].to_s.include?(key) }.empty?) &&
        !exclude_keys.include?(k) && !exclude_keys.include?(label) &&
        exclude_keys.select { |key| v[:key].to_s.include?(key) }.empty?
    end
  end

  def filter_properties(top_keys, bottom_keys, exclude_keys, concept_properties)
    all_keys = concept_properties&.keys || []
    top_set = properties_set_by_keys(top_keys, concept_properties, exclude_keys)
    bottom_set = properties_set_by_keys(bottom_keys, concept_properties, exclude_keys)
    leftover = properties_set_by_keys(all_keys, concept_properties, exclude_keys)
    leftover = leftover.reject { |key, _| top_set.key?(key) || bottom_set.key?(key) }
    [top_set, leftover, bottom_set]
  end

  private

  def link_to_format_modal(format, icon)
    link_to_modal(nil, "/ontologies/#{@acronym}/#{escape(@concept_id)}/serialize/#{format}", { id: "resource_content_#{format}", data: { show_modal_title_value: @concept_id, show_modal_size_value: 'modal-xl' } }) do
      inline_svg("icons/#{icon}.svg", width: '50px', height: '50px')
    end
  end

  def concept_properties2hash(properties)
    properties_data = {}
    keys = properties.members
    keys.each do |key|
      next if properties[key].nil? # ignore :context and :links when nil.

      k = key.to_s if key.kind_of?(Symbol)
      k ||= key.to_s

      resolved_label = resolve_property_label(k)
      label = resolved_label.presence || local_name_from_iri(k)

      begin
        # Try to simplify the property values, when they are a struct.
        if properties[key].is_a?(OpenStruct)
          values = language_hash(properties[key])
        else
          values = properties[key].map { |v| v.string }
        end
      rescue
        # Each value is probably a simple datatype already.
        values = properties[key]
      end
      data = { :key => key, :values => values, :label => label }
      prop_key = properties_data.key?(label) ? "#{label}__#{key}" : label
      properties_data[prop_key] = data
    end
    properties_data
  end

  # shortcut: bounded per-request lookup misses (20) with local-name fallback; upgrade when ontologies_api provides a bulk property-label endpoint.
  def resolve_property_label(iri)
    return nil unless iri.to_s.start_with?('http')
    return nil if @acronym.to_s.strip.empty?
    return nil unless defined?(LinkedData::Client::HTTP)

    origin = api_origin.to_s
    cache_key = [origin, @acronym.to_s, iri.to_s]
    cache = property_labels_cache

    if cache.key?(cache_key)
      return cache[cache_key]
    end

    if property_label_miss_count >= MAX_PROPERTY_LABEL_MISSES_PER_REQUEST
      cache[cache_key] = nil
      return nil
    end

    path = "/ontologies/#{@acronym}/properties/#{CGI.escape(iri.to_s)}/label"
    begin
      response = LinkedData::Client::HTTP.get(path)
      label = if response.respond_to?(:label)
                response.label
              elsif response.is_a?(Hash)
                response['label'] || response[:label]
              end
      if label.present? && label.is_a?(String) && !label.strip.empty?
        cache[cache_key] = label.strip
      else
        increment_property_label_miss_count!
        cache[cache_key] = nil
      end
    rescue Exception => e
      raise if fatal_exception?(e)
      increment_property_label_miss_count!
      cache[cache_key] = nil
    end

    cache[cache_key]
  end

  def request_env
    req = Thread.current[:request]
    req.env if req.respond_to?(:env) && req.env.is_a?(Hash)
  end

  def property_labels_cache
    if (env = request_env)
      env[PROPERTY_LABEL_CACHE_ENV_KEY] ||= {}
    else
      @instance_property_labels_cache ||= {}
    end
  end

  def property_label_miss_count
    if (env = request_env)
      env[PROPERTY_LABEL_MISS_ENV_KEY] ||= 0
    else
      @instance_property_label_miss_count ||= 0
    end
  end

  def increment_property_label_miss_count!
    if (env = request_env)
      env[PROPERTY_LABEL_MISS_ENV_KEY] = (env[PROPERTY_LABEL_MISS_ENV_KEY] || 0) + 1
    else
      @instance_property_label_miss_count = (@instance_property_label_miss_count || 0) + 1
    end
  end

  def api_origin
    (defined?(LinkedData::Client) && LinkedData::Client.respond_to?(:settings) && LinkedData::Client.settings&.rest_url) ||
      (defined?($REST_URL) && $REST_URL) ||
      ''
  end

  def fatal_exception?(exception)
    exception.is_a?(SystemExit) ||
      exception.is_a?(Interrupt) ||
      exception.is_a?(SignalException) ||
      exception.is_a?(NoMemoryError) ||
      (defined?(fatal) && exception.is_a?(fatal))
  end

  def local_name_from_iri(iri)
    k = iri.to_s.gsub(/.*#/, '').gsub(/.*\//, '')
    k.empty? ? iri.to_s : k
  end

  def exclude_relation?(relation_to_check, ontology = nil)
    excluded_relations = ["type", "rdf:type", "[R]", "SuperClass", "InstanceCount"]

    # Show or hide property based on the property and ontology settings
    if ontology
      # TODO_REV: Handle obsolete classes
      # Hide owl:deprecated if a user has set class or property based obsolete checking
      # if !ontology.obsoleteParent.nil? && relation_to_check.include?("owl:deprecated") || !ontology.obsoleteProperty.nil? && relation_to_check.include?("owl:deprecated")
      #   return true
      # end
    end

    excluded_relations.each do |relation|
      return true if relation_to_check.is_a?(Array) && relation_to_check.include?(relation)
    end
    return false
  end

  def remove_owl_notation(string)
    # TODO_REV: No OWL notation, but should we modify the IRI?
    return string

    unless string.nil?
      strings = string.split(":")
      if strings.size < 2
        # return string.titleize
        return string
      else
        # return strings[1].titleize
        return strings[1]
      end
    end
  end

  def convert_dates(hash)
    hash.transform_values do |property|
      if property[:key].to_s.include?("http://purl.org/dc/terms/created") || property[:key].to_s.include?("http://purl.org/dc/terms/modified")
        value = property[:values].first
        parsed_date = l(Date.parse(value), format: :monthfull_day_year.to_sym) rescue value
        property[:values] = [parsed_date]
      end
      property
    end
  end

end
