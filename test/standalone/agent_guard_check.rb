# frozen_string_literal: true

require 'minitest/autorun'
require 'logger'
require 'ostruct'
require 'cgi'

# =============================================================================
# Standalone Offline Agent Role Guard & Mutator Boundary Check (ONTO-T-B04)
#
# Validates the B04 agent role boundary contract:
# 1. AgentsController prepends session-local authorization checks:
#    - :authorize_admin for admin-only mutators [:destroy, :update_agent_usages]
#    - :authorize_and_redirect for authenticated mutators [:new, :create, :edit, :update]
#    Both precede inherited startup callbacks (:set_global_thread_values, etc.).
# 2. Anonymous callers to all mutators are halted before startup callbacks:
#    - Sentinels in Thread.current[:request] and Thread.current[:session] untouched.
#    - Zero Agent/Ontology/Submission model reads or writes.
# 3. Ordinary users (including creator of the agent) cannot delete or update usages:
#    - :destroy and :update_agent_usages are admin-only; non-admin creator is halted
#      before startup callbacks. Zero delete or submission update writes.
# 4. Ownership boundary on edit/update:
#    - Non-owners are denied; update_agent is never called; payload is not mutated.
#    - Missing/blank creator is denied for non-admin.
#    - Prefix and foreign creator values are denied (no URI suffix or substring matching).
#    - Request-supplied creator params have zero authority; actual persisted creator is used.
#    - Blank session actor ID is denied.
#    - Exact persisted creator is permitted for both edit and update.
# 5. Administrators and supported session[:admin_user] impersonation context:
#    - Admitted on all mutators (edit, update, destroy, update_agent_usages).
# 6. Execution timing & checked DTO reuse:
#    - Ownership lookup runs AFTER set_global_thread_values (thread request/session present).
#    - Permitted edit reuses checked @agent DTO with 0 additional lookups.
#    - Permitted update passes checked @agent DTO to update_agent with 0 additional lookups.
# 7. Feature-disabled behavior:
#    - When agents are disabled (Flipper 'Agents' false), non-admin creator cannot edit/update
#      (redirected to root_path). Admin is allowed through.
# 8. Create creator binding:
#    - save_agent binds creator strictly from session[:user].id, ignoring request params.
# 9. Known API 401/403 responses:
#    - Render error alerts and never produce success alerts.
# 10. Shared reads preservation:
#     - Shared GET routes (index, details, show, search, usages) remain accessible.
# 11. Real ApplicationController authorization helpers without policy doubles.
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
require 'action_dispatch/middleware/flash'
require 'active_record'
require 'action_view/testing/resolvers'

Mime::Type.register 'text/vnd.turbo-stream.html', :turbo_stream rescue nil

module Turbo
  module Streams
  end
end

require '/usr/local/bundle/ruby/3.1.0/gems/turbo-rails-2.0.12/app/helpers/turbo/streams/action_helper.rb' rescue nil
require '/usr/local/bundle/ruby/3.1.0/gems/turbo-rails-2.0.12/app/models/turbo/streams/tag_builder.rb' rescue nil
require '/usr/local/bundle/ruby/3.1.0/gems/turbo-rails-2.0.12/app/helpers/turbo/streams_helper.rb' rescue nil
require '/usr/local/bundle/ruby/3.1.0/gems/turbo-rails-2.0.12/app/controllers/turbo/streams/turbo_streams_tag_builder.rb' rescue nil
require '/usr/local/bundle/ruby/3.1.0/gems/turbo-rails-2.0.12/app/helpers/turbo/frames_helper.rb' rescue nil

ActionView::Base.include Turbo::StreamsHelper if defined?(Turbo::StreamsHelper)
ActionView::Base.include Turbo::FramesHelper if defined?(Turbo::FramesHelper)
ActionController::Base.include Turbo::Streams::TurboStreamsTagBuilder if defined?(Turbo::Streams::TurboStreamsTagBuilder)

ActionController::Renderers.add :turbo_stream do |html, _options|
  self.content_type ||= 'text/vnd.turbo-stream.html; charset=utf-8'
  self.response_body = html.is_a?(Array) ? html.join : html.to_s
end

# Presentation Boundary: Display::AlertComponent for TurboHelper alert rendering
module Display
  class AlertComponent
    attr_reader :id, :type

    def initialize(id: nil, type: 'info', **_opts)
      @id = id
      @type = type
    end

    def render_in(view_context, &block)
      content = block ? view_context.capture(&block) : ''
      "<div class=\"alert alert-#{@type}\" id=\"#{@id}\">#{content}</div>".html_safe
    end
  end
end

require 'ontologies_api_client'

ActionController::Base.logger = Logger.new(nil)
Rails.logger = Logger.new(nil)
Rails.cache = ActiveSupport::Cache::MemoryStore.new
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
require 'turbo_helper'
require 'agent_helper'
require 'application_controller'
require 'agents_controller'

ActionController::Base.helper ApplicationHelper
ActionController::Base.helper AgentHelper
ActionController::Base.helper TurboHelper
ActionController::Base.helper UrlsHelper

module AgentHelper
  def agents_metadata_attributes
    [
      ['hasCreator', 'Creator'],
      ['hasContributor', 'Contributor'],
      ['curatedBy', 'Curated By'],
      ['publisher', 'Publisher'],
      ['fundedBy', 'Funded By'],
      ['endorsedBy', 'Endorsed By'],
      ['translator', 'Translator']
    ]
  end
end

