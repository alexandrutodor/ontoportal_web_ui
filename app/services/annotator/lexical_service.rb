# frozen_string_literal: true

module Annotator
  class LexicalService < ApplicationService
    MATCH_WEIGHTS = {
      "PREF" => 1.0,
      "SYN" => 0.85,
      "PARTIAL" => 0.60
    }.freeze

    attr_reader :text, :raw_annotations, :options

    def initialize(text, raw_annotations = [], options = {})
      @text = text.to_s
      @raw_annotations = Array(raw_annotations)
      @options = options
      @temperature = (options[:temperature] || 1.0).to_f
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

      # Compute match score based on matchType and span length
      match_type = extract_match_type(annotations_list)
      base_weight = MATCH_WEIGHTS[match_type] || 0.80

      calibration = ConfidenceCalibrator.calibrate(base_weight, {
        temperature: @temperature,
        tier: "fast",
        accept_threshold: @options[:accept_threshold] || ConfidenceCalibrator::DEFAULT_ACCEPT_THRESHOLD,
        review_threshold: @options[:review_threshold] || ConfidenceCalibrator::DEFAULT_REVIEW_THRESHOLD
      })

      item["tier"] = "fast"
      item["confidence"] = calibration[:probability]
      item["decision"] = calibration[:decision]
      item["matchType"] = match_type

      # Extract quote text if present in annotations list
      if annotations_list.any?
        first_span = annotations_list.first
        from = (first_span["from"] || first_span[:from] || 1).to_i
        to = (first_span["to"] || first_span[:to] || from).to_i
        item["quote"] = extract_quote(from, to)
      end

      item
    end

    def extract_match_type(spans)
      return "PREF" if spans.empty?

      types = spans.map { |s| (s["matchType"] || s[:matchType]).to_s.upcase }
      if types.include?("PREF")
        "PREF"
      elsif types.include?("SYN")
        "SYN"
      else
        types.first || "PREF"
      end
    end

    def extract_quote(from_pos, to_pos)
      # 1-indexed character positions from BioPortal annotator
      idx_start = [from_pos - 1, 0].max
      idx_len = [to_pos - from_pos + 1, 1].max
      @text[idx_start, idx_len] || ""
    end
  end
end
