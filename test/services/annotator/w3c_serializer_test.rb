# frozen_string_literal: true

begin
  require_relative "../../test_helper_standalone"
rescue LoadError
  require "test_helper"
end

class W3cSerializerTest < ActiveSupport::TestCase
  def setup
    @text = "Melanoma is an aggressive skin cancer."
    @sample_annotations = [
      {
        "annotatedClass" => {
          "@id" => "http://purl.bioontology.org/ontology/NCIT/C3224",
          "prefLabel" => "Melanoma",
          "ontology" => { "name" => "NCIT", "acronym" => "NCIT" },
          "semantic_types" => ["Neoplastic Process"]
        },
        "annotations" => [
          { "from" => 1, "to" => 8, "matchType" => "PREF", "text" => "Melanoma" }
        ],
        "confidence" => 0.96,
        "decision" => "accept",
        "tier" => "fast"
      }
    ]
  end

  test "serializes annotations into W3C Web Annotation JSON-LD standard" do
    result = Annotator::W3cSerializer.serialize(@sample_annotations, @text)

    assert_equal "http://www.w3.org/ns/anno.jsonld", result["@context"]
    assert_equal "AnnotationCollection", result["type"]
    assert_equal 1, result["total"]
    assert_equal 1, result["items"].length

    item = result["items"].first
    assert_equal "Annotation", item["type"]
    assert_equal "tagging", item["motivation"]

    # Check body
    body = item["body"]
    assert_equal "SpecificResource", body["type"]
    assert_equal "http://purl.bioontology.org/ontology/NCIT/C3224", body["source"]
    assert_equal "Melanoma", body["prefLabel"]
    assert_equal 0.96, body["confidence"]
    assert_equal "accept", body["decision"]
    assert_equal "fast", body["tier"]
    assert_equal ["Neoplastic Process"], body["semanticTypes"]

    # Check target & selectors
    target = item["target"]
    selectors = target["selector"]
    assert_equal 2, selectors.length

    pos_sel = selectors.find { |s| s["type"] == "TextPositionSelector" }
    assert !pos_sel.nil?
    assert_equal 0, pos_sel["start"]
    assert_equal 8, pos_sel["end"]

    quote_sel = selectors.find { |s| s["type"] == "TextQuoteSelector" }
    assert !quote_sel.nil?
    assert_equal "Melanoma", quote_sel["exact"]
  end
end
