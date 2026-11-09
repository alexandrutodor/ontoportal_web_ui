# frozen_string_literal: true

require 'minitest/autorun'
require 'ostruct'
require 'logger'

# =============================================================================
# Standalone Offline Local Admin Request Boundary Regression Check (ONTO-T-B03)
#
# Tests the HTTP request-boundary authorization and input guards for:
# 1. Admin::LicensesController (index, new, create):
#    - Unauthorized requests (anonymous, ordinary non-admin) halt BEFORE
#      inherited ApplicationController callbacks (specifically :init_trial_license)
#      with zero model or API calls.
#    - Literal 'trial' key submissions are refused even for admins with
#      controlled form error (:trial_not_allowed), HTTP 422, preserved input,
#      and zero save calls across repeated attempts.
#    - Legitimate administrator key submissions proceed to save and render success.
# 2. VirtualApplianceController (index, create):
#    - Grant creation (:create) requires admin authorization BEFORE any
#      administrative model/API operations (init_trial_license, User lookup, grant write).
#    - Grant access/status page (:index) remains preserved for ordinary logged-in users;
#      reads only own grant, strictly avoiding reading all grants (@va_users = []).
#    - Administrators retain full access to all grants and add-user workflow.
#    - Sequential grant creation is idempotent: repeated requests for existing grant
#      perform zero duplicate saves.
# 3. Both supported administrator session forms are covered:
#    - Direct admin: session[:user].admin? == true
#    - Masquerade / switched admin: session[:admin_user].admin? == true (current_login_as_admin?)
#
# Note: Local cryptographic and database driver validations are labeled untested
# in this offline suite. Internal once-per-installation trial bootstrap,
# concurrency guards, and historical data cleanup remain deferred.
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
require 'action_view' # app helpers include ActionView modules at load time

# Require actual helpers needed by ApplicationController
require 'urls_helper'
require 'terms_reuses'
require 'components_helper'
require 'ontologies_helper'
require 'internationalisation_helper'
require 'multi_languages_helper'

# Load actual ApplicationController and target controllers
require 'application_controller'
module Admin; end
require 'admin/licenses_controller'
require 'virtual_appliance_controller'

# Configure I18n dictionary from actual locale files
I18n.load_path = Dir[File.join(worktree_root, 'config/locales/*.yml')]
I18n.default_locale = :en
I18n.locale = :en

# Configure controller testing defaults
$ENABLE_SLICES = false
ActionController::Base.allow_forgery_protection = false
ActionController::Base.logger = Logger.new(nil)
Rails.logger = Logger.new(nil)

Admin::LicensesController.layout false
VirtualApplianceController.layout false

# Finite route helper stubs
module LocalAdminRouteHelperStubs
  def login_index_path(*args, **kwargs)
    '/login'
  end

  def virtual_appliance_index_path(*args, **kwargs)
    '/virtual_appliance'
  end

  def url_for(options = nil)
    case options
    when Hash
      if options[:action].to_s == 'index'
        '/virtual_appliance'
      else
        "/#{options[:action]}"
      end
    when String
      options
    else
      super
    end
  end
end
ActionController::Base.include LocalAdminRouteHelperStubs

# =============================================================================
# Call Tracker Spy & Persistence Doubles
# =============================================================================

class LocalAdminCallSpy
  attr_accessor :license_where_calls, :license_create_calls, :license_current_calls
  attr_accessor :license_new_calls, :license_save_calls
  attr_accessor :va_where_calls, :va_order_calls, :va_new_calls, :va_save_calls
  attr_accessor :user_find_calls

  def initialize
    reset!
  end

  def reset!
    @license_where_calls = 0
    @license_create_calls = 0
    @license_current_calls = 0
    @license_new_calls = 0
    @license_save_calls = 0
    @va_where_calls = 0
    @va_order_calls = 0
    @va_new_calls = 0
    @va_save_calls = 0
    @user_find_calls = 0
  end

  def total_license_io_calls
    @license_where_calls + @license_create_calls + @license_current_calls + @license_save_calls
  end

  def total_grant_io_calls
    @va_where_calls + @va_order_calls + @va_save_calls + @user_find_calls
  end
end

$call_spy = LocalAdminCallSpy.new

