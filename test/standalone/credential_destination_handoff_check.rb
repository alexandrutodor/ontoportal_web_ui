# frozen_string_literal: true

require 'minitest/autorun'
require 'logger'
require 'ostruct'
require 'uri'
require 'cgi'
require 'rack'

# =============================================================================
# Standalone Native Caller URL-Policy & Credential Handoff Check (ONTO-T-B01)
#
# Validates the native caller seams of SafeUrlPolicy across:
# 1. LoginController#index:
#    - Sanitization of redirect candidate via SafeUrlPolicy.sanitize_redirect_param
#    - Session storage (session[:redirect])
#    - Haml form hidden field rendering (app/views/login/index.html.haml)
# 2. LoginController#create (Password login):
#    - Resolution of destination via SafeUrlPolicy.resolve_login_redirect
#    - Real ActionController redirect_to with allow_other_host guard
#    - Session cleanup and credential attachment
# 3. LoginController#create_omniauth (OmniAuth callback):
#    - Native token provider resolution and session-redirect consumption
#    - Real redirect_to and safe fallback
# 4. ApplicationHelper#api_button_link_and_target / #append_apikey_if_rest_url:
#    - Anonymous redirect wrapper vs direct API link
#    - Synthetic user vs fallback apikey attachment
# 5. OntologiesHelper#ontology_icon_links:
#    - Native metadata icon generation with real link_to and helper chaining
#
# Boundary & Isolation:
# - Minimal test routing preserving actual production routes:
#   `resources :login`, `get 'auth/:provider/callback', to: 'login#create_omniauth'`
# - ApplicationController unrelated callbacks isolated (:set_locale, :init_trial_license, etc.)
# - Zero real external network calls, IdP tokens, DB, or privileged credentials.
# - Strictly synthetic keys and example.org/reserved domain fixtures.
# =============================================================================

# Gem paths in native container environment
if Dir.exist?('/usr/local/bundle/ruby/3.1.0/gems') && (ENV['GEM_PATH'].nil? || !ENV['GEM_PATH'].include?('/usr/local/bundle/ruby/3.1.0'))
  Gem.use_paths(nil, Gem.path + ['/usr/local/bundle/ruby/3.1.0'])
end

WORKTREE_ROOT = File.expand_path('../..', __dir__)
$LOAD_PATH.unshift(File.join(WORKTREE_ROOT, 'app/helpers'))
$LOAD_PATH.unshift(File.join(WORKTREE_ROOT, 'app/controllers/concerns'))
$LOAD_PATH.unshift(File.join(WORKTREE_ROOT, 'app/controllers'))
$LOAD_PATH.unshift(File.join(WORKTREE_ROOT, 'app/components'))
$LOAD_PATH.unshift(File.join(WORKTREE_ROOT, 'app/services'))

require 'rails'
require 'action_controller'
require 'action_view'
require 'active_record'
require 'ontologies_api_client'
require 'haml'

# Initialize minimal Rails application
app = Class.new(Rails::Application) do
  config.eager_load = false
  config.secret_key_base = '0' * 64
end
Rails.application = app.new

# Actual production route seams under test
Rails.application.routes.draw do
  resources :login
  get 'auth/:provider/callback', to: 'login#create_omniauth'
  get '/users/new', to: 'users#new', as: :new_user
  root to: 'home#index'
end

# Required production helpers and models
require 'urls_helper'
require 'terms_reuses'
require 'components_helper'
require 'ontologies_helper'
require 'internationalisation_helper'
require 'multi_languages_helper'
require 'modal_helper'
require 'application_helper'
require 'safe_url_policy'
require 'application_controller'
require 'login_controller'

# Configure locale dictionary from actual YAML files
I18n.load_path = Dir[File.join(WORKTREE_ROOT, 'config/locales/*.yml')]
I18n.default_locale = :en
I18n.locale = :en

# Controller configuration & isolation
ActionController::Base.allow_forgery_protection = false
ActionController::Base.include Rails.application.routes.url_helpers
ActionView::Base.include Rails.application.routes.url_helpers
ActionController::Base.logger = Logger.new(nil)
Rails.logger = Logger.new(nil)

