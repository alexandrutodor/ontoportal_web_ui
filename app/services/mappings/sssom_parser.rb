# frozen_string_literal: true

require 'yaml'
require 'csv'
require 'ostruct'

module Mappings
  class SssomParser
    DEFAULT_CURIE_MAP = {
      'skos' => 'http://www.w3.org/2004/02/skos/core#',
      'owl' => 'http://www.w3.org/2002/07/owl#',
      'rdfs' => 'http://www.w3.org/2000/01/rdf-schema#',
      'rdf' => 'http://www.w3.org/1999/02/22-rdf-syntax-ns#',
      'semapv' => 'https://w3id.org/semapv/vocab/',
      'qudt' => 'http://qudt.org/schema/qudt/',
      'unit' => 'http://qudt.org/vocab/unit/',
      'om' => 'http://www.ontology-of-units-of-measure.org/resource/om-2/'
    }.freeze

    REQUIRED_FIELDS = %w[subject_id predicate_id object_id mapping_justification].freeze

    def self.parse(input)
      new(input).parse
    end

    def initialize(input)
      @content = input.respond_to?(:read) ? input.read : input.to_s
    end

    def parse
      metadata_lines = []
      tsv_lines = []

      @content.each_line do |line|
        stripped = line.strip
        next if stripped.empty?

        if stripped.start_with?('#')
          # YAML header line
          yaml_content = stripped.sub(/^#\s?/, '')
          metadata_lines << yaml_content unless yaml_content.strip.empty?
        else
          tsv_lines << line
        end
      end

      metadata = parse_yaml_metadata(metadata_lines.join("\n"))
      curie_map = DEFAULT_CURIE_MAP.merge(metadata['curie_map'] || {})

      mappings, errors = parse_tsv_data(tsv_lines.join, curie_map)

      OpenStruct.new(
        metadata: metadata,
        curie_map: curie_map,
        mappings: mappings,
        errors: errors,
        valid?: errors.empty?
      )
    end

    private

    def parse_yaml_metadata(yaml_str)
      return {} if yaml_str.strip.empty?

      parsed = YAML.safe_load(yaml_str, permitted_classes: [Date, Time])
      parsed.is_a?(Hash) ? parsed : {}
    rescue StandardError => e
      { 'parse_error' => "Invalid YAML metadata header: #{e.message}" }
    end

    def parse_tsv_data(tsv_str, curie_map)
      mappings = []
      errors = []

      return [mappings, errors] if tsv_str.strip.empty?

      begin
        csv = CSV.parse(tsv_str, col_sep: "\t", headers: true, skip_blanks: true)
      rescue StandardError => e
        errors << "TSV parsing error: #{e.message}"
        return [mappings, errors]
      end

      # Validate headers
      headers = csv.headers.map(&:to_s).map(&:strip)
      missing_headers = REQUIRED_FIELDS - headers
      unless missing_headers.empty?
        errors << "Missing required SSSOM fields: #{missing_headers.join(', ')}"
        return [mappings, errors]
      end

      csv.each_with_index do |row, index|
        line_no = index + 2 # Header is line 1
        record = row.to_h.transform_keys { |k| k.to_s.strip }
                         .transform_values { |v| v.is_a?(String) ? v.strip : v }

        # Check required row values
        missing_row_vals = REQUIRED_FIELDS.select { |f| record[f].nil? || record[f].empty? }
        if missing_row_vals.any?
          errors << "Line #{line_no}: missing required values for #{missing_row_vals.join(', ')}"
          next
        end

        # Expand CURIEs to full URIs if applicable
        expanded_subject = expand_curie(record['subject_id'], curie_map)
        expanded_predicate = expand_curie(record['predicate_id'], curie_map)
        expanded_object = expand_curie(record['object_id'], curie_map)

        confidence_val = record['confidence'] ? Float(record['confidence'], exception: false) : nil

        mappings << OpenStruct.new(
          subject_id: record['subject_id'],
          subject_uri: expanded_subject,
          subject_label: record['subject_label'],
          predicate_id: record['predicate_id'],
          predicate_uri: expanded_predicate,
          predicate_modifier: record['predicate_modifier'],
          object_id: record['object_id'],
          object_uri: expanded_object,
          object_label: record['object_label'],
          mapping_justification: record['mapping_justification'],
          mapping_provider: record['mapping_provider'],
          mapping_tool: record['mapping_tool'],
          confidence: confidence_val,
          comment: record['comment'],
          subject_source: record['subject_source'],
          object_source: record['object_source'],
          raw_data: record
        )
      end

      [mappings, errors]
    end

    def expand_curie(curie, curie_map)
      return curie unless curie.is_a?(String)
      return curie if curie.start_with?('http://', 'https://', 'urn:')

      prefix, local = curie.split(':', 2)
      return curie unless prefix && local && curie_map[prefix]

      "#{curie_map[prefix]}#{local}"
    end
  end
end
