# frozen_string_literal: true

require 'minitest/autorun'
require 'uri'
require 'cgi'
require 'haml'
require 'yaml'
require 'ostruct'

# =============================================================================
# Standalone Offline Subscription Confirmation Test (ONTO-T-B02 Subscription Slice)
#
# Tests actual UsersController subscription methods and target binding with
# no-network mailer and client doubles, route model assertions, Haml compilation,
# and exact value preservation (dots/plus, zero GET/HEAD delivery, POST write).
# =============================================================================

# --- 1. Minimal Doubles and Stubs for Standalone Execution ---

class Object
  def blank?
    respond_to?(:empty?) ? !!empty? : !self
  end

  def present?
    !blank?
  end

  def presence
    present? ? self : nil
  end
end

class MiniRails
  def self.application; @app ||= MiniApp.new; end
  def self.env; @env ||= Struct.new(:development?, :test?, :production?).new(false, true, false); end
end

class MiniApp
  def routes; @routes ||= MiniRoutes.new; end
end

class MiniRoutes
  attr_reader :route_set
  def draw(&block)
    @route_set = RouteSetDouble.new
    @route_set.instance_eval(&block)
  end
end

Object.const_set(:Rails, MiniRails) unless defined?(Rails)
module LetterOpenerWeb; class Engine; end; end unless defined?(LetterOpenerWeb)
module Flipper; class UI; def self.app(*); end; end; end unless defined?(Flipper)
module Lookbook; class Engine; end; end unless defined?(Lookbook)

# Minimal ApplicationController stub
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

  def unescape(string)
    CGI.unescape(string) if string
  end

  def escape(string)
    CGI.escape(string) if string
  end

  def not_found(message = '')
    raise ActiveRecord::RecordNotFound, message
  end
end

class ActiveRecord
  class RecordNotFound < StandardError; end
end

module TurboHelper; end

$ANNOUNCE_LIST = "ontoportal-announce@lists.example.org"

# Mailer and Job doubles
class JobDouble
  attr_accessor :delivered

  def initialize(should_raise: false)
    @should_raise = should_raise
    @delivered = false
  end

  def deliver
    raise StandardError, "Delivery network failure" if @should_raise

    @delivered = true
  end
end

class SubscribeMailer
  class << self
    attr_accessor :register_calls, :unregister_calls, :should_raise

    def reset!
      @register_calls = []
      @unregister_calls = []
      @should_raise = false
    end

    def register_for_announce_list(email, first_name, last_name)
      @register_calls << { email: email, firstName: first_name, lastName: last_name }
      JobDouble.new(should_raise: @should_raise)
    end

    def unregister_for_announce_list(email)
      @unregister_calls << { email: email }
      JobDouble.new(should_raise: @should_raise)
    end
  end
end

# Client model double
module LinkedData
  module Client
    module Models
      class User
        attr_accessor :id, :username, :email, :firstName, :lastName, :admin

        def initialize(attrs = {})
          @id = attrs[:id] || "http://data.matportal.org/users/#{attrs[:username]}"
          @username = attrs[:username] || "testuser"
          @email = attrs[:email] || "testuser@example.org"
          @firstName = attrs[:firstName] || "Test"
          @lastName = attrs[:lastName] || "User"
          @admin = attrs[:admin] || false
        end

        def admin?
          !!@admin
        end

        class << self
          attr_accessor :find_calls

          def reset!
            @find_calls = []
            @users = {}
          end

          def register(user)
            @users ||= {}
            @users[user.username] = user
            @users[user.id] = user
          end

          def find(id, options = {})
            @find_calls << { id: id, options: options }
            @users ? @users[id] : nil
          end
        end
      end
    end
  end
end

