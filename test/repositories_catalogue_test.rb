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

load File.expand_path("../app/controllers/repositories_controller.rb", __dir__)

class RepositoriesCatalogueTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)

  def read(path)
    File.binread(File.join(ROOT, path)).force_encoding(Encoding::UTF_8)
  end

  def controller_for(query = {})
    controller = RepositoriesController.new
    controller.define_singleton_method(:params) { query }
    controller.define_singleton_method(:render) { |view| @rendered_view = view }
    controller.define_singleton_method(:head) { |status| @head_status = status }
    controller
  end

  def repositories_for(query = {})
    controller = controller_for(query)
    controller.index
    controller.instance_variable_get(:@repositories)
  end

  def test_json_preserves_accepted_records_and_excludes_held_candidates
    document = JSON.parse(File.binread(RepositoriesController::CATALOGUE_PATH), symbolize_names: true)
    assert_equal document[:repositories], RepositoriesController::CATALOGUE
    assert_equal "ontoportal-code-repository-catalogue-v1", document[:profile]
    assert_equal 27, RepositoriesController::CATALOGUE.length
    assert_equal 6, document[:held_candidates].length
    held_ids = document[:held_candidates].map { |candidate| candidate[:id] }
    assert held_ids.none? { |id| RepositoriesController::CATALOGUE.any? { |repository| repository[:id] == id } }
    assert_equal 27, repositories_for.length

    sorted = controller_for(Sort_by: "name_desc")
    sorted.index
    names = sorted.instance_variable_get(:@repositories).map { |repository| repository[:project_name].downcase }
    assert_equal names.sort.reverse, names
  end

  def test_primary_language_search_and_package_filters_are_exact
    unknown_secondary = RepositoriesController::CATALOGUE.count { |repository| repository.dig(:languages, :secondary) == "Unknown" }
    assert_equal 11, unknown_secondary

    controller = controller_for
    controller.index
    language_options = controller.instance_variable_get(:@language_options)
    assert_equal RepositoriesController::CATALOGUE.map { |repository| repository.dig(:languages, :primary) }.uniq.sort, language_options.sort
    refute_includes language_options, "Unknown"
    assert_equal ["spglib"], repositories_for(language: ["C"]).map { |repository| repository[:id] }
    assert_equal ["spglib"], repositories_for(language: ["c"]).map { |repository| repository[:id] }
    assert_equal 27, repositories_for(language: ["Pyt"]).length
    assert_equal ["mace"], repositories_for(q: "mace-torch").map { |repository| repository[:id] }
    assert_equal ["quantum-espresso"], repositories_for(q: "doi:10.1088/0953-8984/21/39/395502").map { |repository| repository[:id] }
    assert_equal ["spglib"], repositories_for(host: ["GitHub"], language: ["C"]).map { |repository| repository[:id] }
    assert_equal %w[abinit cp2k quantum-espresso spglib], repositories_for(language: ["C", "Fortran"]).map { |repository| repository[:id] }
    assert_equal ["mace"], repositories_for(package: ["mace-torch"], license: ["MIT"]).map { |repository| repository[:id] }
  end

  def test_detail_sections_and_unknown_license_are_preserved
    controller = controller_for(id: "quantum-espresso", section: "languages")
    controller.show
    assert_equal "languages", controller.instance_variable_get(:@section)
    assert_equal :show, controller.instance_variable_get(:@rendered_view)

    invalid = controller_for(id: "quantum-espresso", section: "invalid")
    invalid.show
    assert_equal "overview", invalid.instance_variable_get(:@section)

    missing = controller_for(id: "held-candidate")
    missing.show
    assert_equal :not_found, missing.instance_variable_get(:@head_status)

    show = read("app/views/repositories/show.html.haml")
    index = read("app/views/repositories/index.html.haml")
    %w[Secondary languages License scopes documentation_license data_license_or_terms model_license_or_terms dependency_license_note].each do |text|
      assert_includes show, text
    end
    assert_includes show, "License unknown or unresolved"
    refute_includes show, "Catalogued date"
    refute_includes index, "Catalogued date"
  end

  def test_fair_readiness_and_view_contract
    RepositoriesController::CATALOGUE.each do |repository|
      score = RepositoriesController.fair_score_for(repository)
      assert_includes 0..100, score[:overall_score]
      assert_equal %w[A F I R], score[:principles].keys.sort
      assert score[:criteria].values.all? { |criteria| criteria.length == 4 }
      assert_equal "ontoportal-repository-fair-metadata-readiness-v1", score[:profile]
      assert_includes score[:disclaimer], "Repository FAIR metadata readiness v1"
      assert_includes score[:methodology], "16 objective catalogue checks"
    end

    empty = RepositoriesController.fair_score_for({})
    assert_equal 0, empty[:overall_score]
    assert_equal({ "F" => 0, "A" => 0, "I" => 0, "R" => 0 }, empty[:principles])
    assert_includes read("app/views/repositories/index.html.haml"), "Repository FAIR metadata readiness"
    assert_includes read("app/views/repositories/show.html.haml"), "Metadata criteria checks"
  end

  def test_source_is_read_only_generic_and_has_no_dataset_route_dependency
    source = read("app/controllers/repositories_controller.rb") + read("app/views/repositories/index.html.haml") + read("app/views/repositories/show.html.haml")
    refute_match(/\b(?:propose|create|publish|upload)\b/i, source)
    refute_includes source, "linked_data_datasets_path"
    refute_includes source, "matportal"
    refute_includes source, "DEFAULT_PROJECTS"
    refute_includes source, "current_slice_acronym"
  end
end
