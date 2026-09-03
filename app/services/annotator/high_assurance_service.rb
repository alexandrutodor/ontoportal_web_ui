# frozen_string_literal: true

module Annotator
  class HighAssuranceService < ApplicationService
    attr_reader :text, :raw_annotations, :options

    def initialize(text, raw_annotations = [], options = {})
      @text = text.to_s
      @raw_annotations = Array(raw_annotations)
      @options = options
      @required_semantic_types = Array(options[:semantic_types]).reject(&:empty?)
      @allowed_ontologies = Array(options[:ontologies]).reject(&:empty?)
    end

    def call
      # Start with balanced contextual results
      contextual_results = ContextualService.call(@text, @raw_annotations, @options.merge(tier: "assurance"))

      processed = contextual_results.map do |item|
        apply_symbolic_constraints(item)
      end

      processed
    end

    private

    def apply_symbolic_constraints(item)
      annotated_class = item["annotatedClass"] || item[:annotatedClass] || {}
      class_id = (annotated_class["@id"] || annotated_class[:id] || "").to_s
      cls_sem_types = Array(annotated_class["semantic_types"] || annotated_class[:semantic_types])
      ontology_uri = (annotated_class["links"] ? annotated_class["links"]["ontology"] : nil) || ""

      checks_passed = true
      failure_reasons = []

      # Constraint 1: Class ID must be well-formed URI
      unless class_id.start_with?("http://", "https://", "urn:")
        checks_passed = false
        failure_reasons << "malformed_concept_uri"
      end

      # Constraint 2: Semantic types constraint
      if @required_semantic_types.any?
        has_matching_type = cls_sem_types.any? { |st| @required_semantic_types.include?(st) }
        unless has_matching_type
          checks_passed = false
          failure_reasons << "semantic_type_mismatch"
        end
      end

      # Constraint 3: Disallow empty/blank prefLabel
      pref_label = (annotated_class["prefLabel"] || annotated_class[:prefLabel] || "").to_s.strip
      if pref_label.empty?
        checks_passed = false
        failure_reasons << "missing_pref_label"
      end

      item["tier"] = "assurance"
      item["symbolic_checks_passed"] = checks_passed

      if checks_passed
        # Boost confidence under high-assurance symbolic validation
        boosted_prob = ((item["confidence"] || 0.8) * 1.05).clamp(0.0, 1.0).round(4)
        item["confidence"] = boosted_prob
        item["decision"] = ConfidenceCalibrator.decision_for(
          boosted_prob,
          @options[:accept_threshold] || 0.85, # Stricter accept threshold for assurance
          @options[:review_threshold] || 0.60
        )
      else
        item["failure_reasons"] = failure_reasons
        item["confidence"] = [item["confidence"] || 0.5, 0.45].min.round(4)
        item["decision"] = ConfidenceCalibrator::DECISION_ABSTAIN
        quote = item["quote"] || ""
        item["nil_proposal"] = {
          curie: "NIL:SANITY_FAIL",
          surface_form: quote,
          reason: "symbolic_constraint_violation",
          details: failure_reasons
        }
      end

      item
    end
  end
end
