# frozen_string_literal: true

require 'minitest/autorun'
require 'haml'

# =============================================================================
# Standalone Offline Cookie Consent Mutation Regression Test (ONTO-T-B02)
#
# Tests actual HomeController#set_cookies with request/cookie/render doubles.
# Validates GET/HEAD zero writes, POST exact permanent cookie persistence,
# and verifies the caller Haml template uses button_to POST with cookies: true.
# No full Rails/ActionView bootstrap, bundle invocation, network, or DB needed.
# =============================================================================

# Minimal ApplicationController stub and unused helper modules
class ApplicationController
  def self.layout(*); end

  attr_accessor :params, :request, :cookies, :rendered

  def render(template, options = {})
    @rendered = { template: template, options: options }
  end
end

module FairScoreHelper; end
module FederationHelper; end
module MetricsHelper; end
module AgentHelper; end

# Load the actual controller under test
require_relative '../../app/controllers/home_controller'

class CookieJarDouble
  attr_reader :store, :permanent_store

  def initialize(initial_store = {})
    @store = initial_store.dup
    @permanent_store = {}
  end

  def [](key)
    @permanent_store[key] || @store[key]
  end

  def []=(key, value)
    @store[key] = value
  end

  def permanent
    @permanent_store
  end
end

class RequestDouble
  attr_accessor :method

  def initialize(method = 'GET')
    @method = method.to_s.upcase
  end

  def post?
    @method == 'POST'
  end

  def get?
    @method == 'GET'
  end

  def head?
    @method == 'HEAD'
  end
end

class CookieMutationRegressionTest < Minitest::Test
  def setup
    @controller = HomeController.new
    @controller.cookies = CookieJarDouble.new
  end

  def test_get_request_with_cookies_param_does_not_mutate_state
    @controller.request = RequestDouble.new('GET')
    @controller.params = { cookies: 'true' }

    @controller.set_cookies

    assert_empty @controller.cookies.permanent_store, 'GET request with cookies=true must not write permanent cookies'
    assert_equal({ template: 'cookies', options: { layout: nil } }, @controller.rendered)
  end

  def test_head_request_with_cookies_param_does_not_mutate_state
    @controller.request = RequestDouble.new('HEAD')
    @controller.params = { cookies: 'true' }

    @controller.set_cookies

    assert_empty @controller.cookies.permanent_store, 'HEAD request with cookies=true must not write permanent cookies'
    assert_equal({ template: 'cookies', options: { layout: nil } }, @controller.rendered)
  end

  def test_post_request_without_cookies_param_does_not_mutate_state
    @controller.request = RequestDouble.new('POST')
    @controller.params = {}

    @controller.set_cookies

    assert_empty @controller.cookies.permanent_store, 'POST request without cookies param must not write permanent cookies'
    assert_equal({ template: 'cookies', options: { layout: nil } }, @controller.rendered)
  end

  def test_post_request_with_cookies_param_persists_choice
    @controller.request = RequestDouble.new('POST')
    @controller.params = { cookies: 'true' }

    @controller.set_cookies

    assert_equal 'true', @controller.cookies.permanent_store[:cookies_accepted],
                 'POST request with cookies=true must write permanent cookies_accepted choice'
    assert_equal({ template: 'cookies', options: { layout: nil } }, @controller.rendered)
  end

  def test_view_template_source_and_haml_caller
    view_path = File.expand_path('../../app/views/home/cookies.html.haml', __dir__)
    source = File.read(view_path)

    # Source caller assertions
    assert_includes source, 'button_to', 'Accept control must use button_to'
    assert_includes source, 'cookies_path', 'Accept control must target cookies_path'
    assert_includes source, 'method: :post', 'Accept control must use POST method'
    assert_includes source, 'params: { cookies: true }', 'Accept control must pass params cookies: true'
    assert_includes source, "id: 'accept-cookie-selector'", 'Accept control must preserve id accept-cookie-selector'
    assert_includes source, "class: 'regular-button slim primary-button'", 'Accept control must preserve styling classes'
    assert_includes source, 'turbo_frame_tag :cookies_modal', 'Must preserve turbo_frame_tag :cookies_modal'
    assert_includes source, 'cookies[:cookies_accepted].nil?', 'Must preserve nil/selected condition check'
    refute_includes source, 'link_button_component', 'Old GET link component must be replaced'

    # Installed Haml syntax & compilation check
    engine = Haml::Engine.new(source)
    view_context = Class.new do
      attr_reader :invocations

      def initialize
        @invocations = []
      end

      def turbo_frame_tag(name, &block)
        "<turbo-frame id=\"#{name}\">#{block ? block.call : ''}</turbo-frame>"
      end

      def cookies
        {}
      end

      def t(key, **_opts)
        key
      end

      def portal_name
        'MatPortal'
      end

      def cookies_path(args = {})
        '/cookies'
      end

      def link_to(name, href)
        "<a href=\"#{href}\">#{name}</a>"
      end

      def button_to(name, url, method: :post, params: nil, **html_options)
        @invocations << { name: name, url: url, method: method, params: params, html_options: html_options }
        "<button id=\"#{html_options[:id]}\" class=\"#{html_options[:class]}\">#{name}</button>"
      end
    end.new

    $FOOTER_LINKS = { sections: { agreements: { privacy_policy: '/privacy' } } }
    rendered_output = engine.render(view_context)

    assert_equal 1, view_context.invocations.size
    call = view_context.invocations.first
    assert_equal 'cookies_modal.accept_button', call[:name]
    assert_equal '/cookies', call[:url]
    assert_equal :post, call[:method]
    assert_equal({ cookies: true }, call[:params])
    assert_equal 'accept-cookie-selector', call[:html_options][:id]
    assert_equal 'regular-button slim primary-button', call[:html_options][:class]
    assert_includes rendered_output, 'id="accept-cookie-selector"'
  end
end