# Finite test double for License model
class License
  include ActiveModel::Model
  # Non-MySQL adapter: init_trial_license keeps its plain check-then-create path.
  def self.connection = Struct.new(:adapter_name).new('NullDB')
  include ActiveModel::Validations

  attr_accessor :encrypted_key, :created_at

  def self.i18n_scope
    :activerecord
  end

  def initialize(attrs = {})
    $call_spy.license_new_calls += 1
    attrs ||= {}
    @encrypted_key = attrs[:encrypted_key]
    @created_at = attrs[:created_at] || Time.current
  end

  def is_trial?
    @encrypted_key == 'trial'
  end

  def save
    $call_spy.license_save_calls += 1
    # Simple simulated validation: valid keys succeed, blank fails
    if @encrypted_key.blank?
      errors.add(:encrypted_key, :blank)
      false
    else
      true
    end
  end

  def self.where(*args)
    $call_spy.license_where_calls += 1
    OpenStruct.new(exists?: true)
  end

  def self.create(*args)
    $call_spy.license_create_calls += 1
    new(*args)
  end

  def self.current_license
    $call_spy.license_current_calls += 1
    [new(encrypted_key: 'active_license_stub')]
  end
end

# Finite test double for VirtualApplianceUser model
class VirtualApplianceUser
  attr_accessor :user_id, :saved

  # In-memory registry to test sequential idempotence
  class << self
    attr_accessor :records
  end
  self.records = []

  def self.reset_records!
    self.records = []
  end

  def initialize(attrs = {})
    $call_spy.va_new_calls += 1
    attrs ||= {}
    @user_id = attrs[:user_id]
    @saved = false
  end

  def save
    $call_spy.va_save_calls += 1
    @saved = true
    self.class.records << self unless self.class.records.include?(self)
    true
  end

  def self.where(conditions = {})
    $call_spy.va_where_calls += 1
    uid = conditions[:user_id]
    self.records.select { |r| r.user_id == uid }
  end

  def self.order(*args)
    $call_spy.va_order_calls += 1
    self.records.sort_by { |r| r.user_id.to_s }
  end
end

# Finite test double for LinkedData::Client::Models::User
module LinkedData
  module Client
    module Models
      class User
        def self.find_by_username(username)
          $call_spy.user_find_calls += 1
          if username == 'unknown_user'
            []
          else
            [OpenStruct.new(id: 1001, username: username)]
          end
        end
      end
    end
  end
end

# =============================================================================
# Test Suite
# =============================================================================