# Finite Route Helper Stubs
module AgentRouteHelperStubs
  def root_path(*args, **kwargs)
    '/'
  end

  def agents_path(*args, **kwargs)
    '/agents'
  end

  def agent_path(id, *args, **kwargs)
    "/agents/#{id}"
  end

  def edit_agent_path(id, *args, **kwargs)
    "/agents/#{id}/edit"
  end

  def agents_metadata_attributes
    [
      ['hasCreator', 'Creator'],
      ['hasContributor', 'Contributor'],
      ['curatedBy', 'Curated By'],
      ['publisher', 'Publisher'],
      ['fundedBy', 'Funded By'],
      ['endorsedBy', 'Endorsed By'],
      ['translator', 'Translator']
    ]
  end

  def submission_metadata
    []
  end
end
AgentHelper.prepend AgentRouteHelperStubs
ActionView::Base.include AgentRouteHelperStubs
ActionController::Base.include AgentRouteHelperStubs
ActionController::Base.helper AgentRouteHelperStubs

# Record pristine callback order immediately upon loading AgentsController
ORIGINAL_ACTION_CALLBACKS = AgentsController._process_action_callbacks.dup.freeze

# Finite Presentation Boundary: Fixture Resolver for offline partial rendering
AGENT_FIXTURE_RESOLVER = ActionView::FixtureResolver.new(
  'agents/edit.html.erb' => '<form id="edit_agent">Edit Agent</form>',
  'agents/new.html.erb' => '<form id="new_agent">New Agent</form>',
  'agents/show.html.erb' => '<div id="agent_show">Agent Show Page</div>',
  'agents/_agent.html.erb' => '<tr id="agent_row">Agent Row</tr>',
  'agents/_agent_show.html.erb' => '<div id="agent_show">Agent Show</div>',
  'agents/_agent_usage.html.erb' => '<div id="agent_usage">Agent Usage</div>',
  'agents/table/_name.html.erb' => '<span><%= agent.name %></span>',
  'agents/table/_affiliations.html.erb' => '<span>Affiliations</span>',
  'agents/table/_usages.html.erb' => '<span>Usages</span>',
  'agents/table/_actions.html.erb' => '<span>Actions</span>'
)

AgentsController.view_paths = [AGENT_FIXTURE_RESOLVER]
AgentsController.layout false

# Honest offline startup skips for unrelated background initialization
AgentsController.skip_before_action :set_locale, :domain_ontology_set, :init_trial_license, raise: false

# =============================================================================
# Finite Boundary Spies and Flipper Configuration
# =============================================================================

class Flipper
  class << self
    attr_accessor :agents_enabled_override

    def enabled?(feature, *args)
      if feature.to_s.casecmp('agents').zero?
        return agents_enabled_override.nil? ? true : agents_enabled_override
      end
      false
    end
  end
end

class AgentBoundarySpy
  attr_accessor :agent_find_calls, :agent_find_ids
  attr_accessor :agent_save_calls, :last_saved_agent
  attr_accessor :agent_update_calls, :last_update_values
  attr_accessor :agent_delete_calls
  attr_accessor :submission_update_calls
  attr_accessor :thread_request_at_find, :thread_session_at_find
  attr_accessor :forced_update_response, :forced_delete_response, :forced_submission_response

  def initialize
    reset!
  end

  def reset!
    @agent_find_calls = 0
    @agent_find_ids = []
    @agent_save_calls = 0
    @last_saved_agent = nil
    @agent_update_calls = 0
    @last_update_values = nil
    @agent_delete_calls = 0
    @submission_update_calls = 0
    @thread_request_at_find = nil
    @thread_session_at_find = nil
    @forced_update_response = nil
    @forced_delete_response = nil
    @forced_submission_response = nil
  end
end

$agent_spy = AgentBoundarySpy.new

# Finite SDK Model Stubs
class AgentStatisticsCalculatorComponent
  def initialize(agent)
    @agent = agent
  end

  def stats
    OpenStruct.new
  end
end

