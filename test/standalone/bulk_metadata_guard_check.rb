# frozen_string_literal: true

require 'minitest/autorun'
require 'logger'
require 'ostruct'
require 'cgi'

# =============================================================================
# Standalone Offline Bulk Metadata Admin-UI Guard Check (ONTO-T-B04)
#
# Validates the B04 admin-UI authorization boundary for bulk metadata curation:
# 1. OntologiesMetadataCuratorController prepends :authorize_admin before inherited
#    startup callbacks (:set_global_thread_values, :init_trial_license) and local
#    :submission_metadata callback, scoped strictly to [:result, :edit, :update].
# 2. Native Rails role boundary proof for all 3 bulk actions:
#    - Anonymous actor: direct access denied via redirect_to_home (HTTP 302 to '/').
#    - Ordinary authenticated actor: direct access denied via redirect_to_home.
#    - Non-admin ontology owner: direct access denied; no invented ontology-owner
#      bulk privileges.
# 3. For all denied requests:
#    - Halted BEFORE startup callbacks execute: Thread.current sentinels untouched.
#    - Halted BEFORE ApplicationController#submission_metadata or helpers.
#    - Halted BEFORE external API/model lookups or writes.
# 4. Portal administrator (session[:user].admin? == true) and supported
#    session[:admin_user] impersonation context are admitted.
# 5. Admitted administrator requests reach startup callbacks (sentinels updated)
#    and execute :submission_metadata which forwards to helpers.submission_metadata.
# 6. Positive bulk action control:
#    - :result processes ontology/submission selection and responds.
#    - :edit renders the bulk edit form partial.
#    - :update invokes update_submission and renders alert_success on 204.
# 7. Known API 401/403 responses are NOT treated as success; error alert rendered.
# 8. Shared GET routes (:show_metadata_by_ontology, :show_metadata_value) remain
#    accessible without admin authorization.
# 9. Real ApplicationController#authorize_admin and #current_user_admin? used
#    directly with zero policy doubles.
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
require 'submissions_helper'
require 'metadata_helper'
require 'turbo_helper'
require 'submission_updater'
require 'application_controller'
require 'ontologies_metadata_curator_controller'

ActionController::Base.helper MetadataHelper
ActionController::Base.helper UrlsHelper

# Finite Route Helper Stubs
module CuratorRouteHelperStubs
  def admin_index_path(*args, **kwargs)
    '/admin'
  end

  def root_path(*args, **kwargs)
    '/'
  end
end
ActionController::Base.include CuratorRouteHelperStubs

# =============================================================================
# Callback Precedence Capture BEFORE Finite Offline Skips
# =============================================================================
ORIGINAL_ACTION_CALLBACKS = OntologiesMetadataCuratorController._process_action_callbacks.dup.freeze

# Finite Presentation Boundary: Fixture Resolver for offline partial rendering
CURATOR_FIXTURE_RESOLVER = ActionView::FixtureResolver.new(
  'ontologies_metadata_curator/_form_edit.html.erb' => '<form id="bulk_edit"><%= @selected_metadata.inspect %></form>',
  'ontologies_metadata_curator/_metadata_table.html.erb' => '<table id="metadata_table"></table>',
  'ontologies_metadata_curator/_submission.html.erb' => '<tr id="submission_row">Submission</tr>',
  'submissions/_form_content.html.erb' => '<div id="form_content">Form <%= acronym %> <%= submissionId %></div>',
  'ontologies_metadata_curator/_attribute.html.erb' => '<div id="<%= id %>">Attribute <%= attribute %></div>'
)

OntologiesMetadataCuratorController.view_paths = [CURATOR_FIXTURE_RESOLVER]
OntologiesMetadataCuratorController.layout false

# Finite unrelated startup boundaries skipped honestly for offline standalone test environment
OntologiesMetadataCuratorController.skip_before_action :set_locale, :domain_ontology_set, :init_trial_license, raise: false

