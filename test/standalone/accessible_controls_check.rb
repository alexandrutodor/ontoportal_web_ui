# frozen_string_literal: true

# ONTO-T-U05: accessible controls, programmatic labels, and keyboard semantics check.
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

class ActionView::Base
  def inline_svg(name, options = {}) = "<svg data-icon=\"#{name}\"></svg>".html_safe
  def inline_svg_tag(name, options = {}) = "<svg data-icon=\"#{name}\"></svg>".html_safe
  def image_tag(name, options = {}) = "<img src=\"#{name}\" class=\"#{options[:class]}\" />".html_safe
end

class ViewComponent::Base
  def inline_svg(name, options = {}) = "<svg data-icon=\"#{name}\"></svg>".html_safe
  def inline_svg_tag(name, options = {}) = "<svg data-icon=\"#{name}\"></svg>".html_safe
  def image_tag(name, options = {}) = "<img src=\"#{name}\" class=\"#{options[:class]}\" />".html_safe
end

module Input; end
module Display
  class HeaderComponent < ViewComponent::Base
    def initialize(text: nil, tooltip: nil)
      @text = text
      @tooltip = tooltip
    end
    def call = "<h3>#{@text}</h3>".html_safe
  end
  class AlertComponent < ViewComponent::Base
    def initialize(type: 'danger', closable: false); end
    def call = "<div>#{content}</div>".html_safe
  end
  class InfoTooltipComponent < ViewComponent::Base
    def initialize(**opts); end
    def call = "<span>#{content}</span>".html_safe
  end
end

module Layout
  class ListComponent < ViewComponent::Base
    def call = "<div>#{content}</div>".html_safe
    def row; yield; end
  end
end

module Buttons
  class RegularButtonComponent < ViewComponent::Base
    def initialize(id: nil, value: '', type: 'button')
      @id = id
      @value = value
      @type = type
    end
    def call = "<button type=\"#{@type}\" id=\"#{@id}\">#{@value}</button>".html_safe
  end
end

class DropdownButtonComponent < ViewComponent::Base
  def header; yield; end
  def with_section(**); yield(self); end
  def item; yield; end
  def call = '<div></div>'.html_safe
end

require File.join(ROOT, 'app/components/input/input_field_component')
require File.join(ROOT, 'app/components/input/text_input_component')
require File.join(ROOT, 'app/components/dropdown_container_component')
require File.join(ROOT, 'app/components/nested_form_inputs_component')