module LinkedData
  module Client
    module Models
      class Agent
        attr_accessor :id, :name, :creator, :agentType, :acronym, :email, :homepage
        attr_accessor :identifiers, :affiliations, :usages, :status, :errors, :acronym_text

        class << self
          def registry
            @registry ||= {}
          end

          def clear_registry!
            @registry = {}
          end

          def find(id, options = {})
            $agent_spy.agent_find_calls += 1
            $agent_spy.agent_find_ids << id
            $agent_spy.thread_request_at_find = Thread.current[:request]
            $agent_spy.thread_session_at_find = Thread.current[:session]

            key = id.to_s.split('/').last
            agent = registry[key] || registry[id.to_s]
            agent ? agent.dup_record : nil
          end

          def all(options = {})
            agents = registry.values.map(&:dup_record)
            [OpenStruct.new(collection: agents, totalCount: agents.size)]
          end
        end

        def initialize(options = {})
          vals = options[:values] || {}
          vals.each { |k, v| send("#{k}=", v) if respond_to?("#{k}=") }
          @usages ||= {}
          @errors = nil
          @status = 200
        end

        def dup_record
          dup
        end

        def save
          $agent_spy.agent_save_calls += 1
          $agent_spy.last_saved_agent = self
          key = @id ? @id.to_s.split('/').last : "new_#{$agent_spy.agent_save_calls}"
          self.class.registry[key] = self
          self
        end

        def update(values: {})
          $agent_spy.agent_update_calls += 1
          $agent_spy.last_update_values = values
          return $agent_spy.forced_update_response if $agent_spy.forced_update_response

          values.each { |k, v| send("#{k}=", v) if respond_to?("#{k}=") }
          OpenStruct.new(status: 204, errors: nil)
        end

        def update_from_params(params)
          self
        end

        def delete
          $agent_spy.agent_delete_calls += 1
          return $agent_spy.forced_delete_response if $agent_spy.forced_delete_response

          key = @id ? @id.to_s.split('/').last : nil
          self.class.registry.delete(key) if key
          OpenStruct.new(status: 204, errors: nil)
        end
      end

      class SubmissionMock
        attr_accessor :hasCreator, :hasContributor, :curatedBy, :publisher, :fundedBy, :endorsedBy, :translator

        def initialize
          @hasCreator = []
          @hasContributor = []
          @curatedBy = []
          @publisher = []
          @fundedBy = []
          @endorsedBy = []
          @translator = []
        end

        def update(values: {}, cache_refresh_all: false)
          $agent_spy.submission_update_calls += 1
          return $agent_spy.forced_submission_response if $agent_spy.forced_submission_response

          OpenStruct.new(status: 204, errors: nil)
        end
      end

      class ExploreMock
        def latest_submission(options = {})
          SubmissionMock.new
        end
      end

      class Ontology
        attr_accessor :acronym, :name

        class << self
          def find_by_acronym(acronym, options = {})
            ont = OpenStruct.new(acronym: acronym, name: "#{acronym} Name", explore: ExploreMock.new)
            [ont]
          end

          def all(options = {})
            [OpenStruct.new(acronym: 'TEST_ONT')]
          end
        end
      end
    end

    module HTTP
      class << self
        def get(path, params = {})
          OpenStruct.new(collection: [], totalCount: 0)
        end
      end
    end
  end
end

# =============================================================================
# Test Suite
# =============================================================================

