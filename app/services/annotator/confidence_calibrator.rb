# frozen_string_literal: true

module Annotator
  class ConfidenceCalibrator < ApplicationService
    DEFAULT_ACCEPT_THRESHOLD = 0.80
    DEFAULT_REVIEW_THRESHOLD = 0.50
    DEFAULT_TEMPERATURE = 1.0

    DECISION_ACCEPT = "accept"
    DECISION_REVIEW = "review"
    DECISION_ABSTAIN = "abstain"

    attr_reader :score, :temperature, :accept_threshold, :review_threshold, :margin

    def self.calibrate(raw_score, options = {})
      new(raw_score, options).call
    end

    def self.decision_for(probability, accept_th = DEFAULT_ACCEPT_THRESHOLD, review_th = DEFAULT_REVIEW_THRESHOLD)
      prob = probability.to_f
      if prob >= accept_th
        DECISION_ACCEPT
      elsif prob >= review_th
        DECISION_REVIEW
      else
        DECISION_ABSTAIN
      end
    end

    def self.brier_score(probabilities, actuals)
      return 0.0 if probabilities.empty? || probabilities.length != actuals.length

      sum_sq = probabilities.zip(actuals).sum do |prob, actual|
        (prob.to_f - actual.to_f)**2
      end
      (sum_sq / probabilities.length.to_f).round(6)
    end

    def self.expected_calibration_error(probabilities, actuals, bins: 10)
      return 0.0 if probabilities.empty? || probabilities.length != actuals.length

      n = probabilities.length.to_f
      bin_size = 1.0 / bins
      total_ece = 0.0

      (0...bins).each do |b|
        bin_lower = b * bin_size
        bin_upper = (b + 1) * bin_size

        indices = probabilities.each_index.select do |i|
          p = probabilities[i]
          b == bins - 1 ? (p >= bin_lower && p <= bin_upper) : (p >= bin_lower && p < bin_upper)
        end

        next if indices.empty?

        bin_count = indices.length.to_f
        avg_prob = indices.sum { |i| probabilities[i] } / bin_count
        avg_actual = indices.sum { |i| actuals[i] } / bin_count

        total_ece += (bin_count / n) * (avg_prob - avg_actual).abs
      end

      total_ece.round(6)
    end

    def initialize(raw_score, options = {})
      @score = parse_score(raw_score)
      @temperature = (options[:temperature] || DEFAULT_TEMPERATURE).to_f
      @temperature = DEFAULT_TEMPERATURE if @temperature <= 0.0

      @accept_threshold = (options[:accept_threshold] || DEFAULT_ACCEPT_THRESHOLD).to_f
      @review_threshold = (options[:review_threshold] || DEFAULT_REVIEW_THRESHOLD).to_f
      @margin = options[:margin] ? options[:margin].to_f : nil
      @tier = options[:tier] || "fast"
    end

    def call
      prob = calculate_probability
      # If margin is provided and very low (ambiguous match), penalize probability
      if @margin && @margin < 0.05
        prob = (prob * 0.85).clamp(0.0, 1.0)
      end

      decision = self.class.decision_for(prob, @accept_threshold, @review_threshold)

      {
        raw_score: @score,
        probability: prob.round(4),
        decision: decision,
        temperature: @temperature,
        accept_threshold: @accept_threshold,
        review_threshold: @review_threshold,
        tier: @tier
      }
    end

    private

    def parse_score(val)
      return 0.5 if val.nil?
      return val.to_f if val.is_a?(Numeric)

      str = val.to_s.strip
      return 0.5 if str.empty?

      # If score is a string like "0.85" or "10"
      num = str.to_f
      num
    end

    def calculate_probability
      # If score is already bounded in [0.0, 1.0]
      if @score >= 0.0 && @score <= 1.0
        # Apply temperature scaling around midpoint 0.5
        logit = (@score - 0.5) * 6.0 / @temperature
        sigmoid(logit)
      else
        # For unbounded or integer-based scores (e.g. c-value 0..50+)
        # normalize via shifted logit
        scaled = @score / 10.0
        logit = (scaled - 1.0) / @temperature
        sigmoid(logit)
      end
    end

    def sigmoid(x)
      return 1.0 if x > 15.0
      return 0.0 if x < -15.0

      1.0 / (1.0 + Math.exp(-x))
    end
  end
end
