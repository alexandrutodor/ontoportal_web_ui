# frozen_string_literal: true

require 'minitest/autorun'
require 'uri'
require 'cgi'
require 'haml'
require 'yaml'
require 'ostruct'

# =============================================================================
# Standalone Offline Auth Mutation Regression Test (ONTO-T-B02 Account Slice)
#
# Tests actual controller/action logic with no-network API and session doubles,
# explicit route model coverage, Haml template compilation, and CSRF token fixture.
# No actual services/API/browser/DB/Docker or package installs required.
# =============================================================================

# --- 1. Environment & Base Doubles for Controller Execution ---

class String
  def html_safe
    self
  end

  def blank?
    strip.empty?
  end

  def presence
    blank? ? nil : self
  end

  def singularize
    sub(/ies$/, "y").sub(/s$/, "")
  end unless method_defined?(:singularize)

  def pluralize
    "#{self}s"
  end unless method_defined?(:pluralize)
end

class NilClass
  def blank?
    true
  end

  def presence
    nil
  end
end

# Minimal ApplicationController stub providing Rails controller infrastructure
class ApplicationController
  def self.layout(*); end
  def self.before_action(*); end

  attr_accessor :session, :params, :flash, :request, :rendered, :redirected_to

  def initialize
    @session = {}
    @params = {}
    @flash = {}
    @rendered = nil
    @redirected_to = nil
  end

  def t(key, options = {})
    # Simple localization resolver using loaded YAML catalogs or fallback
    @locales ||= begin
      en = YAML.load_file(File.expand_path('../../config/locales/en.yml', __dir__))
      en['en'] || {}
    rescue StandardError
      {}
    end

    parts = key.to_s.split('.')
    val = parts.inject(@locales) { |acc, k| acc.is_a?(Hash) ? acc[k] : nil }
    val ||= key.to_s

    if val.is_a?(String) && options.any?
      result = val.dup
      options.each do |k, v|
        result = result.gsub("%{#{k}}", v.to_s)
      end
      result
    else
      val.to_s
    end
  end

  def render(options)
    @rendered = options
  end

  def redirect_to(target, **_options)
    @redirected_to = target
  end

  def helpers
    self
  end

  def omniauth_token_provider(provider)
    provider.to_s
  end
end

# Fake LinkedData client models and HTTP client doubles (no network)
module LinkedData
  module Client
    class HTTP
      class << self
        attr_accessor :post_calls

        def reset!
          @post_calls = []
          @post_handler = nil
        end

        def on_post(&block)
          @post_handler = block
        end

        def post(path, body = {})
          @post_calls << { path: path, body: body }
          if @post_handler
            @post_handler.call(path, body)
          else
            nil
          end
        end
      end
    end

    module Models
      class User
        attr_accessor :id, :username, :email, :admin, :apikey, :errors, :validate_password, :customOntology

        def initialize(attrs = {})
          @id = attrs[:id] || "http://data.matportal.org/users/#{attrs[:username]}"
          @username = attrs[:username] || "testuser"
          @email = attrs[:email] || "testuser@example.org"
          @admin = attrs[:admin] || false
          @apikey = attrs[:apikey] || "dummy-key-123"
          @errors = attrs[:errors]
          @customOntology = attrs[:customOntology] || []
          @validate_password = false
        end

        def admin?
          !!@admin
        end

        class << self
          attr_accessor :find_by_username_calls, :find_calls

          def reset!
            @find_by_username_calls = []
            @find_calls = []
            @users_by_username = {}
          end

          def register_user(user)
            @users_by_username ||= {}
            @users_by_username[user.username] = user
          end

          def find_by_username(username)
            @find_by_username_calls << username
            user = @users_by_username ? @users_by_username[username] : nil
            user ? [user] : []
          end

          def find(id, options = {})
            @find_calls << { id: id, options: options }
            @users_by_username&.values&.find { |u| u.id == id } || User.new(id: id)
          end
        end
      end
    end
  end
end

# Service double for SafeUrlPolicy
class SafeUrlPolicy
  def self.sanitize_redirect_param(raw, fallback: nil, allowed_hosts: [])
    fallback
  end

  def self.resolve_login_redirect(raw, user:, allowed_hosts: [])
    "/"
  end

  def self.permitted_service_url?(_url)
    false
  end

  def self.append_apikey_if_permitted(url, _user)
    url
  end
