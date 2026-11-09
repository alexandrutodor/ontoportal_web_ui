# frozen_string_literal: true

require 'minitest/autorun'
require 'logger'
require 'ostruct'
require 'cgi'

# =============================================================================
# Standalone Offline Project Guard & Authorization Check (ONTO-T-B04)
#
# Validates the B04 project authorization and mutation guard contracts:
# 1. Anonymous requests to mutators (new, create, edit, update) redirect to /login
#    before inherited startup callbacks or API lookups execute (0 lookups, 0 writes).
# 2. Anonymous and non-admin requests to destroy redirect to home (/) before
#    inherited startup callbacks or API lookups execute (0 lookups, 0 writes).
# 3. Ordinary project owners (scalar or co-owners) CANNOT delete projects
#    (destroy is strictly admin-only).
# 4. Resource ownership check (authorize_owner) for edit/update runs AFTER
#    inherited thread initialization (sees current request/session context).
# 5. Non-owner edit/update performs exactly 1 Project lookup, 0 writes, 0 user list
#    expansions, and redirects to home (/).
# 6. Foreign/prefix/suffix/URL aliases or empty creator identities do not match.
# 7. Scalar legacy owner (creator == user.id) and co-owners (creator.include?(user.id))
#    are admitted to edit/update, and reuse the checked DTO without duplicate lookup.
# 8. Admin and masquerading admin_user contexts are admitted to edit/update/destroy.
# 9. Missing project flash and redirect to projects_path are preserved.
# 10. Permitted Cancel submits redirect without writes.
# 11. Known upstream 401/403 API responses do not become success.
# 12. Creator collaborator multi-select on create is preserved (not note-author bound).
# =============================================================================

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
require 'action_view'
require 'action_dispatch'
require 'active_record'

ActionController::Base.logger = Logger.new(nil)
Rails.logger = Logger.new(nil)
ActionController::Base.allow_forgery_protection = false
$ENABLE_SLICES = false
$REST_URL = 'http://example.com'
$API_KEY = 'test'

I18n.load_path = Dir[File.join(worktree_root, 'config/locales/*.yml')]
I18n.default_locale = :en
I18n.locale = :en

require 'urls_helper'
require 'terms_reuses'
require 'components_helper'
require 'ontologies_helper'
require 'internationalisation_helper'
require 'multi_languages_helper'
require 'modal_helper'
require 'application_helper'
require 'application_controller'
require 'projects_controller'

# Record pristine callback order immediately upon loading ProjectsController, prior to any fixture skips
ORIGINAL_ACTION_CALLBACKS = ProjectsController._process_action_callbacks.map(&:filter).freeze

# Finite route helper stubs
module ProjectRouteHelperStubs
  def login_index_path(*args, **kwargs)
    '/login'
  end

  def projects_path(*args, **kwargs)
    '/projects'
  end

  def project_path(id, *args, **kwargs)
    "/projects/#{id}"
  end

  def new_project_path(*args, **kwargs)
    '/projects/new'
  end

  def edit_project_path(id, *args, **kwargs)
    "/projects/#{id}/edit"
  end

  def ontology_path(id, *args, **kwargs)
    "/ontologies/#{id}"
  end

  def url_for(options = nil)
    case options
    when Hash
      if options[:controller] == 'login'
        '/login'
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
ActionController::Base.include ProjectRouteHelperStubs

# =============================================================================
# Call Tracker Spy & Synthetic SDK Doubles
# =============================================================================

class ProjectCallSpy
  attr_accessor :project_find_by_acronym_calls, :project_find_by_acronym_args
  attr_accessor :project_all_calls, :project_save_calls, :project_update_calls, :project_delete_calls
  attr_accessor :project_update_from_params_calls
  attr_accessor :user_all_calls, :ontology_all_calls, :ontology_find_calls
  attr_accessor :init_trial_license_calls

  def initialize
    reset!
  end

  def reset!
    @project_find_by_acronym_calls = 0
    @project_find_by_acronym_args = []
    @project_all_calls = 0
    @project_save_calls = 0
    @project_update_calls = 0
    @project_delete_calls = 0
    @project_update_from_params_calls = 0
    @user_all_calls = 0
    @ontology_all_calls = 0
    @ontology_find_calls = 0
    @init_trial_license_calls = 0
  end

  def total_lookup_calls
    @project_find_by_acronym_calls + @project_all_calls
  end

  def total_write_calls
    @project_save_calls + @project_update_calls + @project_delete_calls
  end