# Request double supporting GET, HEAD, POST
class RequestDouble
  attr_accessor :method, :url

  def initialize(method: "GET", url: "http://test.matportal.org/")
    @method = method.to_s.upcase
    @url = url
  end

  def get?
    @method == "GET"
  end

  def head?
    @method == "HEAD"
  end

  def post?
    @method == "POST"
  end

  def delete?
    @method == "DELETE"
  end

  def xhr?
    false
  end
end

# Load actual UsersController implementation
load File.expand_path('../../app/controllers/users_controller.rb', __dir__)

# --- 2. Minimal Route DSL Double for config/routes.rb assertions ---

class RouteSetDouble
  Route = Struct.new(:verb, :path_spec, :controller, :action, :constraints)
  attr_reader :routes

  def initialize
    @routes = []
    @scope_stack = []
  end

  def match(*args, **kwargs)
    options = kwargs.dup
    path = args.first
    verbs = Array(options[:via] || [:get, :post, :put, :patch, :delete])
    ctrl, act = parse_to(options[:to])
    verbs.each do |v|
      @routes << Route.new(v.to_s.upcase, path, ctrl, act, options[:constraints])
    end
  end

  def get(*args, **kwargs)
    match(*args, **kwargs.merge(via: [:get]))
  end

  def post(*args, **kwargs)
    match(*args, **kwargs.merge(via: [:post]))
  end

  def resources(*); end
  def resource(*); end
  def scope(*); end
  def namespace(*); end
  def delete(*); end
  def put(*); end
  def patch(*); end
  def root(*); end
  def mount(*); end

  def match_request(verb, path)
    routes.each do |r|
      next unless r.verb == verb.upcase

      pattern = r.path_spec.dup
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
      if (m = regex.match(path))
        return { controller: r.controller, action: r.action, params: m.named_captures }
      end
    end
    nil
  end

  private

  def parse_to(to_str)
    return ["", ""] unless to_str.is_a?(String)

    to_str.split("#")
  end
end

# --- 3. Test Suite ---

