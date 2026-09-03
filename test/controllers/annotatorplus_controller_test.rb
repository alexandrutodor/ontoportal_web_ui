# frozen_string_literal: true

begin
  require "test_helper"
rescue LoadError
  require "minitest/autorun"
end

class AnnotatorplusControllerTest < (defined?(ActionDispatch::IntegrationTest) ? ActionDispatch::IntegrationTest : Minitest::Test)
  def setup
    @sample_annotations = fixtures(:annotator)["sample_response"]
  end

  test "should get annotatorplus index" do
    get "/annotatorplus"
    assert_response :success
    assert_select "#annotator_tier"
    assert_select "#annotator_review_drawer"
  end

  test "should create annotatorplus annotations with legacy json format" do
    AnnotatorplusController.any_instance.stubs(:parse_json).returns(@sample_annotations)
    AnnotatorplusController.any_instance.stubs(:massage_annotated_classes).returns(true)

    post "/annotatorplus", params: {
      text: "Melanoma was excised from patient tissue",
      tier: "fast"
    }

    assert_response :success
    json = JSON.parse(response.body)

    assert json.key?("annotations")
    assert_equal "fast", json["tier"]
    assert json.key?("summary")
  end

  test "should create annotatorplus annotations with w3c json-ld format" do
    AnnotatorplusController.any_instance.stubs(:parse_json).returns(@sample_annotations)
    AnnotatorplusController.any_instance.stubs(:massage_annotated_classes).returns(true)

    post "/annotatorplus", params: {
      text: "Melanoma was excised from patient tissue",
      tier: "balanced",
      output_format: "w3c"
    }, headers: { "Accept" => "application/ld+json" }

    assert_response :success
    assert_match(/application\/ld\+json/, response.content_type)

    json = JSON.parse(response.body)
    assert_equal "http://www.w3.org/ns/anno.jsonld", json["@context"]
    assert_equal "AnnotationCollection", json["type"]
    assert json["items"].any?
  end
end
