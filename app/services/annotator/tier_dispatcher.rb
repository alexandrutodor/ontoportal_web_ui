# frozen_string_literal: true

module Annotator
  class TierDispatcher < ApplicationService
    TIER_FAST = "fast"
    TIER_BALANCED = "balanced"
    TIER_ASSURANCE = "assurance"

    TIER_ALIASES = {
      "fast" => TIER_FAST,
      "lexical" => TIER_FAST,
      "lexical-fast" => TIER_FAST,
      "balanced" => TIER_BALANCED,
      "contextual" => TIER_BALANCED,
      "contextual-balanced" => TIER_BALANCED,
      "assurance" => TIER_ASSURANCE,
      "high_assurance" => TIER_ASSURANCE,
      "high-assurance" => TIER_ASSURANCE
    }.freeze

    attr_reader :text, :raw_annotations, :options, :tier

    def self.normalize_tier(raw_tier)
      return TIER_FAST if raw_tier.nil? || raw_tier.to_s.strip.empty?

      TIER_ALIASES[raw_tier.to_s.strip.downcase] || TIER_FAST
    end

    def initialize(text, raw_annotations = [], options = {})
      @text = text.to_s
      @raw_annotations = Array(raw_annotations)
      @options = options
      @tier = self.class.normalize_tier(options[:tier])
    end

    def call
      processed_annotations = case @tier
                              when TIER_BALANCED
                                ContextualService.call(@text, @raw_annotations, @options)
                              when TIER_ASSURANCE
                                HighAssuranceService.call(@text, @raw_annotations, @options)
                              else
                                LexicalService.call(@text, @raw_annotations, @options)
                              end

      summary = calculate_summary(processed_annotations)
      nil_proposals = extract_nil_proposals(processed_annotations)

      {
        tier: @tier,
        annotations: processed_annotations,
        summary: summary,
        nil_proposals: nil_proposals
      }
    end

    private

    def calculate_summary(annotations)
      summary = {
        total: annotations.length,
        accept: 0,
        review: 0,
        abstain: 0
      }

      annotations.each do |anno|
        decision = anno["decision"] || anno[:decision] || ConfidenceCalibrator::DECISION_ABSTAIN
        case decision
        when ConfidenceCalibrator::DECISION_ACCEPT
          summary[:accept] += 1
        when ConfidenceCalibrator::DECISION_REVIEW
          summary[:review] += 1
        else
          summary[:abstain] += 1
        end
      end

      summary
    end

    def extract_nil_proposals(annotations)
      proposals = []
      annotations.each do |anno|
        if anno["nil_proposal"]
          proposals << anno["nil_proposal"]
        end
      end
      proposals.uniq { |p| p[:curie] || p["curie"] || p[:surface_form] || p["surface_form"] }
    end
  end
end
