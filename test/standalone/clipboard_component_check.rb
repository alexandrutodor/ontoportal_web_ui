# frozen_string_literal: true

# Set up gem paths for native docker image if present
if Dir.exist?('/usr/local/bundle/ruby/3.1.0/gems') && (ENV['GEM_PATH'].nil? || !ENV['GEM_PATH'].include?('/usr/local/bundle/ruby/3.1.0'))
  Gem.use_paths(nil, Gem.path + ['/usr/local/bundle/ruby/3.1.0'])
end

require 'minitest/autorun'
require 'rails'
require 'action_controller'
require 'action_view'
require 'haml'
require 'haml/template'
require 'view_component'
require 'i18n'
require 'nokogiri'

# Load locale files for en and fr
I18n.load_path << File.expand_path('../../config/locales/en.yml', __dir__)
I18n.load_path << File.expand_path('../../config/locales/fr.yml', __dir__)
I18n.available_locales = [:en, :fr]
I18n.default_locale = :en

# Minimal inline_svg_tag helper mock matching application helper contract
module InlineSvgHelperMock
  def inline_svg_tag(filename, options = {})
    width = options[:width] ? %( width="#{options[:width]}") : ''
    height = options[:height] ? %( height="#{options[:height]}") : ''
    fill = options[:fill] ? %( fill="#{options[:fill]}") : ''
    class_attr = options[:class] ? %( class="#{options[:class]}") : ''
    %(<svg data-src="#{filename}"#{width}#{height}#{fill}#{class_attr}></svg>).html_safe
  end
end

# Load ClipboardComponent and include helper mock
require_relative '../../app/components/clipboard_component'
ClipboardComponent.include(InlineSvgHelperMock)

class ClipboardComponentCheck < Minitest::Test
  def setup
    I18n.locale = :en
    @view_context = ActionView::Base.empty
    @view_context.extend(InlineSvgHelperMock)
    @view_context.extend(ActionView::Helpers::SanitizeHelper)
  end

  def render_component(component, &block)
    component.render_in(@view_context, &block)
  end

  def parsed_content_target(html)
    Nokogiri::HTML::DocumentFragment.parse(html).at_css("[data-clipboard-target='content']")
  end

  def rendered_content_text(html)
    parsed_content_target(html)&.text
  end

  # --- 1. Component Ruby API & Localization ---

  def test_default_title_and_labels_in_english
    comp = ClipboardComponent.new
    render_component(comp)
    assert_equal 'Copy', comp.accessible_label
    assert_equal 'Copied!', comp.copied_label
    assert_equal 'Copy failed', comp.failed_label
  end

  def test_default_title_and_labels_in_french
    I18n.locale = :fr
    comp = ClipboardComponent.new
    render_component(comp)
    assert_equal 'Copier', comp.accessible_label
    assert_equal 'Copié !', comp.copied_label
    assert_equal 'Échec de la copie', comp.failed_label
  end

  def test_accessible_label_strips_html_markup_from_custom_title
    # Portal helper custom title pattern: "Copy MatPortal URI <a href=...>...</a>"
    raw_title = %(Copy MatPortal URI <a href="https://stage.matportal.org/ontologies/TEST/c1">https://stage.matportal.org/ontologies/TEST/c1</a>)
    comp = ClipboardComponent.new(title: raw_title)
    render_component(comp)

    plain = comp.accessible_label
    refute_includes plain, '<a'
    refute_includes plain, '</a>'
    refute_includes plain, 'href='
    assert_includes plain, 'Copy MatPortal URI'
    assert_includes plain, 'https://stage.matportal.org/ontologies/TEST/c1'
  end

  # --- 2. Haml Rendering & Accessibility Contract ---

  def test_renders_native_button_with_accessible_label
    comp = ClipboardComponent.new(message: 'sample')
    html = render_component(comp)

    assert_includes html, '<button'
    assert_match(/type=['"]button['"]/, html)
    assert_includes html, 'clipboard-btn'
    assert_match(/aria-label=['"]Copy['"]/, html)
    assert_match(/data-action=['"]click-&gt;clipboard#copy['"]/, html)
    assert_match(/data-clipboard-target=['"]button['"]/, html)
  end

  def test_renders_copy_check_and_fail_targets_with_icon_attributes
    comp = ClipboardComponent.new(message: 'sample')
    html = render_component(comp)

    # Copy icon (visible initially)
    assert_match(/class=['"][^'"]*\bcopy\b[^'"]*['"]/, html)
    assert_match(/data-clipboard-target=['"]copy['"]/, html)
    assert_includes html, 'data-src="icons/copy.svg"'
    assert_includes html, 'width="20"'
    assert_includes html, 'height="21px"'

    # Check icon (hidden initially)
    assert_match(/class=['"][^'"]*\bd-none\b[^'"]*\bcheck\b[^'"]*['"]/, html)
    assert_match(/data-clipboard-target=['"]check['"]/, html)
    assert_includes html, 'data-src="check.svg"'
    assert_includes html, 'width="18px"'
    assert_includes html, 'height="18px"'
    assert_match(/title=['"]Copied!['"]/, html)

    # Fail icon (hidden initially)
    assert_match(/class=['"][^'"]*\bd-none\b[^'"]*\bfail\b[^'"]*['"]/, html)
    assert_match(/data-clipboard-target=['"]fail['"]/, html)
    assert_includes html, 'data-src="icons/error.svg"'
    assert_includes html, 'width="18px"'
    assert_includes html, 'height="18px"'
    assert_match(/title=['"]Copy failed['"]/, html)
  end

  def test_renders_live_feedback_region
    comp = ClipboardComponent.new(message: 'sample')
    html = render_component(comp)

    assert_match(/<span[^>]*class=['"][^'"]*\bsr-only\b[^'"]*['"]/, html)
    assert_match(/data-clipboard-target=['"]feedback['"]/, html)
    assert_match(/aria-live=['"]polite['"]/, html)
  end

  def test_preserves_custom_html_title_in_copy_tooltip_attribute
    raw_title = %(Copy MatPortal URI <a href="https://example.org">https://example.org</a>)
    comp = ClipboardComponent.new(title: raw_title, message: 'https://example.org')
    html = render_component(comp)

    # Tooltip on .copy must receive the custom title (with link) for Tippy
    assert_match(/data-controller=['"]tooltip['"]/, html)
    assert_match(/title=['"]Copy MatPortal URI &lt;a href=&quot;https:\/\/example\.org&quot;&gt;https:\/\/example\.org&lt;\/a&gt;['"]/, html)
    # Accessible button label must be plain text
    assert_match(/aria-label=['"]Copy MatPortal URI https:\/\/example\.org['"]/, html)
  end

  def test_message_escaping_prevents_xss_and_preserves_plain_text
    dangerous = %(<script>alert("xss")</script>&<xml tag="val">)
    comp = ClipboardComponent.new(message: dangerous, show_content: true)
    html = render_component(comp)

    # Must be escaped by Haml
    assert_includes html, '&lt;script&gt;alert(&quot;xss&quot;)&lt;/script&gt;&amp;&lt;xml tag=&quot;val&quot;&gt;'
    refute_includes html, '<script>alert'
    assert_equal dangerous, rendered_content_text(html)
  end

  # --- 3. Known Callers Fixtures ---

  def test_users_show_apikey_fixture
    # Synthetic fixture token for users/show apikey rendering check
    dummy_token = 'fixture-synthetic-token-user-12345'
    comp = ClipboardComponent.new(message: dummy_token)
    html = render_component(comp)

    assert_includes html, dummy_token
    assert_match(/data-clipboard-target=['"]content['"]/, html)
    assert_includes html, 'clipboard-btn'
    assert_equal dummy_token, rendered_content_text(html)
  end

  def test_htaccess_fixture_with_hidden_content_and_multiline_config
    htaccess_content = <<~APACHE
      RewriteEngine On
      RewriteCond %{HTTP_ACCEPT} text/turtle
      RewriteRule ^(.*)$ http://data.stage.matportal.org/$1 [R=303,L]
    APACHE

    comp = ClipboardComponent.new(message: htaccess_content, show_content: false)
    html = render_component(comp)

    # Hidden container
    assert_match(/class=['"][^'"]*\bd-none\b[^'"]*['"]/, html)
    assert_includes html, 'RewriteEngine On'
    assert_match(/data-clipboard-target=['"]content['"]/, html)
    # Button remains visible
    assert_includes html, 'clipboard-btn'
    assert_equal htaccess_content, rendered_content_text(html)
  end

  def test_components_helper_uri_copy_fixture
    url = 'https://stage.matportal.org/ontologies/TEST?concept=http%3A%2F%2Fexample.org%2Fc1&format=json'
    comp = ClipboardComponent.new(title: 'Copy original URI', message: url, show_content: false)
    html = render_component(comp)

    assert_match(/aria-label=['"]Copy original URI['"]/, html)
    assert_match(/title=['"]Copy original URI['"]/, html)
    assert_includes html, url.gsub('&', '&amp;')
    assert_equal url, rendered_content_text(html)
  end

  def test_rdf_highlighter_hidden_content_fixture
    rdf_content = '<owl:Class rdf:about="http://example.org#Test"/>'
    comp = ClipboardComponent.new(message: rdf_content, show_content: false)
    html = render_component(comp)

    assert_match(/class=['"][^'"]*\bd-none\b[^'"]*['"]/, html)
    assert_includes html, '&lt;owl:Class rdf:about=&quot;http://example.org#Test&quot;/&gt;'
    assert_equal rdf_content, rendered_content_text(html)
  end

  def test_french_locale_renders_french_messages_in_html
    I18n.locale = :fr
    comp = ClipboardComponent.new(message: 'valeur')
    html = render_component(comp)

    assert_match(/aria-label=['"]Copier['"]/, html)
    assert_match(/data-clipboard-copied-message-value=['"]Copié !['"]/, html)
    assert_match(/data-clipboard-failed-message-value=['"]Échec de la copie['"]/, html)
    assert_match(/title=['"]Copié !['"]/, html)
    assert_match(/title=['"]Échec de la copie['"]/, html)
  end

  # --- 4. Rendered DOM Text Fidelity (Nokogiri) ---

  def test_rendered_content_preserves_meaningful_leading_and_trailing_whitespace
    message = "  fixture<&>\n"
    comp = ClipboardComponent.new(message: message)
    html = render_component(comp)

    assert_equal message, rendered_content_text(html)
  end

  def test_rendered_content_preserves_empty_string
    comp = ClipboardComponent.new(message: '')
    html = render_component(comp)

    assert_equal '', rendered_content_text(html)
  end

  def test_rendered_content_hidden_flag_retains_exact_text_with_d_none
    message = 'hidden-exact-content-123'
    comp = ClipboardComponent.new(message: message, show_content: false)
    html = render_component(comp)

    target = parsed_content_target(html)
    refute_nil target
    assert_includes target['class'].split, 'd-none'
    assert_equal message, target.text
  end

  def test_captured_safe_markup_yields_text_with_escaping_boundary_unchanged
    safe_markup = %(<em>highlighted &amp; text</em>).html_safe
    comp = ClipboardComponent.new
    html = render_component(comp) { safe_markup }

    target = parsed_content_target(html)
    refute_nil target
    # Text content extracts decoded plain text
    assert_equal 'highlighted & text', target.text
    # Escaping boundary in rendered HTML preserves markup elements
    assert_includes target.inner_html, '<em>highlighted &amp; text</em>'
  end
end
