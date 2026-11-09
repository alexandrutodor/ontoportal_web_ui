# frozen_string_literal: true

# ONTO-T-U09: shared actions and account submit labels follow the portal locale.
# Renders the two shared components with real I18n (en/fr locale files) and checks the
# remaining call sites use keys that exist in both locales instead of English literals.
require 'minitest/autorun'
require 'active_support/all'
require 'action_view'
require 'rails'
require 'haml'
require 'haml/template'
require 'view_component'
require 'yaml'

ROOT = File.expand_path('../..', __dir__)
I18n.load_path += [File.join(ROOT, 'config/locales/en.yml'), File.join(ROOT, 'config/locales/fr.yml')]
I18n.available_locales = %i[en fr]
I18n.raise_on_missing_translations = true if I18n.respond_to?(:raise_on_missing_translations=)

class ViewComponent::Base
  def inline_svg(name, options = {}) = "<svg data-icon=\"#{name}\"></svg>".html_safe
end
require File.join(ROOT, 'app/components/list_items_show_more_component')
require File.join(ROOT, 'app/components/nested_form_inputs_component')

class FrenchSharedActionsCheck < Minitest::Test
  def view = ActionView::Base.new(ActionView::LookupContext.new([File.join(ROOT, 'app/components')]), {}, nil)

  def show_more_html(locale)
    I18n.with_locale(locale) do
      c = ListItemsShowMoreComponent.new(max_items: 1)
      3.times { |i| c.with_container { "item#{i}" } }
      c.render_in(view)
    end
  end

  def nested_html(locale)
    I18n.with_locale(locale) { NestedFormInputsComponent.new(object_name: 'contact').render_in(view) }
  end

  def test_show_more_actions_follow_locale
    assert_includes show_more_html(:en), 'See more...'
    assert_includes show_more_html(:en), 'See less...'
    fr = show_more_html(:fr)
    assert_includes fr, 'Voir plus...'
    assert_includes fr, 'Voir moins...'
    refute_match(/See (more|less)/, fr)
  end

  def test_add_another_follows_locale_with_object_name
    assert_includes nested_html(:en), 'Add another contact'
    fr = nested_html(:fr)
    assert_includes fr, 'Ajouter un autre contact'
    refute_includes fr, 'Add another'
    assert_includes fr, 'nested-form#add', 'Stimulus action unchanged'
  end

  SITES = {
    'app/components/concept_details_component/concept_details_component.html.haml' => ["t('components.raw_data')", "'Raw data'"],
    'app/views/login/index.html.haml' => ["value: t('login.title')", 'value: "Login"'],
    'app/views/users/_form.html.haml' => ["value: t('register.title')", 'value: "Register"']
  }.freeze

  def test_other_sites_use_keys_present_in_both_locales
    SITES.each do |path, (call, literal)|
      src = File.read(File.join(ROOT, path))
      assert_includes src, call, path
      refute_includes src, literal, "#{path} still hardcodes #{literal}"
      key = call[/t\('([^']+)'\)/, 1]
      en = I18n.t(key, locale: :en)
      fr = I18n.t(key, locale: :fr)
      refute_equal en, fr, "#{key} has a French translation"
    end
    assert_equal ['Raw data', 'Données brutes'], %i[en fr].map { |l| I18n.t('components.raw_data', locale: l) }
    assert_equal %w[Login Connexion], %i[en fr].map { |l| I18n.t('login.title', locale: l) }
    assert_equal ['Register', "S'inscrire"], %i[en fr].map { |l| I18n.t('register.title', locale: l) }
  end
end
