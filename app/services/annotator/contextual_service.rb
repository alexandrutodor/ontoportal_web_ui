# frozen_string_literal: true

module Annotator
  class ContextualService < ApplicationService
    CONTEXT_WINDOW = 120

    attr_reader :text, :raw_annotations, :options

    def initialize(text, raw_annotations = [], options = {})
      @text = text.to_s
      @raw_annotations = Array(raw_annotations)
      @options = options
      @window_size = (options[:context_window] || CONTEXT_WINDOW).to_i
      @temperature = (options[:temperature] || 0.9).to_f
    end

    def call
      processed = @raw_annotations.map do |anno|
        process_annotation(anno)
      end.compact

      processed
    end

    private

    def process_annotation(anno)
      return nil unless anno.is_a?(Hash)

      item = anno.deep_dup rescue Marshal.load(Marshal.dump(anno))
      annotations_list = item["annotations"] || item[:annotations] || []

      first_span = annotations_list.first || {}
      from = (first_span["from"] || first_span[:from] || 1).to_i
      to = (first_span["to"] || first_span[:to] || from).to_i

      quote = extract_quote(from, to)
      prefix, suffix = extract_context_window(from, to)

      match_type = (first_span["matchType"] || first_span[:matchType] || "PREF").to_s.upcase
      base_weight = match_type == "PREF" ? 1.0 : 0.85

      # Calculate contextual relevance score based on surrounding sentence cues
      context_score = compute_contextual_score(quote, prefix, suffix, item)
      combined_score = (0.55 * base_weight + 0.45 * context_score).clamp(0.0, 1.0)

      # Calibrate combined score
      calibration = ConfidenceCalibrator.calibrate(combined_score, {
        temperature: @temperature,
        tier: "balanced",
        accept_threshold: @options[:accept_threshold] || ConfidenceCalibrator::DEFAULT_ACCEPT_THRESHOLD,
        review_threshold: @options[:review_threshold] || ConfidenceCalibrator::DEFAULT_REVIEW_THRESHOLD
      })

      # Run NIL detection for ambiguity or low confidence
      nil_check = NilDetector.detect([item.merge(probability: calibration[:probability])], quote, @options)

      item["tier"] = "balanced"
      item["confidence"] = calibration[:probability]
      item["decision"] = nil_check[:nil] ? ConfidenceCalibrator::DECISION_ABSTAIN : calibration[:decision]
      item["quote"] = quote
      item["context"] = {
        "prefix" => prefix,
        "suffix" => suffix,
        "context_score" => context_score.round(4)
      }

      if nil_check[:nil]
        item["nil_proposal"] = nil_check[:proposal]
      end

      item
    end

    def extract_quote(from_pos, to_pos)
      idx_start = [from_pos - 1, 0].max
      idx_len = [to_pos - from_pos + 1, 1].max
      @text[idx_start, idx_len] || ""
    end

    def extract_context_window(from_pos, to_pos)
      idx_start = [from_pos - 1, 0].max
      idx_end = [to_pos, idx_start + 1].max

      pref_start = [idx_start - @window_size, 0].max
      pref_len = idx_start - pref_start
      prefix = @text[pref_start, pref_len] || ""

      suffix = @text[idx_end, @window_size] || ""

      [prefix, suffix]
    end

    def compute_contextual_score(quote, prefix, suffix, item)
      score = 0.75

      # Bonus if quote matches whole word boundary
      is_whole_word = (prefix.empty? || prefix =~ /\s|[[:punct:]]$/) &&
                      (suffix.empty? || suffix =~ /^\s|[[:punct:]]/)
      score += 0.15 if is_whole_word

      # Label or synonyms match
      annotated_class = item["annotatedClass"] || item[:annotatedClass] || {}
      pref_label = (annotated_class["prefLabel"] || annotated_class[:prefLabel] || "").to_s.downcase

      if pref_label == quote.downcase
        score += 0.10
      end

      # Penalty for ultra-short 1-2 char acronyms without capital letters
      if quote.length <= 2 && quote != quote.upcase
        score -= 0.25
      end

      score.clamp(0.1, 1.0)
    end
  end
end