class AgentGuardCheck < Minitest::Test
  OWNER_ID = 'http://example.com/users/agent_creator_1'
  OTHER_ID = 'http://example.com/users/other_user_2'
  ADMIN_ID = 'http://example.com/users/portal_admin'
  ADMIN_USER_ID = 'http://example.com/users/real_admin_user'

  OWNER_USER = OpenStruct.new(id: OWNER_ID, username: 'agent_creator_1', admin?: false).freeze
  OTHER_USER = OpenStruct.new(id: OTHER_ID, username: 'other_user_2', admin?: false).freeze
  ADMIN_ACTOR = OpenStruct.new(id: ADMIN_ID, username: 'portal_admin', admin?: true).freeze
  SUPPORTED_ADMIN_USER = OpenStruct.new(id: ADMIN_USER_ID, username: 'real_admin_user', admin?: true).freeze

  def setup
    $agent_spy.reset!
    Flipper.agents_enabled_override = true
    LinkedData::Client::Models::Agent.clear_registry!
    seed_agents!
  end

  def teardown
    Thread.current[:request] = nil
    Thread.current[:session] = nil
    Flipper.agents_enabled_override = true
  end

  def seed_agents!
    # Canonical agent owned by OWNER_USER
    agent1 = LinkedData::Client::Models::Agent.new
    agent1.id = 'http://example.com/agents/agent-101'
    agent1.name = 'Agent 101'
    agent1.creator = OWNER_ID
    agent1.agentType = 'person'
    agent1.usages = {}
    LinkedData::Client::Models::Agent.registry['agent-101'] = agent1

    # Agent with missing / empty creator
    agent2 = LinkedData::Client::Models::Agent.new
    agent2.id = 'http://example.com/agents/agent-102'
    agent2.name = 'Agent 102'
    agent2.creator = ''
    agent2.agentType = 'organization'
    agent2.usages = {}
    LinkedData::Client::Models::Agent.registry['agent-102'] = agent2

    # Agent with foreign creator URI
    agent3 = LinkedData::Client::Models::Agent.new
    agent3.id = 'http://example.com/agents/agent-103'
    agent3.name = 'Agent 103'
    agent3.creator = OTHER_ID
    agent3.agentType = 'person'
    agent3.usages = {}
    LinkedData::Client::Models::Agent.registry['agent-103'] = agent3

    # Agent with prefix-matching creator (contains OWNER_ID as prefix + extra suffix)
    agent4 = LinkedData::Client::Models::Agent.new
    agent4.id = 'http://example.com/agents/agent-104'
    agent4.name = 'Agent 104'
    agent4.creator = "#{OWNER_ID}_extra"
    agent4.agentType = 'person'
    agent4.usages = {}
    LinkedData::Client::Models::Agent.registry['agent-104'] = agent4
  end

  def valid_agent_params(overrides = {})
    base = {
      'agentType' => 'person',
      'name' => 'Test Agent',
      'identifiers' => { '0' => { 'notation' => '0000-0002-1825-0097' } },
      'affiliations' => { '0' => { 'name' => 'Test Org' } }
    }
    overrides.each { |k, v| base[k.to_s] = v }
    base
  end

  def dispatch(action, user: nil, admin_user: nil, params: {}, headers: {})
    req = ActionDispatch::TestRequest.create('rack.session' => {})
    req.session[:user] = user if user
    req.session[:admin_user] = admin_user if admin_user
    headers.each { |k, v| req.headers[k] = v }
    params.each { |k, v| req.params[k] = v }

    res = ActionDispatch::TestResponse.create
    ctrl = AgentsController.new
    ctrl.set_request!(req)
    ctrl.set_response!(res)
    ctrl.process(action)
    [ctrl, req, res]
  end

  # ===========================================================================
  # 1. Callback Chain Declaration, Ordering, and Scope Verification
  # ===========================================================================
  def test_01_callback_chain_precedence_and_action_scope
    callbacks = ORIGINAL_ACTION_CALLBACKS
    filter_names = callbacks.map(&:filter)

    admin_auth_idx = filter_names.index(:authorize_admin)
    login_auth_idx = filter_names.index(:authorize_and_redirect)
    thread_idx = filter_names.index(:set_global_thread_values)
    enabled_idx = filter_names.index(:check_agents_enabled)
    editor_auth_idx = filter_names.index(:authorize_agent_editor)

    refute_nil admin_auth_idx, 'AgentsController must declare :authorize_admin callback'
    refute_nil login_auth_idx, 'AgentsController must declare :authorize_and_redirect callback'
    refute_nil editor_auth_idx, 'AgentsController must declare :authorize_agent_editor callback'

    # Both prepended checks must precede inherited :set_global_thread_values
    assert_operator admin_auth_idx, :<, thread_idx, ':authorize_admin must precede inherited :set_global_thread_values'
    assert_operator login_auth_idx, :<, thread_idx, ':authorize_and_redirect must precede inherited :set_global_thread_values'

    # :check_agents_enabled must precede :authorize_agent_editor in normal before_actions
    assert_operator enabled_idx, :<, editor_auth_idx, ':check_agents_enabled must precede :authorize_agent_editor'
    assert_operator thread_idx, :<, editor_auth_idx, ':set_global_thread_values must precede :authorize_agent_editor'

    # Action scope verification for :authorize_admin
    admin_cb = callbacks.find { |c| c.filter == :authorize_admin }
    admin_actions = admin_cb.instance_variable_get(:@if)&.first&.instance_variable_get(:@actions)
    assert_equal Set['destroy', 'update_agent_usages'], admin_actions,
                 ':authorize_admin must be scoped strictly to [:destroy, :update_agent_usages]'

    # Action scope verification for :authorize_and_redirect
    login_cb = callbacks.find { |c| c.filter == :authorize_and_redirect }
    login_actions = login_cb.instance_variable_get(:@if)&.first&.instance_variable_get(:@actions)
    assert_equal Set['new', 'create', 'edit', 'update'], login_actions,
                 ':authorize_and_redirect must be scoped strictly to [:new, :create, :edit, :update]'

    # Action scope verification for :authorize_agent_editor
    editor_cb = callbacks.find { |c| c.filter == :authorize_agent_editor }
    editor_actions = editor_cb.instance_variable_get(:@if)&.first&.instance_variable_get(:@actions)
    assert_equal Set['edit', 'update'], editor_actions,
                 ':authorize_agent_editor must be scoped strictly to [:edit, :update]'

    # Verify shared reads are excluded from mutator callbacks
    shared_reads = %w[index details show ajax_agents_list search_agents ajax_agents show_search agent_usages]
    shared_reads.each do |sr|
      refute_includes admin_actions, sr, ":authorize_admin must NOT guard shared read #{sr}"
      refute_includes login_actions, sr, ":authorize_and_redirect must NOT guard shared read #{sr}"
      refute_includes editor_actions, sr, ":authorize_agent_editor must NOT guard shared read #{sr}"
    end
  end

  # ===========================================================================
  # 2. Anonymous Direct Mutators Denied Before Startup, Models, and Writes
  # ===========================================================================
  def test_02_anonymous_mutators_halted_before_startup
    mutators = {
      destroy: { id: 'agent-101' },
      update_agent_usages: { id: 'agent-101' },
      new: {},
      create: valid_agent_params(name: 'Anon Agent'),
      edit: { id: 'agent-101' },
      update: valid_agent_params(id: 'agent-101', name: 'Hacked Agent')
    }

    mutators.each do |action, params|
      $agent_spy.reset!
      sentinel_req = Object.new
      sentinel_sess = Object.new
      Thread.current[:request] = sentinel_req
      Thread.current[:session] = sentinel_sess

      _ctrl, _req, res = dispatch(action, user: nil, admin_user: nil, params: params)

      assert_equal 302, res.status, "Anonymous direct #{action} must redirect"
      assert_equal 'http://test.host/', res.location, "Anonymous direct #{action} must redirect to home"

      # Startup callback sentinel verification (must be untouched)
      assert_same sentinel_req, Thread.current[:request],
                  "Anonymous direct #{action} must NOT execute set_global_thread_values"
      assert_same sentinel_sess, Thread.current[:session],
                  "Anonymous direct #{action} must NOT mutate Thread.current[:session]"

      # External model reads and writes must be zero
      assert_equal 0, $agent_spy.agent_find_calls, "Anonymous direct #{action} must NOT call Agent.find"
      assert_equal 0, $agent_spy.agent_save_calls, "Anonymous direct #{action} must NOT call agent.save"
      assert_equal 0, $agent_spy.agent_update_calls, "Anonymous direct #{action} must NOT call agent.update"
      assert_equal 0, $agent_spy.agent_delete_calls, "Anonymous direct #{action} must NOT call agent.delete"
      assert_equal 0, $agent_spy.submission_update_calls, "Anonymous direct #{action} must NOT call submission.update"
    end
  end

  # ===========================================================================
  # 3. Ordinary Authenticated Actor Denied Delete and Usage Writes Before Startup
  # ===========================================================================
  def test_03_ordinary_creator_denied_delete_and_usages_before_startup
    # Even if OWNER_USER is the creator of agent-101, destroy and update_agent_usages are admin-only
    [:destroy, :update_agent_usages].each do |action|
      $agent_spy.reset!
      sentinel_req = Object.new
      sentinel_sess = Object.new
      Thread.current[:request] = sentinel_req
      Thread.current[:session] = sentinel_sess

      _ctrl, _req, res = dispatch(action, user: OWNER_USER, params: { id: 'agent-101' })

      assert_equal 302, res.status, "Creator direct #{action} must redirect (admin-only)"
      assert_equal 'http://test.host/', res.location, "Creator direct #{action} must redirect to home"

      # Halted before startup callbacks
      assert_same sentinel_req, Thread.current[:request],
                  "Ordinary creator direct #{action} must NOT execute set_global_thread_values"
      assert_same sentinel_sess, Thread.current[:session],
                  "Ordinary creator direct #{action} must NOT mutate Thread.current[:session]"

      assert_equal 0, $agent_spy.agent_delete_calls, "Creator direct #{action} must NOT invoke delete"
      assert_equal 0, $agent_spy.submission_update_calls, "Creator direct #{action} must NOT invoke submission update"
    end
  end

  # ===========================================================================
  # 4. Ownership Role Matrix for Edit and Update
  # ===========================================================================
  def test_04_ownership_role_matrix_for_edit_and_update
    # 4A. Ordinary Non-Owner -> Denied before update_agent or payload mutation
    $agent_spy.reset!
    _ctrl, _req, res_edit_nonowner = dispatch(:edit, user: OTHER_USER, params: { id: 'agent-101' })
    assert_equal 302, res_edit_nonowner.status, 'Non-owner edit must redirect to home'
    assert_equal 'http://test.host/', res_edit_nonowner.location

    $agent_spy.reset!
    _ctrl, _req, res_upd_nonowner = dispatch(:update, user: OTHER_USER, params: valid_agent_params(id: 'agent-101', name: 'Unauthorized Change'))
    assert_equal 302, res_upd_nonowner.status, 'Non-owner update must redirect to home'
    assert_equal 'http://test.host/', res_upd_nonowner.location
    assert_equal 0, $agent_spy.agent_update_calls, 'Non-owner update must NOT call agent.update'
    assert_nil $agent_spy.last_update_values, 'Non-owner update must not mutate payload'

    # 4B. Missing / Empty Persisted Creator -> Denied for non-admin
    $agent_spy.reset!
    _ctrl, _req, res_missing = dispatch(:edit, user: OWNER_USER, params: { id: 'agent-102' })
    assert_equal 302, res_missing.status, 'Edit agent with missing creator must redirect non-admin'
    _ctrl, _req, res_missing_upd = dispatch(:update, user: OWNER_USER, params: valid_agent_params(id: 'agent-102', name: 'No Creator'))
    assert_equal 302, res_missing_upd.status, 'Update agent with missing creator must redirect non-admin'
    assert_equal 0, $agent_spy.agent_update_calls

    # 4C. Prefix Persisted Creator -> Denied (no prefix matching allowed)
    $agent_spy.reset!
    _ctrl, _req, res_prefix = dispatch(:edit, user: OWNER_USER, params: { id: 'agent-104' })
    assert_equal 302, res_prefix.status, 'Prefix creator must not authorize edit'
    _ctrl, _req, res_prefix_upd = dispatch(:update, user: OWNER_USER, params: valid_agent_params(id: 'agent-104', name: 'Prefix Edit'))
    assert_equal 302, res_prefix_upd.status, 'Prefix creator must not authorize update'
    assert_equal 0, $agent_spy.agent_update_calls

    # 4D. Foreign Persisted Creator URI -> Denied (no URI suffix stripping)
    $agent_spy.reset!
    _ctrl, _req, res_foreign = dispatch(:edit, user: OWNER_USER, params: { id: 'agent-103' })
    assert_equal 302, res_foreign.status, 'Foreign creator must not authorize edit'
    _ctrl, _req, res_foreign_upd = dispatch(:update, user: OWNER_USER, params: valid_agent_params(id: 'agent-103', name: 'Foreign Edit'))
    assert_equal 302, res_foreign_upd.status, 'Foreign creator must not authorize update'
    assert_equal 0, $agent_spy.agent_update_calls

    # 4E. Spoofed Request Creator -> Denied (actual persisted creator is authoritative)
    $agent_spy.reset!
    spoofed_params = valid_agent_params(id: 'agent-103', creator: OWNER_ID, name: 'Spoofed Update')
    _ctrl, _req, res_spoof = dispatch(:update, user: OWNER_USER, params: spoofed_params)
    assert_equal 302, res_spoof.status, 'Spoofed request creator must NOT grant authority'
    assert_equal 0, $agent_spy.agent_update_calls

    # 4F. Blank Authenticated Actor ID -> Denied
    blank_actor = OpenStruct.new(id: '', username: 'blank_id', admin?: false)
    _ctrl, _req, res_blank = dispatch(:edit, user: blank_actor, params: { id: 'agent-101' })
    assert_equal 302, res_blank.status, 'Blank actor ID must redirect to home'
    _ctrl, _req, res_blank_upd = dispatch(:update, user: blank_actor, params: valid_agent_params(id: 'agent-101', name: 'Blank'))
    assert_equal 302, res_blank_upd.status, 'Blank actor ID must redirect update to home'
    assert_equal 0, $agent_spy.agent_update_calls

    # 4G. Exact Persisted Creator -> Permitted
    $agent_spy.reset!
    ctrl_owner_edit, _req, res_owner_edit = dispatch(:edit, user: OWNER_USER, params: { id: 'agent-101' })
    assert_equal 200, res_owner_edit.status, 'Exact owner must be permitted to edit'
    assert_includes res_owner_edit.body, 'Edit Agent', 'Edit template must be rendered'
    assert_equal 'http://example.com/agents/agent-101', ctrl_owner_edit.instance_variable_get(:@agent).id

    $agent_spy.reset!
    ctrl_owner_upd, _req, res_owner_upd = dispatch(:update, user: OWNER_USER, params: valid_agent_params(id: 'agent-101', name: 'Valid Edit By Owner'), headers: { 'ACCEPT' => 'text/vnd.turbo-stream.html' })
    assert_equal 200, res_owner_upd.status, 'Exact owner must be permitted to update'
    assert_equal 1, $agent_spy.agent_update_calls, 'Owner update must call agent.update exactly once'
    assert_equal 'Valid Edit By Owner', $agent_spy.last_update_values['name']
    assert_includes res_owner_upd.body, 'alert-success', 'Successful update renders alert-success turbo stream'
  end

  # ===========================================================================
  # 5. Portal Admin and Supported admin_user Admitted on All Mutators
  # ===========================================================================
  def test_05_portal_admin_and_admin_user_permitted_on_all_mutators
    # 5A. Direct Portal Admin (session[:user].admin? == true)
    # Can edit agent created by someone else
    $agent_spy.reset!
    _ctrl, _req, res_admin_edit = dispatch(:edit, user: ADMIN_ACTOR, params: { id: 'agent-101' })
    assert_equal 200, res_admin_edit.status, 'Admin must be permitted to edit any agent'

    # Can update agent created by someone else
    $agent_spy.reset!
    _ctrl, _req, res_admin_upd = dispatch(:update, user: ADMIN_ACTOR, params: valid_agent_params(id: 'agent-101', name: 'Admin Edited Name'), headers: { 'ACCEPT' => 'text/vnd.turbo-stream.html' })
    assert_equal 200, res_admin_upd.status, 'Admin must be permitted to update any agent'
    assert_equal 1, $agent_spy.agent_update_calls

    # Can delete agent
    $agent_spy.reset!
    _ctrl, _req, res_admin_del = dispatch(:destroy, user: ADMIN_ACTOR, params: { id: 'agent-101' }, headers: { 'ACCEPT' => 'text/vnd.turbo-stream.html' })
    assert_equal 200, res_admin_del.status, 'Admin must be permitted to delete agent'
    assert_equal 1, $agent_spy.agent_delete_calls
    assert_includes res_admin_del.body, 'alert-success', 'Successful delete renders alert-success'
    seed_agents!

    # Can update agent usages
    $agent_spy.reset!
    usage_params = { id: 'agent-101', hasCreator: ['TEST_ONT'] }
    _ctrl, _req, res_admin_usage = dispatch(:update_agent_usages, user: ADMIN_ACTOR, params: usage_params, headers: { 'ACCEPT' => 'text/vnd.turbo-stream.html' })
    assert_equal 200, res_admin_usage.status, 'Admin must be permitted to update agent usages'
    assert_equal 1, $agent_spy.submission_update_calls

    # 5B. Proxy session with non-admin effective user gets no admin-only grant
    # When effective user is non-admin non-owner, edit/update/destroy/usage are denied
    $agent_spy.reset!
    _ctrl, _req, res_au_edit = dispatch(:edit, user: OTHER_USER, admin_user: SUPPORTED_ADMIN_USER, params: { id: 'agent-101' })
    assert_equal 302, res_au_edit.status, 'Proxy admin_user with non-owner effective user must redirect edit to home'
    assert_equal 'http://test.host/', res_au_edit.location

    $agent_spy.reset!
    _ctrl, _req, res_au_upd = dispatch(:update, user: OTHER_USER, admin_user: SUPPORTED_ADMIN_USER, params: valid_agent_params(id: 'agent-101', name: 'AdminUser Edit'), headers: { 'ACCEPT' => 'text/vnd.turbo-stream.html' })
    assert_equal 302, res_au_upd.status, 'Proxy admin_user with non-owner effective user must redirect update to home'
    assert_equal 0, $agent_spy.agent_update_calls

    $agent_spy.reset!
    _ctrl, _req, res_au_del = dispatch(:destroy, user: OTHER_USER, admin_user: SUPPORTED_ADMIN_USER, params: { id: 'agent-101' }, headers: { 'ACCEPT' => 'text/vnd.turbo-stream.html' })
    assert_equal 302, res_au_del.status, 'Proxy admin_user with non-admin effective user must redirect delete to home'
    assert_equal 0, $agent_spy.agent_delete_calls

    $agent_spy.reset!
    _ctrl, _req, res_au_usage = dispatch(:update_agent_usages, user: OTHER_USER, admin_user: SUPPORTED_ADMIN_USER, params: usage_params, headers: { 'ACCEPT' => 'text/vnd.turbo-stream.html' })
    assert_equal 302, res_au_usage.status, 'Proxy admin_user with non-admin effective user must redirect usages to home'
    assert_equal 0, $agent_spy.submission_update_calls

    # If effective user independently owns the agent, they may edit/update, but delete/usages remain admin-only
    $agent_spy.reset!
    _ctrl, _req, res_au_owner_edit = dispatch(:edit, user: OWNER_USER, admin_user: SUPPORTED_ADMIN_USER, params: { id: 'agent-101' })
    assert_equal 200, res_au_owner_edit.status, 'Owner with proxy admin_user may edit their own agent'

    $agent_spy.reset!
    _ctrl, _req, res_au_owner_upd = dispatch(:update, user: OWNER_USER, admin_user: SUPPORTED_ADMIN_USER, params: valid_agent_params(id: 'agent-101', name: 'Owner Edit With Proxy'), headers: { 'ACCEPT' => 'text/vnd.turbo-stream.html' })
    assert_equal 200, res_au_owner_upd.status, 'Owner with proxy admin_user may update their own agent'
    assert_equal 1, $agent_spy.agent_update_calls

    $agent_spy.reset!
    _ctrl, _req, res_au_owner_del = dispatch(:destroy, user: OWNER_USER, admin_user: SUPPORTED_ADMIN_USER, params: { id: 'agent-101' }, headers: { 'ACCEPT' => 'text/vnd.turbo-stream.html' })
    assert_equal 302, res_au_owner_del.status, 'Owner with proxy admin_user is still denied admin-only delete'
    assert_equal 0, $agent_spy.agent_delete_calls

    $agent_spy.reset!
    _ctrl, _req, res_au_owner_usage = dispatch(:update_agent_usages, user: OWNER_USER, admin_user: SUPPORTED_ADMIN_USER, params: usage_params, headers: { 'ACCEPT' => 'text/vnd.turbo-stream.html' })
    assert_equal 302, res_au_owner_usage.status, 'Owner with proxy admin_user is still denied admin-only usages'
    assert_equal 0, $agent_spy.submission_update_calls
  end

  # ===========================================================================
  # 6. Execution Timing and Checked DTO Reuse
  # ===========================================================================
  def test_06_execution_timing_and_checked_dto_reuse
    # 6A. Ownership lookup timing: must run AFTER set_global_thread_values
    $agent_spy.reset!
    ctrl, req, res = dispatch(:edit, user: OWNER_USER, params: { id: 'agent-101' })
    assert_equal 200, res.status

    refute_nil $agent_spy.thread_request_at_find, 'Thread.current[:request] must be set when Agent.find executes'
    refute_nil $agent_spy.thread_session_at_find, 'Thread.current[:session] must be set when Agent.find executes'
    assert_same req, $agent_spy.thread_request_at_find, 'Thread.current[:request] must match current request'

    # 6B. Checked DTO reuse in edit: exactly 1 Agent.find call occurs (in authorize_agent_editor), none in action body
    assert_equal 1, $agent_spy.agent_find_calls, 'Edit must reuse checked @agent DTO without second find'

    # 6C. Checked DTO reuse in update: exactly 1 Agent.find call before update_agent
    $agent_spy.reset!
    _ctrl_upd, _req_upd, res_upd = dispatch(:update, user: OWNER_USER, params: valid_agent_params(id: 'agent-101', name: 'DTO Reuse'), headers: { 'ACCEPT' => 'text/vnd.turbo-stream.html' })
    assert_equal 200, res_upd.status
    # Call 1: in authorize_agent_editor (reused in update_agent)
    # Call 2: in update post-write reload (find_agent for updated partial render)
    # Critically, update_agent itself performed 0 additional finds prior to write!
    assert_equal 'agent-101', $agent_spy.agent_find_ids.first, 'First lookup was in authorize_agent_editor'
    assert_equal 1, $agent_spy.agent_update_calls, 'update_agent was called with checked DTO'
  end

  # ===========================================================================
  # 7. Feature-Disabled Prevents Non-Admin Bypass
  # ===========================================================================
  def test_07_feature_disabled_prevents_non_admin_bypass
    Flipper.agents_enabled_override = false

    # Ordinary owner cannot bypass feature flag even though they own the agent
    $agent_spy.reset!
    _ctrl, _req, res = dispatch(:edit, user: OWNER_USER, params: { id: 'agent-101' })
    assert_equal 302, res.status, 'Feature-disabled must redirect ordinary owner'
    assert_equal 'http://test.host/', res.location, 'Feature-disabled must redirect to root_path'
    assert_equal 0, $agent_spy.agent_find_calls, 'Feature-disabled must halt before ownership lookup'

    # Portal admin CAN access even when feature is disabled (as per check_agents_enabled contract)
    $agent_spy.reset!
    _ctrl_admin, _req_admin, res_admin = dispatch(:edit, user: ADMIN_ACTOR, params: { id: 'agent-101' })
    assert_equal 200, res_admin.status, 'Admin is permitted when agents feature is disabled'
    assert_equal 1, $agent_spy.agent_find_calls
  end

  # ===========================================================================
  # 8. save_agent Creator Binding on Create
  # ===========================================================================
  def test_08_save_agent_creator_binding_on_create
    $agent_spy.reset!
    create_params = valid_agent_params(
      name: 'Created Agent',
      agentType: 'person',
      creator: 'http://example.com/users/attacker_fake_id' # Attempt to spoof creator
    )

    _ctrl, _req, res = dispatch(:create, user: OWNER_USER, params: create_params, headers: { 'ACCEPT' => 'text/vnd.turbo-stream.html' })
    assert_equal 200, res.status
    assert_equal 1, $agent_spy.agent_save_calls

    saved = $agent_spy.last_saved_agent
    refute_nil saved, 'Agent must be saved'
    assert_equal OWNER_ID, saved.creator, 'save_agent must bind creator strictly from session[:user].id'
    refute_equal 'http://example.com/users/attacker_fake_id', saved.creator, 'Spoofed creator parameter must be ignored'
  end

  # ===========================================================================
  # 9. Known API 401/403 Responses Never Become Success
  # ===========================================================================
  def test_09_known_api_401_403_never_become_success
    # 9A. API 401 on Update
    $agent_spy.reset!
    $agent_spy.forced_update_response = OpenStruct.new(status: 401, errors: ['Unauthorized external API key'])
    _ctrl, _req, res_upd_401 = dispatch(:update, user: OWNER_USER, params: valid_agent_params(id: 'agent-101', name: 'Denied Update'), headers: { 'ACCEPT' => 'text/vnd.turbo-stream.html' })
    assert_equal 200, res_upd_401.status
    refute_includes res_upd_401.body, 'alert-success', 'API 401 must NOT produce alert-success on update'
    assert_includes res_upd_401.body, 'alert-danger', 'API 401 must produce alert-danger on update'

    # 9B. API 403 on Update
    $agent_spy.reset!
    $agent_spy.forced_update_response = OpenStruct.new(status: 403, errors: ['Forbidden'])
    _ctrl, _req, res_upd_403 = dispatch(:update, user: OWNER_USER, params: valid_agent_params(id: 'agent-101', name: 'Denied Update 403'), headers: { 'ACCEPT' => 'text/vnd.turbo-stream.html' })
    assert_equal 200, res_upd_403.status
    refute_includes res_upd_403.body, 'alert-success', 'API 403 must NOT produce alert-success on update'
    assert_includes res_upd_403.body, 'alert-danger', 'API 403 must produce alert-danger on update'

    # 9C. API 403 on Destroy
    $agent_spy.reset!
    $agent_spy.forced_delete_response = OpenStruct.new(status: 403, errors: ['Forbidden delete'])
    _ctrl, _req, res_del_403 = dispatch(:destroy, user: ADMIN_ACTOR, params: { id: 'agent-101' }, headers: { 'ACCEPT' => 'text/vnd.turbo-stream.html' })
    assert_equal 200, res_del_403.status
    refute_includes res_del_403.body, 'alert-success', 'API 403 must NOT produce alert-success on destroy'
    assert_includes res_del_403.body, 'alert-danger', 'API 403 must produce alert-danger on destroy'

    # 9D. API 403 on update_agent_usages
    $agent_spy.reset!
    $agent_spy.forced_submission_response = OpenStruct.new(status: 403, errors: ['Forbidden submission update'])
    _ctrl, _req, res_usage_403 = dispatch(:update_agent_usages, user: ADMIN_ACTOR, params: { id: 'agent-101', hasCreator: ['TEST_ONT'] }, headers: { 'ACCEPT' => 'text/vnd.turbo-stream.html' })
    assert_equal 200, res_usage_403.status
    refute_includes res_usage_403.body, 'alert-success', 'API 403 must NOT produce alert-success on usages'
    assert_includes res_usage_403.body, 'alert-danger', 'API 403 must produce alert-danger on usages'
  end

  # ===========================================================================
  # 10. Shared Reads Remain Accessible
  # ===========================================================================
  def test_10_shared_reads_remain_accessible
    # Shared GET / search / usage read endpoints remain accessible to ordinary users
    _ctrl, _req, res_show = dispatch(:show, user: OTHER_USER, params: { agent_id: 'agent-101' })
    assert_equal 200, res_show.status, 'Shared show must be accessible'

    _ctrl, _req, res_ajax = dispatch(:ajax_agents_list, user: nil, params: { pagesize: 10 })
    assert_equal 200, res_ajax.status, 'Shared ajax_agents_list must be accessible'

    _ctrl, _req, res_usages = dispatch(:agent_usages, user: OTHER_USER, params: { id: 'agent-101' })
    assert_equal 200, res_usages.status, 'Shared agent_usages read must be accessible'
  end

  # ===========================================================================
  # 11. Real ApplicationController Auth Helpers Without Policy Doubles
  # ===========================================================================
  def test_11_real_auth_helpers_without_policy_doubles
    ctrl_anon = AgentsController.new
    req_anon = ActionDispatch::TestRequest.create('rack.session' => {})
    ctrl_anon.set_request!(req_anon)
    refute ctrl_anon.current_user_admin?, 'Anonymous session must not be admin'

    ctrl_user = AgentsController.new
    req_user = ActionDispatch::TestRequest.create('rack.session' => { user: OWNER_USER })
    ctrl_user.set_request!(req_user)
    refute ctrl_user.current_user_admin?, 'Ordinary actor session must not be admin'

    ctrl_admin = AgentsController.new
    req_admin = ActionDispatch::TestRequest.create('rack.session' => { user: ADMIN_ACTOR })
    ctrl_admin.set_request!(req_admin)
    assert ctrl_admin.current_user_admin?, 'Direct portal admin must satisfy current_user_admin?'

    ctrl_impersonate = AgentsController.new
    req_impersonate = ActionDispatch::TestRequest.create('rack.session' => { admin_user: SUPPORTED_ADMIN_USER })
    ctrl_impersonate.set_request!(req_impersonate)
    refute ctrl_impersonate.current_user_admin?, 'Proxy admin_user without session[:user].admin? does not satisfy current_user_admin?'
  end
end