end

$project_spy = ProjectCallSpy.new

# Synthetic SDK Project Model Double
module LinkedData
  module Client
    module Models
      class Project
        attr_accessor :name, :acronym, :institution, :contacts, :creator, :homePage, :description, :ontologyUsed
        attr_accessor :forced_save_response, :forced_update_response, :forced_delete_response

        class << self
          attr_accessor :registry, :raise_on_find_by_acronym
        end
        self.registry = {}
        self.raise_on_find_by_acronym = false

        def self.reset_registry!
          self.registry = {}
          self.raise_on_find_by_acronym = false
        end

        def self.register(proj)
          self.registry[proj.acronym.to_s] = proj
          proj
        end

        def self.all
          $project_spy.project_all_calls += 1
          self.registry.values
        end

        def self.find_by_acronym(acronym)
          raise RuntimeError, 'Backend outage: find_by_acronym unavailable' if @raise_on_find_by_acronym

          $project_spy.project_find_by_acronym_calls += 1
          $project_spy.project_find_by_acronym_args << acronym.to_s
          proj = self.registry[acronym.to_s]
          proj ? [proj] : []
        end

        def initialize(values: {})
          @ontologyUsed = []
          @creator = []
          values.to_h.each do |k, v|
            send("#{k}=", v) if respond_to?("#{k}=")
          end
        end

        def update_from_params(params = {})
          $project_spy.project_update_from_params_calls += 1
          params.to_h.each do |k, v|
            send("#{k}=", v) if respond_to?("#{k}=")
          end
          self
        end

        def save
          $project_spy.project_save_calls += 1
          return @forced_save_response if @forced_save_response

          LinkedData::Client::Models::Project.register(self)
          OpenStruct.new(status: 201, errors: nil)
        end

        def update
          $project_spy.project_update_calls += 1
          return @forced_update_response if @forced_update_response

          OpenStruct.new(status: 200, errors: nil)
        end

        def delete
          $project_spy.project_delete_calls += 1
          return @forced_delete_response if @forced_delete_response

          LinkedData::Client::Models::Project.registry.delete(@acronym.to_s)
          OpenStruct.new(status: 204, errors: nil)
        end
      end

      class User
        attr_accessor :id, :username, :role

        def initialize(id: nil, username: nil, role: ['USER'])
          @id = id
          @username = username
          @role = role
        end

        def admin?
          @role == 'ADMIN' || (@role.is_a?(Array) && @role.include?('ADMIN'))
        end

        def self.all
          $project_spy.user_all_calls += 1
          [
            User.new(id: 'http://example.com/users/alice', username: 'alice'),
            User.new(id: 'http://example.com/users/bob', username: 'bob')
          ]
        end
      end

      class Ontology
        attr_accessor :id, :acronym, :name, :errors

        def initialize(id: nil, acronym: nil, name: nil, errors: nil)
          @id = id
          @acronym = acronym
          @name = name
          @errors = errors
        end

        def self.all(options = {})
          $project_spy.ontology_all_calls += 1
          [
            Ontology.new(id: 'http://example.com/ontologies/ONT1', acronym: 'ONT1', name: 'Ontology 1')
          ]
        end

        def self.find(id)
          $project_spy.ontology_find_calls += 1
          Ontology.new(id: id, acronym: id.to_s.split('/').last, name: "Ontology #{id}")
        end
      end
    end
  end
end

ProjectsController.layout false
# Finite unrelated startup boundaries skipped honestly for offline standalone test environment
ProjectsController.skip_before_action :set_locale, :domain_ontology_set, :clean_empty_strings_from_params_arrays, :init_trial_license, raise: false

