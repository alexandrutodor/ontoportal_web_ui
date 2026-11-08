# frozen_string_literal: true

require 'digest'
require 'time'
require 'json'

class ScientificRunRecord
  SCHEMA_VERSION = '1.0.0'
  UNKNOWN = 'unknown'

  ANNOTATOR_TOOLS = %w[annotator annotatorplus ncbo_annotatorplus].freeze
  RECOMMENDER_TOOLS = %w[recommender].freeze
  VALID_TOOLS = (ANNOTATOR_TOOLS + RECOMMENDER_TOOLS).freeze

  DISALLOWED_KEY_PATTERNS = [
    /apikey/i, /api_key/i, /token/i, /password/i, /secret/i,
    /session/i, /cookie/i, /credential/i, /auth/i
  ].freeze

  attr_reader :tool, :schema_version, :timestamp, :source_portal, :service_version,
              :selected_settings, :effective_settings, :input_info, :captured_result

  def initialize(tool:, selected_settings:, effective_settings:, input_text:, captured_result:, source_portal: 'matportal', timestamp: nil)
    @tool = tool.to_s
    @schema_version = SCHEMA_VERSION
    @timestamp = timestamp || Time.now.utc.iso8601
    @source_portal = source_portal.to_s
    @service_version = UNKNOWN
    @selected_settings = selected_settings || {}
    @effective_settings = effective_settings || {}
    @input_info = build_input_info(input_text)
    @captured_result = captured_result || {}
  end

  def self.build_annotator_record(tool:, params:, effective_params:, results:, raw_annotations: nil, subdomain_filter: nil, text: '')
    selected = {
      ontologies: normalize_ontologies(params[:ontologies]),
      whole_word_only: boolean_param(params[:whole_word_only]),
      longest_only: boolean_param(params[:longest_only]),
      expand_mappings: boolean_param(params[:expand_mappings]),
      exclude_numbers: boolean_param(params[:exclude_numbers]),
      exclude_synonyms: boolean_param(params[:exclude_synonyms]),
      class_hierarchy_max_level: params[:class_hierarchy_max_level].presence || 'None',
      score: params[:score].presence || 'none',
      score_threshold: params[:score_threshold].present? ? params[:score_threshold].to_f : 0.0,
      confidence_threshold: params[:confidence_threshold].present? ? params[:confidence_threshold].to_f : 0.0,
      fast_context: boolean_param(params[:fast_context]),
      lemmatize: boolean_param(params[:lemmatize]),
      semantic_types: normalize_list(params[:semantic_types]),
      semantic_groups: normalize_list(params[:semantic_groups])
    }

    effective = {
      ontologies: normalize_ontologies(effective_params[:ontologies]),
      whole_word_only: boolean_param(effective_params[:whole_word_only]),
      longest_only: boolean_param(effective_params[:longest_only]),
      expand_mappings: boolean_param(effective_params[:expand_mappings]),
      exclude_numbers: boolean_param(effective_params[:exclude_numbers]),
      exclude_synonyms: boolean_param(effective_params[:exclude_synonyms]),
      class_hierarchy_max_level: effective_params[:class_hierarchy_max_level].presence || 'None',
      score: effective_params[:score].presence || 'none',
      score_threshold: effective_params[:score_threshold].present? ? effective_params[:score_threshold].to_f : 0.0,
      confidence_threshold: effective_params[:confidence_threshold].present? ? effective_params[:confidence_threshold].to_f : 0.0,
      fast_context: boolean_param(effective_params[:fast_context]),
      lemmatize: boolean_param(effective_params[:lemmatize]),
      semantic_types: normalize_list(effective_params[:semantic_types]),
      semantic_groups: normalize_list(effective_params[:semantic_groups])
    }

    captured = build_annotator_captured_results(results)

    new(
      tool: tool,
      selected_settings: selected,
      effective_settings: effective,
      input_text: text.to_s,
      captured_result: captured
    )
  end

  def self.build_recommender_record(params:, effective_params:, results:, raw_recommendations: nil, subdomain_filter: nil, input: '')
    selected = {
      input_type: params[:input_type].presence || '1',
      output_type: params[:output_type].presence || '1',
      wc: params[:wc].present? ? params[:wc].to_f : 0.55,
      wa: params[:wa].present? ? params[:wa].to_f : 0.15,
      wd: params[:wd].present? ? params[:wd].to_f : 0.15,
      ws: params[:ws].present? ? params[:ws].to_f : 0.15,
      max_elements_set: params[:max_elements_set].present? ? params[:max_elements_set].to_i : 3,
      ontologies: normalize_ontologies(params[:ontologies])
    }

    effective = {
      input_type: effective_params[:input_type].presence || '1',
      output_type: effective_params[:output_type].presence || '1',
      wc: effective_params[:wc].present? ? effective_params[:wc].to_f : 0.55,
      wa: effective_params[:wa].present? ? effective_params[:wa].to_f : 0.15,
      wd: effective_params[:wd].present? ? effective_params[:wd].to_f : 0.15,
      ws: effective_params[:ws].present? ? effective_params[:ws].to_f : 0.15,
      max_elements_set: effective_params[:max_elements_set].present? ? effective_params[:max_elements_set].to_i : 3,
      ontologies: normalize_ontologies(effective_params[:ontologies])
    }

    captured = build_recommender_captured_results(results)

    new(
      tool: 'recommender',
      selected_settings: selected,
      effective_settings: effective,
      input_text: input.to_s,
      captured_result: captured
    )
  end

  def to_h(include_input_text: true, include_results: true)
    input_data = {
      sha256: @input_info[:sha256],
      digest_serialization: @input_info[:digest_serialization],
      byte_size: @input_info[:byte_size],
      char_count: @input_info[:char_count],
      mode: include_input_text ? 'text' : 'digest'
    }
    input_data[:text] = @input_info[:text] if include_input_text

    record = {
      record_type: 'scientific_run_record',
      schema_version: @schema_version,
      tool: @tool,
      source_portal: @source_portal,
      timestamp: @timestamp,
      service_version: @service_version,
      settings: {
        selected: @selected_settings,
        effective: @effective_settings
      },
      input: input_data
    }

    record[:captured_result] = @captured_result if include_results
    record
  end

  def to_json(options = {})
    to_h(include_input_text: true, include_results: true).to_json(options)
  end

  def to_settings_only_json(options = {})
    to_h(include_input_text: false, include_results: true).to_json(options)
  end

  def self.validate_import(data, expected_tool: nil)
    record = data.is_a?(String) ? (JSON.parse(data) rescue nil) : data
    return { valid: false, error: 'invalid_json', message: 'Invalid record: file is not valid JSON.' } unless record.is_a?(Hash)

    version = record['schema_version'] || record[:schema_version]
    unless version.to_s.start_with?('1.')
      return { valid: false, error: 'unsupported_schema', message: "Unsupported schema version: #{version}." }
    end

    tool = (record['tool'] || record[:tool]).to_s
    unless VALID_TOOLS.include?(tool)
      return { valid: false, error: 'unsupported_tool', message: "Unsupported tool: record tool '#{tool}' is not recognized." }
    end

    if expected_tool && !tools_compatible?(expected_tool.to_s, tool)
      return { valid: false, error: 'tool_mismatch', message: "Unsupported tool: record tool '#{tool}' does not match expected '#{expected_tool}'." }
    end

    if contains_credentials?(record)
      return { valid: false, error: 'credentials_rejected', message: 'Rejected: record contains credential or authentication fields.' }
    end

    settings = record['settings'] || record[:settings] || {}
    if contains_foreign_urls?(settings)
      return { valid: false, error: 'foreign_url_rejected', message: 'Rejected: record contains foreign endpoint URLs.' }
    end

    {
      valid: true,
      tool: tool,
      schema_version: version,
      settings: settings['selected'] || settings[:selected] || settings['effective'] || settings[:effective] || {},
      input: record['input'] || record[:input] || {}
    }
  end

  def self.tools_compatible?(expected, actual)
    if ANNOTATOR_TOOLS.include?(expected)
      ANNOTATOR_TOOLS.include?(actual)
    elsif RECOMMENDER_TOOLS.include?(expected)
      RECOMMENDER_TOOLS.include?(actual)
    else
      expected == actual
    end
  end

  def self.contains_credentials?(obj)
    check = lambda do |val, key = ''|
      return true if key.to_s =~ /apikey|api_key|token|password|secret|credential|session|cookie|auth/i
      return false if val.nil?

      if val.is_a?(String)
        return true if val =~ /apikey=|api_key=/i
        return false
      end

      if val.is_a?(Hash)
        val.each { |k, v| return true if check.call(v, k) }
      elsif val.is_a?(Array)
        val.each { |v| return true if check.call(v, key) }
      end
      false
    end

    check.call(obj)
  end

  def self.contains_foreign_urls?(settings)
    check = lambda do |val|
      return false if val.nil?

      if val.is_a?(String)
        return true if val.strip =~ %r{\Ahttps?://}i
        return false
      end

      if val.is_a?(Hash)
        val.each_value { |v| return true if check.call(v) }
      elsif val.is_a?(Array)
        val.each { |v| return true if check.call(v) }
      end
      false
    end

    check.call(settings)
  end

  private

  def build_input_info(text)
    raw = text.to_s
    utf8_str = raw.encode('UTF-8', invalid: :replace, undef: :replace)
    {
      text: utf8_str,
      sha256: Digest::SHA256.hexdigest(utf8_str),
      digest_serialization: 'SHA-256 of raw UTF-8 input text bytes',
      byte_size: utf8_str.bytesize,
      char_count: utf8_str.length
    }
  end

  def self.boolean_param(val)
    return false if val.nil? || val == false || val == 'false' || val == 0 || val == '0'
    true
  end

  def self.normalize_ontologies(ont)
    return nil if ont.nil?
    if ont.is_a?(Array)
      ont.map { |o| o.to_s.split('/').last }.reject(&:empty?).join(',')
    else
      ont.to_s
    end
  end

  def self.normalize_list(val)
    return nil if val.nil?
    val.is_a?(Array) ? val.map(&:to_s) : val.to_s
  end

  def self.build_annotator_captured_results(results)
    items = (results || []).map do |row|
      cls_label = row.dig(:class, :text)
      cls_link = row.dig(:class, :link)
      ont_name = row.dig(:ontology, :text)
      ont_link = row.dig(:ontology, :link)

      contexts = Array(row[:context]).map do |ctx|
        if ctx.is_a?(Hash) && ctx[:child]
          {
            type: 'parent',
            level: ctx[:level]&.to_i,
            child_label: ctx.dig(:child, :text),
            child_link: ctx.dig(:child, :link)
          }
        else
          from = ctx.respond_to?(:from) ? ctx.from : (ctx.is_a?(Hash) ? ctx[:from] : nil)
          to = ctx.respond_to?(:to) ? ctx.to : (ctx.is_a?(Hash) ? ctx[:to] : nil)
          matched = ctx.respond_to?(:text) ? ctx.text : (ctx.is_a?(Hash) ? ctx[:text] : nil)
          {
            type: 'direct',
            from: from.nil? ? nil : from.to_i,
            to: to.nil? ? nil : to.to_i,
            matched_text: matched
          }
        end
      end

      score_num = row[:score].present? ? row[:score].to_f : nil

      {
        class_label: cls_label,
        class_id: cls_link,
        ontology_name: ont_name,
        ontology_link: ont_link,
        ontology_version: UNKNOWN,
        service_version: UNKNOWN,
        result_type: row[:type] || 'direct',
        score: score_num,
        annotations: contexts
      }
    end

    {
      representation: 'ui_snapshot',
      count: items.length,
      items: items
    }
  end

  def self.build_recommender_captured_results(results)
    items = (results || []).map do |row|
      onts = Array(row[:ontologies]).map { |o| o.is_a?(Hash) ? o[:acronym] : o.to_s }
      {
        ontologies: onts,
        ontology_version: UNKNOWN,
        service_version: UNKNOWN,
        highlighted: row[:highlighted] == true,
        scores: {
          final_score: row[:final_score].present? ? row[:final_score].to_f : 0.0,
          coverage_score: row[:coverage_score].present? ? row[:coverage_score].to_f : 0.0,
          acceptance_score: row[:acceptance_score].present? ? row[:acceptance_score].to_f : 0.0,
          detail_score: row[:details_score].present? ? row[:details_score].to_f : 0.0,
          specialization_score: row[:specialization_score].present? ? row[:specialization_score].to_f : 0.0
        },
        annotations_count: Array(row[:annotations]).length,
        annotations: Array(row[:annotations]).map { |a| { text: a[:text], class_id: a[:link] } }
      }
    end

    {
      representation: 'ui_snapshot',
      count: items.length,
      items: items
    }
  end
end
