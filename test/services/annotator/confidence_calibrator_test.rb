# frozen_string_literal: true

begin
  require_relative "../../test_helper_standalone"
rescue LoadError
  require "test_helper"
end

class ConfidenceCalibratorTest < ActiveSupport::TestCase
  test "calibrates standard score within bounds [0.0, 1.0]" do
    result = Annotator::ConfidenceCalibrator.calibrate(0.85)

    assert_includes 0.0..1.0, result[:probability]
    assert_equal "accept", result[:decision]
    assert_equal 0.85, result[:raw_score]
  end

  test "classifies scores into accept, review, and abstain decisions" do
    high = Annotator::ConfidenceCalibrator.calibrate(0.95)
    medium = Annotator::ConfidenceCalibrator.calibrate(0.55)
    low = Annotator::ConfidenceCalibrator.calibrate(0.15)

    assert_equal "accept", high[:decision]
    assert_equal "review", medium[:decision]
    assert_equal "abstain", low[:decision]
  end

  test "handles temperature scaling" do
    sharp = Annotator::ConfidenceCalibrator.calibrate(0.7, temperature: 0.5)
    diffuse = Annotator::ConfidenceCalibrator.calibrate(0.7, temperature: 2.0)

    assert sharp[:probability] > diffuse[:probability]
  end

  test "penalizes probability when ambiguous margin is low" do
    unambiguous = Annotator::ConfidenceCalibrator.calibrate(0.85, margin: 0.25)
    ambiguous = Annotator::ConfidenceCalibrator.calibrate(0.85, margin: 0.02)

    assert unambiguous[:probability] > ambiguous[:probability]
  end

  test "calculates Brier score and ECE correctly" do
    predictions = [0.9, 0.8, 0.2, 0.1]
    actuals = [1.0, 1.0, 0.0, 0.0]

    brier = Annotator::ConfidenceCalibrator.brier_score(predictions, actuals)
    ece = Annotator::ConfidenceCalibrator.expected_calibration_error(predictions, actuals, bins: 5)

    assert brier >= 0.0
    assert brier <= 1.0
    assert ece >= 0.0
    assert ece <= 1.0
  end
end