class ProjectGuardCheck < Minitest::Test
  ALICE_ID = 'http://example.com/users/alice'
  BOB_ID = 'http://example.com/users/bob'
  CHARLIE_ID = 'http://example.com/users/charlie'
  ADMIN_ID = 'http://example.com/users/admin_user'

  def setup
    $project_spy.reset!
    LinkedData::Client::Models::Project.reset_registry!

    # Setup seed projects:
    # 1. SCALAR_PROJ: legacy scalar creator (Alice)
    @scalar_proj = LinkedData::Client::Models::Project.new(values: {
      name: 'Scalar Project',
      acronym: 'SCALAR',
      creator: ALICE_ID,
      institution: 'Inst A',
      contacts: 'Alice Contact',
      ontologyUsed: ['http://example.com/ontologies/ONT1']
    })
    LinkedData::Client::Models::Project.register(@scalar_proj)

    # 2. MULTI_PROJ: co-owned project (Alice and Bob)
    @multi_proj = LinkedData::Client::Models::Project.new(values: {
      name: 'Multi Project',
      acronym: 'MULTI',
      creator: [ALICE_ID, BOB_ID],
      institution: 'Inst AB',
      contacts: 'AB Contact',
      ontologyUsed: ['http://example.com/ontologies/ONT1']
    })
    LinkedData::Client::Models::Project.register(@multi_proj)

    # 3. PREFIX_PROJ: creator with suffix/prefix that should NOT match Alice
    @foreign_proj = LinkedData::Client::Models::Project.new(values: {
      name: 'Foreign Project',
      acronym: 'FOREIGN',
      creator: "#{ALICE_ID}_extra",
      institution: 'Inst Foreign',
      contacts: 'Foreign Contact'
    })
    LinkedData::Client::Models::Project.register(@foreign_proj)

    # Users
    @user_alice = OpenStruct.new(id: ALICE_ID, username: 'alice', admin?: false)
    @user_bob = OpenStruct.new(id: BOB_ID, username: 'bob', admin?: false)
    @user_charlie = OpenStruct.new(id: CHARLIE_ID, username: 'charlie', admin?: false)
    @user_admin = OpenStruct.new(id: ADMIN_ID, username: 'admin', admin?: true)
  end

  def teardown
    Thread.current[:request] = nil
    Thread.current[:session] = nil
  end

  # Helper to dispatch requests through real Rails ActionPack controller stack
  def dispatch(action, method: :get, params: {}, session: {})
    ctrl = ProjectsController.new
    req = ActionDispatch::TestRequest.create
    req.request_method = method.to_s.upcase
    params.each { |k, v| req.params[k] = v }
    req.set_header 'rack.session', session
    req.set_header 'action_dispatch.request.flash_hash', ActionDispatch::Flash::FlashHash.new
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
      super(opts)
    end

    ctrl.process(action)
    [ctrl, req, res]
  end

  # ===========================================================================
  # 1. ActionPack Callback Chain & Ordering Verification
  # ===========================================================================

  def test_pristine_callback_ordering_and_precedence
    auth_admin_idx = ORIGINAL_ACTION_CALLBACKS.index(:authorize_admin)
    req_login_idx = ORIGINAL_ACTION_CALLBACKS.index(:require_login)
    thread_val_idx = ORIGINAL_ACTION_CALLBACKS.index(:set_global_thread_values)
    auth_owner_idx = ORIGINAL_ACTION_CALLBACKS.index(:authorize_owner)

    refute_nil auth_admin_idx, 'ProjectsController must declare :authorize_admin callback'
    refute_nil req_login_idx, 'ProjectsController must declare :require_login callback'
    refute_nil auth_owner_idx, 'ProjectsController must declare :authorize_owner callback'
    refute_nil thread_val_idx, 'ProjectsController must inherit :set_global_thread_values callback'

    # Session-local checks must be prepended ahead of inherited startup callbacks
    assert_operator auth_admin_idx, :<, thread_val_idx,
                    ':authorize_admin must precede inherited :set_global_thread_values'
    assert_operator req_login_idx, :<, thread_val_idx,
                    ':require_login must precede inherited :set_global_thread_values'

    # Resource ownership check must be ordinary before_action after inherited thread values
    assert_operator thread_val_idx, :<, auth_owner_idx,
                    ':authorize_owner must execute after inherited :set_global_thread_values'
  end

  # ===========================================================================
  # 2. Anonymous Mutator Denials & Thread Sentinel Verification
  # ===========================================================================

  def test_anonymous_new_denied_with_zero_lookups_and_sentinel_preserved
    sentinel_req = Object.new
    sentinel_session = Object.new
    Thread.current[:request] = sentinel_req
    Thread.current[:session] = sentinel_session

    _ctrl, _req, res = dispatch(:new, session: {})

    assert_equal 302, res.status
    assert_includes res.location, '/login', 'Anonymous new must redirect to /login'
    assert_equal 0, $project_spy.total_lookup_calls, 'Anonymous new must make 0 lookups'
    assert_equal 0, $project_spy.user_all_calls, 'Anonymous new must not expand user list'
    assert_same sentinel_req, Thread.current[:request], 'Thread sentinel request must be preserved'
    assert_same sentinel_session, Thread.current[:session], 'Thread sentinel session must be preserved'
  end

  def test_anonymous_create_denied_with_zero_lookups_zero_writes_and_sentinel_preserved
    sentinel_req = Object.new
    sentinel_session = Object.new
    Thread.current[:request] = sentinel_req
    Thread.current[:session] = sentinel_session

    params = { project: { name: 'Hack Proj', acronym: 'HACK' } }
    _ctrl, _req, res = dispatch(:create, method: :post, params: params, session: {})

    assert_equal 302, res.status
    assert_includes res.location, '/login', 'Anonymous create must redirect to /login'
    assert_equal 0, $project_spy.total_lookup_calls, 'Anonymous create must make 0 lookups'
    assert_equal 0, $project_spy.total_write_calls, 'Anonymous create must make 0 writes'
    assert_same sentinel_req, Thread.current[:request], 'Thread sentinel request must be preserved'
    assert_same sentinel_session, Thread.current[:session], 'Thread sentinel session must be preserved'
  end

  def test_anonymous_edit_denied_with_zero_lookups_and_sentinel_preserved
    sentinel_req = Object.new
    sentinel_session = Object.new
    Thread.current[:request] = sentinel_req
    Thread.current[:session] = sentinel_session

    _ctrl, _req, res = dispatch(:edit, params: { id: 'SCALAR' }, session: {})

    assert_equal 302, res.status
    assert_includes res.location, '/login', 'Anonymous edit must redirect to /login'
    assert_equal 0, $project_spy.total_lookup_calls, 'Anonymous edit must make 0 lookups'
    assert_equal 0, $project_spy.total_write_calls, 'Anonymous edit must make 0 writes'
    assert_same sentinel_req, Thread.current[:request], 'Thread sentinel request must be preserved'
    assert_same sentinel_session, Thread.current[:session], 'Thread sentinel session must be preserved'
  end

  def test_anonymous_update_denied_with_zero_lookups_and_sentinel_preserved
    sentinel_req = Object.new
    sentinel_session = Object.new
    Thread.current[:request] = sentinel_req
    Thread.current[:session] = sentinel_session

    params = { id: 'SCALAR', project: { name: 'Hacked Name' } }
    _ctrl, _req, res = dispatch(:update, method: :put, params: params, session: {})

    assert_equal 302, res.status
    assert_includes res.location, '/login', 'Anonymous update must redirect to /login'
    assert_equal 0, $project_spy.total_lookup_calls, 'Anonymous update must make 0 lookups'
    assert_equal 0, $project_spy.total_write_calls, 'Anonymous update must make 0 writes'
    assert_same sentinel_req, Thread.current[:request], 'Thread sentinel request must be preserved'
    assert_same sentinel_session, Thread.current[:session], 'Thread sentinel session must be preserved'
  end

  def test_anonymous_destroy_denied_with_zero_lookups_and_sentinel_preserved
    sentinel_req = Object.new
    sentinel_session = Object.new
    Thread.current[:request] = sentinel_req
    Thread.current[:session] = sentinel_session

    _ctrl, _req, res = dispatch(:destroy, method: :delete, params: { id: 'SCALAR' }, session: {})

    assert_equal 302, res.status
    assert_equal 'http://test.host/', res.location, 'Anonymous destroy must redirect to home'
    assert_equal 0, $project_spy.total_lookup_calls, 'Anonymous destroy must make 0 lookups'
    assert_equal 0, $project_spy.total_write_calls, 'Anonymous destroy must make 0 writes'
    assert_same sentinel_req, Thread.current[:request], 'Thread sentinel request must be preserved'
    assert_same sentinel_session, Thread.current[:session], 'Thread sentinel session must be preserved'
  end

  # ===========================================================================
  # 3. Non-Admin Destroy Denials (Ordinary Owners CANNOT Delete)
  # ===========================================================================

  def test_scalar_owner_cannot_destroy_project
    sentinel_req = Object.new
    sentinel_session = Object.new
    Thread.current[:request] = sentinel_req
    Thread.current[:session] = sentinel_session

    _ctrl, _req, res = dispatch(:destroy, method: :delete, params: { id: 'SCALAR' }, session: { user: @user_alice })

    assert_equal 302, res.status
    assert_equal 'http://test.host/', res.location, 'Ordinary owner cannot destroy project; redirects to home'
    assert_equal 0, $project_spy.total_lookup_calls, 'Non-admin destroy must make 0 lookups'
    assert_equal 0, $project_spy.total_write_calls, 'Non-admin destroy must make 0 writes'
    assert_same sentinel_req, Thread.current[:request], 'Thread sentinel request must be preserved'
    assert_same sentinel_session, Thread.current[:session], 'Thread sentinel session must be preserved'
  end

  def test_co_owner_cannot_destroy_project
    _ctrl, _req, res = dispatch(:destroy, method: :delete, params: { id: 'MULTI' }, session: { user: @user_bob })

    assert_equal 302, res.status
    assert_equal 'http://test.host/', res.location, 'Ordinary co-owner cannot destroy project; redirects to home'
    assert_equal 0, $project_spy.total_lookup_calls
    assert_equal 0, $project_spy.total_write_calls
  end

  def test_nonowner_cannot_destroy_project
    _ctrl, _req, res = dispatch(:destroy, method: :delete, params: { id: 'SCALAR' }, session: { user: @user_charlie })

    assert_equal 302, res.status
    assert_equal 'http://test.host/', res.location, 'Non-owner non-admin cannot destroy project'
    assert_equal 0, $project_spy.total_lookup_calls
    assert_equal 0, $project_spy.total_write_calls
  end

  # ===========================================================================
  # 4. Non-Owner Edit & Update (Necessary Read Only, 0 Writes, 0 List Expansion)
  # ===========================================================================

  def test_authenticated_nonowner_edit_denied_with_exact_single_lookup
    ctrl, req, res = dispatch(:edit, params: { id: 'SCALAR' }, session: { user: @user_charlie })

    assert_equal 302, res.status
    assert_equal 'http://test.host/', res.location, 'Non-owner edit must redirect to home'
    assert_equal 1, $project_spy.project_find_by_acronym_calls, 'Must perform exactly 1 lookup to verify ownership'
    assert_equal 0, $project_spy.total_write_calls, 'Non-owner edit must make 0 writes'
    assert_equal 0, $project_spy.user_all_calls, 'Non-owner edit must NOT expand user list'
    assert_equal 0, $project_spy.ontology_all_calls, 'Non-owner edit must NOT expand ontology list'

    # Current request/session context was initialized for the read
    assert_same req, Thread.current[:request]
  end

  def test_authenticated_nonowner_update_denied_with_exact_single_lookup_and_no_param_update
    params = { id: 'SCALAR', project: { name: 'Illicit Update' } }
    ctrl, req, res = dispatch(:update, method: :put, params: params, session: { user: @user_charlie })

    assert_equal 302, res.status
    assert_equal 'http://test.host/', res.location, 'Non-owner update must redirect to home'
    assert_equal 1, $project_spy.project_find_by_acronym_calls, 'Must perform exactly 1 lookup to verify ownership'
    assert_equal 0, $project_spy.project_update_from_params_calls, 'Must reject before update_from_params'
    assert_equal 0, $project_spy.total_write_calls, 'Non-owner update must make 0 writes'
    assert_equal 0, $project_spy.user_all_calls, 'Non-owner update must NOT expand user list'
    assert_equal 0, $project_spy.ontology_all_calls, 'Non-owner update must NOT expand ontology list'
    assert_equal 'Scalar Project', @scalar_proj.name, 'Project name in registry must remain unmodified'
  end

  # ===========================================================================
  # 5. Foreign, Prefix, URL Suffix, and Empty Creator Identities Not Matched
  # ===========================================================================

  def test_foreign_suffix_creator_not_matched
    ctrl, _req, res = dispatch(:edit, params: { id: 'FOREIGN' }, session: { user: @user_alice })
    assert_equal 302, res.status
    assert_equal 'http://test.host/', res.location, 'Creator suffix match must NOT be admitted'
    assert_equal 1, $project_spy.project_find_by_acronym_calls
    assert_equal 0, $project_spy.user_all_calls
  end

  def test_url_suffix_or_alias_creator_not_matched_against_bare_username
    # Alice user with bare username ID should NOT match URI creator
    bare_alice = OpenStruct.new(id: 'alice', username: 'alice', admin?: false)
    _ctrl, _req, res = dispatch(:edit, params: { id: 'SCALAR' }, session: { user: bare_alice })
    assert_equal 302, res.status
    assert_equal 'http://test.host/', res.location, 'URL suffix alias must NOT be matched'
    assert_equal 1, $project_spy.project_find_by_acronym_calls
    assert_equal 0, $project_spy.user_all_calls
  end

  def test_empty_or_whitespace_creator_not_matched
    empty_proj = LinkedData::Client::Models::Project.new(values: {
      name: 'Empty Creator Project',
      acronym: 'EMPTY_CR',
      creator: '   '
    })
    LinkedData::Client::Models::Project.register(empty_proj)

    empty_user = OpenStruct.new(id: '   ', username: 'empty', admin?: false)
    _ctrl, _req, res = dispatch(:edit, params: { id: 'EMPTY_CR' }, session: { user: empty_user })
    assert_equal 302, res.status
    assert_equal 'http://test.host/', res.location, 'Empty creator identity must NOT match'
  end

  # ===========================================================================
  # 6. Scalar Owner & Co-Owner Admitted (Checked DTO Reused, Writes Observed)
  # ===========================================================================

  def test_scalar_owner_edit_admitted_and_reuses_loaded_dto
    ctrl, _req, res = dispatch(:edit, params: { id: 'SCALAR' }, session: { user: @user_alice })

    assert_equal 200, res.status
    assert_equal 1, $project_spy.project_find_by_acronym_calls, 'Exactly 1 lookup'
    assert_equal 0, $project_spy.total_write_calls, 'Edit makes 0 writes'
    assert_equal 1, $project_spy.user_all_calls, 'User select list populated for permitted edit'
    assert_equal 1, $project_spy.ontology_all_calls, 'Ontologies loaded for permitted edit'
    assert_same @scalar_proj, ctrl.instance_variable_get(:@project), 'Loaded DTO must be reused in controller'
  end

  def test_scalar_owner_update_admitted_and_writes_observed
    params = {
      id: 'SCALAR',
      project: { name: 'Updated Scalar Name', institution: 'New Inst' }
    }
    ctrl, _req, res = dispatch(:update, method: :put, params: params, session: { user: @user_alice })

    assert_equal 302, res.status
    assert_includes res.location, '/projects/SCALAR'
    assert_equal 1, $project_spy.project_find_by_acronym_calls, 'Exactly 1 lookup'
    assert_equal 1, $project_spy.project_update_from_params_calls, 'Parameters updated on checked DTO'
    assert_equal 1, $project_spy.project_update_calls, 'Exactly 1 update write observed'
    assert_equal 'Updated Scalar Name', @scalar_proj.name
    assert_equal 'New Inst', @scalar_proj.institution
    assert_same @scalar_proj, ctrl.instance_variable_get(:@project), 'Checked DTO must be directly written'
  end

  def test_co_owner_edit_and_update_admitted
    # Bob is co-owner on MULTI
    _ctrl, _req, res = dispatch(:edit, params: { id: 'MULTI' }, session: { user: @user_bob })
    assert_equal 200, res.status
    assert_equal 1, $project_spy.project_find_by_acronym_calls

    params = { id: 'MULTI', project: { name: 'Updated Multi by Bob' } }
    _ctrl, _req, res_up = dispatch(:update, method: :put, params: params, session: { user: @user_bob })
    assert_equal 302, res_up.status
    assert_includes res_up.location, '/projects/MULTI'
    assert_equal 1, $project_spy.project_update_calls
    assert_equal 'Updated Multi by Bob', @multi_proj.name
  end

  def test_permitted_actor_cancel_update_performs_zero_writes
    LinkedData::Client::Models::Project.raise_on_find_by_acronym = true
    params = {
      id: 'SCALAR',
      commit: 'Cancel',
      project: { name: 'Cancelled Name' }
    }

    # 1. Permitted owner Cancel update redirects to /projects with zero lookups and zero writes
    _ctrl, _req, res = dispatch(:update, method: :put, params: params, session: { user: @user_alice })

    assert_equal 302, res.status
    assert_includes res.location, '/projects'
    assert_equal 0, $project_spy.total_lookup_calls, 'Cancel must perform 0 project/resource lookups'
    assert_equal 0, $project_spy.project_find_by_acronym_calls, 'Cancel must not lookup project by acronym'
    assert_equal 0, $project_spy.project_all_calls, 'Cancel must not lookup all projects'
    assert_equal 0, $project_spy.user_all_calls, 'Cancel must not expand user list'
    assert_equal 0, $project_spy.ontology_all_calls, 'Cancel must not expand ontology list'
    assert_equal 0, $project_spy.project_update_from_params_calls, 'Cancel must not update params'
    assert_equal 0, $project_spy.total_write_calls, 'Cancel must perform 0 writes'
    assert_equal 0, $project_spy.project_save_calls, 'Cancel must not call save'
    assert_equal 0, $project_spy.project_update_calls, 'Cancel must not call update'
    assert_equal 0, $project_spy.project_delete_calls, 'Cancel must not call delete'
    assert_equal 'Scalar Project', @scalar_proj.name, 'Registry project name must remain unmodified'

    # 2. Permitted admin Cancel update also succeeds with zero lookups and zero writes
    _ctrl_adm, _req_adm, res_adm = dispatch(:update, method: :put, params: params, session: { user: @user_admin })
    assert_equal 302, res_adm.status
    assert_includes res_adm.location, '/projects'
    assert_equal 0, $project_spy.total_lookup_calls, 'Admin Cancel must perform 0 lookups'
    assert_equal 0, $project_spy.total_write_calls, 'Admin Cancel must perform 0 writes'

    # 3. Anonymous Cancel update must not bypass login guard (redirects to /login with zero lookups and writes)
    _ctrl_anon, _req_anon, res_anon = dispatch(:update, method: :put, params: params, session: {})
    assert_equal 302, res_anon.status
    assert_includes res_anon.location, '/login'
    assert_equal 0, $project_spy.total_lookup_calls, 'Anonymous Cancel must perform 0 lookups'
    assert_equal 0, $project_spy.total_write_calls, 'Anonymous Cancel must perform 0 writes'

    # 4. Scope: edit action does not bypass ownership guard when commit is Cancel (reaches find_by_acronym and raises)
    assert_raises(RuntimeError) do
      dispatch(:edit, params: { id: 'SCALAR', commit: 'Cancel' }, session: { user: @user_alice })
    end

    # 5. Scope: non-owner edit with Cancel is denied by ownership guard
    LinkedData::Client::Models::Project.raise_on_find_by_acronym = false
    _ctrl_nonowner, _req_nonowner, res_nonowner = dispatch(:edit, params: { id: 'SCALAR', commit: 'Cancel' }, session: { user: @user_charlie })
    assert_equal 302, res_nonowner.status
    assert_equal 'http://test.host/', res_nonowner.location
  ensure
    LinkedData::Client::Models::Project.raise_on_find_by_acronym = false
  end

  # ===========================================================================
  # 7. Admin and Admin_User Contexts Admitted (Can Edit, Update, Destroy)
  # ===========================================================================

  def test_portal_admin_can_edit_update_and_destroy
    # Edit
    _ctrl, _req, res = dispatch(:edit, params: { id: 'SCALAR' }, session: { user: @user_admin })
    assert_equal 200, res.status

    # Update
    params = { id: 'SCALAR', project: { name: 'Admin Updated' } }
    _ctrl, _req, res_up = dispatch(:update, method: :put, params: params, session: { user: @user_admin })
    assert_equal 302, res_up.status
    assert_equal 1, $project_spy.project_update_calls

    # Destroy
    _ctrl, _req, res_del = dispatch(:destroy, method: :delete, params: { id: 'SCALAR' }, session: { user: @user_admin })
    assert_equal 302, res_del.status
    assert_includes res_del.location, '/projects'
    assert_equal 1, $project_spy.project_delete_calls
    assert_nil LinkedData::Client::Models::Project.registry['SCALAR'], 'Project must be deleted from registry'
  end

  def test_admin_user_masquerade_context_can_edit_update_and_destroy
    # Charlie is ordinary user, but session[:admin_user] is admin
    session_masquerade = { user: @user_charlie, admin_user: @user_admin }

    # Edit
    _ctrl, _req, res = dispatch(:edit, params: { id: 'SCALAR' }, session: session_masquerade)
    assert_equal 200, res.status, 'Masquerading admin_user context admitted to edit'

    # Update
    params = { id: 'SCALAR', project: { name: 'Masquerade Updated' } }
    _ctrl, _req, res_up = dispatch(:update, method: :put, params: params, session: session_masquerade)
    assert_equal 302, res_up.status
    assert_equal 1, $project_spy.project_update_calls

    # Destroy
    _ctrl, _req, res_del = dispatch(:destroy, method: :delete, params: { id: 'SCALAR' }, session: session_masquerade)
    assert_equal 302, res_del.status
    assert_includes res_del.location, '/projects'
    assert_equal 1, $project_spy.project_delete_calls
    assert_nil LinkedData::Client::Models::Project.registry['SCALAR'], 'Project deleted by admin_user'
  end

  # ===========================================================================
  # 8. Missing Project Handling & Upstream API 401/403 Errors
  # ===========================================================================

  def test_missing_project_edit_and_update_redirect_with_flash_error
    ctrl, _req, res = dispatch(:edit, params: { id: 'NONEXISTENT' }, session: { user: @user_alice })
    assert_equal 302, res.status
    assert_includes res.location, '/projects'
    assert_includes ctrl.flash[:notice].to_s, 'red', 'Missing project sets styled flash notice'

    ctrl_up, _req_up, res_up = dispatch(:update, method: :put, params: { id: 'NONEXISTENT', project: { name: 'X' } }, session: { user: @user_alice })
    assert_equal 302, res_up.status
    assert_includes res_up.location, '/projects'
    assert_includes ctrl_up.flash[:notice].to_s, 'red'
  end

  def test_missing_project_destroy_by_admin_redirects_with_flash_error
    ctrl, _req, res = dispatch(:destroy, method: :delete, params: { id: 'NONEXISTENT' }, session: { user: @user_admin })
    assert_equal 302, res.status
    assert_includes res.location, '/projects'
    assert_equal 0, $project_spy.project_delete_calls
    assert_includes ctrl.flash[:notice].to_s, 'red'
  end

  def test_upstream_api_401_403_on_create_does_not_become_success
    error_resp = OpenStruct.new(status: 403, errors: ['Unauthorized upstream mutation'])
    # Temporarily force save response error
    save_stub = proc { error_resp }

    LinkedData::Client::Models::Project.class_eval do
      alias_method :orig_save, :save
      define_method(:save) do
        $project_spy.project_save_calls += 1
        error_resp
      end
    end

    params = { project: { name: 'Failing Proj', acronym: 'FAIL' } }
    ctrl, _req, res = dispatch(:create, method: :post, params: params, session: { user: @user_alice })

    LinkedData::Client::Models::Project.class_eval do
      alias_method :save, :orig_save
    end

    refute_equal 302, res.status, 'Upstream 403 must not redirect to success'
    assert_equal 200, res.status, 'Upstream 403 renders new action'
    refute_nil ctrl.instance_variable_get(:@errors), 'Errors must be populated'
  end

  def test_upstream_api_401_403_on_update_does_not_become_success
    error_resp = OpenStruct.new(status: 401, errors: ['Upstream session expired'])
    @scalar_proj.forced_update_response = error_resp

    params = { id: 'SCALAR', project: { name: 'Failing Update' } }
    ctrl, _req, res = dispatch(:update, method: :put, params: params, session: { user: @user_alice })

    refute_equal 302, res.status, 'Upstream 401 must not redirect to success'
    assert_equal 200, res.status, 'Upstream 401 renders edit'
    refute_nil ctrl.instance_variable_get(:@errors), 'Errors must be populated'
  end

  def test_upstream_api_500_on_destroy_does_not_become_success
    error_resp = OpenStruct.new(status: 500, errors: ['Internal error deleting project'])
    @scalar_proj.forced_delete_response = error_resp

    ctrl, _req, res = dispatch(:destroy, method: :delete, params: { id: 'SCALAR' }, session: { user: @user_admin })

    assert_equal 302, res.status
    assert_includes res.location, '/projects'
    refute_includes ctrl.flash[:notice].to_s, 'successfully deleted', 'Must not flash success on upstream error'
    refute_nil LinkedData::Client::Models::Project.registry['SCALAR'], 'Project remains in registry'
  end

  # ===========================================================================
  # 9. Creator Multi-Select Preserved on Create (Not Note-Author Bound)
  # ===========================================================================

  def test_creator_multi_select_collaborators_preserved_on_create
    params = {
      project: {
        name: 'Collaborative Project',
        acronym: 'COLLAB',
        creator: [ALICE_ID, BOB_ID, CHARLIE_ID],
        institution: 'Joint Lab'
      }
    }
    ctrl, _req, res = dispatch(:create, method: :post, params: params, session: { user: @user_alice })

    assert_equal 302, res.status
    assert_includes res.location, '/projects/COLLAB'
    saved = LinkedData::Client::Models::Project.registry['COLLAB']
    refute_nil saved, 'Created project must be in registry'
    assert_equal [ALICE_ID, BOB_ID, CHARLIE_ID], saved.creator,
                 'Creator multi-select collaborators must be preserved, not overwritten with actor ID'
  end
end