end

# Load actual LoginController implementation
load File.expand_path('../../app/controllers/login_controller.rb', __dir__)

# Request double
class RequestDouble
  attr_accessor :method, :url, :host, :referer, :env

  def initialize(method: "GET", url: "http://test.matportal.org/", referer: nil)
    @method = method.to_s.upcase
    @url = url
    @host = URI.parse(url).host rescue "test.matportal.org"
    @referer = referer
    @env = {}
  end

  def get?
    @method == "GET"
  end

  def post?
    @method == "POST"
  end

  def delete?
    @method == "DELETE"
  end
end

# --- 2. Isolated Routing Model (DSL Double for config/routes.rb) ---

class RouteSetDouble
  Route = Struct.new(:verb, :path_spec, :controller, :action, :constraints)

  attr_reader :routes

  def initialize
    @routes = []
    @scope_stack = []
  end

  def match(*args, **kwargs)
    path, options = normalize_args(*args, **kwargs)
    verbs = Array(options[:via] || [:get, :post, :put, :patch, :delete])
    verbs = [:get, :post, :put, :patch, :delete] if verbs.include?(:all)
    ctrl, act = parse_to(options[:to], options, path)
    verbs.each do |v|
      add_route(v.to_s.upcase, path, ctrl, act, options)
    end
  end

  def get(*args, **kwargs)
    add_verb_route("GET", *args, **kwargs)
  end

  def post(*args, **kwargs)
    add_verb_route("POST", *args, **kwargs)
  end

  def put(*args, **kwargs)
    add_verb_route("PUT", *args, **kwargs)
  end

  def patch(*args, **kwargs)
    add_verb_route("PATCH", *args, **kwargs)
  end

  def delete(*args, **kwargs)
    add_verb_route("DELETE", *args, **kwargs)
  end

  def root(options = {})
    get("/", options)
  end

  def mount(app, options = {}); end

  def scope(*args, **kwargs, &block)
    options = kwargs.dup
    path = args.first.to_s
    @scope_stack.push(path: path, options: options)
    instance_eval(&block)
    @scope_stack.pop
  end

  def namespace(name, &block)
    scope(name.to_s, module: name.to_s, as: name.to_s, &block)
  end

  def constraints(constraint_arg, &block)
    instance_eval(&block)
  end

  def resources(name, options = {}, &block)
    name_str = name.to_s
    actions = options[:only] ? Array(options[:only]).map(&:to_s) : %w[index create new show edit update destroy]
    actions -= Array(options[:except]).map(&:to_s) if options[:except]
    base_path = name_str
    ctrl = options[:controller] || name_str
    get(base_path, to: "#{ctrl}#index") if actions.include?("index")
    post(base_path, to: "#{ctrl}#create") if actions.include?("create")
    get("#{base_path}/new", to: "#{ctrl}#new") if actions.include?("new")
    get("#{base_path}/:id", to: "#{ctrl}#show", constraints: options[:constraints]) if actions.include?("show")
    get("#{base_path}/:id/edit", to: "#{ctrl}#edit", constraints: options[:constraints]) if actions.include?("edit")
    put("#{base_path}/:id", to: "#{ctrl}#update", constraints: options[:constraints]) if actions.include?("update")
    patch("#{base_path}/:id", to: "#{ctrl}#update", constraints: options[:constraints]) if actions.include?("update")
    delete("#{base_path}/:id", to: "#{ctrl}#destroy", constraints: options[:constraints]) if actions.include?("destroy")
    if block_given?
      parent_param = "#{name_str.singularize}_id"
      scope("#{name_str}/:#{parent_param}", &block)
    end
  end

  def resource(name, options = {}, &block)
    name_str = name.to_s
    actions = options[:only] ? Array(options[:only]).map(&:to_s) : %w[show new create edit update destroy]
    ctrl = options[:controller] || name_str.pluralize
    base_path = name_str
    get(base_path, to: "#{ctrl}#show") if actions.include?("show")
    put(base_path, to: "#{ctrl}#update") if actions.include?("update")
    patch(base_path, to: "#{ctrl}#update") if actions.include?("update")
  end

  def match_request(verb, path)
    clean_path = (path.length > 1 && path.end_with?("/")) ? path.chomp("/") : path
    routes.each do |r|
      next unless r.verb == verb.upcase
      pattern = r.path_spec.dup
      pattern = pattern.sub("(/:action(/:id))", "(?:/:action(?:/:id)?)?")
      constraints = r.constraints || {}
      pattern = pattern.gsub(/:([a-zA-Z0-9_]+)/) do |_m|
        param = $1.to_sym
        if constraints[param]
          c = constraints[param].is_a?(Regexp) ? constraints[param].source : constraints[param].to_s
          "(?<#{param}>#{c})"
        else
          "(?<#{param}>[^\\/]+)"
        end
      end
      regex = Regexp.new("\\A#{pattern}\\z")
      if (m = regex.match(clean_path))
        ctrl = r.controller.empty? ? (m.names.include?("controller") ? m[:controller] : "") : r.controller
        act = r.action.empty? ? (m.names.include?("action") ? m[:action] : "index") : r.action
        return { controller: ctrl, action: act, path_spec: r.path_spec, params: m.named_captures }
      end
    end
    nil
  end

  private

  def normalize_args(*args, **kwargs)
    options = kwargs.dup
    path = args.first
    if path.nil?
      path_key = options.keys.find { |k| k.to_s.start_with?("/") || k.to_s.include?(":") || k.to_s == "" }
      if path_key
        path = path_key.to_s
        options[:to] = options.delete(path_key)
      end
    end
    [path.to_s, options]
  end

  def add_verb_route(verb, *args, **kwargs)
    path, options = normalize_args(*args, **kwargs)
    ctrl, act = parse_to(options[:to], options, path)
    add_route(verb, path, ctrl, act, options)
  end

  def parse_to(to_param, options, path)
    if to_param
      parts = to_param.to_s.split("#")
      [parts[0], parts[1]]
    else
      c = options[:controller] ? options[:controller].to_s : ""
      a = options[:action] ? options[:action].to_s : ""
      [c, a]
    end
  end

  def add_route(verb, path, ctrl, act, options)
    clean_path = path.sub(/^\//, "")
    scoped_path_parts = @scope_stack.map { |s| s[:path].to_s.sub(/^\//, "").sub(/\/$/, "") }.reject(&:empty?)
    scoped_path_parts << clean_path unless clean_path.empty?
    full_path = "/" + scoped_path_parts.join("/")

    module_parts = @scope_stack.map { |s| s[:options][:module] ? s[:options][:module].to_s : nil }.compact
    final_ctrl = (module_parts + [ctrl]).reject(&:empty?).join("/")

    constraints = options[:constraints] || {}
    @scope_stack.each do |s|
      constraints = s[:options][:constraints].merge(constraints) if s[:options][:constraints]
    end

    @routes << Route.new(verb, full_path, final_ctrl, act, constraints)
  end
end

class MiniRails
  def self.application
    @app ||= AppDouble.new
  end

  def self.env
    @env ||= Struct.new(:development?, :test?, :production?).new(false, true, false)
  end
end

class AppDouble
  attr_reader :routes

  def initialize
    @routes = RoutesWrapperDouble.new
  end
end

class RoutesWrapperDouble
  attr_reader :route_set

  def initialize
    @route_set = RouteSetDouble.new
  end

  def draw(&block)
    @route_set.instance_eval(&block)
  end
end

Object.const_set(:Rails, MiniRails) unless defined?(Rails)
module LetterOpenerWeb; class Engine; end; end unless defined?(LetterOpenerWeb)
module Flipper; class UI; def self.app(*); end; end; end unless defined?(Flipper)
module Lookbook; class Engine; end; end unless defined?(Lookbook)

def load_route_set
  routes_file = File.expand_path('../../config/routes.rb', __dir__)
  load routes_file
  Rails.application.routes.route_set
end

# =============================================================================
# Main Test Suite
# =============================================================================

class AuthMutationRegressionTest < Minitest::Test
  def setup
    LinkedData::Client::HTTP.reset!
    LinkedData::Client::Models::User.reset!

    @admin_user = LinkedData::Client::Models::User.new(
      username: "admin_user",
      email: "admin@example.org",
      admin: true,
      apikey: "admin-api-key-999"
    )
    @regular_user = LinkedData::Client::Models::User.new(
      username: "regular_user",
      email: "regular@example.org",
      admin: false,
      apikey: "user-api-key-111"
    )
    @target_user = LinkedData::Client::Models::User.new(
      username: "target_user",
      email: "target@example.org",
      admin: false,
      apikey: "target-api-key-222"
    )

    LinkedData::Client::Models::User.register_user(@admin_user)
    LinkedData::Client::Models::User.register_user(@regular_user)
    LinkedData::Client::Models::User.register_user(@target_user)

    @controller = LoginController.new
    @routes = load_route_set
  end

  # --- 1. Route Model Matrix Tests ---

  def test_logout_route_matrix
    get_res = @routes.match_request("GET", "/logout")
    assert get_res, "GET /logout must route"
    assert_equal "login", get_res[:controller]
    assert_equal "destroy", get_res[:action]

    post_res = @routes.match_request("POST", "/logout")
    assert post_res, "POST /logout must route"
    assert_equal "login", post_res[:controller]
    assert_equal "destroy", post_res[:action]

    delete_res = @routes.match_request("DELETE", "/logout")
    assert delete_res, "DELETE /logout must route"
    assert_equal "login", delete_res[:controller]
    assert_equal "destroy", delete_res[:action]

    put_res = @routes.match_request("PUT", "/logout")
    assert_nil put_res, "PUT /logout must not route"
  end

  def test_login_as_route_matrix
    get_res = @routes.match_request("GET", "/login_as/target_user")
    assert get_res, "GET /login_as/:login_as must route"
    assert_equal "login", get_res[:controller]
    assert_equal "login_as", get_res[:action]
    assert_equal "target_user", get_res[:params]["login_as"]

    post_res = @routes.match_request("POST", "/login_as/target_user")
    assert post_res, "POST /login_as/:login_as must route"
    assert_equal "login", post_res[:controller]
    assert_equal "login_as", post_res[:action]
    assert_equal "target_user", post_res[:params]["login_as"]

    delete_res = @routes.match_request("DELETE", "/login_as/target_user")
    assert_nil delete_res, "DELETE /login_as/:login_as must not route"

    put_res = @routes.match_request("PUT", "/login_as/target_user")
    assert_nil put_res, "PUT /login_as/:login_as must not route"
  end

  def test_reset_password_route_matrix
    get_res = @routes.match_request("GET", "/reset_password")
    assert get_res, "GET /reset_password must route"
    assert_equal "login", get_res[:controller]
    assert_equal "reset_password", get_res[:action]

    post_res = @routes.match_request("POST", "/reset_password")
    assert post_res, "POST /reset_password must route"
    assert_equal "login", post_res[:controller]
    assert_equal "reset_password", post_res[:action]

    delete_res = @routes.match_request("DELETE", "/reset_password")
    assert_nil delete_res, "DELETE /reset_password must not route"

    put_res = @routes.match_request("PUT", "/reset_password")
    assert_nil put_res, "PUT /reset_password must not route"
  end

  def test_preservation_of_read_urls_and_alias_shadowing
    assert @routes.match_request("GET", "/statistics"), "GET /statistics preserved"
    assert @routes.match_request("GET", "/search/json_search"), "GET /search/json_search preserved"
    assert_nil @routes.match_request("GET", "/projects/destroy/test"), "Catchall GET mutation rejected"
    assert_nil @routes.match_request("GET", "/ajax/notes/delete"), "Obsolete GET notes delete rejected"
  end

  # --- 2. Controller Action Execution: Logout (/logout) ---

  def test_get_logout_with_authenticated_user_does_not_mutate_session
    @controller.session[:user] = @regular_user
    @controller.request = RequestDouble.new(method: "GET", url: "http://test.matportal.org/logout", referer: "/account")

    @controller.destroy

    assert_equal @regular_user, @controller.session[:user], "GET /logout must NOT clear user session"
    assert_equal "login/logout_confirm", @controller.rendered, "GET /logout must render safe confirmation view"
    assert_nil @controller.redirected_to, "GET /logout must not redirect immediately on authenticated session"
  end

  def test_get_logout_with_admin_impersonating_does_not_revert_session
    @controller.session[:user] = @target_user
    @controller.session[:admin_user] = @admin_user
    @controller.request = RequestDouble.new(method: "GET", url: "http://test.matportal.org/logout")

    @controller.destroy

    assert_equal @target_user, @controller.session[:user], "GET /logout must NOT revert impersonated user"
    assert_equal @admin_user, @controller.session[:admin_user], "GET /logout must NOT clear admin_user"
    assert_equal "login/logout_confirm", @controller.rendered, "GET /logout must render safe confirmation view"
  end

  def test_get_logout_unauthenticated_safely_redirects
    @controller.session[:user] = nil
    @controller.request = RequestDouble.new(method: "GET", url: "http://test.matportal.org/logout")

    @controller.destroy

    assert_nil @controller.session[:user], "Session user remains nil"
    assert_equal "/", @controller.redirected_to, "Unauthenticated GET /logout safely redirects to root"
    assert_nil @controller.rendered, "No confirmation rendered for unauthenticated visitor"
  end

  def test_delete_logout_clears_user_session
    @controller.session[:user] = @regular_user
    @controller.request = RequestDouble.new(method: "DELETE", url: "http://test.matportal.org/logout", referer: "/account")

    @controller.destroy

    assert_nil @controller.session[:user], "DELETE /logout must clear user session"
    assert_equal "You have successfully logged out", @controller.flash[:success]
    assert_equal "/account", @controller.redirected_to, "DELETE /logout redirects to referer"
  end

  def test_post_logout_reverts_admin_impersonation
    @controller.session[:user] = @target_user
    @controller.session[:admin_user] = @admin_user
    @controller.request = RequestDouble.new(method: "POST", url: "http://test.matportal.org/logout")

    @controller.destroy

    assert_equal @admin_user, @controller.session[:user], "POST /logout reverts session user to admin"
    assert_nil @controller.session[:admin_user], "POST /logout removes admin_user session key"
    assert_includes @controller.flash[:success], "Logged out", "Flash confirms return to admin"
    assert_equal "/", @controller.redirected_to
  end

  # --- 3. Controller Action Execution: Impersonation (/login_as) ---

  def test_login_as_non_admin_rejected_on_get_and_post
    # GET as regular user
    @controller.session[:user] = @regular_user
    @controller.params[:login_as] = "target_user"
    @controller.request = RequestDouble.new(method: "GET", url: "http://test.matportal.org/login_as/target_user")

    @controller.login_as

    assert_equal "/", @controller.redirected_to, "Non-admin GET /login_as must redirect to root"
    assert_equal @regular_user, @controller.session[:user], "Session user must not change"
    assert_empty LinkedData::Client::Models::User.find_by_username_calls, "No backend lookup on unauthorized GET"

    # POST as regular user
    @controller.redirected_to = nil
    @controller.request = RequestDouble.new(method: "POST", url: "http://test.matportal.org/login_as/target_user")

    @controller.login_as

    assert_equal "/", @controller.redirected_to, "Non-admin POST /login_as must redirect to root"
    assert_equal @regular_user, @controller.session[:user], "Session user must not change"
    assert_empty LinkedData::Client::Models::User.find_by_username_calls, "No backend lookup on unauthorized POST"
  end

  def test_get_login_as_by_admin_displays_confirmation_without_mutating_session_or_api
    @controller.session[:user] = @admin_user
    @controller.params[:login_as] = "target_user"
    @controller.request = RequestDouble.new(method: "GET", url: "http://test.matportal.org/login_as/target_user")

    @controller.login_as

    assert_equal "login/login_as_confirm", @controller.rendered, "GET /login_as must render confirmation view"
    assert_equal "target_user", @controller.instance_variable_get(:@target_username)
    assert_equal @admin_user, @controller.session[:user], "Session user must NOT change on GET"
    assert_nil @controller.session[:admin_user], "admin_user must NOT be set on GET"
    assert_empty LinkedData::Client::Models::User.find_by_username_calls, "No backend lookup must occur on GET"
  end

  def test_post_login_as_by_admin_performs_impersonation
    @controller.session[:user] = @admin_user
    @controller.params[:login_as] = "target_user"
    @controller.request = RequestDouble.new(method: "POST", url: "http://test.matportal.org/login_as/target_user")

    @controller.login_as

    assert_equal ["target_user"], LinkedData::Client::Models::User.find_by_username_calls
    assert_equal @admin_user, @controller.session[:admin_user], "Previous admin saved in session[:admin_user]"
    assert_equal @target_user, @controller.session[:user], "Target user logged in as session[:user]"
    assert_equal "admin-api-key-999", @controller.session[:user].apikey, "Impersonated user inherits admin apikey"
    assert_equal "/", @controller.redirected_to
  end

  # --- 4. Controller Action Execution: Password Reset (/reset_password) ---

  def test_get_reset_password_with_missing_params_fails_shape_check_and_does_not_call_backend
    @controller.params = { un: "testuser", em: "test@example.org" } # missing tk
    @controller.request = RequestDouble.new(method: "GET", url: "http://test.matportal.org/reset_password")

    @controller.reset_password

    assert_empty LinkedData::Client::HTTP.post_calls, "Backend reset API must NOT be called on shape failure"
    assert_equal "/lost_pass", @controller.redirected_to
    assert_includes @controller.flash[:notice], "Please reset your password again"
    assert_nil @controller.session[:user], "No session mutation on failed GET"
  end

  def test_get_reset_password_with_invalid_email_shape_fails_and_does_not_call_backend
    @controller.params = { un: "testuser", em: "not-an-email", tk: "dummy-token-abc" }
    @controller.request = RequestDouble.new(method: "GET", url: "http://test.matportal.org/reset_password")

    @controller.reset_password

    assert_empty LinkedData::Client::HTTP.post_calls, "Backend reset API must NOT be called on invalid email shape"
    assert_equal "/lost_pass", @controller.redirected_to
    assert_nil @controller.session[:user]
  end

  def test_get_reset_password_valid_shape_renders_confirmation_without_consuming_token
    token_val = "SECRET_RESET_TOKEN_!@#$%^"
    @controller.params = { un: "target_user", em: "target@example.org", tk: token_val }
    @controller.request = RequestDouble.new(method: "GET", url: "http://test.matportal.org/reset_password")

    @controller.reset_password

    assert_empty LinkedData::Client::HTTP.post_calls, "Backend reset API must NOT be called on GET (token must not be consumed)"
    assert_equal "login/reset_password", @controller.rendered, "Must render confirmation form view"
    assert_equal "target_user", @controller.instance_variable_get(:@username)
    assert_equal "target@example.org", @controller.instance_variable_get(:@email)
    assert_equal token_val, @controller.instance_variable_get(:@token), "Exact token preserved without alteration"
    assert_nil @controller.session[:user], "User must NOT be logged in on GET"
  end

  def test_post_reset_password_consumes_token_and_authenticates_on_success
    token_val = "CONSUMABLE_TOKEN_777"
    consumed_params = nil

    LinkedData::Client::HTTP.on_post do |path, body|
      if path == "/users/reset_password"
        consumed_params = body
        @target_user
      end
    end

    @controller.params = { un: "target_user", em: "target@example.org", tk: token_val }
    @controller.request = RequestDouble.new(method: "POST", url: "http://test.matportal.org/reset_password")

    @controller.reset_password

    assert_equal 1, LinkedData::Client::HTTP.post_calls.size, "Backend reset endpoint called exactly once on POST"
    assert_equal "/users/reset_password", LinkedData::Client::HTTP.post_calls.first[:path]
    assert_equal({ username: "target_user", email: "target@example.org", token: token_val }, consumed_params)

    assert_equal @target_user, @controller.session[:user], "User logged in after successful POST reset"
    assert_equal true, @target_user.validate_password, "validate_password set to true for edit form"
    assert_equal "users/edit", @controller.rendered, "Renders users/edit for password change"
  end

  def test_post_reset_password_with_backend_error_redirects_with_notice
    error_response = OpenStruct.new(errors: ["Token expired or invalid"])

    LinkedData::Client::HTTP.on_post do |path, _body|
      error_response if path == "/users/reset_password"
    end

    @controller.params = { un: "target_user", em: "target@example.org", tk: "expired_token" }
    @controller.request = RequestDouble.new(method: "POST", url: "http://test.matportal.org/reset_password")

    @controller.reset_password

    assert_nil @controller.session[:user], "User must NOT be logged in on failed reset"
    assert_equal "/lost_pass", @controller.redirected_to
    assert_includes @controller.flash[:notice], "Token expired or invalid"
    assert_includes @controller.flash[:notice], "Please reset your password again"
  end

  # --- 5. Template Compilation & Caller Verification ---

  def test_haml_views_compile_cleanly
    views = [
      "app/views/login/logout_confirm.html.haml",
      "app/views/login/login_as_confirm.html.haml",
      "app/views/login/reset_password.html.haml",
      "app/views/layouts/_topnav.html.haml",
      "app/views/users/index.html.haml"
    ]

    views.each do |view_path|
      full_path = File.expand_path("../../#{view_path}", __dir__)
      assert File.exist?(full_path), "View file #{view_path} must exist"
      content = File.read(full_path)
      engine = Haml::Engine.new(content)
      assert engine, "Haml engine compiles #{view_path} without syntax errors"
    end
  end

  def test_reset_password_template_contains_safe_hidden_fields
    content = File.read(File.expand_path('../../app/views/login/reset_password.html.haml', __dir__))
    assert_includes content, "hidden_field :un", "Template preserves un parameter"
    assert_includes content, "hidden_field :em", "Template preserves em parameter"
    assert_includes content, "hidden_field :tk", "Template preserves tk parameter"
    assert_includes content, "form_with", "Uses Rails form_with helper"
    assert_includes content, "method: :post", "Form submits via POST"
  end

  def test_topnav_caller_uses_delete_button_to
    content = File.read(File.expand_path('../../app/views/layouts/_topnav.html.haml', __dir__))
    assert_includes content, "button_to(t('layout.header.logout'), logout_path, method: :delete",
                    "Topnav logout must use button_to with DELETE method"
  end

  def test_users_index_caller_uses_post_button_to
    content = File.read(File.expand_path('../../app/views/users/index.html.haml', __dir__))
    assert_includes content, "button_to t('users.index.login_as'), login_as_path(user.username), method: :post",
                    "Users index login_as caller must use button_to with POST method"
  end

  # --- 6. Request / CSRF Token Fixture ---

  class CsrfProtectionFixture
    # Demonstrates session-authenticity token contract check.
    # Note: This is an isolated contract fixture demonstrating form token verification
    # semantics against session state; it does NOT substitute for live Rails Rack middleware
    # CSRF enforcement in a running server/browser runtime.
    def self.verify_authenticity(session, request_params, request_verb)
      # Safe GET requests do not require authenticity token
      return :safe_read if request_verb.to_s.upcase == "GET"

      expected_token = session[:_csrf_token]
      provided_token = request_params[:authenticity_token]

      if expected_token && provided_token && expected_token == provided_token
        :verified
      else
        :invalid_authenticity_token
      end
    end
  end

  def test_csrf_protection_fixture_contract
    session = { _csrf_token: "mock-valid-csrf-token-abc123xyz" }

    # Safe GET navigation
    assert_equal :safe_read, CsrfProtectionFixture.verify_authenticity(session, {}, "GET")

    # Mutation without token
    assert_equal :invalid_authenticity_token,
                 CsrfProtectionFixture.verify_authenticity(session, {}, "POST")
    assert_equal :invalid_authenticity_token,
                 CsrfProtectionFixture.verify_authenticity(session, {}, "DELETE")

    # Mutation with invalid token
    assert_equal :invalid_authenticity_token,
                 CsrfProtectionFixture.verify_authenticity(session, { authenticity_token: "wrong-token" }, "POST")

    # Mutation with valid matching session token
    assert_equal :verified,
                 CsrfProtectionFixture.verify_authenticity(session, { authenticity_token: "mock-valid-csrf-token-abc123xyz" }, "POST")
    assert_equal :verified,
                 CsrfProtectionFixture.verify_authenticity(session, { authenticity_token: "mock-valid-csrf-token-abc123xyz" }, "DELETE")
  end
end