class AccessibleControlsCheck < Minitest::Test
  def view
    ActionView::Base.new(ActionView::LookupContext.new([File.join(ROOT, 'app/components')]), {}, nil)
  end

  def render_login_view
    lookup = ActionView::LookupContext.new([File.join(ROOT, 'app/views')])
    v = ActionView::Base.with_empty_template_cache.new(lookup, { errors: nil, redirect_url: '/' }, nil)
    v.define_singleton_method(:url_for) { |*| '/login' }
    v.define_singleton_method(:protect_against_forgery?) { false }
    v.define_singleton_method(:omniauth_providers_info) { {} }
    v.define_singleton_method(:new_user_path) { '/users/new' }
    template = File.read(File.join(ROOT, 'app/views/login/index.html.haml'))
    Haml::Engine.new(template).render(v)
  end

  def render_users_form
    lookup = ActionView::LookupContext.new([File.join(ROOT, 'app/views')])
    user = OpenStruct.new(firstName: 'Jane', lastName: 'Doe', username: 'janedoe', orcidId: '0000',
                          githubId: 'jane', email: 'jane@example.com', password: '', password_confirmation: '')
    v = ActionView::Base.with_empty_template_cache.new(lookup, { user: user }, nil)
    v.define_singleton_method(:url_for) { |*| '/users' }
    v.define_singleton_method(:protect_against_forgery?) { false }
    v.define_singleton_method(:asset_path) { |path| "/assets/#{path}" }
    v.define_singleton_method(:portal_name) { 'MatPortal' }
    v.define_singleton_method(:using_captcha?) { false }
    template = File.read(File.join(ROOT, 'app/views/users/_form.html.haml'))
    Haml::Engine.new(template).render(v)
  end

  def render_topnav
    lookup = ActionView::LookupContext.new([File.join(ROOT, 'app/views')])
    controller = Struct.new(:session).new({})
    v = ActionView::Base.with_empty_template_cache.new(lookup, {}, controller)
    v.define_singleton_method(:portal_name) { 'MatPortal' }
    v.define_singleton_method(:asset_path) { |p| "/assets/#{p}" }
    v.define_singleton_method(:navitems) { [] }
    v.define_singleton_method(:current_page?) { |*| false }
    v.define_singleton_method(:ontologies_content_autocomplete) { |**| '<input />'.html_safe }
    v.define_singleton_method(:portal_language_selector) { '' }
    v.define_singleton_method(:agents_enabled?) { false }
    v.define_singleton_method(:sparql_enabled?) { false }
    template = File.read(File.join(ROOT, 'app/views/layouts/_topnav.html.haml'))
    Haml::Engine.new(template).render(v)
  end

  def test_input_field_label_matches_input_id_derived_and_supplied
    # Case 1: Derived ID from name ("user[profile][name]" -> "user_profile_name")
    c_derived = Input::InputFieldComponent.new(label: 'Full Name', name: 'user[profile][name]')
    html_derived = c_derived.render_in(view)
    assert_match(/<label[^>]*class=['"][^'"]*text-input-label[^'"]*d-block[^'"]*['"][^>]*for=['"]user_profile_name['"]/, html_derived)
    assert_match(/<input[^>]*id=['"]user_profile_name['"]/, html_derived)

    # Case 2: Supplied ID takes precedence
    c_supplied = Input::InputFieldComponent.new(label: 'Full Name', name: 'user[profile][name]', id: 'custom_input_id')
    html_supplied = c_supplied.render_in(view)
    assert_match(/<label[^>]*class=['"][^'"]*text-input-label[^'"]*d-block[^'"]*['"][^>]*for=['"]custom_input_id['"]/, html_supplied)
    assert_match(/<input[^>]*id=['"]custom_input_id['"]/, html_supplied)

    # Case 3: When component wraps content, keep div and do not render label for
    c_block = Input::InputFieldComponent.new(label: 'Wrapped Field', name: 'wrapped[field]')
    html_block = c_block.render_in(view) { '<div>nested content</div>' }
    assert_match(/<div class=['"]text-input-label['"]>\s*Wrapped Field\s*<\/div>/, html_block)
    refute_match(/<label[^>]*text-input-label/, html_block)

    # Case 4: unlabeled repeated rows get no derived id (avoids duplicate ids)
    html_rows = 2.times.map { Input::InputFieldComponent.new(name: 'config[items][]').render_in(view) }.join
    refute_match(/<input[^>]*\sid=/, html_rows)
  end

  def test_text_input_forwards_id_derived_and_supplied
    # Supplied ID
    c_supplied = Input::TextInputComponent.new(label: 'Handle', name: 'handle', id: 'my_handle_id')
    html_supplied = c_supplied.render_in(view)
    assert_match(/<label[^>]*for=['"]my_handle_id['"]/, html_supplied)
    assert_match(/<input[^>]*id=['"]my_handle_id['"]/, html_supplied)

    # Derived ID
    c_derived = Input::TextInputComponent.new(label: 'Deep Field', name: 'a[b][c]')
    html_derived = c_derived.render_in(view)
    assert_match(/<label[^>]*for=['"]a_b_c['"]/, html_derived)
    assert_match(/<input[^>]*id=['"]a_b_c['"]/, html_derived)
  end

  def test_aria_describedby_and_invalid_state
    # No error or help: no aria-invalid, no aria-describedby
    c_clean = Input::InputFieldComponent.new(label: 'Email', name: 'email')
    html_clean = c_clean.render_in(view)
    refute_includes html_clean, 'aria-invalid'
    refute_includes html_clean, 'aria-describedby'

    # Error only: aria-invalid="true" and aria-describedby points to error element
    c_err = Input::InputFieldComponent.new(label: 'Email', name: 'email', error_message: 'Invalid email address')
    html_err = c_err.render_in(view)
    assert_match(/aria-invalid=['"]true['"]/, html_err)
    assert_match(/aria-describedby=['"]email_error['"]/, html_err)
    assert_match(/<div[^>]*class=['"][^'"]*text-input-error-text[^'"]*['"][^>]*id=['"]email_error['"]/, html_err)

    # Help only: no aria-invalid, aria-describedby points to help element
    c_help = Input::InputFieldComponent.new(label: 'Email', name: 'email', helper_text: 'We never share your email')
    html_help = c_help.render_in(view)
    refute_includes html_help, 'aria-invalid'
    assert_match(/aria-describedby=['"]email_help['"]/, html_help)
    assert_match(/<div[^>]*class=['"][^'"]*text-input-helper-text[^'"]*['"][^>]*id=['"]email_help['"]/, html_help)

    # Both error and help: aria-invalid="true" and aria-describedby points to both IDs
    c_both = Input::InputFieldComponent.new(label: 'Email', name: 'email', error_message: 'Invalid', helper_text: 'Help text')
    html_both = c_both.render_in(view)
    assert_match(/aria-invalid=['"]true['"]/, html_both)
    assert_match(/aria-describedby=['"]email_error email_help['"]/, html_both)
    assert_match(/id=['"]email_error['"]/, html_both)
    assert_match(/id=['"]email_help['"]/, html_both)
  end

  def test_dropdown_container_trigger_button_semantics
    c_open = DropdownContainerComponent.new(id: 'section_one', title: 'Details', is_open: true)
    html_open = c_open.render_in(view)
    assert_match(/<button[^>]*class=['"][^'"]*dropdown-title-bar[^'"]*['"]/, html_open)
    refute_match(/dropdown-title-bar[^'"]*\bbtn\b/, html_open) # .btn would override the bar's flex/font rules
    assert_match(/type=['"]button['"]/, html_open)
    assert_match(/aria-expanded=['"]true['"]/, html_open)
    assert_match(/aria-controls=['"]section_one['"]/, html_open)
    assert_match(/data-toggle=['"]collapse['"]/, html_open)
    assert_match(/data-target=['"]#section_one['"]/, html_open)

    c_closed = DropdownContainerComponent.new(id: 'section_two', title: 'Details', is_open: false)
    html_closed = c_closed.render_in(view)
    assert_match(/aria-expanded=['"]false['"]/, html_closed)
    assert_match(/aria-controls=['"]section_two['"]/, html_closed)
  end

  def test_nested_form_inputs_buttons_and_accessible_name
    c = NestedFormInputsComponent.new(object_name: 'contact')
    c.with_row { '<div>row 1</div>' }

    html_en = c.render_in(view)
    # Buttons have type="button" and unchanged data-action
    assert_match(/<button[^>]*class=['"][^'"]*add-another-object[^'"]*['"][^>]*type=['"]button['"]/, html_en)
    assert_match(/data-action=['"]click(?:->|-&gt;)nested-form#add['"]/, html_en)
    assert_match(/<button[^>]*class=['"][^'"]*delete[^'"]*['"][^>]*type=['"]button['"]/, html_en)
    assert_match(/aria-label=['"]Remove row['"]/, html_en)
    assert_match(/data-action=['"]click(?:->|-&gt;)nested-form#remove['"]/, html_en)

    I18n.with_locale(:fr) do
      html_fr = c.render_in(view)
      assert_match(/aria-label=['"]Supprimer la ligne['"]/, html_fr)
      assert_match(/data-action=['"]click(?:->|-&gt;)nested-form#remove['"]/, html_fr)
      assert_match(/data-action=['"]click(?:->|-&gt;)nested-form#add['"]/, html_fr)
    end
  end

  def test_login_and_registration_labels_point_to_real_inputs
    login_html = render_login_view
    assert_match(/<label[^>]*class=['"][^'"]*login-input-title[^'"]*['"][^>]*for=['"]user_username['"]/, login_html)
    assert_match(/<input[^>]*id=['"]user_username['"]/, login_html)
    assert_match(/<label[^>]*class=['"][^'"]*login-input-title[^'"]*['"][^>]*for=['"]user_password['"]/, login_html)
    assert_match(/<input[^>]*id=['"]user_password['"]/, login_html)

    reg_html = render_users_form
    expected_fields = %w[
      user_firstName
      user_lastName
      user_username
      user_orcidId
      user_githubId
      user_email
      user_password
      user_password_confirmation
    ]
    expected_fields.each do |field_id|
      assert_match(/<label[^>]*class=['"][^'"]*register-input-title[^'"]*['"][^>]*for=['"]#{field_id}['"]/, reg_html, "Missing label for #{field_id}")
      assert_match(/<input[^>]*id=['"]#{field_id}['"]/, reg_html, "Missing input with id #{field_id}")
    end
  end

  def test_nav_checkbox_not_display_none_and_has_focus_indicator
    scss = File.read(File.join(ROOT, 'app/assets/stylesheets/nav_bar.scss'))
    refute_match(/\.top-nav input\[type=["']?checkbox["']?\]\s*\{\s*display:\s*none/m, scss)
    assert_match(/top-nav input\[type=["']?checkbox["']?\]\s*\{[^}]*position:\s*absolute/m, scss)
    assert_match(/focus-visible \+ label/m, scss)

    topnav_html = render_topnav
    assert_match(/<input[^>]*id=['"]nav-menu['"]/, topnav_html)
    assert_match(/<input[^>]*aria-label=['"]Toggle navigation['"]/, topnav_html)
    assert_match(/<label[^>]*class=['"][^'"]*menu-btn[^'"]*['"][^>]*for=['"]nav-menu['"]/, topnav_html)
  end
end