ApplicationController.skip_before_action :set_locale, :set_global_thread_values, :domain_ontology_set,
                                        :clean_empty_strings_from_params_arrays, :init_trial_license,
                                        raise: false
LoginController.layout false

# Component doubles for login Haml view rendering fidelity
module Display
  class AlertComponent
    def initialize(**opts); @opts = opts; end
    def render_in(_); ''.html_safe; end
  end
  class InfoTooltipComponent
    def initialize(**opts); @opts = opts; end
    def render_in(_); ''.html_safe; end
  end
end

module Buttons
  class RegularButtonComponent
    def initialize(**opts); @opts = opts; end
    def render_in(_); "<button id=\"#{@opts[:id]}\">#{@opts[:value]}</button>".html_safe; end
  end
end

class CredentialDestinationHandoffCheck < Minitest::Test
  # Synthetic reserved domain test origins
  UI_HOST = 'stage.matportal.org'
  SYNTHETIC_REST_URL = 'http://data.matportal.org'
  SYNTHETIC_FAIRNESS_URL = 'https://fairness.stage.matportal.org'
  SYNTHETIC_FALLBACK_KEY = 'synthetic-fallback-key-00000' # gitleaks:allow
  SYNTHETIC_USER_KEY = 'synthetic-current-user-key-77777' # gitleaks:allow
  SYNTHETIC_OAUTH_KEY = 'synthetic-oauth-user-key-88888' # gitleaks:allow

  def setup
    I18n.locale = :en
    $REST_URL = SYNTHETIC_REST_URL
    $FAIRNESS_URL = SYNTHETIC_FAIRNESS_URL
    $UI_URL = "https://#{UI_HOST}"
    $HOSTNAME = UI_HOST
    $API_KEY = SYNTHETIC_FALLBACK_KEY

    LinkedData::Client.config do |config|
      config.rest_url = SYNTHETIC_REST_URL
      config.apikey = SYNTHETIC_FALLBACK_KEY
    end

    $OMNIAUTH_PROVIDERS = {
      keycloak: { name: 'keycloak', strategy: :keycloak_openid, enable: true }
    }
  end

  # ===========================================================================
  # 1. LoginController#index Sanitization, Session Storage, and Haml Form Value
  # ===========================================================================

  def test_login_index_sanitizes_destinations_and_populates_session_and_haml_form
    cases = [
      {
        name: 'foreign_rest_in_query',
        raw: "https://attacker.example.org/phish?target=#{SYNTHETIC_REST_URL}/ontologies",
        expected_sanitized: nil,
        expected_session: nil,
        expect_form_value: false
      },
      {
        name: 'foreign_rest_in_path',
        raw: "https://attacker.example.org/#{SYNTHETIC_REST_URL}/download",
        expected_sanitized: nil,
        expected_session: nil,
        expect_form_value: false
      },
      {
        name: 'approved_local_path',
        raw: '/ontologies/RADX?tab=views#summary',
        expected_sanitized: '/ontologies/RADX?tab=views#summary',
        expected_session: '/ontologies/RADX?tab=views#summary',
        expect_form_value: true
      },
      {
        name: 'approved_rest_subpath',
        raw: "#{SYNTHETIC_REST_URL}/ontologies/RADX/download",
        expected_sanitized: "#{SYNTHETIC_REST_URL}/ontologies/RADX/download",
        expected_session: "#{SYNTHETIC_REST_URL}/ontologies/RADX/download",
        expect_form_value: true
      },
      {
        name: 'approved_fairness_subpath',
        raw: "#{SYNTHETIC_FAIRNESS_URL}/eval?ontologies=RADX",
        expected_sanitized: "#{SYNTHETIC_FAIRNESS_URL}/eval?ontologies=RADX",
        expected_session: "#{SYNTHETIC_FAIRNESS_URL}/eval?ontologies=RADX",
        expect_form_value: true
      },
      {
        name: 'complex_unicode_and_plus',
        raw: "#{SYNTHETIC_REST_URL}/ontologies/RADX/concepts/M%C3%BCnchen+City?filter=A%26B%3DC#frag",
        expected_sanitized: "#{SYNTHETIC_REST_URL}/ontologies/RADX/concepts/M%C3%BCnchen+City?filter=A%26B%3DC#frag",
        expected_session: "#{SYNTHETIC_REST_URL}/ontologies/RADX/concepts/M%C3%BCnchen+City?filter=A%26B%3DC#frag",
        expect_form_value: true
      },
      {
        name: 'security_wrong_port',
        raw: "#{SYNTHETIC_REST_URL}:9999/ontologies",
        expected_sanitized: nil,
        expected_session: nil,
        expect_form_value: false
      },
      {
        name: 'security_userinfo',
        raw: "http://attacker:secret@data.matportal.org/ontologies",
        expected_sanitized: nil,
        expected_session: nil,
        expect_form_value: false
      },
      {
        name: 'security_protocol_relative',
        raw: '//attacker.example.org/ontologies',
        expected_sanitized: nil,
        expected_session: nil,
        expect_form_value: false
      },
      {
        name: 'security_dot_traversal',
        raw: "#{SYNTHETIC_REST_URL}/../outside",
        expected_sanitized: nil,
        expected_session: nil,
        expect_form_value: false
      }
    ]

    cases.each do |c|
      ctrl, req, res = dispatch_request(
        LoginController,
        :index,
        method: :get,
        url: "https://#{UI_HOST}/login?redirect=#{CGI.escape(c[:raw])}",
        params: { redirect: c[:raw] }
      )

      sanitized_url = ctrl.instance_variable_get(:@redirect_url)
      if c[:expected_sanitized].nil?
        assert_nil sanitized_url, "[#{c[:name]}] @redirect_url should be nil"
      else
        assert_equal c[:expected_sanitized], sanitized_url, "[#{c[:name]}] @redirect_url mismatch"
      end

      if c[:expected_session].nil?
        assert_nil ctrl.session[:redirect], "[#{c[:name]}] session[:redirect] should be nil"
      else
        assert_equal c[:expected_session], ctrl.session[:redirect], "[#{c[:name]}] session[:redirect] mismatch"
      end

      # Render actual login/index.html.haml template to verify hidden field value
      view = ctrl.view_context
      view.extend ApplicationHelper
      def view.inline_svg(*_); '<svg></svg>'.html_safe; end

      template_path = File.join(WORKTREE_ROOT, 'app/views/login/index.html.haml')
      rendered_haml = Haml::Engine.new(File.read(template_path)).render(view)

      if c[:expect_form_value]
        expected_escaped = CGI.escapeHTML(c[:expected_sanitized])
        assert_includes rendered_haml, %(value="#{expected_escaped}"),
                        "[#{c[:name]}] Haml form must include sanitized redirect value"
      else
        refute_includes rendered_haml, %(value="#{CGI.escapeHTML(c[:raw])}"),
                        "[#{c[:name]}] Haml form must NOT include rejected foreign target"
        refute_match(/name="redirect"[^>]+value="[^"]+"/, rendered_haml,
                     "[#{c[:name]}] Haml form must have empty or absent redirect value on rejection")
      end
    end
  end

  # ===========================================================================
  # 2. LoginController#create Native Password Authentication Handoff Matrix
  # ===========================================================================

  def test_login_create_password_handoff_matrix
    synthetic_user = OpenStruct.new(
      id: 101,
      username: 'alice',
      apikey: SYNTHETIC_USER_KEY,
      errors: nil,
      customOntology: []
    )

    # Stub native authenticate method only; real action/redirect logic executes
    LinkedData::Client::Models::User.define_singleton_method(:authenticate) do |user, _pass|
      synthetic_user if user == 'alice'
    end

    matrix = [
      {
        name: 'foreign_rest_in_query_falls_back_local',
        input: "https://attacker.example.org/phish?target=#{SYNTHETIC_REST_URL}",
        expected_location_host: UI_HOST,
        expected_location_path: '/',
        expect_key_attached: false
      },
      {
        name: 'foreign_rest_in_path_falls_back_local',
        input: "https://attacker.example.org/#{SYNTHETIC_REST_URL}/download",
        expected_location_host: UI_HOST,
        expected_location_path: '/',
        expect_key_attached: false
      },
      {
        name: 'approved_local_path_preserved',
        input: '/ontologies/RADX?tab=views#summary',
        expected_location_host: UI_HOST,
        expected_location_path: '/ontologies/RADX',
        expected_query: 'tab=views',
        expected_fragment: 'summary',
        expect_key_attached: false
      },
      {
        name: 'approved_rest_subpath_attaches_synthetic_user_key',
        input: "#{SYNTHETIC_REST_URL}/ontologies/RADX/download",
        expected_location_host: URI.parse(SYNTHETIC_REST_URL).host,
        expected_location_path: '/ontologies/RADX/download',
        expect_key_attached: true
      },
      {
        name: 'approved_fairness_subpath_attaches_synthetic_user_key',
        input: "#{SYNTHETIC_FAIRNESS_URL}/eval?ontologies=RADX",
        expected_location_host: URI.parse(SYNTHETIC_FAIRNESS_URL).host,
        expected_location_path: '/eval',
        expected_param_ontologies: 'RADX',
        expect_key_attached: true
      },
      {
        name: 'complex_unicode_plus_encoded_delimiters_and_hash',
        input: "#{SYNTHETIC_REST_URL}/ontologies/RADX/concepts/M%C3%BCnchen+City?filter=A%26B%3DC&q=Gr%C3%B6%C3%9Fe#section2",
        expected_location_host: URI.parse(SYNTHETIC_REST_URL).host,
        expected_location_path: '/ontologies/RADX/concepts/M%C3%BCnchen+City',
        expected_fragment: 'section2',
        expected_param_filter: 'A&B=C',
        expected_param_q: 'Größe',
        expect_key_attached: true
      },
      {
        name: 'duplicate_stale_apikey_replaced_with_single_user_key',
        input: "#{SYNTHETIC_REST_URL}/ontologies/RADX?apikey=STALE_1&format=json&apikey=STALE_2",
        expected_location_host: URI.parse(SYNTHETIC_REST_URL).host,
        expected_location_path: '/ontologies/RADX',
        expected_param_format: 'json',
        expect_key_attached: true
      },
      {
        name: 'wrong_port_falls_back_local',
        input: "#{SYNTHETIC_REST_URL}:9999/ontologies",
        expected_location_host: UI_HOST,
        expected_location_path: '/',
        expect_key_attached: false
      },
      {
        name: 'userinfo_target_falls_back_local',
        input: 'http://attacker:pass@data.matportal.org/ontologies',
        expected_location_host: UI_HOST,
        expected_location_path: '/',
        expect_key_attached: false
      },
      {
        name: 'protocol_relative_target_falls_back_local',
        input: '//attacker.example.org/ontologies',
        expected_location_host: UI_HOST,
        expected_location_path: '/',
        expect_key_attached: false
      },
      {
        name: 'leading_double_slash_falls_back_local',
        input: "https://#{UI_HOST}//attacker.example.org/test",
        expected_location_host: UI_HOST,
        expected_location_path: '/',
        expect_key_attached: false
      },
      {
        name: 'dot_segment_traversal_falls_back_local',
        input: "#{SYNTHETIC_REST_URL}/../escaped",
        expected_location_host: UI_HOST,
        expected_location_path: '/',
        expect_key_attached: false
      }
    ]

    matrix.each do |c|
      session_store = { redirect: c[:input] }
      ctrl, req, res = dispatch_request(
        LoginController,
        :create,
        method: :post,
        params: {
          user: { username: 'alice', password: 'valid_password' },
          redirect: c[:input]
        },
        session: session_store
      )

      assert_equal 302, res.status, "[#{c[:name]}] Expected redirect status 302"
      assert_nil ctrl.session[:redirect], "[#{c[:name]}] session[:redirect] must be deleted after consumption"
      assert_equal synthetic_user, ctrl.session[:user], "[#{c[:name]}] session[:user] must be set"

      location = res.headers['Location']
      refute_nil location, "[#{c[:name]}] Location header must be present"
      loc_uri = URI.parse(location)

      # Host and path validation
      if loc_uri.host
        assert_equal c[:expected_location_host], loc_uri.host, "[#{c[:name]}] Emitted host mismatch"
      end
      assert_equal c[:expected_location_path], loc_uri.path, "[#{c[:name]}] Emitted path mismatch"

      # Rack-decoded query inspection
      query_params = loc_uri.query ? Rack::Utils.parse_nested_query(loc_uri.query) : {}
      raw_query_pairs = loc_uri.query ? URI.decode_www_form(loc_uri.query) : []

      if c[:expect_key_attached]
        assert_equal SYNTHETIC_USER_KEY, query_params['apikey'],
                     "[#{c[:name]}] Permitted destination must receive synthetic current-user apikey"
        apikey_count = raw_query_pairs.count { |k, _| k == 'apikey' }
        assert_equal 1, apikey_count, "[#{c[:name]}] Permitted destination must have exactly 1 apikey param"
        refute_includes location, 'STALE_1'
        refute_includes location, 'STALE_2'
      else
        assert_nil query_params['apikey'], "[#{c[:name]}] Local/foreign destination must NOT receive apikey"
        refute_includes location, SYNTHETIC_USER_KEY
        refute_includes location, SYNTHETIC_FALLBACK_KEY
      end

      # Query parameter & fragment preservation
      if c[:expected_query]
        assert_equal c[:expected_query], loc_uri.query, "[#{c[:name]}] Query string mismatch"
      end
      if c[:expected_fragment]
        assert_equal c[:expected_fragment], loc_uri.fragment, "[#{c[:name]}] Fragment mismatch"
      end
      if c[:expected_param_ontologies]
        assert_equal c[:expected_param_ontologies], query_params['ontologies'], "[#{c[:name]}] ontologies param mismatch"
      end
      if c[:expected_param_filter]
        assert_equal c[:expected_param_filter], query_params['filter'], "[#{c[:name]}] filter param mismatch"
      end
      if c[:expected_param_q]
        assert_equal c[:expected_param_q], query_params['q'], "[#{c[:name]}] q param mismatch"
      end
      if c[:expected_param_format]
        assert_equal c[:expected_param_format], query_params['format'], "[#{c[:name]}] format param mismatch"
      end
    end
  end

  # ===========================================================================
  # 3. LoginController#create_omniauth Native Callback Handoff Matrix
  # ===========================================================================

  def test_login_create_omniauth_handoff_matrix
    synthetic_oauth_user = OpenStruct.new(
      id: 202,
      username: 'keycloak_alice',
      apikey: SYNTHETIC_OAUTH_KEY,
      errors: nil,
      customOntology: []
    )

    # Stub native LinkedData::Client::HTTP.post token exchange response only
    LinkedData::Client::HTTP.define_singleton_method(:post) do |url, payload|
      synthetic_oauth_user if payload[:token_provider] == :keycloak
    end

    matrix = [
      {
        name: 'omniauth_foreign_rest_in_query_falls_back_local',
        input: "https://attacker.example.org/phish?target=#{SYNTHETIC_REST_URL}",
        expected_host: UI_HOST,
        expected_path: '/',
        expect_key_attached: false
      },
      {
        name: 'omniauth_approved_local_path_preserved',
        input: '/ontologies/RADX?tab=views#summary',
        expected_host: UI_HOST,
        expected_path: '/ontologies/RADX',
        expected_query: 'tab=views',
        expected_fragment: 'summary',
        expect_key_attached: false
      },
      {
        name: 'omniauth_approved_rest_subpath_attaches_synthetic_oauth_key',
        input: "#{SYNTHETIC_REST_URL}/ontologies/RADX/download",
        expected_host: URI.parse(SYNTHETIC_REST_URL).host,
        expected_path: '/ontologies/RADX/download',
        expect_key_attached: true
      },
      {
        name: 'omniauth_complex_unicode_plus_and_delimiters',
        input: "#{SYNTHETIC_REST_URL}/ontologies/RADX/concepts/M%C3%BCnchen+City?filter=A%26B%3DC#frag",
        expected_host: URI.parse(SYNTHETIC_REST_URL).host,
        expected_path: '/ontologies/RADX/concepts/M%C3%BCnchen+City',
        expected_fragment: 'frag',
        expected_filter: 'A&B=C',
        expect_key_attached: true
      },
      {
        name: 'omniauth_duplicate_apikey_replaced',
        input: "#{SYNTHETIC_REST_URL}/ontologies/RADX?apikey=OLD_A&apikey=OLD_B&type=owl",
        expected_host: URI.parse(SYNTHETIC_REST_URL).host,
        expected_path: '/ontologies/RADX',
        expected_type: 'owl',
        expect_key_attached: true
      },
      {
        name: 'omniauth_userinfo_falls_back_local',
        input: 'http://admin:pass@data.matportal.org/ontologies',
        expected_host: UI_HOST,
        expected_path: '/',
        expect_key_attached: false
      }
    ]

    matrix.each do |c|
      session_store = { redirect: c[:input] }
      ctrl, req, res = dispatch_request(
        LoginController,
        :create_omniauth,
        method: :get,
        params: { provider: 'keycloak' },
        session: session_store,
        env: {
          'omniauth.auth' => OpenStruct.new(
            credentials: OpenStruct.new(token: 'synthetic-jwt-keycloak-token')
          )
        }
      )

      assert_equal 302, res.status, "[#{c[:name]}] Expected redirect status 302"
      assert_nil ctrl.session[:redirect], "[#{c[:name]}] session[:redirect] must be deleted"
      assert_equal synthetic_oauth_user, ctrl.session[:user], "[#{c[:name]}] session[:user] must be set"

      location = res.headers['Location']
      refute_nil location, "[#{c[:name]}] Location header must be present"
      loc_uri = URI.parse(location)

      if loc_uri.host
        assert_equal c[:expected_host], loc_uri.host, "[#{c[:name]}] Host mismatch"
      end
      assert_equal c[:expected_path], loc_uri.path, "[#{c[:name]}] Path mismatch"

      query_params = loc_uri.query ? Rack::Utils.parse_nested_query(loc_uri.query) : {}
      raw_query_pairs = loc_uri.query ? URI.decode_www_form(loc_uri.query) : []

      if c[:expect_key_attached]
        assert_equal SYNTHETIC_OAUTH_KEY, query_params['apikey'],
                     "[#{c[:name]}] Permitted destination must receive synthetic OAuth user apikey"
        apikey_count = raw_query_pairs.count { |k, _| k == 'apikey' }
        assert_equal 1, apikey_count, "[#{c[:name]}] Must have exactly 1 apikey param"
        refute_includes location, 'OLD_A'
        refute_includes location, 'OLD_B'
      else
        assert_nil query_params['apikey'], "[#{c[:name]}] Local/foreign destination must NOT receive apikey"
        refute_includes location, SYNTHETIC_OAUTH_KEY
        refute_includes location, SYNTHETIC_FALLBACK_KEY
      end

      if c[:expected_query]
        assert_equal c[:expected_query], loc_uri.query, "[#{c[:name]}] Query string mismatch"
      end
      if c[:expected_fragment]
        assert_equal c[:expected_fragment], loc_uri.fragment, "[#{c[:name]}] Fragment mismatch"
      end
      if c[:expected_filter]
        assert_equal c[:expected_filter], query_params['filter'], "[#{c[:name]}] Filter param mismatch"
      end
      if c[:expected_type]
        assert_equal c[:expected_type], query_params['type'], "[#{c[:name]}] Type param mismatch"
      end
    end
  end

  # ===========================================================================
  # 4. ApplicationHelper#api_button_link_and_target Native Helper Handoff
  # ===========================================================================

  def test_application_helper_api_link_and_target_native_handoff
    ctrl = LoginController.new
    req = ActionDispatch::TestRequest.create('rack.session' => {})
    ctrl.set_request!(req)
    view = ctrl.view_context
    view.extend ApplicationHelper

    # 4A. Anonymous session with allow_annonymous = false -> redirects through /login?redirect=...
    def view.current_user; nil; end
    view.session[:user] = nil

    target_rest = "#{SYNTHETIC_REST_URL}/ontologies/RADX"
    login_handoff, target_attr = view.api_button_link_and_target(target_rest, false)
    assert_equal '_top', target_attr
    assert_equal "/login?redirect=#{CGI.escape(target_rest)}", login_handoff
    refute_includes login_handoff, SYNTHETIC_FALLBACK_KEY
    refute_includes login_handoff, SYNTHETIC_USER_KEY

    # 4B. Anonymous session with allow_annonymous = true -> attaches fallback apikey on permitted service
    anon_direct, target_attr = view.api_button_link_and_target(target_rest, true)
    assert_equal '_blank', target_attr
    assert_equal "#{target_rest}?apikey=#{SYNTHETIC_FALLBACK_KEY}", anon_direct

    # 4C. Anonymous session with allow_annonymous = true on foreign URL -> NO key attached
    foreign_url = "https://attacker.example.org/phish?target=#{SYNTHETIC_REST_URL}"
    foreign_direct, target_attr = view.api_button_link_and_target(foreign_url, true)
    assert_equal '_blank', target_attr
    assert_equal foreign_url, foreign_direct
    refute_includes foreign_direct, SYNTHETIC_FALLBACK_KEY

    # 4D. Authenticated session -> attaches current_user apikey on permitted service
    synthetic_user = OpenStruct.new(id: 303, username: 'alice', apikey: SYNTHETIC_USER_KEY)
    view.define_singleton_method(:current_user) { synthetic_user }
    view.session[:user] = synthetic_user

    auth_direct, target_attr = view.api_button_link_and_target(target_rest, false)
    assert_equal '_blank', target_attr
    assert_equal "#{target_rest}?apikey=#{SYNTHETIC_USER_KEY}", auth_direct

    # 4E. Authenticated session on foreign URL -> NO key attached
    auth_foreign, target_attr = view.api_button_link_and_target(foreign_url, false)
    assert_equal '_blank', target_attr
    assert_equal foreign_url, auth_foreign
    refute_includes auth_foreign, SYNTHETIC_USER_KEY
    refute_includes auth_foreign, SYNTHETIC_FALLBACK_KEY

    # 4F. Authenticated session on complex unicode/plus/delimited destination
    complex_target = "#{SYNTHETIC_REST_URL}/ontologies/RADX/concepts/M%C3%BCnchen+City?filter=A%26B%3DC#frag"
    complex_direct, _ = view.api_button_link_and_target(complex_target, false)
    assert_includes complex_direct, 'M%C3%BCnchen+City'
    assert_includes complex_direct, 'filter=A%26B%3DC'
    assert_includes complex_direct, "apikey=#{SYNTHETIC_USER_KEY}"
    assert complex_direct.end_with?('#frag')

    # 4G. Authenticated session with duplicate apikey in link
    dup_target = "#{SYNTHETIC_REST_URL}/ontologies/RADX?apikey=OLD_KEY&format=json"
    dup_direct, _ = view.api_button_link_and_target(dup_target, false)
    refute_includes dup_direct, 'OLD_KEY'
    assert_includes dup_direct, "apikey=#{SYNTHETIC_USER_KEY}"
    parsed_dup = URI.parse(dup_direct)
    raw_pairs = URI.decode_www_form(parsed_dup.query)
    assert_equal 1, raw_pairs.count { |k, _| k == 'apikey' }
    assert_equal SYNTHETIC_USER_KEY, raw_pairs.assoc('apikey')[1]
  end

  # ===========================================================================
  # 5. OntologiesHelper#ontology_icon_links Native Metadata Icon Handoff
  # ===========================================================================

  def test_ontologies_helper_metadata_icon_links_native_handoff
    ctrl = LoginController.new
    req = ActionDispatch::TestRequest.create('rack.session' => {})
    ctrl.set_request!(req)
    view = ctrl.view_context
    view.extend OntologiesHelper
    view.extend ApplicationHelper

    def view.inline_svg(*_); '<svg></svg>'.html_safe; end
    def view.url_for(options = nil)
      case options
      when String then options
      when Hash
        # Support tooltip pseudo-link link_to(link, target: '_blank')
        options[:target] ? '#' : super
      else
        super
      end
    end

    synthetic_user = OpenStruct.new(id: 404, username: 'alice', apikey: SYNTHETIC_USER_KEY)
    view.define_singleton_method(:current_user) { synthetic_user }
    view.session[:user] = synthetic_user

    links = [['download', :pullLocation, 'Download Link']]

    # 5A. Permitted REST download link receives synthetic user apikey
    valid_submission = OpenStruct.new(pullLocation: "#{SYNTHETIC_REST_URL}/ontologies/RADX/download")
    html_valid = view.ontology_icon_links(links, valid_submission)
    href_match = html_valid.match(/href="([^"]+)"/)
    refute_nil href_match, 'Generated HTML must contain href attribute'
    emitted_href = href_match[1]

    assert_includes emitted_href, "apikey=#{SYNTHETIC_USER_KEY}"
    loc_uri = URI.parse(emitted_href)
    raw_pairs = URI.decode_www_form(loc_uri.query)
    assert_equal 1, raw_pairs.count { |k, _| k == 'apikey' }
    assert_equal SYNTHETIC_USER_KEY, raw_pairs.assoc('apikey')[1]

    # 5B. Foreign link containing REST URL in query receives NO apikey
    foreign_submission = OpenStruct.new(pullLocation: "https://attacker.example.org/evil?target=#{SYNTHETIC_REST_URL}")
    html_foreign = view.ontology_icon_links(links, foreign_submission)
    foreign_href_match = html_foreign.match(/<a[^>]+target="_blank"[^>]+href="([^"]+)"/)
    refute_nil foreign_href_match, 'Generated HTML must contain <a> tag'
    foreign_href = CGI.unescapeHTML(foreign_href_match[1])

    assert_equal "https://attacker.example.org/evil?target=#{SYNTHETIC_REST_URL}", foreign_href
    refute_includes foreign_href, SYNTHETIC_USER_KEY
    refute_includes foreign_href, SYNTHETIC_FALLBACK_KEY
    refute_includes foreign_href, 'apikey='

    # 5C. Complex unicode and plus link preserves characters and attaches single key
    complex_target = "#{SYNTHETIC_REST_URL}/ontologies/RADX/download?file=M%C3%BCnchen+Schema.owl&rev=1%262#desc"
    complex_submission = OpenStruct.new(pullLocation: complex_target)
    html_complex = view.ontology_icon_links(links, complex_submission)
    complex_href = CGI.unescapeHTML(html_complex.match(/<a[^>]+target="_blank"[^>]+href="([^"]+)"/)[1])

    assert_includes complex_href, 'M%C3%BCnchen+Schema.owl'
    assert_includes complex_href, 'rev=1%262'
    assert_includes complex_href, "apikey=#{SYNTHETIC_USER_KEY}"
    assert complex_href.end_with?('#desc')

    # 5D. Security vector (userinfo) receives NO apikey
    userinfo_target = 'http://attacker:pass@data.matportal.org/download'
    userinfo_submission = OpenStruct.new(pullLocation: userinfo_target)
    html_userinfo = view.ontology_icon_links(links, userinfo_submission)
    userinfo_href = CGI.unescapeHTML(html_userinfo.match(/<a[^>]+target="_blank"[^>]+href="([^"]+)"/)[1])

    assert_equal userinfo_target, userinfo_href
    refute_includes userinfo_href, SYNTHETIC_USER_KEY
    refute_includes userinfo_href, 'apikey='
  end

  private

  def dispatch_request(ctrl_class, action, method: :get, params: {}, session: {}, env: {}, host: UI_HOST, url: nil)
    ctrl = ctrl_class.new
    req_env = {
      'HTTP_HOST' => host,
      'rack.session' => session,
      'action_dispatch.request.flash_hash' => ActionDispatch::Flash::FlashHash.new
    }.merge(env)

    if url
      parsed = URI.parse(url) rescue nil
      if parsed
        req_env['rack.url_scheme'] = parsed.scheme if parsed.scheme
        req_env['HTTP_HOST'] = parsed.host if parsed.host
        req_env['PATH_INFO'] = parsed.path if parsed.path
        req_env['QUERY_STRING'] = parsed.query if parsed.query
      end
    end

    req = ActionDispatch::TestRequest.create(req_env)
    req.request_method = method.to_s.upcase
    params.each { |k, v| req.params[k] = v }
    res = ActionDispatch::TestResponse.create
    ctrl.set_request!(req)
    ctrl.set_response!(res)

    ctrl.define_singleton_method(:default_render) do |*args|
      render plain: "rendered: #{action_name}"
    end

    ctrl.process(action)
    [ctrl, req, res]
  end
end
