# frozen_string_literal: true

require 'minitest/autorun'
require 'active_support/all'
require 'action_view'
require 'rails'
require 'haml'
require 'haml/template'
require 'view_component'
require 'yaml'
require 'ostruct'

ROOT = File.expand_path('../..', __dir__)
I18n.load_path += [File.join(ROOT, 'config/locales/en.yml'), File.join(ROOT, 'config/locales/fr.yml')]
I18n.available_locales = %i[en fr]
I18n.raise_on_missing_translations = true if I18n.respond_to?(:raise_on_missing_translations=)

require File.join(ROOT, 'app/components/query_recipe_component')

class QueryRecipeComponentCheck < Minitest::Test
  def setup
    I18n.locale = :en
  end

  def teardown
    I18n.locale = :en
  end

  def view(recipes_enabled: false)
    lookup = ActionView::LookupContext.new([File.join(ROOT, 'app/components')])
    v = ActionView::Base.with_empty_template_cache.new(lookup, {}, nil)
    v.define_singleton_method(:query_recipes_enabled?) { recipes_enabled }
    v.define_singleton_method(:portal_name) { 'MatPortal' }
    v
  end

  def test_feature_off_renders_nothing
    v = view(recipes_enabled: false)

    # With explicit enabled: false
    c1 = QueryRecipeComponent.new(kind: 'browse', enabled: false)
    assert_equal '', c1.render_in(v).to_s

    # With default enabled: nil checking helper
    c2 = QueryRecipeComponent.new(kind: 'browse')
    assert_equal '', c2.render_in(v).to_s
  end

  def test_feature_on_renders_en_and_buttons
    v = view(recipes_enabled: true)
    I18n.locale = :en

    c = QueryRecipeComponent.new(kind: 'browse', enabled: true)
    html = c.render_in(v).to_s

    refute_empty html
    assert_includes html, 'Saved Recipes'
    assert_includes html, 'Save current settings'
    assert_includes html, 'data-controller="query-recipe"'
    assert_includes html, 'data-query-recipe-kind-value="browse"'
    assert_includes html, 'data-query-recipe-portal-value="MatPortal"'
    assert_includes html, 'data-query-recipe-storage-key-value="ontoportal_query_recipes_v1"'

    # Verify accessibility semantics
    assert_includes html, 'aria-haspopup="dialog"'
    assert_includes html, 'aria-expanded="false"'
    assert_includes html, 'role="dialog"'
    assert_includes html, 'role="status"'

    # Verify all button elements have explicit type="button"
    buttons = html.scan(/<button\b[^>]*>/)
    refute_empty buttons
    buttons.each do |btn|
      assert_match(/type=["']button["']/, btn, "Expected #{btn} to have type='button'")
    end
  end

  def test_interpolated_values_are_escaped
    v = ActionView::Base.empty
    html = QueryRecipeComponent.new(kind: 'browse', portal: 'A"<b>', enabled: true).render_in(v).to_s
    assert_includes html, 'data-query-recipe-portal-value="A&quot;&lt;b&gt;"'
    refute_includes html, '<b>'
  end

  def test_feature_on_renders_fr
    v = view(recipes_enabled: true)
    I18n.locale = :fr

    c = QueryRecipeComponent.new(kind: 'search', portal: 'OntoPortal', enabled: true)
    html = c.render_in(v).to_s

    refute_empty html
    assert_includes html, 'Recettes enregistrées'
    assert_includes html, 'Enregistrer les filtres actuels'
    assert_includes html, 'data-query-recipe-kind-value="search"'
    assert_includes html, 'data-query-recipe-portal-value="OntoPortal"'

    # Verify all buttons have type="button"
    buttons = html.scan(/<button\b[^>]*>/)
    refute_empty buttons
    buttons.each do |btn|
      assert_match(/type=["']button["']/, btn, "Expected #{btn} to have type='button'")
    end
  end
end
