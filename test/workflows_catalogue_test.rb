#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require "minitest/autorun"

class ApplicationController
  def self.layout(name = nil)
    @layout_name = name if name
    @layout_name
  end
end unless defined?(ApplicationController)

load File.expand_path("../app/controllers/workflows_controller.rb", __dir__)

class WorkflowsCatalogueTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)

  def read(path)
    File.binread(File.join(ROOT, path)).force_encoding(Encoding::UTF_8)
  end

  def controller_for(query = {})
    controller = WorkflowsController.new
    controller.define_singleton_method(:params) { query }
    controller.define_singleton_method(:render) { |view| @rendered_view = view }
    controller.define_singleton_method(:head) { |status| @head_status = status }
    controller
  end

  def workflows_for(query = {})
    controller = controller_for(query)
    controller.index
    controller.instance_variable_get(:@workflows)
  end

  def test_json_is_authoritative_and_preserves_the_final_catalogue
    document = JSON.parse(File.binread(WorkflowsController::CATALOGUE_PATH), symbolize_names: true)
    assert_equal document[:records], WorkflowsController::CATALOGUE
    assert_equal 24, WorkflowsController::CATALOGUE.length
    assert_equal 12, WorkflowsController::TAXONOMY_FAMILIES.length
    assert_includes WorkflowsController::TAXONOMY_FAMILIES, "Defects & disorder"
    assert_operator read("app/controllers/workflows_controller.rb").lines.length, :<, 1_000
    refute_match(/CATALOGUE\s*=\s*\[/, read("app/controllers/workflows_controller.rb"))

    controller = controller_for
    controller.index
    assert_equal WorkflowsController::SORT_OPTIONS, controller.instance_variable_get(:@sort_options)
    assert_equal WorkflowsController::TAXONOMY_FAMILIES.sort_by(&:downcase), controller.instance_variable_get(:@family_options)
  end

  def test_controlled_facets_and_search_are_exact_and_composable
    record = WorkflowsController::CATALOGUE.first
    {
      family: record.dig(:classification, :family),
      task: record.dig(:classification, :scientific_tasks).first,
      domain: record.dig(:classification, :domains).first,
      engine: record.dig(:implementation, :workflow_engine_or_orchestrator).first,
      software: record.dig(:implementation, :primary_software).first,
      language: record.dig(:implementation, :programming_or_workflow_languages).first,
      license: record.dig(:licensing, :workflow_definition, :license),
      environment: record.dig(:execution, :environments).first,
      access: record[:access_proprietary_status],
      maintenance: record.dig(:maintenance, :status)
    }.each do |facet, value|
      assert_includes workflows_for(facet => value.swapcase).map { |w| w[:catalogue_id] }, record[:catalogue_id]
      refute workflows_for(facet => value.to_s[0...-1]).any?, "partial #{facet} facet must not match"
    end

    assert_equal 4, workflows_for(engine: "AiiDA").length
    assert_equal 4, workflows_for(task: "Geometry optimisation").length
    refute_empty workflows_for(q: "PwBandsWorkChain")
    assert_operator workflows_for(q: "band").length, :>, 1
    assert_equal 13, workflows_for(engine: ["AiiDA", "jobflow"], language: ["Python"]).length
  end

  def test_sorting_and_detail_section_selection
    descending = controller_for(Sort_by: "name_desc")
    descending.index
    names = descending.instance_variable_get(:@workflows).map { |workflow| workflow[:name].downcase }
    assert_equal names.sort.reverse, names

    controller = controller_for(id: "WF-AIIDA-QE-PW-BANDS", section: "reproducibility")
    controller.show
    assert_equal "reproducibility", controller.instance_variable_get(:@section)
    assert_equal :show, controller.instance_variable_get(:@rendered_view)

    invalid = controller_for(id: "WF-AIIDA-QE-PW-BANDS", section: "invalid")
    invalid.show
    assert_equal "overview", invalid.instance_variable_get(:@section)

    missing = controller_for(id: "held-or-missing")
    missing.show
    assert_equal :not_found, missing.instance_variable_get(:@head_status)
  end

  def test_fair_readiness_and_view_preserve_detail_sections
    WorkflowsController::CATALOGUE.each do |workflow|
      score = WorkflowsController.fair_score_for(workflow)
      assert_includes 0..100, score[:overall_score]
      assert_equal %w[A F I R], score[:principles].keys.sort
      assert score[:criteria].values.all? { |criteria| criteria.length == 4 }
      assert_equal "ontoportal-workflow-fair-metadata-readiness-v1", score[:profile]
      assert_includes score[:disclaimer], "Workflow FAIR metadata readiness v1"
    end

    view = read("app/views/workflows/show.html.haml")
    %w[overview steps software-environment related-resources papers-code reproducibility].each do |section|
      assert_includes view, "##{section}"
    end
    assert_includes view, "Open workflow definition"
    assert_includes view, "Metadata criteria checks"
  end

  def test_source_is_read_only_generic_and_has_no_unavailable_dataset_dependency
    source = read("app/controllers/workflows_controller.rb") + read("app/views/workflows/index.html.haml") + read("app/views/workflows/show.html.haml")
    refute_match(/\b(?:propose|create|publish|upload)\b/i, source)
    refute_includes source, "linked_data_datasets_path"
    refute_includes source, "matportal"
    refute_includes source, "DEFAULT_PROJECTS"
    refute_includes source, "current_slice_acronym"
  end
end