# =============================================================================
# Spies, Finite Metadata Upstream, and Finite External Write Boundaries
# =============================================================================

SAMPLE_METADATA_DEFINITIONS = [
  { 'attribute' => 'description', 'enforce' => ['textarea'] },
  { 'attribute' => 'version', 'enforce' => ['string'] }
].freeze

class CuratorBoundarySpy
  attr_accessor :helper_metadata_calls, :controller_metadata_calls
  attr_accessor :ontology_find_by_acronym_calls, :ontology_all_calls
  attr_accessor :submission_all_calls, :update_submission_calls
  attr_accessor :last_update_submission_data, :last_update_submission_id
  attr_accessor :update_submission_stub_response
  attr_accessor :received_submission_data, :responses_by_ontology

  def initialize
    reset!
  end

  def reset!
    @helper_metadata_calls = 0
    @controller_metadata_calls = 0
    @ontology_find_by_acronym_calls = 0
    @ontology_all_calls = 0
    @submission_all_calls = 0
    @update_submission_calls = 0
    @last_update_submission_data = nil
    @last_update_submission_id = nil
    @update_submission_stub_response = nil
    @received_submission_data = []
    @responses_by_ontology = {}
  end

  def total_api_read_calls
    @ontology_find_by_acronym_calls + @ontology_all_calls + @submission_all_calls
  end

  def total_external_write_calls
    @update_submission_calls
  end
end

$curator_spy = CuratorBoundarySpy.new

# Instrument ApplicationController#submission_metadata to count forwarding
class ApplicationController
  alias_method :orig_submission_metadata, :submission_metadata

  def submission_metadata
    $curator_spy.controller_metadata_calls += 1
    orig_submission_metadata
  end
end

# Finite Metadata Upstream Boundary: helpers.submission_metadata
module MetadataHelper
  alias_method :orig_helper_submission_metadata, :submission_metadata rescue nil

  def submission_metadata
    $curator_spy.helper_metadata_calls += 1
    SAMPLE_METADATA_DEFINITIONS
  end
end

# Finite SDK Model Stubs
class ExploreMock
  def submissions(*args)
    OpenStruct.new(submissionId: args.last || 1, description: 'Existing Description')
  end
end

class LinkedData::Client::Models::Ontology
  class << self
    def find_by_acronym(acronym, options = {})
      $curator_spy.ontology_find_by_acronym_calls += 1
      ont = OpenStruct.new(
        acronym: acronym,
        name: "#{acronym} Name",
        ontologyId: "http://example.com/ontologies/#{acronym}",
        administeredBy: ['http://example.com/users/owner_actor'],
        explore: ExploreMock.new
      )
      def ont.admin?(user)
        user && user.id == 'http://example.com/users/owner_actor'
      end
      [ont]
    end

    def all(options = {})
      $curator_spy.ontology_all_calls += 1
      [OpenStruct.new(acronym: 'TEST', name: 'TEST Ontology')]
    end
  end
end

class LinkedData::Client::Models::OntologySubmission
  class << self
    def all(options = {})
      $curator_spy.submission_all_calls += 1
      [OpenStruct.new(id: 'http://example.com/ontologies/TEST/submissions/1', submissionId: 1, acronym: 'TEST')]
    end
  end
end

# Finite External Write Boundary: SubmissionUpdater#update_submission
module SubmissionUpdater
  def update_submission(new_submission_hash, submission_id, ontology = nil)
    $curator_spy.update_submission_calls += 1
    $curator_spy.last_update_submission_id = submission_id
    $curator_spy.received_submission_data << new_submission_hash.to_unsafe_h.deep_dup
    $curator_spy.last_update_submission_data = $curator_spy.received_submission_data.last

    submission = OpenStruct.new(submissionId: submission_id, ontology: new_submission_hash[:ontology] || 'TEST')
    @submission = submission

    # Mutate in place like the real update_submission (convert_values_to_types, delete :ontology).
    onto = new_submission_hash.delete(:ontology)
    new_submission_hash[:flag] = true if new_submission_hash[:flag] == 'true'

    response = $curator_spy.responses_by_ontology[onto] || $curator_spy.update_submission_stub_response || OpenStruct.new(status: 204)
    [submission, response]
  end
