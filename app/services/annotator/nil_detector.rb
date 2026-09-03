# frozen_string_literal: true

require "digest"

module Annotator
  class NilDetector < ApplicationService
    DEFAULT_MARGIN_THRESHOLD = 0.08
    DEFAULT_MIN_CONFIDENCE = 0.50

    attr_reader :candidates, :span_text, :options

    def self.detect(candidates, span_text, options = {})
      new(candidates, span_text, options).call
    end

    def initialize(candidates, span_text, options = {})
      @candidates = Array(candidates)
      @span_text = span_text.to_s.strip
      @options = options
      @margin_threshold = (options[:margin_threshold] || DEFAULT_MARGIN_THRESHOLD).to_f
      @min_confidence = (options[:min_confidence] || DEFAULT_MIN_CONFIDENCE).to_f
    end

    def call
      if @candidates.empty?
        return build_nil_result("no_candidates", 0.0, 0.0)
      end

      sorted_candidates = @candidates.sort_by { |c| -(extract_score(c)) }
      top_candidate = sorted_candidates[0]
      top_score = extract_score(top_candidate)

      # Check for low confidence
      if top_score < @min_confidence
        return build_nil_result("low_confidence", top_score, 0.0, top_candidate)
      end

      # If multiple candidates, check ambiguity margin s1 - s2
      if sorted_candidates.length > 1
        second_score = extract_score(sorted_candidates[1])
        margin = (top_score - second_score).round(4)
        if margin < @margin_threshold
          return build_nil_result("high_ambiguity", top_score, margin, top_candidate)
        end
      else
        margin = 1.0
      end

      # Not a NIL - standard candidate accepted/reviewed
      {
        nil: false,
        decision: ConfidenceCalibrator.decision_for(top_score),
        top_candidate: top_candidate,
        margin: margin,
        confidence: top_score.round(4)
      }
    end

    private

    def extract_score(cand)
      if cand.is_a?(Hash)
        (cand[:probability] || cand["probability"] || cand[:score] || cand["score"] || 0.5).to_f
      elsif cand.respond_to?(:probability)
        cand.probability.to_f
      elsif cand.respond_to?(:score)
        cand.score.to_f
      else
        0.5
      end
    end

    def build_nil_result(reason, confidence, margin, top_candidate = nil)
      provisional_hash = Digest::SHA1.hexdigest("#{@span_text}_#{reason}")[0..9]
      provisional_curie = "NIL:#{provisional_hash.upcase}"

      {
        nil: true,
        decision: ConfidenceCalibrator::DECISION_ABSTAIN,
        reason: reason,
        confidence: confidence.round(4),
        margin: margin.round(4),
        proposal: {
          curie: provisional_curie,
          surface_form: @span_text,
          suggested_label: format_label(@span_text),
          reason: reason,
          top_conflicting_candidate: top_candidate,
          status: "proposed_nil"
        }
      }
    end

    def format_label(text)
      return "" if text.empty?

      # If all upper-case acronym, keep it, otherwise capitalize words
      if text == text.upcase && text.length <= 6
        text
      else
        text.split.map(&:capitalize).join(" ")
      end
    end
  end
end
