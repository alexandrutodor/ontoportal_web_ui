#!/usr/bin/env ruby
# frozen_string_literal: true

require "minitest/autorun"

class CatalogueConsistencyContractTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)
  CATALOGUES = {
    "datasets" => "datasets",
    "models" => "models_catalogue",
    "workflows" => "workflows_catalogue",
    "repositories" => "repositories_catalogue"
  }.freeze

  def read(path)
    File.binread(File.join(ROOT, path)).force_encoding(Encoding::UTF_8)
  end

  def test_catalogue_features_are_registered_described_and_disabled_by_default
    setup = read("app/lib/flipper/flipper_setup.rb")
    initializer = read("config/initializers/flipper.rb")
    CATALOGUES.each_value do |feature|
      assert_includes setup, feature
      assert_includes initializer, "\"#{feature}\""
      assert_includes initializer, "Disabled by default"
      refute_match(/DISABLED_BY_DEFAULT_FEATURES\.each.*enable/, setup)
    end
    assert_match(/DISABLED_BY_DEFAULT_FEATURES\s*=\s*%w\[datasets models_catalogue workflows_catalogue repositories_catalogue\]/, setup)
    assert_includes setup, "existing_features = primary_adapter.features.map(&:to_s)"
    assert_includes setup, "DISABLED_BY_DEFAULT_FEATURES.each { |feature| Flipper.add(feature) }"
  end

  def test_routes_are_bounded_get_only_index_and_show_routes
    routes = read("config/routes.rb")
    %w[models workflows repositories].each do |resource|
      route_name = resource == "models" ? "model" : resource == "workflows" ? "workflow" : "repository"
      assert_match(%r{get '/#{resource}', to: '#{resource}#index', as: :#{resource}}, routes)
      assert_match(%r{get '/#{resource}/:id', to: '#{resource}#show', as: :#{route_name}.*id: /\[A-Za-z0-9\]\[A-Za-z0-9_-\]\{0,160\}/}, routes)
    end
    assert_match(%r{resources :datasets, only: \[:index, :show\], constraints: \{ id: /\[a-zA-Z0-9\]\[a-zA-Z0-9\._:-\]\{0,119\}/ \}}, routes)
    assert_empty routes.lines.grep(/(?:post|put|patch|delete) .*\b(?:datasets|models|workflows|repositories)\b/)
    assert_empty routes.lines.grep(/resources :(?:datasets|models|workflows|repositories)(?!, only: \[:index, :show\])/)
  end

  def test_controllers_gate_index_and_show_before_read_only_catalogue_work
    CATALOGUES.each do |resource, feature|
      source = read("app/controllers/#{resource}_controller.rb")
      assert_includes source, "before_action :require_#{resource}"
      assert_includes source, "Flipper.enabled?(:#{feature})"
      assert_match(/def (?:index|show)/, source)
      refute_match(/def (?:propose|create|update|destroy|publish|upload)/, source)
    end
  end

  def test_topnav_and_catalogue_switch_links_are_conditional
    topnav = read("app/views/layouts/_topnav.html.haml")
    assert_includes topnav, "datasets_enabled?"
    assert_includes topnav, "datasets_path"
    %w[models workflows repositories].each do |resource|
      assert_includes topnav, "Flipper.enabled?(:#{resource}_catalogue)"
      assert_includes topnav, "#{resource}_path"
    end

    CATALOGUES.each_key do |resource|
      view = read("app/views/#{resource}/index.html.haml")
      assert_includes view, ".browse-switch"
      assert_includes view, ".browse-search-filters" if resource != "datasets"
      assert_includes view, "datasets_path" if resource != "datasets"
      assert_includes view, "datasets_enabled?" if resource != "datasets"
      %w[models workflows repositories].reject { |other| other == resource }.each do |other|
        assert_includes view, "Flipper.enabled?(:#{other}_catalogue)"
        assert_includes view, "#{other}_path"
      end
      refute_includes view, "linked_data_datasets_path"
      refute_includes view, "data_graph"
      refute_includes view, "matportal"
      refute_match(/\b(?:Add|Suggest|Propose|Upload|Publish)\b/i, view)
    end
  end

  def test_catalogue_data_uses_generic_portal_keys
    %w[workflow-catalogue.json repository-catalogue.json].each do |file|
      refute_includes read("config/catalogues/#{file}"), "matportal"
    end

    repositories = read("config/catalogues/repository-catalogue.json")
    refute_includes repositories, "repository-schema.json"
    assert_includes repositories, '"implementation_status": "implemented_read_only_catalogue"'
  end

  def test_all_catalogue_views_are_generic_read_only_and_bound_external_links
    CATALOGUES.each_key do |resource|
      %w[index show].each do |action|
        view = read("app/views/#{resource}/#{action}.html.haml")
        refute_includes view, "MatPortal"
        refute_includes view, "linked_data_datasets_path"
        refute_includes view, "data_graph"
        refute_match(/\b(?:propose|create|publish|upload|admin)\b/i, view)
      end
    end
    assert_includes read("app/views/models/show.html.haml"), "resource_url.start_with?('https://')"
    assert_includes read("app/views/workflows/show.html.haml"), "external_url.start_with?('https://')"
    assert_includes read("app/views/repositories/show.html.haml"), "canonical_url.start_with?('https://')"
  end
end