class LocalAdminRequestGuardsCheck < Minitest::Test
  def setup
    I18n.locale = :en
    $call_spy.reset!
    VirtualApplianceUser.reset_records!
    # Global flag used by ApplicationController#init_trial_license
    $trial_license_initialized = false
  end

  # --- Helper to dispatch requests through real Rails ActionPack controller stack ---
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
      action_rendered = args.first
      opts[:plain] ||= "rendered: #{action_rendered}"
      @rendered_action = action_rendered
      super(opts)
    end

    ctrl.process(action)
    [ctrl, req, res]
  end

  # ===========================================================================
  # 1. ActionPack Callback Chain Verification
  # ===========================================================================

  def test_licenses_controller_prepends_authorize_admin_before_init_trial_license
    callbacks = Admin::LicensesController._process_action_callbacks.map(&:filter)
    admin_idx = callbacks.index(:authorize_admin)
    trial_idx = callbacks.index(:init_trial_license)

    refute_nil admin_idx, 'Admin::LicensesController must declare :authorize_admin callback'
    refute_nil trial_idx, 'Admin::LicensesController must inherit :init_trial_license callback'
    assert_operator admin_idx, :<, trial_idx,
                    ':authorize_admin must be prepended ahead of inherited :init_trial_license'
    assert_equal 0, admin_idx, ':authorize_admin must be the very first callback executed'
  end

  def test_virtual_appliance_controller_callback_ordering
    callbacks = VirtualApplianceController._process_action_callbacks.map(&:filter)
    admin_idx = callbacks.index(:authorize_admin)
    login_idx = callbacks.index(:require_login)
    trial_idx = callbacks.index(:init_trial_license)

    refute_nil admin_idx, 'VirtualApplianceController must declare :authorize_admin callback'
    refute_nil login_idx, 'VirtualApplianceController must declare :require_login callback'
    refute_nil trial_idx, 'VirtualApplianceController must inherit :init_trial_license callback'

    assert_operator login_idx, :<, admin_idx, ':require_login must precede :authorize_admin'
    assert_operator admin_idx, :<, trial_idx, ':authorize_admin must precede :init_trial_license'
  end

  # ===========================================================================
  # 2. Admin::LicensesController: Denied Requests (Assert 0 Model / API calls)
  # ===========================================================================

  def test_license_index_denied_for_anonymous_with_zero_model_calls
    ctrl, _req, res = dispatch(Admin::LicensesController, :index, session: {})
    assert_equal 302, res.status
    assert_equal 'http://test.host/', res.location
    assert_equal 0, $call_spy.total_license_io_calls, 'Unauthorized index must make 0 license I/O calls'
    refute $trial_license_initialized, 'Inherited trial bootstrap must NOT have run'
  end

  def test_license_new_denied_for_anonymous_with_zero_model_calls
    ctrl, _req, res = dispatch(Admin::LicensesController, :new, session: {})
    assert_equal 302, res.status
    assert_equal 'http://test.host/', res.location
    assert_equal 0, $call_spy.total_license_io_calls, 'Unauthorized new must make 0 license I/O calls'
    refute $trial_license_initialized, 'Inherited trial bootstrap must NOT have run'
  end

  def test_license_create_denied_for_anonymous_with_zero_model_calls
    ctrl, _req, res = dispatch(Admin::LicensesController, :create, method: :post,
                               params: { license: { encrypted_key: 'trial' } }, session: {})
    assert_equal 302, res.status
    assert_equal 'http://test.host/', res.location
    assert_equal 0, $call_spy.total_license_io_calls, 'Unauthorized create must make 0 license I/O calls'
    refute $trial_license_initialized, 'Inherited trial bootstrap must NOT have run'
  end

  def test_license_index_denied_for_ordinary_user_with_zero_model_calls
    session = { user: OpenStruct.new(id: 42, username: 'reg_user', admin?: false) }
    ctrl, _req, res = dispatch(Admin::LicensesController, :index, session: session)
    assert_equal 302, res.status
    assert_equal 'http://test.host/', res.location
    assert_equal 0, $call_spy.total_license_io_calls, 'Ordinary user index must make 0 license I/O calls'
    refute $trial_license_initialized, 'Inherited trial bootstrap must NOT have run'
  end

  def test_license_new_denied_for_ordinary_user_with_zero_model_calls
    session = { user: OpenStruct.new(id: 42, username: 'reg_user', admin?: false) }
    ctrl, _req, res = dispatch(Admin::LicensesController, :new, session: session)
    assert_equal 302, res.status
    assert_equal 'http://test.host/', res.location
    assert_equal 0, $call_spy.total_license_io_calls, 'Ordinary user new must make 0 license I/O calls'
    refute $trial_license_initialized, 'Inherited trial bootstrap must NOT have run'
  end

  def test_license_create_denied_for_ordinary_user_with_zero_model_calls
    session = { user: OpenStruct.new(id: 42, username: 'reg_user', admin?: false) }
    ctrl, _req, res = dispatch(Admin::LicensesController, :create, method: :post,
                               params: { license: { encrypted_key: 'trial' } }, session: session)
    assert_equal 302, res.status
    assert_equal 'http://test.host/', res.location
    assert_equal 0, $call_spy.total_license_io_calls, 'Ordinary user create must make 0 license I/O calls'
    refute $trial_license_initialized, 'Inherited trial bootstrap must NOT have run'
  end

  # ===========================================================================
  # 3. Admin::LicensesController: Permitted Actions & Session Forms
  # ===========================================================================

  def test_license_index_permitted_for_direct_admin
    session = { user: OpenStruct.new(id: 1, username: 'admin', admin?: true) }
    ctrl, _req, res = dispatch(Admin::LicensesController, :index, session: session)
    assert_equal 200, res.status
    assert_equal 1, $call_spy.license_current_calls, 'Admin index loads current license'
  end

  def test_license_new_permitted_for_direct_admin
    session = { user: OpenStruct.new(id: 1, username: 'admin', admin?: true) }
    ctrl, _req, res = dispatch(Admin::LicensesController, :new, session: session)
    assert_equal 200, res.status
    assert_equal 1, $call_spy.license_new_calls, 'Admin new builds new license instance'
  end

  def test_license_index_permitted_for_login_as_admin
    session = {
      user: OpenStruct.new(id: 42, username: 'target_user', admin?: false),
      admin_user: OpenStruct.new(id: 1, username: 'admin', admin?: true)
    }
    ctrl, _req, res = dispatch(Admin::LicensesController, :index, session: session)
    assert_equal 200, res.status
    assert_equal 1, $call_spy.license_current_calls, 'Impersonated admin index loads current license'
  end

  def test_license_new_permitted_for_login_as_admin
    session = {
      user: OpenStruct.new(id: 42, username: 'target_user', admin?: false),
      admin_user: OpenStruct.new(id: 1, username: 'admin', admin?: true)
    }
    ctrl, _req, res = dispatch(Admin::LicensesController, :new, session: session)
    assert_equal 200, res.status
    assert_equal 1, $call_spy.license_new_calls, 'Impersonated admin new builds new license instance'
  end

  # ===========================================================================
  # 4. Admin::LicensesController: Literal Trial Refusal (Controlled Form Error, No Save)
  # ===========================================================================

  def test_license_create_literal_trial_refused_for_direct_admin
    session = { user: OpenStruct.new(id: 1, username: 'admin', admin?: true) }
    ctrl, _req, res = dispatch(Admin::LicensesController, :create, method: :post,
                               params: { license: { encrypted_key: 'trial' } }, session: session)

    assert_equal 422, res.status, 'Form error must render HTTP 422 unprocessable_entity'
    license = ctrl.instance_variable_get(:@license)
    assert_equal 'trial', license.encrypted_key, 'Submitted input must be preserved in model instance'
    assert_includes license.errors[:encrypted_key], 'cannot be a trial license.'
    assert_equal 0, $call_spy.license_save_calls, 'License.save must NEVER be called for trial key'
  end

  def test_license_create_literal_trial_refused_for_login_as_admin
    session = {
      user: OpenStruct.new(id: 42, username: 'target', admin?: false),
      admin_user: OpenStruct.new(id: 1, username: 'admin', admin?: true)
    }
    ctrl, _req, res = dispatch(Admin::LicensesController, :create, method: :post,
                               params: { license: { encrypted_key: 'trial' } }, session: session)

    assert_equal 422, res.status
    license = ctrl.instance_variable_get(:@license)
    assert_equal 'trial', license.encrypted_key
    assert_includes license.errors[:encrypted_key], 'cannot be a trial license.'
    assert_equal 0, $call_spy.license_save_calls
  end

  def test_license_create_trial_with_whitespace_and_mixed_case_refused
    session = { user: OpenStruct.new(id: 1, username: 'admin', admin?: true) }
    ctrl, _req, res = dispatch(Admin::LicensesController, :create, method: :post,
                               params: { license: { encrypted_key: '   TrIaL   ' } }, session: session)

    assert_equal 422, res.status
    assert_equal 0, $call_spy.license_save_calls, 'Padded/mixed-case trial must not be saved'
    license = ctrl.instance_variable_get(:@license)
    assert_includes license.errors[:encrypted_key], 'cannot be a trial license.'
  end

  def test_license_create_trial_repeated_attempts_never_save
    session = { user: OpenStruct.new(id: 1, username: 'admin', admin?: true) }

    3.times do |i|
      _ctrl, _req, res = dispatch(Admin::LicensesController, :create, method: :post,
                                  params: { license: { encrypted_key: 'trial' } }, session: session)
      assert_equal 422, res.status, "Attempt #{i + 1} must return 422"
    end

    assert_equal 0, $call_spy.license_save_calls, 'Repeated trial submissions must perform 0 saves'
  end

  def test_license_create_trial_french_locale_translation
    I18n.locale = :fr
    session = { user: OpenStruct.new(id: 1, username: 'admin', admin?: true), locale: :fr }
    ctrl, _req, res = dispatch(Admin::LicensesController, :create, method: :post,
                               params: { license: { encrypted_key: 'trial' } }, session: session,
                               cookies: { locale: :fr })

    assert_equal 422, res.status
    license = ctrl.instance_variable_get(:@license)
    assert_includes license.errors.full_messages, "Encrypted key ne peut pas être une licence d'essai."
    assert_equal 0, $call_spy.license_save_calls
  end

  # ===========================================================================
  # 5. Admin::LicensesController: Permitted Valid Key Submission
  # ===========================================================================

  def test_license_create_valid_key_saves_and_renders_success
    session = { user: OpenStruct.new(id: 1, username: 'admin', admin?: true) }
    ctrl, _req, res = dispatch(Admin::LicensesController, :create, method: :post,
                               params: { license: { encrypted_key: 'encrypted_key_abcdef' } }, session: session)

    assert_equal 200, res.status
    assert_equal :create_success, ctrl.instance_variable_get(:@rendered_action)
    assert_equal 1, $call_spy.license_save_calls, 'Valid key must be saved'
  end

  def test_license_create_valid_key_saves_for_login_as_admin
    session = {
      user: OpenStruct.new(id: 42, username: 'target', admin?: false),
      admin_user: OpenStruct.new(id: 1, username: 'admin', admin?: true)
    }
    ctrl, _req, res = dispatch(Admin::LicensesController, :create, method: :post,
                               params: { license: { encrypted_key: 'encrypted_key_login_as_admin' } }, session: session)

    assert_equal 200, res.status
    assert_equal :create_success, ctrl.instance_variable_get(:@rendered_action)
    assert_equal 1, $call_spy.license_save_calls
  end

  def test_license_create_invalid_key_renders_new_with_422
    session = { user: OpenStruct.new(id: 1, username: 'admin', admin?: true) }
    ctrl, _req, res = dispatch(Admin::LicensesController, :create, method: :post,
                               params: { license: { encrypted_key: '' } }, session: session)

    assert_equal 422, res.status
    assert_equal :new, ctrl.instance_variable_get(:@rendered_action)
    assert_equal 1, $call_spy.license_save_calls, 'Failed save called validator'
  end

  # ===========================================================================
  # 6. VirtualApplianceController: Denied Requests (Assert 0 Model / API calls)
  # ===========================================================================

  def test_va_index_denied_for_anonymous_requires_login_with_zero_grant_calls
    ctrl, _req, res = dispatch(VirtualApplianceController, :index, session: {})
    assert_equal 302, res.status
    assert_equal 'http://test.host/login', res.location
    assert_equal 0, $call_spy.total_grant_io_calls, 'Anonymous index must make 0 grant calls'
    assert_equal 0, $call_spy.total_license_io_calls, 'Anonymous index must NOT run init_trial_license'
    refute $trial_license_initialized
  end

  def test_va_create_denied_for_anonymous_halts_before_model_and_api
    ctrl, _req, res = dispatch(VirtualApplianceController, :create, method: :post,
                               params: { appliance_user: { user_id: 'target_account' } }, session: {})
    assert_equal 302, res.status
    assert_equal 'http://test.host/login', res.location
    assert_equal 0, $call_spy.total_grant_io_calls, 'Anonymous create must make 0 user/grant calls'
    assert_equal 0, $call_spy.total_license_io_calls, 'Anonymous create must NOT run init_trial_license'
    refute $trial_license_initialized
  end

  def test_va_create_denied_for_ordinary_user_halts_before_model_and_api
    session = { user: OpenStruct.new(id: 42, username: 'reg_user', admin?: false) }
    ctrl, _req, res = dispatch(VirtualApplianceController, :create, method: :post,
                               params: { appliance_user: { user_id: 'target_account' } }, session: session)
    assert_equal 302, res.status
    assert_equal 'http://test.host/', res.location
    assert_equal 0, $call_spy.total_grant_io_calls, 'Ordinary user create must make 0 user/grant calls'
    assert_equal 0, $call_spy.total_license_io_calls, 'Ordinary user create must NOT run init_trial_license'
    refute $trial_license_initialized
  end

  # ===========================================================================
  # 7. VirtualApplianceController: Preserved Ordinary User Status/Access Page
  # ===========================================================================

  def test_va_index_preserved_for_ordinary_user_reads_only_own_grant
    # Pre-populate some other grants to verify they are NOT queried
    VirtualApplianceUser.records << VirtualApplianceUser.new(user_id: 999)
    $call_spy.reset!

    user = OpenStruct.new(id: 42, username: 'reg_user', admin?: false)
    session = { user: user }

    ctrl, _req, res = dispatch(VirtualApplianceController, :index, session: session)
    assert_equal 200, res.status
    assert_equal 1, $call_spy.va_where_calls, 'Loads only own grant via where(user_id: user.id)'
    assert_equal 0, $call_spy.va_order_calls, 'Must NOT query all grants (VirtualApplianceUser.order) for non-admin'
    assert_equal [], ctrl.instance_variable_get(:@va_users), '@va_users must be empty array for non-admin'
    refute ctrl.instance_variable_get(:@virtual_appliance_access), 'Access false when no own grant exists'
  end

  def test_va_index_ordinary_user_with_own_grant_sets_access_true
    user = OpenStruct.new(id: 42, username: 'reg_user', admin?: false)
    VirtualApplianceUser.records << VirtualApplianceUser.new(user_id: 42)
    $call_spy.reset!

    ctrl, _req, res = dispatch(VirtualApplianceController, :index, session: { user: user })
    assert_equal 200, res.status
    assert_equal 1, $call_spy.va_where_calls
    assert_equal 0, $call_spy.va_order_calls, 'Must NOT query all grants for non-admin even if granted'
    assert ctrl.instance_variable_get(:@virtual_appliance_access), 'Access true when own grant exists'
  end

  # ===========================================================================
  # 8. VirtualApplianceController: Administrator Access & Grant Creation Flow
  # ===========================================================================

  def test_va_index_permitted_for_direct_admin_queries_all_grants
    user = OpenStruct.new(id: 1, username: 'admin', admin?: true)
    ctrl, _req, res = dispatch(VirtualApplianceController, :index, session: { user: user })
    assert_equal 200, res.status
    assert_equal 1, $call_spy.va_where_calls
    assert_equal 1, $call_spy.va_order_calls, 'Direct admin queries all grants for user list'
    assert ctrl.instance_variable_get(:@virtual_appliance_access), 'Admin always has access'
  end

  def test_va_index_permitted_for_login_as_admin_queries_all_grants
    session = {
      user: OpenStruct.new(id: 42, username: 'target', admin?: false),
      admin_user: OpenStruct.new(id: 1, username: 'admin', admin?: true)
    }
    ctrl, _req, res = dispatch(VirtualApplianceController, :index, session: session)
    assert_equal 200, res.status
    assert_equal 1, $call_spy.va_where_calls
    assert_equal 1, $call_spy.va_order_calls, 'Impersonated admin queries all grants'
    assert ctrl.instance_variable_get(:@virtual_appliance_access), 'Impersonated admin has access'
  end

  def test_va_create_permitted_for_direct_admin_adds_grant
    session = { user: OpenStruct.new(id: 1, username: 'admin', admin?: true) }
    ctrl, _req, res = dispatch(VirtualApplianceController, :create, method: :post,
                               params: { appliance_user: { user_id: 'alice' } }, session: session)

    assert_equal 302, res.status
    assert_equal '/virtual_appliance', res.location
    assert_equal 1, $call_spy.user_find_calls, 'User lookup must run'
    assert_equal 1, $call_spy.va_save_calls, 'New grant row must be saved'
    assert_equal 1, VirtualApplianceUser.records.size
    assert_equal 1001, VirtualApplianceUser.records.first.user_id
  end

  def test_va_create_permitted_for_login_as_admin_adds_grant
    session = {
      user: OpenStruct.new(id: 42, username: 'target', admin?: false),
      admin_user: OpenStruct.new(id: 1, username: 'admin', admin?: true)
    }
    ctrl, _req, res = dispatch(VirtualApplianceController, :create, method: :post,
                               params: { appliance_user: { user_id: 'bob' } }, session: session)

    assert_equal 302, res.status
    assert_equal 1, $call_spy.va_save_calls
    assert_equal 1, VirtualApplianceUser.records.size
  end

  def test_va_create_repeated_idempotence_does_not_duplicate_grant
    session = { user: OpenStruct.new(id: 1, username: 'admin', admin?: true) }

    # First addition
    _ctrl, _req, res1 = dispatch(VirtualApplianceController, :create, method: :post,
                                 params: { appliance_user: { user_id: 'alice' } }, session: session)
    assert_equal 302, res1.status
    assert_equal 1, $call_spy.va_save_calls, 'First request creates grant'
    assert_equal 1, VirtualApplianceUser.records.size

    # Repeated addition of the same user
    _ctrl, _req, res2 = dispatch(VirtualApplianceController, :create, method: :post,
                                 params: { appliance_user: { user_id: 'alice' } }, session: session)
    assert_equal 302, res2.status
    assert_equal 1, $call_spy.va_save_calls, 'Repeated request must NOT save a duplicate grant'
    assert_equal 1, VirtualApplianceUser.records.size, 'Record count remains 1 (idempotent)'
  end

  def test_va_create_unknown_user_redirects_with_error_and_zero_saves
    session = { user: OpenStruct.new(id: 1, username: 'admin', admin?: true) }
    ctrl, req, res = dispatch(VirtualApplianceController, :create, method: :post,
                              params: { appliance_user: { user_id: 'unknown_user' } }, session: session)

    assert_equal 302, res.status
    assert_equal 1, $call_spy.user_find_calls
    assert_equal 0, $call_spy.va_save_calls, 'No grant saved for missing user'
    assert_includes req.flash[:error], 'unknown_user'
  end
end
