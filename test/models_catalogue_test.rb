#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require "minitest/autorun"

class ApplicationController
  def self.layout(name = nil)
    @layout_name = name if name
    @layout_name
  end

  class FormatMock
    def initialize(controller)
      @controller = controller
    end

    def html(&b)
      @controller.instance_eval(&b) if block_given?
    end

    def json(&b)
      # ignore for view test
    end
  end

  def respond_to(&block)
    block.call(FormatMock.new(self))
  end
end unless defined?(ApplicationController)



load File.expand_path("../app/controllers/models_controller.rb", __dir__)

class ModelsCatalogueTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)

  def read(path)
    File.binread(File.join(ROOT, path)).force_encoding(Encoding::UTF_8)
  end

  def controller_for(query = {})
    controller = ModelsController.new
    controller.define_singleton_method(:params) { query }
    controller.define_singleton_method(:render) { |view| @rendered_view = view }
    controller.define_singleton_method(:head) { |status| @head_status = status }
    controller
  end

  def models_for(query = {})
    controller = controller_for(query)
    controller.index
    controller.instance_variable_get(:@models)
  end

  def test_catalogue_has_preserved_records_and_resource_arrays
    catalogue = ModelsController::CATALOGUE
    assert_equal 22, catalogue.length
    assert_equal catalogue.length, catalogue.map { |model| model[:id] }.uniq.length
    catalogue.each do |model|
      assert_match(/\A[A-Za-z0-9][A-Za-z0-9_-]{0,160}\z/, model[:id])
      assert model[:name].to_s != ""
      assert model[:summary].to_s != ""
      %i[tasks domains tags hubs].each { |key| assert_kind_of Array, model[key] }
      %i[datasets papers code inference].each do |key|
        assert_kind_of Array, model.dig(:resources, key)
      end
    end
    assert_equal "MatterGen", ModelsController::CATALOGUE.find { |m| m[:id] == "mattergen" }[:name]
    assert_nil ModelsController::CATALOGUE.find { |m| m[:id] == "quokka" }.dig(:model_card, :version)
  end

  def test_search_and_facets_are_combined_with_exact_case_insensitive_matching
    controller = controller_for(search: "Matter", hub: "GitHub", task: "molecular dynamics")
    controller.index
    assert_equal ["mattersim"], controller.instance_variable_get(:@models).map { |model| model[:id] }

    assert_equal %w[mattergen mattersim], models_for(organization: "microsoft research").map { |m| m[:id] }
    assert_equal ["kaggle-chgnet-cathode"], models_for(domain: "battery materials").map { |m| m[:id] }
    assert_equal %w[chgnet matgl-m3gnet pet-mad], models_for(search: "BSD-3-Clause").map { |m| m[:id] }
    assert_equal 0, models_for(organization: "unsupported").length
  end

  def test_options_and_sorting_are_populated
    controller = controller_for
    controller.index
    %i[@organization_options @task_options @domain_options @hub_options @license_options].each do |name|
      options = controller.instance_variable_get(name)
      assert_kind_of Array, options
      refute_empty options
      assert_equal options.uniq, options
      assert_equal options.sort_by(&:downcase), options
    end
    assert_equal ModelsController::SORT_OPTIONS, controller.instance_variable_get(:@sort_options)

    descending = controller_for(Sort_by: "name_desc")
    descending.index
    names = descending.instance_variable_get(:@models).map { |model| model[:name].downcase }
    assert_equal names.sort.reverse, names
  end

  def test_detail_sections_and_missing_records
    controller = controller_for(id: "mattergen", section: "model_card")
    controller.show
    assert_equal "model_card", controller.instance_variable_get(:@section)
    assert_equal :show, controller.instance_variable_get(:@rendered_view)

    invalid = controller_for(id: "mattergen", section: "unknown")
    invalid.show
    assert_equal "overview", invalid.instance_variable_get(:@section)

    missing = controller_for(id: "does-not-exist")
    missing.show
    assert_equal :not_found, missing.instance_variable_get(:@head_status)
  end

  def test_fair_readiness_has_four_bounded_principles_and_honest_profile
    ModelsController::CATALOGUE.each do |model|
      score = ModelsController.fair_score_for(model)
      assert_kind_of Integer, score[:overall_score]
      assert_includes 0..100, score[:overall_score]
      assert_equal %w[A F I R], score[:principles].keys.sort
      assert_equal %w[Accessible Findable Interoperable Reusable], score[:criteria].keys.sort
      assert score[:criteria].values.all? { |criteria| criteria.length == 4 }
      assert_equal "ontoportal-model-fair-metadata-readiness-v1", score[:profile]
      assert_includes score[:disclaimer], "Model FAIR metadata readiness v1"
      assert_includes score[:methodology], "16 objective catalogue checks"
    end

    empty = ModelsController.fair_score_for({})
    assert_equal 0, empty[:overall_score]
    assert_equal({ "F" => 0, "A" => 0, "I" => 0, "R" => 0 }, empty[:principles])
  end

  def test_source_is_read_only_and_does_not_depend_on_dataset_route
    source = read("app/controllers/models_controller.rb") + read("app/views/models/index.html.haml") + read("app/views/models/show.html.haml")
    refute_match(/\b(?:propose|create|publish|upload)\b/i, source)
    refute_includes source, "linked_data_datasets_path"
    refute_includes source, "matportal"
  end
end
