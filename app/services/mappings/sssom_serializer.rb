# frozen_string_literal: true

require 'yaml'
require 'csv'
require 'date'

module Mappings
  class SssomSerializer
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

    STANDARD_COLUMNS = %w[
      subject_id
      subject_label
      predicate_id
      object_id
      object_label
      mapping_justification
      confidence
      mapping_provider
      comment
    ].freeze

    def self.serialize(mappings, metadata: {})
      new(mappings, metadata: metadata).serialize
    end

    def initialize(mappings, metadata: {})
      @mappings = mappings || []
      @metadata = metadata || {}
      @curie_map = DEFAULT_CURIE_MAP.merge(@metadata[:curie_map] || @metadata['curie_map'] || {})
    end

    def serialize
      io = StringIO.new
      write_yaml_frontmatter(io)
      write_tsv_body(io)
      io.string
    end

    private

    def write_yaml_frontmatter(io)
      meta = {
        'mapping_set_id' => @metadata[:mapping_set_id] || @metadata['mapping_set_id'] || 'urn:uuid:ontoportal:mapping_set',
        'mapping_set_version' => @metadata[:mapping_set_version] || @metadata['mapping_set_version'] || '1.0',
        'mapping_set_title' => @metadata[:mapping_set_title] || @metadata['mapping_set_title'] || 'OntoPortal Mappings Export',
        'mapping_date' => @metadata[:mapping_date] || @metadata['mapping_date'] || Date.today.iso8601,
        'license' => @metadata[:license] || @metadata['license'] || 'https://creativecommons.org/publicdomain/zero/1.0/',
        'curie_map' => @curie_map
      }

      yaml_text = YAML.dump(meta).sub(/^---\s*\n/, '')
      yaml_text.each_line do |line|
        io.puts "# #{line}"
      end
    end

    def write_tsv_body(io)
      io.puts STANDARD_COLUMNS.join("\t")

      @mappings.each do |mapping|
        row = extract_row(mapping)
        io.puts STANDARD_COLUMNS.map { |col| sanitize_cell(row[col]) }.join("\t")
      end
    end

    def extract_row(mapping)
      if mapping.respond_to?(:classes) && mapping.classes.is_a?(Array) && mapping.classes.size >= 2
        source_cls = mapping.classes[0]
        target_cls = mapping.classes[1]
        relation = mapping.respond_to?(:relation) ? mapping.relation : 'skos:exactMatch'
        comment = mapping.respond_to?(:comment) ? mapping.comment : nil
        confidence = mapping.respond_to?(:confidence) ? mapping.confidence : 1.0
        provider = mapping.respond_to?(:source) ? mapping.source : 'OntoPortal'

        {
          'subject_id' => contract_uri(source_cls.respond_to?(:id) ? source_cls.id : source_cls.to_s),
          'subject_label' => source_cls.respond_to?(:prefLabel) ? source_cls.prefLabel : nil,
          'predicate_id' => contract_uri(relation),
          'object_id' => contract_uri(target_cls.respond_to?(:id) ? target_cls.id : target_cls.to_s),
          'object_label' => target_cls.respond_to?(:prefLabel) ? target_cls.prefLabel : nil,
          'mapping_justification' => 'semapv:ManualMappingCuration',
          'confidence' => confidence,
          'mapping_provider' => provider,
          'comment' => comment
        }
      elsif mapping.is_a?(Hash)
        {
          'subject_id' => contract_uri(mapping[:subject_id] || mapping['subject_id']),
          'subject_label' => mapping[:subject_label] || mapping['subject_label'],
          'predicate_id' => contract_uri(mapping[:predicate_id] || mapping['predicate_id'] || 'skos:exactMatch'),
          'object_id' => contract_uri(mapping[:object_id] || mapping['object_id']),
          'object_label' => mapping[:object_label] || mapping['object_label'],
          'mapping_justification' => mapping[:mapping_justification] || mapping['mapping_justification'] || 'semapv:ManualMappingCuration',
          'confidence' => mapping[:confidence] || mapping['confidence'] || 1.0,
          'mapping_provider' => mapping[:mapping_provider] || mapping['mapping_provider'] || 'OntoPortal',
          'comment' => mapping[:comment] || mapping['comment']
        }
      elsif mapping.respond_to?(:subject_id)
        {
          'subject_id' => contract_uri(mapping.subject_id),
          'subject_label' => mapping.respond_to?(:subject_label) ? mapping.subject_label : nil,
          'predicate_id' => contract_uri(mapping.respond_to?(:predicate_id) ? mapping.predicate_id : 'skos:exactMatch'),
          'object_id' => contract_uri(mapping.respond_to?(:object_id) ? mapping.object_id : nil),
          'object_label' => mapping.respond_to?(:object_label) ? mapping.object_label : nil,
          'mapping_justification' => mapping.respond_to?(:mapping_justification) ? mapping.mapping_justification : 'semapv:ManualMappingCuration',
          'confidence' => mapping.respond_to?(:confidence) ? mapping.confidence : 1.0,
          'mapping_provider' => mapping.respond_to?(:mapping_provider) ? mapping.mapping_provider : 'OntoPortal',
          'comment' => mapping.respond_to?(:comment) ? mapping.comment : nil
        }
      else
        {}
      end
    end

    def contract_uri(uri)
      return '' if uri.nil?
      uri_str = uri.to_s.strip

      @curie_map.each do |prefix, ns|
        if uri_str.start_with?(ns)
          local = uri_str.sub(ns, '')
          return "#{prefix}:#{local}"
        end
      end

      uri_str
    end

    def sanitize_cell(value)
      return '' if value.nil?
      # Remove newlines and tabs to keep valid TSV
      value.to_s.gsub(/[\r\n\t]+/, ' ').strip
    end
  end
end
