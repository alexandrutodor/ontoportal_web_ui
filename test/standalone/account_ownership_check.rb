# frozen_string_literal: true

require 'minitest/autorun'
require 'ostruct'
require 'logger'
require 'cgi'

# =============================================================================
# Standalone Offline Account Ownership & Session-Bound Subscriptions Check (ONTO-T-B04)
#
# Tests HTTP request-boundary authorization, callback sequencing, alias handling,
# and session-boundary integrity for:
# 1. UsersController (edit, update, custom_ontologies):
#    - Unauthorized requests (anonymous, ordinary non-owner) halt BEFORE
#      inherited ApplicationController callbacks and model lookups/writes.
#    - Owner self access is permitted with username, short-ID, and full-ID aliases.
#    - Administrators may update other accounts and other-account custom ontologies,
#      but the administrator's credential-bearing session state (identity, apikey,
#      custom ontologies) is NEVER overwritten with target user data.
#    - SDK/API 401/403 denials on update and custom_ontologies do NOT produce success
#      notices or modify session state.
# 2. SubscriptionsController (create):
#    - Strictly self-service: unauthenticated calls return 401, mismatched/forged
#      target IDs (including administrator attempts on other accounts) return 403
#      BEFORE any User or Ontology lookups/writes.
#    - Canonical user lookup is always bound to authenticated session identity,
#      never the incoming request parameter.
#    - Self-service subscriptions add, remove, and duplicate avoidance work correctly.
#    - Known SDK/API 401/403 errors yield { updated_sub: false } and do NOT update
#      session subscriptions.
#    - Session object identity (object_id) and sensitive fields (apiKey) are preserved.
# =============================================================================

# Ensure gem load paths in native container environment
if Dir.exist?('/usr/local/bundle/ruby/3.1.0/gems') && (ENV['GEM_PATH'].nil? || !ENV['GEM_PATH'].include?('/usr/local/bundle/ruby/3.1.0'))
  Gem.use_paths(nil, Gem.path + ['/usr/local/bundle/ruby/3.1.0'])
end

sdk_lib = '/usr/local/bundle/ruby/3.1.0/bundler/gems/ontologies_api_ruby_client-6257685e5744/lib'
$LOAD_PATH.unshift(sdk_lib) if Dir.exist?(sdk_lib) && !$LOAD_PATH.include?(sdk_lib)

worktree_root = File.expand_path('../..', __dir__)
$LOAD_PATH.unshift(File.join(worktree_root, 'app/helpers'))
$LOAD_PATH.unshift(File.join(worktree_root, 'app/controllers/concerns'))
$LOAD_PATH.unshift(File.join(worktree_root, 'app/controllers'))

require 'rails'
require 'action_controller'
require 'active_record'

# Require actual helpers needed by ApplicationController and target controllers
require 'urls_helper'
require 'turbo_helper'
require 'terms_reuses'
require 'components_helper'
require 'ontologies_helper'
require 'internationalisation_helper'
require 'multi_languages_helper'

# Load actual ApplicationController and target controllers
require 'application_controller'
require 'users_controller'
require 'subscriptions_controller'

# Configure I18n dictionary from actual locale files
I18n.load_path = Dir[File.join(worktree_root, 'config/locales/*.yml')]
I18n.default_locale = :en
I18n.locale = :en

# Configure controller testing defaults
$ENABLE_SLICES = false
ActionController::Base.allow_forgery_protection = false
ActionController::Base.logger = Logger.new(nil)
Rails.logger = Logger.new(nil)
ActionController::Base.helper UrlsHelper

UsersController.layout false
SubscriptionsController.layout false

# Finite route helper stubs
module AccountOwnershipRouteHelperStubs
  def login_index_path(*args, **kwargs)
    '/login'
  end

  def user_path(id, *args, **kwargs)
    "/accounts/#{id}"
  end

  def edit_user_path(id, *args, **kwargs)
    "/accounts/#{id}/edit"
  end

  def url_for(options = nil)
    case options
    when Hash
      if options[:controller] == 'login'
        "/login?redirect=#{options[:redirect]}"
      elsif options[:action].to_s == 'index'
        "/#{options[:controller]}"
      else
        "/#{options[:controller]}/#{options[:action]}"
      end
    when String
      options
    else
      super
    end
  end