class SubscriptionConfirmationTest < Minitest::Test
  def setup
    SubscribeMailer.reset!
    LinkedData::Client::Models::User.reset!

    @admin_user = LinkedData::Client::Models::User.new(
      username: "admin_user",
      email: "admin@example.org",
      firstName: "Admin",
      lastName: "Portal",
      admin: true
    )
    @standard_user = LinkedData::Client::Models::User.new(
      username: "alice",
      email: "alice@example.org",
      firstName: "Alice",
      lastName: "Wonderland",
      admin: false
    )
    @plus_user = LinkedData::Client::Models::User.new(
      username: "bob+tag",
      email: "bob+tag@example.org",
      firstName: "Bob",
      lastName: "Plus",
      admin: false
    )
    @dot_user = LinkedData::Client::Models::User.new(
      username: "charlie.brown",
      email: "charlie.brown@example.org",
      firstName: "Charlie",
      lastName: "Brown",
      admin: false
    )

    LinkedData::Client::Models::User.register(@admin_user)
    LinkedData::Client::Models::User.register(@standard_user)
    LinkedData::Client::Models::User.register(@plus_user)
    LinkedData::Client::Models::User.register(@dot_user)
  end

  # --- Route Model Assertions ---

  def test_routes_match_get_and_post_for_both_subscription_endpoints
    load File.expand_path('../../config/routes.rb', __dir__)
    route_set = Rails.application.routes.route_set

    sub_get = route_set.match_request("GET", "/users/subscribe/alice")
    assert sub_get, "GET /users/subscribe/:username must match a route"
    assert_equal "users", sub_get[:controller]
    assert_equal "subscribe", sub_get[:action]
    assert_equal "alice", sub_get[:params]["username"]

    sub_post = route_set.match_request("POST", "/users/subscribe/alice")
    assert sub_post, "POST /users/subscribe/:username must match a route"
    assert_equal "users", sub_post[:controller]
    assert_equal "subscribe", sub_post[:action]

    unsub_get = route_set.match_request("GET", "/users/un-subscribe/alice@example.org")
    assert unsub_get, "GET /users/un-subscribe/:email must match a route"
    assert_equal "users", unsub_get[:controller]
    assert_equal "un_subscribe", unsub_get[:action]
    assert_equal "alice@example.org", unsub_get[:params]["email"]

    unsub_post = route_set.match_request("POST", "/users/un-subscribe/alice@example.org")
    assert unsub_post, "POST /users/un-subscribe/:email must match a route"
    assert_equal "users", unsub_post[:controller]
    assert_equal "un_subscribe", unsub_post[:action]
  end

  # --- GET / HEAD Safe Landing & Zero Delivery ---

  def test_subscribe_get_shows_confirmation_and_delivers_zero_mail
    controller = UsersController.new
    controller.params = { username: "alice" }
    controller.request = RequestDouble.new(method: "GET", url: "/users/subscribe/alice")

    controller.subscribe

    assert_equal "users/subscription_confirm", controller.rendered, "GET subscribe must render subscription_confirm view"
    assert_empty SubscribeMailer.register_calls, "GET subscribe must NEVER instantiate mailer"
    assert_nil controller.flash[:success], "GET subscribe must not set success flash"
    assert_nil controller.redirected_to, "GET subscribe must not redirect"
    assert_equal "subscribe", controller.instance_variable_get(:@action_type)
    assert_equal "alice", controller.instance_variable_get(:@target_username)
    assert_equal "alice@example.org", controller.instance_variable_get(:@target_email)
  end

  def test_subscribe_head_shows_confirmation_and_delivers_zero_mail
    controller = UsersController.new
    controller.params = { username: "alice" }
    controller.request = RequestDouble.new(method: "HEAD", url: "/users/subscribe/alice")

    controller.subscribe

    assert_equal "users/subscription_confirm", controller.rendered, "HEAD subscribe must render subscription_confirm view"
    assert_empty SubscribeMailer.register_calls, "HEAD subscribe must NEVER instantiate mailer"
    assert_nil controller.flash[:success], "HEAD subscribe must not set success flash"
    assert_nil controller.redirected_to, "HEAD subscribe must not redirect"
  end

  def test_unsubscribe_get_shows_confirmation_and_delivers_zero_mail
    controller = UsersController.new
    controller.params = { email: "alice@example.org" }
    controller.request = RequestDouble.new(method: "GET", url: "/users/un-subscribe/alice@example.org")

    controller.un_subscribe

    assert_equal "users/subscription_confirm", controller.rendered, "GET unsubscribe must render subscription_confirm view"
    assert_empty SubscribeMailer.unregister_calls, "GET unsubscribe must NEVER instantiate mailer"
    assert_nil controller.flash[:success], "GET unsubscribe must not set success flash"
    assert_nil controller.redirected_to, "GET unsubscribe must not redirect"
    assert_equal "unsubscribe", controller.instance_variable_get(:@action_type)
    assert_equal "alice@example.org", controller.instance_variable_get(:@email)
  end

  def test_unsubscribe_head_shows_confirmation_and_delivers_zero_mail
    controller = UsersController.new
    controller.params = { email: "alice@example.org" }
    controller.request = RequestDouble.new(method: "HEAD", url: "/users/un-subscribe/alice@example.org")

    controller.un_subscribe

    assert_equal "users/subscription_confirm", controller.rendered, "HEAD unsubscribe must render subscription_confirm view"
    assert_empty SubscribeMailer.unregister_calls, "HEAD unsubscribe must NEVER instantiate mailer"
    assert_nil controller.flash[:success], "HEAD unsubscribe must not set success flash"
    assert_nil controller.redirected_to, "HEAD unsubscribe must not redirect"
  end

  # --- POST Execution & Success / Failure ---

  def test_subscribe_post_delivers_mail_and_sets_success_flash
    controller = UsersController.new
    controller.params = { username: "alice" }
    controller.request = RequestDouble.new(method: "POST", url: "/users/subscribe/alice")

    controller.subscribe

    assert_equal 1, SubscribeMailer.register_calls.size, "POST subscribe must instantiate mailer"
    call = SubscribeMailer.register_calls.first
    assert_equal "alice@example.org", call[:email]
    assert_equal "Alice", call[:firstName]
    assert_equal "Wonderland", call[:lastName]
    assert controller.flash[:success]&.include?($ANNOUNCE_LIST), "Flash success must mention announce list"
    assert_equal "/account", controller.redirected_to, "POST subscribe must redirect to /account"
  end

  def test_subscribe_post_handles_mailer_exception
    SubscribeMailer.should_raise = true
    controller = UsersController.new
    controller.params = { username: "alice" }
    controller.request = RequestDouble.new(method: "POST", url: "/users/subscribe/alice")

    controller.subscribe

    assert_equal 1, SubscribeMailer.register_calls.size
    assert_equal "Something went wrong ...", controller.flash[:error], "POST subscribe failure must set error flash"
    assert_equal "/account", controller.redirected_to
  end

  def test_unsubscribe_post_delivers_mail_and_sets_success_flash
    controller = UsersController.new
    controller.params = { email: "alice@example.org" }
    controller.request = RequestDouble.new(method: "POST", url: "/users/un-subscribe/alice@example.org")

    controller.un_subscribe

    assert_equal 1, SubscribeMailer.unregister_calls.size, "POST unsubscribe must instantiate mailer"
    assert_equal "alice@example.org", SubscribeMailer.unregister_calls.first[:email]
    assert controller.flash[:success]&.include?($ANNOUNCE_LIST), "Flash success must mention announce list"
    assert_equal "/account", controller.redirected_to, "POST unsubscribe must redirect to /account"
  end

  def test_unsubscribe_post_handles_mailer_exception
    SubscribeMailer.should_raise = true
    controller = UsersController.new
    controller.params = { email: "alice@example.org" }
    controller.request = RequestDouble.new(method: "POST", url: "/users/un-subscribe/alice@example.org")

    controller.un_subscribe

    assert_equal 1, SubscribeMailer.unregister_calls.size
    assert_equal "Something went wrong ...", controller.flash[:error], "POST unsubscribe failure must set error flash"
    assert_equal "/account", controller.redirected_to
  end

  # --- Character Preservation (Dots and Plus, No Double Decoding) ---

  def test_unsubscribe_preserves_plus_and_dots_without_double_decoding
    controller = UsersController.new
    controller.params = { email: "bob+tag@example.org" }
    controller.request = RequestDouble.new(method: "POST", url: "/users/un-subscribe/bob+tag@example.org")

    controller.un_subscribe

    assert_equal 1, SubscribeMailer.unregister_calls.size
    # Crucial assertion: Must NOT be "bob tag@example.org"
    assert_equal "bob+tag@example.org", SubscribeMailer.unregister_calls.first[:email],
                 "Plus characters in email address must not be converted to spaces"
  end

  def test_subscribe_preserves_plus_in_username_target
    controller = UsersController.new
    controller.params = { username: "bob+tag" }
    controller.request = RequestDouble.new(method: "POST", url: "/users/subscribe/bob+tag")

    controller.subscribe

    assert_equal 1, SubscribeMailer.register_calls.size
    assert_equal "bob+tag@example.org", SubscribeMailer.register_calls.first[:email]
  end

  def test_subscribe_preserves_dots_in_username_target
    controller = UsersController.new
    controller.params = { username: "charlie.brown" }
    controller.request = RequestDouble.new(method: "POST", url: "/users/subscribe/charlie.brown")

    controller.subscribe

    assert_equal 1, SubscribeMailer.register_calls.size
    assert_equal "charlie.brown@example.org", SubscribeMailer.register_calls.first[:email]
  end

  # --- Legacy Format Handling ---

  def test_legacy_format_reconstruction_for_split_dot_username
    controller = UsersController.new
    controller.params = { username: "charlie", format: "brown" }
    controller.request = RequestDouble.new(method: "POST", url: "/users/subscribe/charlie.brown")

    controller.subscribe

    assert_equal 1, SubscribeMailer.register_calls.size
    assert_equal "charlie.brown@example.org", SubscribeMailer.register_calls.first[:email]
  end

  def test_legacy_format_reconstruction_for_split_dot_email
    controller = UsersController.new
    controller.params = { email: "alice@example", format: "org" }
    controller.request = RequestDouble.new(method: "POST", url: "/users/un-subscribe/alice@example.org")

    controller.un_subscribe

    assert_equal 1, SubscribeMailer.unregister_calls.size
    assert_equal "alice@example.org", SubscribeMailer.unregister_calls.first[:email]
  end

  def test_standard_html_format_is_not_appended_to_target
    controller = UsersController.new
    controller.params = { username: "alice", format: "html" }
    controller.request = RequestDouble.new(method: "POST", url: "/users/subscribe/alice.html")

    controller.subscribe

    assert_equal 1, SubscribeMailer.register_calls.size
    assert_equal "alice@example.org", SubscribeMailer.register_calls.first[:email]
  end

  # --- Missing & Invalid Targets ---

  def test_subscribe_missing_username_halts_with_not_found_and_zero_mail
    controller = UsersController.new
    controller.params = {}
    controller.request = RequestDouble.new(method: "POST", url: "/users/subscribe/")

    assert_raises(ActiveRecord::RecordNotFound) do
      controller.subscribe
    end
    assert_empty SubscribeMailer.register_calls, "Missing username must not instantiate or deliver mail"
  end

  def test_subscribe_nonexistent_user_halts_with_not_found_and_zero_mail
    controller = UsersController.new
    controller.params = { username: "ghost_user" }
    controller.request = RequestDouble.new(method: "POST", url: "/users/subscribe/ghost_user")

    assert_raises(ActiveRecord::RecordNotFound) do
      controller.subscribe
    end
    assert_empty SubscribeMailer.register_calls, "Non-existent user must not instantiate or deliver mail"
  end

  def test_unsubscribe_missing_email_halts_with_not_found_and_zero_mail
    controller = UsersController.new
    controller.params = {}
    controller.request = RequestDouble.new(method: "POST", url: "/users/un-subscribe/")

    assert_raises(ActiveRecord::RecordNotFound) do
      controller.un_subscribe
    end
    assert_empty SubscribeMailer.unregister_calls, "Missing email must not instantiate or deliver mail"
  end

  def test_unsubscribe_invalid_email_halts_with_not_found_and_zero_mail
    controller = UsersController.new
    controller.params = { email: "invalid-email-address" }
    controller.request = RequestDouble.new(method: "POST", url: "/users/un-subscribe/invalid-email-address")

    assert_raises(ActiveRecord::RecordNotFound) do
      controller.un_subscribe
    end
    assert_empty SubscribeMailer.unregister_calls, "Invalid email format must not instantiate or deliver mail"
  end

  # --- Haml View & Form Assertions ---

  def test_subscription_confirm_template_compilation_and_form_structure
    view_path = File.expand_path('../../app/views/users/subscription_confirm.html.haml', __dir__)
    assert File.exist?(view_path), "subscription_confirm.html.haml must exist"

    content = File.read(view_path)
    engine = Haml::Engine.new(content)
    assert engine, "Haml engine must compile template without syntax error"

    assert_includes content, "form_with", "Template must use form_with helper"
    assert_includes content, "method: :post", "Template must declare method: :post"
    assert_includes content, "hidden_field :username", "Template must preserve escaped username hidden field"
    assert_includes content, "hidden_field :email", "Template must preserve escaped email hidden field"
    assert_includes content, "link_to t('users.cancel'), \"/account\"", "Template must provide cancel link to /account"
  end
end
