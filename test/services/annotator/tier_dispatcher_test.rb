# frozen_string_literal: true

begin
  require_relative "../../test_helper_standalone"
rescue LoadError
  require "test_helper"
end

class TierDispatcherTest < ActiveSupport::TestCase
  def setup
    @text = "Melanoma was diagnosed in the patient."
    @sample_annotations = [
      {
        "annotatedClass" => {
          "@id" => "http://purl.bioontology.org/ontology/NCIT/C3224",
          "prefLabel" => "Melanoma",
          "links" => { "ontology" => "http://localhost:9393/ontologies/NCIT" }
        },
        "annotations" => [
          { "from" => 1, "to" => 8, "matchType" => "PREF", "text" => "Melanoma" }
        ]
      }
    ]
  end

  test "normalizes tier names and aliases" do
    assert_equal "fast", Annotator::TierDispatcher.normalize_tier(nil)
    assert_equal "fast", Annotator::TierDispatcher.normalize_tier("lexical")
    assert_equal "balanced", Annotator::TierDispatcher.normalize_tier("contextual-balanced")
    assert_equal "assurance", Annotator::TierDispatcher.normalize_tier("high_assurance")
  end

  test "dispatches fast tier and enriches annotations" do
    result = Annotator::TierDispatcher.call(@text, @sample_annotations, tier: "fast")

    assert_equal "fast", result[:tier]
    assert_equal 1, result[:annotations].length
    anno = result[:annotations].first

    assert_equal "fast", anno["tier"]
    assert !anno["confidence"].nil?
    assert_includes ["accept", "review", "abstain"], anno["decision"]
    assert_equal 1, result[:summary][:total]
  end

  test "dispatches balanced tier with contextual window" do
    result = Annotator::TierDispatcher.call(@text, @sample_annotations, tier: "balanced")

    assert_equal "balanced", result[:tier]
    anno = result[:annotations].first

    assert_equal "balanced", anno["tier"]
    assert !anno["context"].nil?
    assert !anno["context"]["prefix"].nil?
    assert !anno["context"]["suffix"].nil?
  end

  test "dispatches assurance tier and enforces symbolic constraints" do
    result = Annotator::TierDispatcher.call(@text, @sample_annotations, tier: "assurance")

    assert_equal "assurance", result[:tier]
    anno = result[:annotations].first

    assert_equal "assurance", anno["tier"]
    assert_equal true, anno["symbolic_checks_passed"]
  end
end