end
ActionController::Base.include AccountOwnershipRouteHelperStubs

# =============================================================================
# Call Tracker Spy & Synthetic SDK / Model Doubles
# =============================================================================

# Finite test double for License model used by ApplicationController#init_trial_license
class License
  def self.where(*args)
    OpenStruct.new(exists?: true)
  end
end

class OwnershipCallSpy
  attr_accessor :user_find_calls, :user_get_calls, :user_update_calls
  attr_accessor :ontology_find_calls, :ontology_find_by_acronym_calls
  attr_accessor :init_trial_license_calls

  def initialize
    reset!
  end

  def reset!
    @user_find_calls = 0
    @user_get_calls = 0
    @user_update_calls = 0
    @ontology_find_calls = 0
    @ontology_find_by_acronym_calls = 0
    @init_trial_license_calls = 0
  end

  def total_lookup_calls
    @user_find_calls + @user_get_calls + @ontology_find_calls + @ontology_find_by_acronym_calls
  end

  def total_write_calls
    @user_update_calls
  end
end

$ownership_spy = OwnershipCallSpy.new

# Synthetic SDK User Model Double
module LinkedData
  module Client
    module Models
      class User
        attr_accessor :id, :username, :email, :firstName, :lastName
        attr_accessor :customOntology, :subscription, :apikey, :role
        attr_accessor :validate_password, :password, :password_confirmation
        attr_accessor :forced_update_response

        class << self
          attr_accessor :registry
        end
        self.registry = {}

        def self.reset_registry!
          self.registry = {}
        end

        def self.register(user)
          # Register under both string id, username, and last path segment
          self.registry[user.id.to_s] = user
          self.registry[user.username.to_s] = user
          self.registry[user.id.to_s.split('/').last] = user
          user
        end

        def dup_record
          copy = self.dup
          copy.customOntology = @customOntology ? @customOntology.dup : []
          copy.subscription = @subscription ? @subscription.map(&:dup) : []
          copy.role = @role ? @role.dup : ['USER']
          copy.forced_update_response = @forced_update_response
          copy
        end

        def self.find(id, options = {})
          $ownership_spy.user_find_calls += 1
          lookup_key = id.to_s.split('/').last
          user = self.registry[lookup_key] || self.registry[id.to_s]
          user ? user.dup_record : nil
        end

        def self.get(escaped_id, options = {})
          $ownership_spy.user_get_calls += 1
          unescaped = CGI.unescape(escaped_id.to_s)
          lookup_key = unescaped.split('/').last
          user = self.registry[lookup_key] || self.registry[unescaped] || self.registry[escaped_id.to_s]
          user ? user.dup_record : nil
        end

        def initialize(attrs = {})
          attrs.each do |k, v|
            send("#{k}=", v) if respond_to?("#{k}=")
          end
          @customOntology ||= []
          @subscription ||= []
          @role ||= ['USER']
        end

        def admin?
          @role == 'ADMIN' || (@role.is_a?(Array) && @role.include?('ADMIN'))
        end

        def update_from_params(params = {})
          params.to_h.each do |k, v|
            send("#{k}=", v) if respond_to?("#{k}=")
          end
          self
        end

        def update(values: {})
          $ownership_spy.user_update_calls += 1
          values.each do |k, v|
            send("#{k}=", v) if respond_to?("#{k}=")
          end

          return @forced_update_response if @forced_update_response

          # Persist successful update back into registry
          reg_user = self.class.registry[@username.to_s] || self.class.registry[@id.to_s]
          if reg_user
            reg_user.firstName = @firstName
            reg_user.lastName = @lastName
            reg_user.email = @email
            reg_user.customOntology = @customOntology.dup if @customOntology
            reg_user.subscription = @subscription.dup if @subscription
            reg_user.password = @password if @password
          end

          self
        end
      end

      class Ontology
        attr_accessor :acronym, :name

        class << self
          attr_accessor :registry
        end
        self.registry = {}

        def self.reset_registry!
          self.registry = {}
        end

        def self.register(ont)
          self.registry[ont.acronym.to_s] = ont
          ont
        end

        def self.find(id, *args)
          $ownership_spy.ontology_find_calls += 1
          acronym = id.to_s.split('/').last
          self.registry[acronym] || self.registry[id.to_s]
        end

        def self.find_by_acronym(acronym)
          $ownership_spy.ontology_find_by_acronym_calls += 1
          ont = self.registry[acronym.to_s]
          ont ? [ont] : []
        end

        def initialize(attrs = {})
          attrs.each do |k, v|
            send("#{k}=", v) if respond_to?("#{k}=")
          end
        end
      end
    end
  end
