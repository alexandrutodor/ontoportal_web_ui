# frozen_string_literal: true

require 'csv'
require 'digest'
require 'json'
require 'time'

class MetadataComparisonRecord
  ONTOLOGY_LEVEL_PROPERTIES = %w[
    acronym name viewingRestriction viewOf group hasDomain administeredBy sampleQueries
  ].freeze

  DEFAULT_PROPERTIES = %w[
    acronym name description version hasLicense released status modificationDate
  ].freeze

  PROPERTY_LABELS = {
    'acronym' => 'Acronym',
    'name' => 'Name',
    'viewingRestriction' => 'Visibility',
    'viewOf' => 'View Of',
    'group' => 'Groups',
    'hasDomain' => 'Categories',
    'administeredBy' => 'Administrators',
    'sampleQueries' => 'Sample Queries',
    'description' => 'Description',
    'version' => 'Version',
    'hasLicense' => 'License',
    'released' => 'Released',
    'status' => 'Status',
    'modificationDate' => 'Modification Date',
    'creationDate' => 'Creation Date',
    'contact' => 'Contact',
    'homepage' => 'Homepage',
    'publication' => 'Publication',
    'documentation' => 'Documentation',
    'keywords' => 'Keywords'
  }.freeze

  attr_reader :retrieval_timestamp, :selection_criteria, :property_ids,
              :properties_metadata, :records, :unknowns, :user, :ontology_acronym

  def self.build(params, user: nil)
    new(params, user: user)
  end

  def initialize(params, user: nil)
    @user = user
    @retrieval_timestamp = Time.now.utc
    params = params.respond_to?(:to_unsafe_h) ? params.to_unsafe_h : params.to_h

    @ontology_acronym = (params[:ontology] || params['ontology']).presence
    @raw_submission_ids = extract_submission_ids(params)
    @property_ids = extract_property_ids(params)
    @properties_metadata = build_properties_metadata(@property_ids)
    @unknowns = []
    @records = resolve_records
  end

  def to_json_package
    payload = {
      'selection_criteria' => selection_criteria,
      'properties' => properties_metadata,
      'records' => records
    }
    canonical_json = JSON.generate(payload)
    digest_value = Digest::SHA256.hexdigest(canonical_json)

    {
      'schema_version' => '1.0.0',
      'retrieval_timestamp' => retrieval_timestamp.iso8601,
      'selection_criteria' => selection_criteria,
      'properties' => properties_metadata,
      'records' => records,
      'unknowns' => unknowns,
      'digest' => {
        'algorithm' => 'SHA-256',
        'value' => digest_value,
        'serialization' => 'SHA-256 hex digest of canonical UTF-8 JSON serialization of {selection_criteria, properties, records}'
      }
    }
  end

  def to_csv
    CSV.generate(force_quotes: false) do |csv|
      headers = %w[row_key ontology_acronym submission_id status version_identifier] + property_ids
      csv << headers
      records.each do |rec|
        version_cell = if rec['version_identifier']
                         rec['version_identifier']
                       elsif rec['status'] == 'unavailable'
                         '[UNAVAILABLE]'
                       else
                         '[UNKNOWN]'
                       end

        row = [
          rec['row_key'],
          rec['ontology_acronym'],
          rec['submission_id'],
          rec['status'],
          version_cell
        ]

        property_ids.each do |prop|
          cell = (rec['values'] && rec['values'][prop]) || { 'state' => 'empty', 'value' => nil }
          case cell['state']
          when 'unavailable'
            row << '[UNAVAILABLE]'
          when 'unknown'
            row << '[UNKNOWN]'
          when 'empty'
            row << ''
          else
            row << format_csv_value(cell['value'])
          end
        end
        csv << row
      end
    end
  end

  def csv_filename
    base = ontology_acronym.presence || 'metadata'
    "#{base}_comparison_#{retrieval_timestamp.strftime('%Y%m%d_%H%M%S')}.csv"
  end

  def json_filename
    base = ontology_acronym.presence || 'metadata'
    "#{base}_comparison_#{retrieval_timestamp.strftime('%Y%m%d_%H%M%S')}.json"
  end

  def selection_criteria
    {
      'ontology' => ontology_acronym,
      'submission_ids' => @raw_submission_ids,
      'property_ids' => property_ids
    }
  end

  private

  def extract_submission_ids(params)
    raw = params[:submission_ids] || params['submission_ids'] ||
          params[:submission_id] || params['submission_id'] ||
          params[:submissions] || params['submissions']

    case raw
    when Array
      raw.map(&:to_s).reject(&:blank?)
    when String
      raw.split(',').map(&:strip).reject(&:blank?)
    else
      raw.present? ? [raw.to_s] : []
    end
  end

  def extract_property_ids(params)
    raw = params[:properties] || params['properties']
    props = case raw
            when Array
              raw.map(&:to_s).reject(&:blank?)
            when String
              raw.split(',').map(&:strip).reject(&:blank?)
            else
              []
            end
    props.empty? ? DEFAULT_PROPERTIES.dup : props.uniq
  end

  def build_properties_metadata(property_ids)
    property_ids.map do |prop|
      level = ONTOLOGY_LEVEL_PROPERTIES.include?(prop) ? 'ontology' : 'submission'
      base_label = PROPERTY_LABELS[prop] || prop.to_s.underscore.humanize
      note = level == 'ontology' ? 'current at capture' : 'submission-level'
      {
        'id' => prop,
        'level' => level,
        'label' => base_label,
        'note' => note
      }
    end
  end

  def resolve_records
    selections = normalize_selections
    ontology_cache = {}

    selections.map do |sel|
      acr = sel[:ontology_acronym]
      sub_id = sel[:submission_id]
      row_key = "#{acr}##{sub_id}"

      ontology = ontology_cache[acr] ||= fetch_ontology(acr)

      if ontology.nil?
        @unknowns << "Ontology #{acr} unavailable or access denied"
        build_unavailable_row(row_key, acr, sub_id, nil, "Ontology #{acr} not found or inaccessible")
      else
        ont_uri = ontology_uri(ontology, acr)
        submission = fetch_submission(ontology, sub_id)

        if submission.nil?
          @unknowns << "Submission #{sub_id} of #{acr} unavailable"
          build_unavailable_row(row_key, acr, sub_id, ont_uri, "Submission #{sub_id} not found")
        else
          build_available_row(row_key, acr, sub_id, ontology, ont_uri, submission)
        end
      end
    end
  end

  def normalize_selections
    if @raw_submission_ids.empty? && @ontology_acronym.present?
      # If no explicit submission id is provided, fetch latest for the default ontology
      ont = fetch_ontology(@ontology_acronym)
      latest = ont&.explore&.latest_submission(include: 'submissionId') rescue nil
      if latest&.submissionId.present?
        return [{ ontology_acronym: @ontology_acronym, submission_id: latest.submissionId.to_s }]
      end
    end

    @raw_submission_ids.map do |item|
      if item.include?('#')
        parts = item.split('#')
        { ontology_acronym: parts[0], submission_id: parts[1] }
      elsif item.include?(':')
        parts = item.split(':')
        { ontology_acronym: parts[0], submission_id: parts[1] }
      elsif @ontology_acronym.present?
        { ontology_acronym: @ontology_acronym, submission_id: item }
      else
        { ontology_acronym: item, submission_id: item }
      end
    end
  end

  def fetch_ontology(acronym)
    return nil if acronym.blank?
    LinkedData::Client::Models::Ontology.find_by_acronym(acronym)&.first rescue nil
  end

  def fetch_submission(ontology, submission_id)
    return nil if ontology.nil? || submission_id.blank?

    begin
      sub = ontology.explore.submissions({ include: 'all' }, submission_id)
      return nil if sub.nil? || (sub.respond_to?(:errors) && sub.errors.present?)
      sub
    rescue StandardError
      nil
    end
  end

  def ontology_uri(ontology, acronym)
    if ontology.respond_to?(:id) && ontology.id.present?
      ontology.id
    elsif ontology.respond_to?(:links) && ontology.links.is_a?(Hash) && ontology.links['self'].present?
      ontology.links['self']
    else
      "http://data.example.org/ontologies/#{acronym}"
    end
  end

  def submission_uri(submission, ont_uri, submission_id)
    if submission.respond_to?(:id) && submission.id.present?
      submission.id
    elsif submission.respond_to?(:links) && submission.links.is_a?(Hash) && submission.links['self'].present?
      submission.links['self']
    else
      "#{ont_uri}/submissions/#{submission_id}"
    end
  end

  def build_unavailable_row(row_key, acr, sub_id, ont_uri, error_message)
    values = {}
    property_ids.each do |prop|
      level = ONTOLOGY_LEVEL_PROPERTIES.include?(prop) ? 'ontology' : 'submission'
      values[prop] = {
        'level' => level,
        'state' => 'unavailable',
        'value' => nil
      }
    end

    {
      'row_key' => row_key,
      'ontology_acronym' => acr,
      'submission_id' => sub_id,
      'ontology_uri' => ont_uri,
      'submission_uri' => nil,
      'status' => 'unavailable',
      'error' => error_message,
      'version_identifier' => nil,
      'values' => values
    }
  end

  def build_available_row(row_key, acr, sub_id, ontology, ont_uri, submission)
    sub_uri = submission_uri(submission, ont_uri, sub_id)
    raw_version = extract_attribute_value(submission, 'version')
    version_id = (raw_version.present? && raw_version.to_s.downcase != 'unknown') ? raw_version.to_s : nil
    @unknowns << "Submission #{sub_id} upstream version unknown" if version_id.nil?

    values = {}
    property_ids.each do |prop|
      is_ontology = ONTOLOGY_LEVEL_PROPERTIES.include?(prop)
      level = is_ontology ? 'ontology' : 'submission'
      raw_val = is_ontology ? extract_attribute_value(ontology, prop) : extract_attribute_value(submission, prop)

      state = classify_value_state(prop, raw_val)
      values[prop] = {
        'level' => level,
        'state' => state,
        'value' => (state == 'present' ? raw_val : nil)
      }
    end

    {
      'row_key' => row_key,
      'ontology_acronym' => acr,
      'submission_id' => sub_id,
      'ontology_uri' => ont_uri,
      'submission_uri' => sub_uri,
      'status' => 'available',
      'error' => nil,
      'version_identifier' => version_id,
      'values' => values
    }
  end

  def extract_attribute_value(target, attribute)
    return nil if target.nil?

    attr_sym = attribute.to_sym
    val = if target.respond_to?(attr_sym)
            target.send(attr_sym)
          elsif target.respond_to?(:[])
            target[attribute] || target[attr_sym]
          elsif target.respond_to?(:to_h)
            h = target.to_h rescue {}
            h[attribute] || h[attr_sym]
          end

    normalize_raw_value(val)
  end

  def normalize_raw_value(val)
    return nil if val.nil?

    if val.is_a?(Array)
      val.map { |item| normalize_raw_value(item) }
    elsif val.is_a?(Hash)
      val.transform_keys(&:to_s)
    elsif val.respond_to?(:to_h) && !val.is_a?(String) && !val.is_a?(Numeric)
      h = val.to_h rescue val
      h.is_a?(Hash) ? h.transform_keys(&:to_s) : h
    else
      val
    end
  end

  def classify_value_state(property, val)
    if property.to_s == 'version' && (val.nil? || val.to_s.strip.empty? || val.to_s.downcase == 'unknown')
      'unknown'
    elsif val.nil?
      'empty'
    elsif val.respond_to?(:empty?) && val.empty?
      'empty'
    elsif val.is_a?(String) && val.strip.empty?
      'empty'
    else
      'present'
    end
  end

  def format_csv_value(val)
    return '' if val.nil?

    if val.is_a?(Array)
      val.map { |x| format_csv_value(x) }.join(' | ')
    elsif val.is_a?(Hash)
      if val.key?('@value')
        lang = val['@language'].present? ? "@#{val['@language']}" : ''
        "#{val['@value']}#{lang}"
      else
        val.to_json
      end
    else
      val.to_s
    end
  end
end
