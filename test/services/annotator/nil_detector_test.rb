# frozen_string_literal: true

begin
  require_relative "../../test_helper_standalone"
rescue LoadError
  require "test_helper"
end

class NilDetectorTest < ActiveSupport::TestCase
  test "returns nil proposal when candidate list is empty" do
    result = Annotator::NilDetector.detect([], "unknown syndrome")

    assert_equal true, result[:nil]
    assert_equal "abstain", result[:decision]
    assert_equal "no_candidates", result[:reason]
    assert !result[:proposal].nil?
    assert_match(/^NIL:/, result[:proposal][:curie])
    assert_equal "Unknown Syndrome", result[:proposal][:suggested_label]
  end

  test "returns nil proposal when top candidate has low confidence" do
    candidates = [{ "score" => 0.2, "prefLabel" => "Hypothetical Term" }]
    result = Annotator::NilDetector.detect(candidates, "atypical lesion")

    assert_equal true, result[:nil]
    assert_equal "low_confidence", result[:reason]
    assert_equal "abstain", result[:decision]
    assert !result[:proposal].nil?
  end

  test "returns nil proposal when candidate margin is within ambiguity threshold" do
    candidates = [
      { "score" => 0.82, "prefLabel" => "Diabetes Type 1" },
      { "score" => 0.80, "prefLabel" => "Diabetes Type 2" }
    ]
    # Margin is 0.02 < 0.08 default threshold
    result = Annotator::NilDetector.detect(candidates, "diabetes")

    assert_equal true, result[:nil]
    assert_equal "high_ambiguity", result[:reason]
    assert_equal "abstain", result[:decision]
  end

  test "accepts high-confidence decisive top candidate" do
    candidates = [
      { "score" => 0.95, "prefLabel" => "Malignant Melanoma" },
      { "score" => 0.40, "prefLabel" => "Skin Lesion" }
    ]
    result = Annotator::NilDetector.detect(candidates, "melanoma")

    assert_equal false, result[:nil]
    assert_equal "accept", result[:decision]
    assert_equal 0.95, result[:confidence]
    assert_equal 0.55, result[:margin]
  end
end