end

# Instrument ApplicationController#init_trial_license to detect if startup callback executed
class ApplicationController
  alias_method :orig_init_trial_license, :init_trial_license

  def init_trial_license
    $ownership_spy.init_trial_license_calls += 1
    orig_init_trial_license
  end
end

# =============================================================================
# Test Suite
# =============================================================================

class AccountOwnershipCheck < Minitest::Test
  def setup
    I18n.locale = :en
    $ownership_spy.reset!
    $trial_license_initialized = false
    LinkedData::Client::Models::User.reset_registry!
    LinkedData::Client::Models::Ontology.reset_registry!

    # Create common standard test fixtures
    @alice = LinkedData::Client::Models::User.new(
      id: 'http://data.bioontology.org/users/1001',
      username: 'alice',
      email: 'alice@example.org',
      firstName: 'Alice',
      lastName: 'Owner',
      role: ['USER'],
      apikey: 'dummy-token-alice', # gitleaks:allow
      customOntology: ['TEST-ONT'],
      subscription: [
        OpenStruct.new(ontology: 'http://data.bioontology.org/ontologies/EXISTING', notification_type: 'NOTES')
      ]
    )
    LinkedData::Client::Models::User.register(@alice)

    @bob = LinkedData::Client::Models::User.new(
      id: 'http://data.bioontology.org/users/1002',
      username: 'bob',
      email: 'bob@example.org',
      firstName: 'Bob',
      lastName: 'Target',
      role: ['USER'],
      apikey: 'dummy-token-bob', # gitleaks:allow
      customOntology: ['BOB-ONT'],
      subscription: []
    )
    LinkedData::Client::Models::User.register(@bob)

    @admin = LinkedData::Client::Models::User.new(
      id: 'http://data.bioontology.org/users/9999',
      username: 'admin',
      email: 'admin@example.org',
      firstName: 'Site',
      lastName: 'Admin',
      role: ['ADMIN'],
      apikey: 'dummy-token-admin', # gitleaks:allow
      customOntology: ['ADMIN-PORTAL-ONT'],
      subscription: []
    )
    LinkedData::Client::Models::User.register(@admin)

    @ontology_ont = LinkedData::Client::Models::Ontology.new(
      acronym: 'ONT-A',
      name: 'Ontology A'
    )
    LinkedData::Client::Models::Ontology.register(@ontology_ont)

    @ontology_existing = LinkedData::Client::Models::Ontology.new(
      acronym: 'EXISTING',
      name: 'Existing Ontology'
    )
    LinkedData::Client::Models::Ontology.register(@ontology_existing)
  end

  # Helper to dispatch requests through real Rails ActionPack controller stack
  def dispatch(ctrl_class, action, method: :get, params: {}, session: {}, cookies: {})
    ctrl = ctrl_class.new
    req = ActionDispatch::TestRequest.create
    req.request_method = method.to_s.upcase
    params.each { |k, v| req.params[k] = v }
    req.set_header 'rack.session', session
    req.set_header 'action_dispatch.request.flash_hash', ActionDispatch::Flash::FlashHash.new
    cookies.each { |k, v| req.cookies[k.to_s] = v }
    res = ActionDispatch::TestResponse.create
    ctrl.set_request!(req)
    ctrl.set_response!(res)

    ctrl.define_singleton_method(:default_render) do |*args|
      render plain: "implicit render: #{action_name}"
    end
    ctrl.define_singleton_method(:render) do |*args, **kwargs, &block|
      opts = args.extract_options!.merge(kwargs)
      action_rendered = args.first || opts[:action]
      opts[:plain] ||= "rendered: #{action_rendered}"
      @rendered_action = action_rendered.to_s
      super(opts)
    end

    ctrl.process(action)
    [ctrl, req, res]
  end

  # ===========================================================================
  # 1. ActionPack Callback Chain Verification
  # ===========================================================================

  def test_users_controller_prepends_verify_owner_before_init_trial_license
    callbacks = UsersController._process_action_callbacks.map(&:filter)
    verify_idx = callbacks.index(:verify_owner)
    trial_idx = callbacks.index(:init_trial_license)
    admin_idx = callbacks.index(:authorize_admin)

    refute_nil verify_idx, 'UsersController must declare :verify_owner callback'
    refute_nil trial_idx, 'UsersController must inherit :init_trial_license callback'
    refute_nil admin_idx, 'UsersController must retain :authorize_admin callback'

    assert_operator verify_idx, :<, trial_idx,
                    ':verify_owner must be prepended ahead of inherited :init_trial_license'
    assert_equal 0, verify_idx, ':verify_owner must be the first callback executed'
  end

  def test_subscriptions_controller_prepends_authorize_session_user_before_init_trial_license
    callbacks = SubscriptionsController._process_action_callbacks.map(&:filter)
    auth_idx = callbacks.index(:authorize_session_user)
    trial_idx = callbacks.index(:init_trial_license)

    refute_nil auth_idx, 'SubscriptionsController must declare :authorize_session_user callback'
    refute_nil trial_idx, 'SubscriptionsController must inherit :init_trial_license callback'

    assert_operator auth_idx, :<, trial_idx,
                    ':authorize_session_user must be prepended ahead of inherited :init_trial_license'
    assert_equal 0, auth_idx, ':authorize_session_user must be the first callback executed'
  end

  # ===========================================================================
  # 2. UsersController: Denied Requests (0 Lookups / 0 Writes / Halted Chain)
  # ===========================================================================

  def test_users_edit_anonymous_denied_with_zero_lookups_and_zero_writes
    _ctrl, _req, res = dispatch(UsersController, :edit, params: { id: 'alice' }, session: {})

    assert_equal 302, res.status
    assert_includes res.location, '/login'
    assert_equal 0, $ownership_spy.total_lookup_calls, 'Unauthorized edit must make 0 lookups'
    assert_equal 0, $ownership_spy.total_write_calls, 'Unauthorized edit must make 0 writes'
    assert_equal 0, $ownership_spy.init_trial_license_calls, 'Inherited callbacks must be halted'
  end

  def test_users_update_anonymous_denied_with_zero_lookups_and_zero_writes
    params = {
      id: 'alice',
      user: { firstName: 'Hacked', lastName: 'Name', email: 'hacked@example.org', username: 'alice' }
    }
    _ctrl, _req, res = dispatch(UsersController, :update, method: :put, params: params, session: {})

    assert_equal 302, res.status
    assert_includes res.location, '/login'
    assert_equal 0, $ownership_spy.total_lookup_calls, 'Unauthorized update must make 0 lookups'
    assert_equal 0, $ownership_spy.total_write_calls, 'Unauthorized update must make 0 writes'
    assert_equal 0, $ownership_spy.init_trial_license_calls, 'Inherited callbacks must be halted'
  end

  def test_users_custom_ontologies_anonymous_denied_with_zero_lookups_and_zero_writes
    params = { id: 'alice', ontologies: ['EVIL-ONT'] }
    _ctrl, _req, res = dispatch(UsersController, :custom_ontologies, method: :post, params: params, session: {})

    assert_equal 302, res.status
    assert_includes res.location, '/login'
    assert_equal 0, $ownership_spy.total_lookup_calls, 'Unauthorized custom_ontologies must make 0 lookups'
    assert_equal 0, $ownership_spy.total_write_calls, 'Unauthorized custom_ontologies must make 0 writes'
    assert_equal 0, $ownership_spy.init_trial_license_calls, 'Inherited callbacks must be halted'
  end

  def test_users_update_non_owner_denied_with_zero_lookups_and_zero_writes
    params = {
      id: 'bob',
      user: { firstName: 'Hacked', lastName: 'Bob', email: 'bob@example.org', username: 'bob' }
    }
    _ctrl, _req, res = dispatch(UsersController, :update, method: :put, params: params, session: { user: @alice })

    assert_equal 302, res.status
    assert_includes res.location, '/login'
    assert_equal 0, $ownership_spy.total_lookup_calls, 'Non-owner update must make 0 lookups'
    assert_equal 0, $ownership_spy.total_write_calls, 'Non-owner update must make 0 writes'
  end

  def test_users_custom_ontologies_non_owner_denied_with_zero_lookups_and_zero_writes
    params = { id: 'bob', ontologies: ['EVIL-ONT'] }
    _ctrl, _req, res = dispatch(UsersController, :custom_ontologies, method: :post, params: params, session: { user: @alice })

    assert_equal 302, res.status
    assert_includes res.location, '/login'
    assert_equal 0, $ownership_spy.total_lookup_calls, 'Non-owner custom_ontologies must make 0 lookups'
    assert_equal 0, $ownership_spy.total_write_calls, 'Non-owner custom_ontologies must make 0 writes'
  end

  # ===========================================================================
  # 3. UsersController: Owner Self Access with Aliases
  # ===========================================================================

  def test_users_update_self_admitted_with_username_alias
    params = {
      id: 'alice',
      user: { firstName: 'AliceUpdated', lastName: 'Owner', email: 'alice@example.org', username: 'alice' }
    }
    _ctrl, req, res = dispatch(UsersController, :update, method: :put, params: params, session: { user: @alice })

    assert_equal 302, res.status
    assert_equal 'AliceUpdated', @alice.firstName
    assert_equal 'AliceUpdated', req.session[:user].firstName
    assert_equal 'dummy-token-alice', req.session[:user].apikey, 'API key must remain intact'
  end

  def test_users_update_self_admitted_with_full_id_alias
    params = {
      id: 'http://data.bioontology.org/users/1001',
      user: { firstName: 'AliceFromURI', lastName: 'Owner', email: 'alice@example.org', username: 'alice' }
    }
    _ctrl, req, res = dispatch(UsersController, :update, method: :put, params: params, session: { user: @alice })

    assert_equal 302, res.status
    assert_equal 'AliceFromURI', @alice.firstName
    assert_equal 'AliceFromURI', req.session[:user].firstName
  end

  def test_users_update_self_admitted_with_short_id_alias
    params = {
      id: '1001',
      user: { firstName: 'AliceShortId', lastName: 'Owner', email: 'alice@example.org', username: 'alice' }
    }
    _ctrl, req, res = dispatch(UsersController, :update, method: :put, params: params, session: { user: @alice })

    assert_equal 302, res.status
    assert_equal 'AliceShortId', @alice.firstName
    assert_equal 'AliceShortId', req.session[:user].firstName
  end

  def test_users_custom_ontologies_self_success_updates_session_custom_ontologies
    params = { id: 'alice', ontologies: ['ONT-A', 'ONT-B'] }
    _ctrl, req, res = dispatch(UsersController, :custom_ontologies, method: :post, params: params, session: { user: @alice })

    assert_equal 302, res.status
    assert_equal ['ONT-A', 'ONT-B'], @alice.customOntology
    assert_equal ['ONT-A', 'ONT-B'], req.session[:user].customOntology
    assert_same @alice, req.session[:user], 'Session user instance object identity must be preserved'
  end

  # ===========================================================================
  # 4. UsersController: Admin Other-Account Modifications & Session Isolation
  # ===========================================================================

  def test_users_update_admin_permitted_on_other_account_without_corrupting_admin_session
    orig_admin_apikey = @admin.apikey
    orig_admin_name = @admin.firstName

    params = {
      id: 'bob',
      user: { firstName: 'BobUpdatedByAdmin', lastName: 'Target', email: 'bob@example.org', username: 'bob' }
    }
    _ctrl, req, res = dispatch(UsersController, :update, method: :put, params: params, session: { user: @admin })

    assert_equal 302, res.status
    assert_equal 'BobUpdatedByAdmin', @bob.firstName, 'Target user must be updated'
    assert_equal orig_admin_name, req.session[:user].firstName, 'Admin session profile must NOT receive target profile data'
    assert_equal orig_admin_apikey, req.session[:user].apikey, 'Admin session API key must remain untouched'
    assert_same @admin, req.session[:user], 'Admin session object identity preserved'
  end

  def test_users_custom_ontologies_admin_permitted_on_other_account_without_copying_to_admin_session
    orig_admin_custom = @admin.customOntology.dup

    params = { id: 'bob', ontologies: ['BOB-NEW-ONT'] }
    _ctrl, req, res = dispatch(UsersController, :custom_ontologies, method: :post, params: params, session: { user: @admin })

    assert_equal 302, res.status
    assert_equal ['BOB-NEW-ONT'], @bob.customOntology, 'Target user custom ontologies must be updated'
    assert_equal orig_admin_custom, req.session[:user].customOntology,
                 'Target custom ontologies must NEVER be copied into administrator session'
    assert_same @admin, req.session[:user], 'Admin session object identity preserved'
  end

  # ===========================================================================
  # 5. UsersController: Known SDK 401/403 Denials
  # ===========================================================================

  def test_users_update_sdk_401_denial_does_not_claim_success_or_copy_session
    @alice.forced_update_response = OpenStruct.new(status: 401, errors: ['Unauthorized modification'])
    orig_name = @alice.firstName

    params = {
      id: 'alice',
      user: { firstName: 'WillFail', lastName: 'Owner', email: 'alice@example.org', username: 'alice' }
    }
    ctrl, req, res = dispatch(UsersController, :update, method: :put, params: params, session: { user: @alice })

    assert_equal 200, res.status, 'Edit form must be re-rendered on failure'
    assert_equal 'edit', ctrl.instance_variable_get(:@rendered_action)
    refute_nil ctrl.instance_variable_get(:@errors)
    assert_nil req.session[:flash_hash]&.[](notice: 'notice')
    assert_equal orig_name, req.session[:user].firstName, 'Session must not be updated on SDK denial'
  end

  def test_users_custom_ontologies_sdk_403_denial_shows_error_flash_and_does_not_update_session
    @alice.forced_update_response = OpenStruct.new(status: 403, errors: ['Forbidden'])
    orig_custom = @alice.customOntology.dup

    params = { id: 'alice', ontologies: ['FAIL-ONT'] }
    ctrl, req, res = dispatch(UsersController, :custom_ontologies, method: :post, params: params, session: { user: @alice })

    assert_equal 302, res.status
    flash_notice = req.get_header('action_dispatch.request.flash_hash')[:notice]
    assert_equal I18n.t('users.error_saving_custom_ontologies'), flash_notice,
                 'Must display error saving custom ontologies on 403 denial'
    assert_equal orig_custom, req.session[:user].customOntology,
                 'Custom ontologies must not be copied to session on SDK denial'
  end

  # ===========================================================================
  # 6. SubscriptionsController: Strict Self-Service Guard (0 Lookups / 0 Writes)
  # ===========================================================================

  def test_subscriptions_create_anonymous_rejected_with_401_and_zero_lookups_and_writes
    _ctrl, _req, res = dispatch(SubscriptionsController, :create, method: :post,
                                params: { ontology_id: 'ONT-A', user_id: 'alice' }, session: {})

    assert_equal 401, res.status
    body = JSON.parse(res.body)
    assert_equal false, body['updated_sub']
    assert_equal 0, $ownership_spy.total_lookup_calls, 'Unauthenticated subscription must make 0 lookups'
    assert_equal 0, $ownership_spy.total_write_calls, 'Unauthenticated subscription must make 0 writes'
    assert_equal 0, $ownership_spy.init_trial_license_calls, 'Inherited callbacks must be halted'
  end

  def test_subscriptions_create_forged_mismatched_target_rejected_with_403
    _ctrl, _req, res = dispatch(SubscriptionsController, :create, method: :post,
                                params: { ontology_id: 'ONT-A', user_id: 'bob' }, session: { user: @alice })

    assert_equal 403, res.status
    body = JSON.parse(res.body)
    assert_equal false, body['updated_sub']
    assert_equal 0, $ownership_spy.total_lookup_calls, 'Mismatched target must make 0 lookups'
    assert_equal 0, $ownership_spy.total_write_calls, 'Mismatched target must make 0 writes'
  end

  def test_subscriptions_create_admin_other_account_strictly_rejected_with_403
    # Subscriptions UI has no admin target selection; strictly self-service
    _ctrl, _req, res = dispatch(SubscriptionsController, :create, method: :post,
                                params: { ontology_id: 'ONT-A', user_id: 'bob' }, session: { user: @admin })

    assert_equal 403, res.status
    body = JSON.parse(res.body)
    assert_equal false, body['updated_sub']
    assert_equal 0, $ownership_spy.total_lookup_calls, 'Admin other-account subscription must make 0 lookups'
    assert_equal 0, $ownership_spy.total_write_calls, 'Admin other-account subscription must make 0 writes'
  end

  # ===========================================================================
  # 7. SubscriptionsController: Self Add, Remove, and Duplicate Avoidance
  # ===========================================================================

  def test_subscriptions_create_self_add_success_bound_to_session_identity
    # Target param absent -> admitted and canonical lookup bound to session user
    _ctrl, req, res = dispatch(SubscriptionsController, :create, method: :post,
                                params: { ontology_id: 'ONT-A', subbed: 'false' }, session: { user: @alice })

    assert_equal 200, res.status
    body = JSON.parse(res.body)
    assert_equal true, body['updated_sub']
    assert_equal 1, $ownership_spy.user_get_calls, 'Must lookup canonical session user'
    assert_equal 1, $ownership_spy.user_update_calls, 'Must execute 1 remote write'

    sub_acronyms = req.session[:user].subscription.map { |s| s[:ontology] }
    assert_includes sub_acronyms, 'ONT-A', 'New subscription must be in session'
    assert_same @alice, req.session[:user], 'Session user object identity must be preserved'
    assert_equal 'dummy-token-alice', req.session[:user].apikey, 'API key must remain intact'
  end

  def test_subscriptions_create_self_duplicate_avoidance
    # Already subscribed to EXISTING with NOTES
    _ctrl, req, res = dispatch(SubscriptionsController, :create, method: :post,
                                params: { ontology_id: 'EXISTING', subbed: 'false', user_id: 'alice' },
                                session: { user: @alice })

    assert_equal 200, res.status
    body = JSON.parse(res.body)
    assert_equal true, body['updated_sub']

    matching_subs = req.session[:user].subscription.select do |s|
      s[:ontology].to_s.split('/').last == 'EXISTING'
    end
    assert_equal 1, matching_subs.length, 'Duplicate NOTES subscription must not be added'
  end

  def test_subscriptions_create_self_remove_success
    # Existing subscription has EXISTING
    _ctrl, req, res = dispatch(SubscriptionsController, :create, method: :post,
                                params: { ontology_id: 'EXISTING', subbed: 'true', user_id: 'alice' },
                                session: { user: @alice })

    assert_equal 200, res.status
    body = JSON.parse(res.body)
    assert_equal true, body['updated_sub']

    matching_subs = req.session[:user].subscription.select do |s|
      s[:ontology].to_s.split('/').last == 'EXISTING'
    end
    assert_empty matching_subs, 'Removed subscription must not remain in session user'
  end

  # ===========================================================================
  # 8. SubscriptionsController: Known SDK 401/403 Error Handling
  # ===========================================================================

  def test_subscriptions_create_sdk_401_error_does_not_update_session
    @alice.forced_update_response = OpenStruct.new(status: 401, errors: ['Unauthorized subscription'])
    orig_subs = @alice.subscription.dup

    _ctrl, req, res = dispatch(SubscriptionsController, :create, method: :post,
                                params: { ontology_id: 'ONT-A', subbed: 'false', user_id: 'alice' },
                                session: { user: @alice })

    assert_equal 200, res.status
    body = JSON.parse(res.body)
    assert_equal false, body['updated_sub'], 'updated_sub must be false on SDK denial'
    assert_equal orig_subs, req.session[:user].subscription, 'Session subscriptions must not be modified on denial'
    assert_same @alice, req.session[:user], 'Session user object identity must be preserved'
  end

  def test_subscriptions_create_sdk_403_error_does_not_update_session
    @alice.forced_update_response = OpenStruct.new(status: 403, errors: ['Forbidden'])
    orig_subs = @alice.subscription.dup

    _ctrl, req, res = dispatch(SubscriptionsController, :create, method: :post,
                                params: { ontology_id: 'ONT-A', subbed: 'false', user_id: 'alice' },
                                session: { user: @alice })

    assert_equal 200, res.status
    body = JSON.parse(res.body)
    assert_equal false, body['updated_sub'], 'updated_sub must be false on SDK denial'
    assert_equal orig_subs, req.session[:user].subscription, 'Session subscriptions must not be modified on denial'
  end
end