end

# =============================================================================
# Test Suite
# =============================================================================

class BulkMetadataGuardCheck < Minitest::Test
  ADMIN_ACTOR = OpenStruct.new(id: 'http://example.com/users/portal_admin', username: 'portal_admin', admin?: true).freeze
  ORDINARY_ACTOR = OpenStruct.new(id: 'http://example.com/users/regular_actor', username: 'regular_actor', admin?: false).freeze
  OWNER_ACTOR = OpenStruct.new(id: 'http://example.com/users/owner_actor', username: 'owner_actor', admin?: false, customOntology: ['TEST']).freeze
  SUPPORTED_ADMIN_USER = OpenStruct.new(id: 'http://example.com/users/real_admin', username: 'real_admin', admin?: true).freeze

  BULK_ACTIONS = [:result, :edit, :update].freeze

  def setup
    $curator_spy.reset!
  end

  def teardown
    Thread.current[:request] = nil
    Thread.current[:session] = nil
  end

  def dispatch(action, user: nil, admin_user: nil, params: {}, headers: {})
    req = ActionDispatch::TestRequest.create('rack.session' => {})
    req.session[:user] = user if user
    req.session[:admin_user] = admin_user if admin_user
    headers.each { |k, v| req.headers[k] = v }
    params.each { |k, v| req.params[k] = v }

    res = ActionDispatch::TestResponse.create
    ctrl = OntologiesMetadataCuratorController.new
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

    auth_idx = filter_names.index(:authorize_admin)
    thread_idx = filter_names.index(:set_global_thread_values)
    license_idx = filter_names.index(:init_trial_license)
    metadata_idx = filter_names.index(:submission_metadata)

    refute_nil auth_idx, 'OntologiesMetadataCuratorController must declare :authorize_admin callback'
    assert_equal 0, auth_idx, ':authorize_admin must be prepended to the head of callback chain'
    assert_operator auth_idx, :<, thread_idx, ':authorize_admin must precede inherited :set_global_thread_values'
    assert_operator auth_idx, :<, license_idx, ':authorize_admin must precede inherited :init_trial_license'
    assert_operator auth_idx, :<, metadata_idx, ':authorize_admin must precede :submission_metadata'

    # Action scope verification for :authorize_admin
    auth_cb = callbacks.find { |c| c.filter == :authorize_admin }
    auth_filter_obj = auth_cb.instance_variable_get(:@if)&.first
    auth_actions = auth_filter_obj&.instance_variable_get(:@actions)

    # ONTO-AT-OP02 adds the admin-only bulk preview/confirm actions to the same guard.
    assert_equal Set['result', 'edit', 'update', 'preview', 'confirm'], auth_actions,
                 ':authorize_admin must be scoped strictly to the bulk actions [:result, :edit, :update, :preview, :confirm]'
    refute_includes auth_actions, 'show_metadata_by_ontology',
                    ':authorize_admin must NOT guard shared GET show_metadata_by_ontology'
    refute_includes auth_actions, 'show_metadata_value',
                    ':authorize_admin must NOT guard shared GET show_metadata_value'

    # Verify active unskipped callback ordering
    active_callbacks = OntologiesMetadataCuratorController._process_action_callbacks.map(&:filter)
    active_auth_idx = active_callbacks.index(:authorize_admin)
    active_thread_idx = active_callbacks.index(:set_global_thread_values)
    active_meta_idx = active_callbacks.index(:submission_metadata)

    assert_operator active_auth_idx, :<, active_thread_idx,
                    'Active chain: :authorize_admin must precede :set_global_thread_values'
    assert_operator active_auth_idx, :<, active_meta_idx,
                    'Active chain: :authorize_admin must precede :submission_metadata'
  end

  # ===========================================================================
  # 2. Anonymous Direct Bulk Actions Denied Before Startup, Metadata, and API
  # ===========================================================================
  def test_02_anonymous_direct_bulk_actions_denied_before_startup_metadata_and_api
    BULK_ACTIONS.each do |action|
      $curator_spy.reset!
      sentinel_req = Object.new
      sentinel_sess = Object.new
      Thread.current[:request] = sentinel_req
      Thread.current[:session] = sentinel_sess

      ctrl, req, res = dispatch(action, user: nil, admin_user: nil)

      assert_equal 302, res.status, "Anonymous direct #{action} must be redirected"
      assert_equal 'http://test.host/', res.location, "Anonymous direct #{action} must redirect to home"

      # Startup callback sentinel verification
      assert_same sentinel_req, Thread.current[:request],
                  "Anonymous direct #{action} must NOT execute set_global_thread_values"
      assert_same sentinel_sess, Thread.current[:session],
                  "Anonymous direct #{action} must NOT mutate Thread.current[:session]"

      # Metadata callback forwarding verification
      assert_equal 0, $curator_spy.controller_metadata_calls,
                   "Anonymous direct #{action} must NOT invoke ApplicationController#submission_metadata"
      assert_equal 0, $curator_spy.helper_metadata_calls,
                   "Anonymous direct #{action} must NOT invoke helpers.submission_metadata"

      # External API read and write verification
      assert_equal 0, $curator_spy.total_api_read_calls,
                   "Anonymous direct #{action} must NOT trigger any external API reads"
      assert_equal 0, $curator_spy.total_external_write_calls,
                   "Anonymous direct #{action} must NOT trigger any external API writes"
    end
  end

  # ===========================================================================
  # 3. Ordinary Authenticated Actor Denied Before Startup, Metadata, and API
  # ===========================================================================
  def test_03_ordinary_actor_direct_bulk_actions_denied_before_startup_metadata_and_api
    BULK_ACTIONS.each do |action|
      $curator_spy.reset!
      sentinel_req = Object.new
      sentinel_sess = Object.new
      Thread.current[:request] = sentinel_req
      Thread.current[:session] = sentinel_sess

      ctrl, req, res = dispatch(action, user: ORDINARY_ACTOR, admin_user: nil)

      assert_equal 302, res.status, "Ordinary actor direct #{action} must be redirected"
      assert_equal 'http://test.host/', res.location, "Ordinary actor direct #{action} must redirect to home"

      assert_same sentinel_req, Thread.current[:request],
                  "Ordinary actor direct #{action} must NOT execute set_global_thread_values"
      assert_same sentinel_sess, Thread.current[:session],
                  "Ordinary actor direct #{action} must NOT mutate Thread.current[:session]"

      assert_equal 0, $curator_spy.controller_metadata_calls,
                   "Ordinary actor direct #{action} must NOT invoke ApplicationController#submission_metadata"
      assert_equal 0, $curator_spy.helper_metadata_calls,
                   "Ordinary actor direct #{action} must NOT invoke helpers.submission_metadata"

      assert_equal 0, $curator_spy.total_api_read_calls,
                   "Ordinary actor direct #{action} must NOT trigger external API reads"
      assert_equal 0, $curator_spy.total_external_write_calls,
                   "Ordinary actor direct #{action} must NOT trigger external API writes"
    end
  end

  # ===========================================================================
  # 4. Non-Admin Ontology Owner Denied; No Invented Bulk Privileges
  # ===========================================================================
  def test_04_nonadmin_ontology_owner_direct_bulk_actions_denied_no_invented_privileges
    BULK_ACTIONS.each do |action|
      $curator_spy.reset!
      sentinel_req = Object.new
      sentinel_sess = Object.new
      Thread.current[:request] = sentinel_req
      Thread.current[:session] = sentinel_sess

      ctrl, req, res = dispatch(action, user: OWNER_ACTOR, admin_user: nil)

      assert_equal 302, res.status, "Non-admin ontology owner direct #{action} must be redirected"
      assert_equal 'http://test.host/', res.location, "Non-admin ontology owner direct #{action} must redirect to home"

      assert_same sentinel_req, Thread.current[:request],
                  "Non-admin ontology owner direct #{action} must NOT execute set_global_thread_values"
      assert_same sentinel_sess, Thread.current[:session],
                  "Non-admin ontology owner direct #{action} must NOT mutate Thread.current[:session]"

      assert_equal 0, $curator_spy.controller_metadata_calls,
                   "Non-admin ontology owner direct #{action} must NOT invoke submission_metadata"
      assert_equal 0, $curator_spy.helper_metadata_calls,
                   "Non-admin ontology owner direct #{action} must NOT invoke helpers.submission_metadata"

      assert_equal 0, $curator_spy.total_api_read_calls,
                   "Non-admin ontology owner direct #{action} must NOT trigger external API reads"
      assert_equal 0, $curator_spy.total_external_write_calls,
                   "Non-admin ontology owner direct #{action} must NOT trigger external API writes"
    end
  end

  # ===========================================================================
  # 5. Direct Portal Administrator Admitted to Bulk Actions
  # ===========================================================================
  def test_05_admin_actor_admitted_to_bulk_actions_reaches_startup_and_metadata
    BULK_ACTIONS.each do |action|
      $curator_spy.reset!
      sentinel_req = Object.new
      sentinel_sess = Object.new
      Thread.current[:request] = sentinel_req
      Thread.current[:session] = sentinel_sess

      params = case action
               when :result
                 { ontology: { ontologyId: ['TEST'] }, search: { metadata: ['description'] } }
               when :edit
                 { selected_acronyms: ['TEST#1'], selected_metadata: ['description'], all_metadata: ['description'] }
               when :update
                 { selected_ontologies: ['TEST#1'], active_ontology: 'TEST#1', all_metadata: 'description',
                   submission: { 'TEST_1' => { description: 'Updated Value' } } }
               end

      headers = action == :update ? { 'Accept' => 'text/vnd.turbo-stream.html' } : {}

      ctrl, req, res = dispatch(action, user: ADMIN_ACTOR, admin_user: nil, params: params, headers: headers)

      # Must NOT redirect to home
      refute_equal 'http://test.host/', res.location, "Admin #{action} must NOT redirect to home"

      # Inherited set_global_thread_values was reached and updated
      assert_same req, Thread.current[:request], "Admin #{action} must update Thread.current[:request]"
      assert_equal req.session, Thread.current[:session], "Admin #{action} must update Thread.current[:session]"

      # submission_metadata was invoked and forwarded to helpers.submission_metadata
      assert_operator $curator_spy.controller_metadata_calls, :>=, 1,
                      "Admin #{action} must invoke ApplicationController#submission_metadata"
      assert_operator $curator_spy.helper_metadata_calls, :>=, 1,
                      "Admin #{action} must forward to helpers.submission_metadata"
    end
  end

  # ===========================================================================
  # 6. Supported session[:admin_user] Impersonation Context Admitted
  # ===========================================================================
  def test_06_supported_admin_user_context_admitted
    BULK_ACTIONS.each do |action|
      $curator_spy.reset!
      sentinel_req = Object.new
      sentinel_sess = Object.new
      Thread.current[:request] = sentinel_req
      Thread.current[:session] = sentinel_sess

      params = case action
               when :result
                 { ontology: { ontologyId: ['TEST'] }, search: { metadata: ['description'] } }
               when :edit
                 { selected_acronyms: ['TEST#1'], selected_metadata: ['description'], all_metadata: ['description'] }
               when :update
                 { selected_ontologies: ['TEST#1'], active_ontology: 'TEST#1', all_metadata: 'description',
                   submission: { 'TEST_1' => { description: 'Updated Value' } } }
               end

      headers = action == :update ? { 'Accept' => 'text/vnd.turbo-stream.html' } : {}

      # Ordinary user session with supported admin_user context
      ctrl, req, res = dispatch(action, user: ORDINARY_ACTOR, admin_user: SUPPORTED_ADMIN_USER,
                                       params: params, headers: headers)

      refute_equal 'http://test.host/', res.location, "Supported admin_user #{action} must NOT redirect to home"
      assert_same req, Thread.current[:request], "Supported admin_user #{action} must reach startup callbacks"
      assert_operator $curator_spy.controller_metadata_calls, :>=, 1,
                      "Supported admin_user #{action} must execute submission_metadata"
    end
  end

  # ===========================================================================
  # 7. Positive Actual Bulk Action Control: Result
  # ===========================================================================
  def test_07_positive_bulk_result_action_control
    ctrl, req, res = dispatch(:result, user: ADMIN_ACTOR, params: {
      ontology: { ontologyId: ['TEST'] },
      search: { metadata: ['description'] }
    })

    assert_equal 302, res.status
    assert_equal 'http://test.host/admin', res.location
    assert_operator $curator_spy.ontology_find_by_acronym_calls, :>=, 1,
                    'Admitted result action must query selected ontology acronym'
  end

  # ===========================================================================
  # 8. Positive Actual Bulk Action Control: Edit
  # ===========================================================================
  def test_08_positive_bulk_edit_action_control
    ctrl, req, res = dispatch(:edit, user: ADMIN_ACTOR, params: {
      selected_acronyms: ['TEST#1'],
      selected_metadata: ['description'],
      all_metadata: ['description']
    })

    assert_equal 200, res.status
    assert_includes res.body, 'bulk_edit'
    assert_includes res.body, 'description'
  end

  # ===========================================================================
  # 9. Positive Actual Bulk Action Control: Update Success (204)
  # ===========================================================================
  def test_09_positive_bulk_update_action_control
    $curator_spy.update_submission_stub_response = OpenStruct.new(status: 204)

    ctrl, req, res = dispatch(:update, user: ADMIN_ACTOR, headers: { 'Accept' => 'text/vnd.turbo-stream.html' }, params: {
      selected_ontologies: ['TEST#1'],
      active_ontology: 'TEST#1',
      all_metadata: 'description',
      submission: { 'TEST_1' => { description: 'Batch new description' } }
    })

    assert_equal 200, res.status
    assert_equal 1, $curator_spy.update_submission_calls,
                 'Admitted update must invoke update_submission finite write boundary'
    assert_equal 'TEST', $curator_spy.last_update_submission_data[:ontology]
    assert_equal '1', $curator_spy.last_update_submission_data[:id]

    assert_includes res.body, 'alert-success'
    assert_includes res.body, I18n.t('ontologies_metadata_curator.alert_success_submissions')
    refute_includes res.body, 'alert-danger'
  end

  # ===========================================================================
  # 10. Known API 401 Error is NOT Treated as Success
  # ===========================================================================
  def test_10_bulk_update_api_401_error_not_treated_as_success
    $curator_spy.update_submission_stub_response = OpenStruct.new(
      status: 401,
      errors: ['API Authentication Required: 401']
    )

    ctrl, req, res = dispatch(:update, user: ADMIN_ACTOR, headers: { 'Accept' => 'text/vnd.turbo-stream.html' }, params: {
      selected_ontologies: ['TEST#1'],
      active_ontology: 'TEST#1',
      all_metadata: 'description',
      submission: { 'TEST_1' => { description: 'Unauthorized attempt' } }
    })

    assert_equal 200, res.status
    assert_equal 1, $curator_spy.update_submission_calls

    assert_includes res.body, 'alert-danger', 'API 401 response must render alert-danger stream'
    assert_includes res.body, 'API Authentication Required: 401'
    refute_includes res.body, 'alert-success', 'API 401 response must NEVER render alert-success'
    refute_includes res.body, I18n.t('ontologies_metadata_curator.alert_success_submissions')
  end

  # ===========================================================================
  # 11. Known API 403 Error is NOT Treated as Success
  # ===========================================================================
  def test_11_bulk_update_api_403_error_not_treated_as_success
    $curator_spy.update_submission_stub_response = OpenStruct.new(
      status: 403,
      errors: ['API Permission Denied: 403']
    )

    ctrl, req, res = dispatch(:update, user: ADMIN_ACTOR, headers: { 'Accept' => 'text/vnd.turbo-stream.html' }, params: {
      selected_ontologies: ['TEST#1'],
      active_ontology: 'TEST#1',
      all_metadata: 'description',
      submission: { 'TEST_1' => { description: 'Forbidden update' } }
    })

    assert_equal 200, res.status
    assert_equal 1, $curator_spy.update_submission_calls

    assert_includes res.body, 'alert-danger', 'API 403 response must render alert-danger stream'
    assert_includes res.body, 'API Permission Denied: 403'
    refute_includes res.body, 'alert-success', 'API 403 response must NEVER render alert-success'
    refute_includes res.body, I18n.t('ontologies_metadata_curator.alert_success_submissions')
  end

  # ===========================================================================
  # 12. Shared GET show_metadata_by_ontology Admitted Without Admin
  # ===========================================================================
  def test_12_shared_get_show_metadata_by_ontology_admitted_without_admin
    # Anonymous request
    ctrl, req, res = dispatch(:show_metadata_by_ontology, user: nil, params: {
      ontology: 'TEST',
      submission_id: '1'
    })

    assert_equal 200, res.status
    assert_includes res.body, 'Form TEST 1'
    refute_equal 302, res.status, 'Shared GET show_metadata_by_ontology must not redirect anonymous user'

    # Ordinary user request
    ctrl2, req2, res2 = dispatch(:show_metadata_by_ontology, user: ORDINARY_ACTOR, params: {
      ontology: 'TEST',
      submission_id: '1'
    })

    assert_equal 200, res2.status
    assert_includes res2.body, 'Form TEST 1'
  end

  # ===========================================================================
  # 13. Shared GET show_metadata_value Admitted Without Admin
  # ===========================================================================
  def test_13_shared_get_show_metadata_value_admitted_without_admin
    # Anonymous request
    ctrl, req, res = dispatch(:show_metadata_value, user: nil, headers: { 'Accept' => 'text/vnd.turbo-stream.html' }, params: {
      ontology: 'TEST',
      submission_id: '1',
      attribute: 'description'
    })

    assert_equal 200, res.status
    assert_includes res.body, 'turbo-stream'
    assert_includes res.body, 'submission[TEST_1]Description_from_group_input'
    assert_includes res.body, 'Attribute description'

    # Ordinary user request
    ctrl2, req2, res2 = dispatch(:show_metadata_value, user: ORDINARY_ACTOR, headers: { 'Accept' => 'text/vnd.turbo-stream.html' }, params: {
      ontology: 'TEST',
      submission_id: '1',
      attribute: 'description'
    })

    assert_equal 200, res2.status
    assert_includes res2.body, 'turbo-stream'
  end

  # ===========================================================================
  # 14. Real authorize_admin and current_user_admin? Without Policy Doubles
  # ===========================================================================
  def test_14_real_current_user_admin_and_authorize_admin_without_policy_doubles
    # 1. Anonymous
    ctrl1 = OntologiesMetadataCuratorController.new
    req1 = ActionDispatch::TestRequest.create('rack.session' => {})
    res1 = ActionDispatch::TestResponse.create
    ctrl1.set_request!(req1)
    ctrl1.set_response!(res1)

    refute ctrl1.current_user_admin?, 'Anonymous session must not be admin'
    ctrl1.authorize_admin
    assert_equal 302, res1.status
    assert_equal 'http://test.host/', res1.location

    # 2. Ordinary user
    ctrl2 = OntologiesMetadataCuratorController.new
    req2 = ActionDispatch::TestRequest.create('rack.session' => {})
    req2.session[:user] = ORDINARY_ACTOR
    res2 = ActionDispatch::TestResponse.create
    ctrl2.set_request!(req2)
    ctrl2.set_response!(res2)

    refute ctrl2.current_user_admin?, 'Ordinary actor session must not be admin'
    ctrl2.authorize_admin
    assert_equal 302, res2.status
    assert_equal 'http://test.host/', res2.location

    # 3. Direct admin user
    ctrl3 = OntologiesMetadataCuratorController.new
    req3 = ActionDispatch::TestRequest.create('rack.session' => {})
    req3.session[:user] = ADMIN_ACTOR
    res3 = ActionDispatch::TestResponse.create
    ctrl3.set_request!(req3)
    ctrl3.set_response!(res3)

    assert ctrl3.current_user_admin?, 'Direct admin user must be admin'
    ctrl3.authorize_admin
    assert_nil res3.location, 'Direct admin user must not be redirected'

    # 4. Impersonated supported admin_user context
    ctrl4 = OntologiesMetadataCuratorController.new
    req4 = ActionDispatch::TestRequest.create('rack.session' => {})
    req4.session[:user] = ORDINARY_ACTOR
    req4.session[:admin_user] = SUPPORTED_ADMIN_USER
    res4 = ActionDispatch::TestResponse.create
    ctrl4.set_request!(req4)
    ctrl4.set_response!(res4)

    assert ctrl4.current_login_as_admin?, 'Supported admin_user context must satisfy current_login_as_admin?'
    assert ctrl4.current_user_admin?, 'Supported admin_user context must satisfy current_user_admin?'
    ctrl4.authorize_admin
    assert_nil res4.location, 'Supported admin_user context must not be redirected'
  end

  # ===========================================================================
  # ONTO-T-B05: each bulk target gets an independent copy and per-ontology results
  # ===========================================================================
  def test_b05_each_target_receives_independent_unconverted_values
    dispatch(:update, user: ADMIN_ACTOR, headers: { 'Accept' => 'text/vnd.turbo-stream.html' }, params: {
      selected_ontologies: ['A#1', 'B#2', 'C#3'],
      active_ontology: 'A#1',
      all_metadata: 'description',
      submission: { 'A_1' => { description: 'Shared', flag: 'true' } }
    })

    received = $curator_spy.received_submission_data
    assert_equal 3, received.length
    assert_equal %w[A B C], received.map { |d| d['ontology'] }
    assert_equal %w[1 2 3], received.map { |d| d['id'] }
    assert_equal ['true'] * 3, received.map { |d| d['flag'] }, 'later targets must not see values converted for earlier ones'
    assert_equal ['Shared'] * 3, received.map { |d| d['description'] }
  end

  def test_b05_partial_failure_reports_failed_ontology_and_keeps_successful_rows
    $curator_spy.responses_by_ontology['B'] = OpenStruct.new(status: 403, errors: ['API Permission Denied: 403'])

    _ctrl, _req, res = dispatch(:update, user: ADMIN_ACTOR, headers: { 'Accept' => 'text/vnd.turbo-stream.html' }, params: {
      selected_ontologies: ['A#1', 'B#2'],
      active_ontology: 'A#1',
      all_metadata: 'description',
      submission: { 'A_1' => { description: 'Partial' } }
    })

    assert_equal 2, $curator_spy.update_submission_calls
    assert_includes res.body, 'alert-danger'
    assert_includes res.body, 'B: API Permission Denied: 403', 'failed ontology is named with its error'
    refute_includes res.body, 'A: ', 'successful ontology is not reported as failed'
    refute_includes res.body, 'alert-success'
    assert_includes res.body, 'A#1_row', 'successful target row is still refreshed'
    refute_includes res.body, 'B#2_row', 'failed target row is not replaced'
  end

end
