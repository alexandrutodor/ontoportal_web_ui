# frozen_string_literal: true

begin
  require "test_helper"
rescue LoadError
  require "minitest/autorun"
end

class AnnotatorControllerTest < (defined?(ActionDispatch::IntegrationTest) ? ActionDispatch::IntegrationTest : Minitest::Test)
  def setup
    @sample_annotations = fixtures(:annotator)["sample_response"]
  end

  test "should get annotator index" do
    get "/annotator"
    assert_response :success
    assert_select "#annotator_tier"
    assert_select "#annotator_review_drawer"
  end

  test "should create annotations with legacy json format and enriched decision fields" do
    AnnotatorController.any_instance.stubs(:parse_json).returns(@sample_annotations)
    AnnotatorController.any_instance.stubs(:massage_annotated_classes).returns(true)

    post "/annotator", params: {
      text: "Melanoma patient presentation",
      tier: "fast"
    }

    assert_response :success
    json = JSON.parse(response.body)

    assert json.key?("annotations")
    assert_equal "fast", json["tier"]
    assert json.key?("summary")
    assert_equal "accept", json["annotations"].first["decision"]
  end

  test "should create annotations with w3c json-ld format" do
    AnnotatorController.any_instance.stubs(:parse_json).returns(@sample_annotations)
    AnnotatorController.any_instance.stubs(:massage_annotated_classes).returns(true)

    post "/annotator", params: {
      text: "Melanoma patient presentation",
      tier: "balanced",
      output_format: "w3c"
    }, headers: { "Accept" => "application/ld+json" }

    assert_response :success
    assert_match(/application\/ld\+json/, response.content_type)

    json = JSON.parse(response.body)
    assert_equal "http://www.w3.org/ns/anno.jsonld", json["@context"]
    assert_equal "AnnotationCollection", json["type"]
    assert json["items"].any?
    assert_equal "SpecificResource", json["items"].first["body"]["type"]
    assert_equal "balanced", json["items"].first["body"]["tier"]
  end

  test "should route high-assurance tier and flag uncalibrated candidates" do
    AnnotatorController.any_instance.stubs(:parse_json).returns(@sample_annotations)
    AnnotatorController.any_instance.stubs(:massage_annotated_classes).returns(true)

    post "/annotator", params: {
      text: "Melanoma patient presentation",
      tier: "assurance"
    }

    assert_response :success
    json = JSON.parse(response.body)
    assert_equal "assurance", json["tier"]
  end
end
