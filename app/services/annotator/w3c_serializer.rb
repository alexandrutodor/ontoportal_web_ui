# frozen_string_literal: true

require "securerandom"
require "time"

module Annotator
  class W3cSerializer < ApplicationService
    CONTEXT_URL = "http://www.w3.org/ns/anno.jsonld"

    attr_reader :annotations, :text, :options

    def self.serialize(annotations, text, options = {})
      new(annotations, text, options).call
    end

    def initialize(annotations, text = "", options = {})
      @annotations = Array(annotations)
      @text = text.to_s
      @options = options
      @source_id = options[:source_id] || "urn:ontoportal:document:#{SecureRandom.uuid}"
      @collection_id = options[:collection_id] || "urn:ontoportal:anno-collection:#{SecureRandom.uuid}"
    end

    def call
      items = @annotations.map do |anno|
        serialize_annotation(anno)
      end.compact

      {
        "@context" => CONTEXT_URL,
        "id" => @collection_id,
        "type" => "AnnotationCollection",
        "total" => items.length,
        "creator" => {
          "id" => "https://ontoportal.org",
          "name" => "OntoPortal Annotator 3.0"
        },
        "generated" => Time.now.utc.iso8601,
        "items" => items
      }
    end

    private

    def serialize_annotation(anno)
      return nil unless anno.is_a?(Hash)

      anno_id = "urn:uuid:#{SecureRandom.uuid}"
      annotated_class = anno["annotatedClass"] || anno[:annotatedClass] || {}
      concept_id = annotated_class["@id"] || annotated_class[:id] || annotated_class[:class] || ""
      pref_label = annotated_class["prefLabel"] || annotated_class[:prefLabel] || ""
      ontology = extract_ontology(annotated_class)
      sem_types = Array(annotated_class["semantic_types"] || annotated_class[:semantic_types])

      annotations_spans = anno["annotations"] || anno[:annotations] || []
      first_span = annotations_spans.first || {}

      # Offsets in BioPortal annotator are 1-indexed
      from_1 = (first_span["from"] || first_span[:from] || 1).to_i
      to_1 = (first_span["to"] || first_span[:to] || from_1).to_i

      start_pos = [from_1 - 1, 0].max
      end_pos = [to_1, start_pos + 1].max

      quote = anno["quote"] || first_span["text"] || extract_quote(start_pos, end_pos)
      prefix, suffix = extract_quote_context(start_pos, end_pos, anno)

      confidence = (anno["confidence"] || 0.8).to_f.round(4)
      decision = anno["decision"] || ConfidenceCalibrator::DECISION_ACCEPT
      tier = anno["tier"] || "fast"

      body = {
        "type" => "SpecificResource",
        "purpose" => "identifying",
        "source" => concept_id,
        "prefLabel" => pref_label,
        "ontology" => ontology,
        "confidence" => confidence,
        "decision" => decision,
        "tier" => tier
      }

      body["semanticTypes"] = sem_types if sem_types.any?
      body["nilProposal"] = anno["nil_proposal"] if anno["nil_proposal"]

      selectors = [
        {
          "type" => "TextPositionSelector",
          "start" => start_pos,
          "end" => end_pos
        },
        {
          "type" => "TextQuoteSelector",
          "exact" => quote,
          "prefix" => prefix,
          "suffix" => suffix
        }
      ]

      {
        "id" => anno_id,
        "type" => "Annotation",
        "motivation" => "tagging",
        "created" => Time.now.utc.iso8601,
        "body" => body,
        "target" => {
          "source" => @source_id,
          "selector" => selectors
        }
      }
    end

    def extract_ontology(annotated_class)
      ont = annotated_class["ontology"] || annotated_class[:ontology]
      if ont.is_a?(Hash)
        ont["acronym"] || ont[:acronym] || ont["name"] || ont[:name] || ""
      elsif ont.is_a?(String)
        ont
      elsif annotated_class["links"] && annotated_class["links"]["ontology"]
        annotated_class["links"]["ontology"]
      else
        ""
      end
    end

    def extract_quote(start_pos, end_pos)
      return "" if @text.empty?

      len = [end_pos - start_pos, 0].max
      @text[start_pos, len] || ""
    end

    def extract_quote_context(start_pos, end_pos, anno)
      # Check if context already calculated
      if anno["context"] && anno["context"]["prefix"]
        return [anno["context"]["prefix"], anno["context"]["suffix"] || ""]
      end

      return ["", ""] if @text.empty?

      prefix_start = [start_pos - 40, 0].max
      prefix = @text[prefix_start, start_pos - prefix_start] || ""

      suffix_end = [end_pos + 40, @text.length].min
      suffix = @text[end_pos, suffix_end - end_pos] || ""

      [prefix, suffix]
    end
  end
end
