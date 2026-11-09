# frozen_string_literal: true

require 'minitest/autorun'
require 'logger'
require 'ostruct'
require 'cgi'
require 'securerandom'

# =============================================================================
# Standalone Offline Bulk Metadata Preview Check (ONTO-AT-OP02)
#
# Validates the OP02 bulk metadata preview, verification, and retry flow:
# 1. Feature flag gating: Flipper 'BulkMetadataPreview' disabled by default =>
#    preview/confirm endpoints return 404; existing bulk flow unaffected.
# 2. Authorization boundary: Non-admin actors (anonymous, ordinary, non-admin owner)
#    are denied (redirect_to_home 302) before any external API lookup or write.
# 3. Read-only preview: Generates before/after diffs per target with typed values
#    (booleans, arrays, localized strings), distinguishing unchanged / added /
#    replaced / cleared / omitted. Makes zero update calls.
# 4. Target exclusion: Unchecking a target prevents its mutation on confirmation.
# 5. Tamper and cross-session rejection: Tampered preview token, mismatched user,
#    mismatched session, or tampered values are rejected with zero writes.
# 6. Stale detection (best-effort recheck): Changed current values between preview
#    and confirmation force a fresh preview requirement with zero writes.
# 7. Review receipt & retry: Produces distinct success / rejected / unknown rows.
#    Fresh retry preview contains ONLY chosen known failures; never replays
#    successes and rejects unknown outcomes without prior re-read.
# 8. ViewComponent presentation: Renders diff table, inclusion checkboxes, and
#    receipt retry controls correctly.
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
$LOAD_PATH.unshift(File.join(worktree_root, 'app/services'))
$LOAD_PATH.unshift(File.join(worktree_root, 'app/components'))

require 'rails'
require 'action_controller'
require 'action_view'
require 'action_dispatch'
require 'active_record'
require 'action_view/testing/resolvers'
require 'view_component'
require 'flipper'

class TestApp < Rails::Application
  config.secret_key_base = 'a' * 64
  config.eager_load = false
end
Rails.application ||= TestApp.new

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
require 'bulk_metadata_preview'
require 'bulk_metadata_preview_component'
require 'application_controller'
require 'ontologies_metadata_curator_controller'

ActionController::Base.helper MetadataHelper
ActionController::Base.helper UrlsHelper
ActionController::Base.helper ApplicationHelper

module CuratorRouteHelperStubs
  def admin_index_path(*args, **kwargs)
    '/admin'
  end

  def root_path(*args, **kwargs)
    '/'
  end
end
ActionController::Base.include CuratorRouteHelperStubs

CURATOR_PREVIEW_RESOLVER = ActionView::FixtureResolver.new(
  'ontologies_metadata_curator/_form_edit.html.erb' => '<form id="bulk_edit"><%= @selected_metadata.inspect %></form>',
  'ontologies_metadata_curator/_metadata_table.html.erb' => '<table id="metadata_table"></table>',
  'ontologies_metadata_curator/_submission.html.erb' => '<tr id="submission_row">Submission</tr>',
  'submissions/_form_content.html.erb' => '<div id="form_content">Form <%= acronym %> <%= submissionId %></div>',
  'ontologies_metadata_curator/_attribute.html.erb' => '<div id="<%= id %>">Attribute <%= attribute %></div>',
  'ontologies_metadata_curator/_preview.html.erb' => '<div id="preview_modal"><%= preview[:preview_token] %></div>',
  'ontologies_metadata_curator/_receipt.html.erb' => '<div id="receipt_modal"><%= receipt.inspect %></div>'
)

OntologiesMetadataCuratorController.view_paths = [CURATOR_PREVIEW_RESOLVER]
OntologiesMetadataCuratorController.layout false
OntologiesMetadataCuratorController.skip_before_action :set_locale, :domain_ontology_set, :init_trial_license, raise: false

SAMPLE_METADATA_DEFINITIONS = [
  { 'attribute' => 'description', 'enforce' => ['textarea'] },
  { 'attribute' => 'version', 'enforce' => ['string'] },
  { 'attribute' => 'flag', 'enforce' => ['boolean'] },
  { 'attribute' => 'keywords', 'enforce' => ['list'] },
  { 'attribute' => 'omitted_field', 'enforce' => ['string'] }
].freeze

class CuratorPreviewSpy
  attr_accessor :helper_metadata_calls, :controller_metadata_calls
  attr_accessor :ontology_find_by_acronym_calls
  attr_accessor :update_submission_calls
  attr_accessor :last_update_submission_data, :last_update_submission_id
  attr_accessor :received_submission_data, :responses_by_ontology
  attr_accessor :submissions_by_target
  attr_accessor :raise_on_update_by_ontology

  def initialize
    reset!
  end

  def reset_call_counts!
    @ontology_find_by_acronym_calls = 0
    @update_submission_calls = 0
    @last_update_submission_data = nil
    @last_update_submission_id = nil
    @received_submission_data = []
  end

  def reset!
    @helper_metadata_calls = 0
    @controller_metadata_calls = 0
    @ontology_find_by_acronym_calls = 0
    @update_submission_calls = 0
    @last_update_submission_data = nil
    @last_update_submission_id = nil
    @received_submission_data = []
    @responses_by_ontology = {}
    @submissions_by_target = {}
    @raise_on_update_by_ontology = {}
  end

  def total_api_read_calls
    @ontology_find_by_acronym_calls
  end

  def total_external_write_calls
    @update_submission_calls
  end
end

$preview_spy = CuratorPreviewSpy.new

module MetadataHelper
  def submission_metadata
    $preview_spy.helper_metadata_calls += 1
    SAMPLE_METADATA_DEFINITIONS
  end
end

class ExplorePreviewMock
  attr_accessor :acronym

  def initialize(acronym = 'TEST')
    @acronym = acronym
  end

  def submissions(*args)
    sub_id = args.last || '1'
    target_key = "#{@acronym}##{sub_id}"
    $preview_spy.submissions_by_target[target_key] ||
      $preview_spy.submissions_by_target["#{@acronym}_#{sub_id}"] ||
      OpenStruct.new(
        submissionId: sub_id,
        description: "Existing Description for #{@acronym}",
        version: '1.0',
        flag: false,
        keywords: ['initial']
      )
  end
end

class LinkedData::Client::Models::Ontology
  class << self
    def find_by_acronym(acronym, options = {})
      $preview_spy.ontology_find_by_acronym_calls += 1
      ont = OpenStruct.new(
        acronym: acronym,
        name: "#{acronym} Name",
        ontologyId: "http://example.com/ontologies/#{acronym}",
        administeredBy: ['http://example.com/users/owner_actor'],
        explore: ExplorePreviewMock.new(acronym)
      )
      def ont.admin?(user)
        user && user.id == 'http://example.com/users/owner_actor'
      end
      [ont]
    end
  end
end

module SubmissionUpdater
  def update_submission(new_submission_hash, submission_id, ontology = nil)
    onto = new_submission_hash[:ontology] || (new_submission_hash['ontology']) || 'TEST'
    $preview_spy.update_submission_calls += 1
    $preview_spy.last_update_submission_id = submission_id
    $preview_spy.received_submission_data << (new_submission_hash.respond_to?(:to_unsafe_h) ? new_submission_hash.to_unsafe_h.deep_dup : new_submission_hash.deep_dup)
    $preview_spy.last_update_submission_data = $preview_spy.received_submission_data.last

    if (err = $preview_spy.raise_on_update_by_ontology[onto])
      raise err
    end

    submission = OpenStruct.new(submissionId: submission_id, ontology: onto)
    @submission = submission

    new_submission_hash.delete(:ontology)
    new_submission_hash.delete('ontology')

    response = $preview_spy.responses_by_ontology[onto] || OpenStruct.new(status: 204)
    [submission, response]
  end
end

# =============================================================================
# Test Suite
# =============================================================================

class BulkMetadataPreviewCheck < Minitest::Test
  ADMIN_ACTOR = OpenStruct.new(id: 'http://example.com/users/portal_admin', username: 'portal_admin', admin?: true).freeze
  OTHER_ADMIN = OpenStruct.new(id: 'http://example.com/users/other_admin', username: 'other_admin', admin?: true).freeze
  ORDINARY_ACTOR = OpenStruct.new(id: 'http://example.com/users/regular_actor', username: 'regular_actor', admin?: false).freeze
  OWNER_ACTOR = OpenStruct.new(id: 'http://example.com/users/owner_actor', username: 'owner_actor', admin?: false, customOntology: ['TEST1']).freeze

  def setup
    $preview_spy.reset!
    Flipper.disable('BulkMetadataPreview')
  end

  def teardown
    Flipper.disable('BulkMetadataPreview')
    Thread.current[:request] = nil
    Thread.current[:session] = nil
  end

  def dispatch(action, user: nil, admin_user: nil, session_hash: {}, params: {}, headers: {})
    req = ActionDispatch::TestRequest.create('rack.session' => session_hash)
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
  # 1. Feature Flag Off: 404 on preview and confirm, existing flow unchanged
  # ===========================================================================
  def test_01_feature_off_returns_404_and_leaves_edit_flow_unchanged
    # Flipper disabled by default
    refute Flipper.enabled?('BulkMetadataPreview')

    ctrl, req, res = dispatch(:preview, user: ADMIN_ACTOR, params: {
      selected_ontologies: ['TEST1#1'],
      active_ontology: 'TEST1#1'
    })
    assert_equal 404, res.status, 'Disabled BulkMetadataPreview must return 404 on :preview'
    assert_equal 0, $preview_spy.total_api_read_calls
    assert_equal 0, $preview_spy.total_external_write_calls

    ctrl, req, res = dispatch(:confirm, user: ADMIN_ACTOR, params: {
      preview_token: 'dummy',
      confirmed_targets: ['TEST1#1']
    })
    assert_equal 404, res.status, 'Disabled BulkMetadataPreview must return 404 on :confirm'
    assert_equal 0, $preview_spy.total_api_read_calls
    assert_equal 0, $preview_spy.total_external_write_calls

    # Existing bulk update still works when feature is off
    ctrl, req, res = dispatch(:update, user: ADMIN_ACTOR, headers: { 'Accept' => 'text/vnd.turbo-stream.html' }, params: {
      selected_ontologies: ['TEST1#1'],
      active_ontology: 'TEST1#1',
      all_metadata: 'description',
      submission: { 'TEST1_1' => { 'description' => 'Unchanged update flow' } }
    })
    assert_includes [200, 204], res.status
    assert_equal 1, $preview_spy.total_external_write_calls
  end

  # ===========================================================================
  # 2. Non-Admin Denied Before Any Lookup
  # ===========================================================================
  def test_02_non_admin_denied_before_any_lookup
    Flipper.enable('BulkMetadataPreview')

    non_admin_actors = [
      [:anonymous, nil],
      [:ordinary, ORDINARY_ACTOR],
      [:owner, OWNER_ACTOR]
    ]

    [:preview, :confirm].each do |action|
      non_admin_actors.each do |role, actor|
        $preview_spy.reset!
        ctrl, req, res = dispatch(action, user: actor, params: {
          selected_ontologies: ['TEST1#1'],
          active_ontology: 'TEST1#1',
          preview_token: 'dummy'
        })
        assert_equal 302, res.status, "#{role} accessing #{action} must be redirected"
        assert_equal 'http://test.host/', res.location, "#{role} accessing #{action} must redirect to home"
        assert_equal 0, $preview_spy.total_api_read_calls, "#{role} accessing #{action} must make 0 API reads"
        assert_equal 0, $preview_spy.total_external_write_calls, "#{role} accessing #{action} must make 0 API writes"
      end
    end
  end

  # ===========================================================================
  # 3. Read-Only Preview: 0 Writes, Exact Before/After, Typed Values, Distinctions
  # ===========================================================================
  def test_03_preview_makes_zero_update_calls_with_exact_before_after_per_target_and_typed_values
    Flipper.enable('BulkMetadataPreview')

    # Configure different starting values per target
    $preview_spy.submissions_by_target['TEST1#1'] = OpenStruct.new(
      submissionId: '1',
      description: 'Old Description 1',
      version: '1.0',
      flag: false,
      keywords: ['ontology', 'materials']
    )
    $preview_spy.submissions_by_target['TEST2#2'] = OpenStruct.new(
      submissionId: '2',
      description: 'Old Description 2',
      version: '',
      flag: true,
      keywords: ['chemistry']
    )

    ctrl, req, res = dispatch(:preview, user: ADMIN_ACTOR, session_hash: { session_id: 'sess_123' }, params: {
      selected_ontologies: ['TEST1#1', 'TEST2#2'],
      active_ontology: 'TEST1#1',
      selected_metadata: ['description', 'version', 'flag', 'keywords', 'omitted_field'],
      submission: {
        'TEST1_1' => {
          'description' => 'Shared Proposed Description',
          'version' => '',
          'flag' => 'true',
          'keywords' => ['shared_tag']
          # omitted_field is intentionally omitted
        }
      }
    })

    assert_equal 200, res.status
    assert_equal 0, $preview_spy.total_external_write_calls, 'Preview must make exactly ZERO update calls'

    preview_res = ctrl.instance_variable_get(:@preview_result)
    refute_nil preview_res
    refute_nil preview_res[:preview_token]

    targets = preview_res[:targets]
    assert_equal 2, targets.size

    # Target 1 Verification
    t1 = targets.find { |t| t[:target_id] == 'TEST1#1' }
    p1 = t1[:properties]
    # description: replaced
    assert_equal :replaced, p1['description'][:status]
    assert_equal 'Old Description 1', p1['description'][:current]
    assert_equal 'Shared Proposed Description', p1['description'][:proposed]
    # version: cleared (had "1.0", explicitly cleared to "")
    assert_equal :cleared, p1['version'][:status]
    assert_equal '1.0', p1['version'][:current]
    assert_equal '', p1['version'][:proposed]
    # flag: replaced (had false, converted to true, typed boolean)
    assert_equal :replaced, p1['flag'][:status]
    assert_equal false, p1['flag'][:current]
    assert_equal true, p1['flag'][:proposed]
    assert_instance_of TrueClass, p1['flag'][:proposed]
    # keywords: replaced (had ["ontology", "materials"], converted to ["shared_tag"], typed array)
    assert_equal :replaced, p1['keywords'][:status]
    assert_equal ['ontology', 'materials'], p1['keywords'][:current]
    assert_equal ['shared_tag'], p1['keywords'][:proposed]
    assert_instance_of Array, p1['keywords'][:proposed]
    # omitted_field: omitted (not cleared!)
    assert_equal :omitted, p1['omitted_field'][:status]
    assert_nil p1['omitted_field'][:proposed]

    # Target 2 Verification
    t2 = targets.find { |t| t[:target_id] == 'TEST2#2' }
    p2 = t2[:properties]
    assert_equal :replaced, p2['description'][:status]
    assert_equal 'Old Description 2', p2['description'][:current]
    assert_equal 'Shared Proposed Description', p2['description'][:proposed]
    # version: unchanged (was empty, proposed is empty)
    assert_equal :unchanged, p2['version'][:status]
    # flag: unchanged (was true, proposed is true)
    assert_equal :unchanged, p2['flag'][:status]
    assert_equal true, p2['flag'][:proposed]
    # keywords: replaced (was ["chemistry"], proposed ["shared_tag"])
    assert_equal :replaced, p2['keywords'][:status]
    # omitted_field: omitted
    assert_equal :omitted, p2['omitted_field'][:status]
  end

  # ===========================================================================
  # 4. Target Exclusion Prevents Mutation on Confirmation
  # ===========================================================================
  def test_04_excluded_target_not_mutated_on_confirmation
    Flipper.enable('BulkMetadataPreview')

    $preview_spy.submissions_by_target['TEST1#1'] = OpenStruct.new(submissionId: '1', description: 'Desc 1')
    $preview_spy.submissions_by_target['TEST2#2'] = OpenStruct.new(submissionId: '2', description: 'Desc 2')

    ctrl, req, res = dispatch(:preview, user: ADMIN_ACTOR, session_hash: { session_id: 'sess_target_test' }, params: {
      selected_ontologies: ['TEST1#1', 'TEST2#2'],
      active_ontology: 'TEST1#1',
      selected_metadata: ['description'],
      submission: { 'TEST1_1' => { 'description' => 'Target 1 Only' } }
    })
    token = ctrl.instance_variable_get(:@preview_result)[:preview_token]

    # Confirm ONLY TEST1#1 (TEST2#2 is unchecked/excluded by curator)
    $preview_spy.reset_call_counts!
    ctrl, req, res = dispatch(:confirm, user: ADMIN_ACTOR, session_hash: { session_id: 'sess_target_test' }, params: {
      preview_token: token,
      confirmed_targets: ['TEST1#1']
    })

    assert_equal 200, res.status
    assert_equal 1, $preview_spy.total_external_write_calls, 'Only 1 target must be updated'
    assert_equal '1', $preview_spy.last_update_submission_id
    mutated_ontologies = $preview_spy.received_submission_data.map { |d| d[:ontology] || d['ontology'] }
    assert_includes mutated_ontologies, 'TEST1'
    refute_includes mutated_ontologies, 'TEST2', 'Excluded target TEST2 must NOT be mutated'
  end

  # ===========================================================================
  # 5. Tampered Context and Other-Session Context Rejected with Zero Writes
  # ===========================================================================
  def test_05_tampered_context_and_other_session_context_rejected_with_zero_writes
    Flipper.enable('BulkMetadataPreview')

    ctrl, req, res = dispatch(:preview, user: ADMIN_ACTOR, session_hash: { session_id: 'sess_secure' }, params: {
      selected_ontologies: ['TEST1#1'],
      active_ontology: 'TEST1#1',
      selected_metadata: ['description'],
      submission: { 'TEST1_1' => { 'description' => 'Secure Payload' } }
    })
    valid_token = ctrl.instance_variable_get(:@preview_result)[:preview_token]

    # 5a. Tampered Token Signature
    $preview_spy.reset!
    ctrl, req, res = dispatch(:confirm, user: ADMIN_ACTOR, session_hash: { session_id: 'sess_secure' }, params: {
      preview_token: "#{valid_token}_tampered",
      confirmed_targets: ['TEST1#1']
    })
    assert_equal 422, res.status, 'Tampered token must be rejected with 422'
    assert_equal 0, $preview_spy.total_external_write_calls, 'Tampered token must cause zero writes'

    # 5b. Other Session Hijack Attempt
    $preview_spy.reset!
    ctrl, req, res = dispatch(:confirm, user: ADMIN_ACTOR, session_hash: { session_id: 'sess_another_session' }, params: {
      preview_token: valid_token,
      confirmed_targets: ['TEST1#1']
    })
    assert_equal 422, res.status, 'Other session context must be rejected with 422'
    assert_equal 0, $preview_spy.total_external_write_calls, 'Other session must cause zero writes'

    # 5c. Different User Hijack Attempt
    $preview_spy.reset!
    ctrl, req, res = dispatch(:confirm, user: OTHER_ADMIN, session_hash: { session_id: 'sess_secure' }, params: {
      preview_token: valid_token,
      confirmed_targets: ['TEST1#1']
    })
    assert_equal 422, res.status, 'Different user context must be rejected with 422'
    assert_equal 0, $preview_spy.total_external_write_calls, 'Different user must cause zero writes'

    # 5d. Tampered Proposed Values in Request
    $preview_spy.reset!
    ctrl, req, res = dispatch(:confirm, user: ADMIN_ACTOR, session_hash: { session_id: 'sess_secure' }, params: {
      preview_token: valid_token,
      active_ontology: 'TEST1#1',
      submission: { 'TEST1_1' => { 'description' => 'TAMPERED IN FLIGHT' } },
      confirmed_targets: ['TEST1#1']
    })
    assert_equal 422, res.status, 'Tampered proposed values must be rejected with 422'
    assert_equal 0, $preview_spy.total_external_write_calls, 'Tampered proposed values must cause zero writes'
  end

  # ===========================================================================
  # 6. Changed Current Value Forces New Preview (Best-Effort Recheck)
  # ===========================================================================
  def test_06_changed_current_value_forces_new_preview_best_effort_recheck
    Flipper.enable('BulkMetadataPreview')

    $preview_spy.submissions_by_target['TEST1#1'] = OpenStruct.new(submissionId: '1', description: 'Original Description')

    ctrl, req, res = dispatch(:preview, user: ADMIN_ACTOR, session_hash: { session_id: 'sess_stale' }, params: {
      selected_ontologies: ['TEST1#1'],
      active_ontology: 'TEST1#1',
      selected_metadata: ['description'],
      submission: { 'TEST1_1' => { 'description' => 'New Description' } }
    })
    token = ctrl.instance_variable_get(:@preview_result)[:preview_token]

    # Simulate concurrent external edit modifying TEST1#1 before confirmation
    $preview_spy.submissions_by_target['TEST1#1'].description = 'Concurrently Modified Description!'

    $preview_spy.reset!
    ctrl, req, res = dispatch(:confirm, user: ADMIN_ACTOR, session_hash: { session_id: 'sess_stale' }, params: {
      preview_token: token,
      confirmed_targets: ['TEST1#1']
    })

    assert_equal 409, res.status, 'Changed current value must force new preview with 409 Conflict'
    assert_includes res.body, 'Current values changed since preview'
    assert_equal 0, $preview_spy.total_external_write_calls, 'Stale detection must perform zero writes'
  end

  # ===========================================================================
  # 7. Mixed Outcomes Produce Distinct Receipt Rows; Retry Only Known Failures
  # ===========================================================================
  def test_07_mixed_outcomes_produce_distinct_receipt_rows_and_retry_preview_contains_only_chosen_known_failures
    Flipper.enable('BulkMetadataPreview')

    $preview_spy.submissions_by_target['TEST1#1'] = OpenStruct.new(submissionId: '1', description: 'Desc 1')
    $preview_spy.submissions_by_target['TEST2#2'] = OpenStruct.new(submissionId: '2', description: 'Desc 2')
    $preview_spy.submissions_by_target['TEST3#3'] = OpenStruct.new(submissionId: '3', description: 'Desc 3')

    # Step 1: Generate Preview for 3 targets
    ctrl, req, res = dispatch(:preview, user: ADMIN_ACTOR, session_hash: { session_id: 'sess_receipt' }, params: {
      selected_ontologies: ['TEST1#1', 'TEST2#2', 'TEST3#3'],
      active_ontology: 'TEST1#1',
      selected_metadata: ['description'],
      submission: { 'TEST1_1' => { 'description' => 'Shared Update' } }
    })
    token = ctrl.instance_variable_get(:@preview_result)[:preview_token]

    # Step 2: Configure mixed outcomes
    # TEST1: 204 (Success)
    $preview_spy.responses_by_ontology['TEST1'] = OpenStruct.new(status: 204)
    # TEST2: 422 (Rejected known failure)
    $preview_spy.responses_by_ontology['TEST2'] = OpenStruct.new(status: 422, response: '{"error": "Validation failed on field"}')
    # TEST3: Timeout / Unknown outcome
    $preview_spy.raise_on_update_by_ontology['TEST3'] = Net::ReadTimeout.new('API upstream timeout')

    # Confirm all 3
    ctrl, req, res = dispatch(:confirm, user: ADMIN_ACTOR, session_hash: { session_id: 'sess_receipt' }, params: {
      preview_token: token,
      confirmed_targets: ['TEST1#1', 'TEST2#2', 'TEST3#3']
    })

    receipt = ctrl.instance_variable_get(:@review_receipt)
    refute_nil receipt, 'Confirmation must produce a review receipt'
    assert_equal 3, receipt.size, 'Receipt must contain exactly 3 rows'

    r_success = receipt.find { |r| r[:target] == 'TEST1#1' }
    r_rejected = receipt.find { |r| r[:target] == 'TEST2#2' }
    r_unknown = receipt.find { |r| r[:target] == 'TEST3#3' }

    assert_equal :success, r_success[:status], 'TEST1#1 must be marked as :success'
    assert_equal :rejected, r_rejected[:status], 'TEST2#2 must be marked as :rejected'
    assert_equal :unknown, r_unknown[:status], 'TEST3#3 must be marked as :unknown'

    # Receipt is stored in session
    assert_equal receipt, req.session[:bulk_metadata_review_receipt]

    # Step 3: Retry Preview Flow
    # Curator selects ONLY the known failure TEST2#2 for retry preview
    ctrl, req, res = dispatch(:preview, user: ADMIN_ACTOR, session_hash: req.session, params: {
      selected_ontologies: ['TEST1#1', 'TEST2#2', 'TEST3#3'],
      retry_targets: ['TEST2#2'],
      active_ontology: 'TEST2#2',
      selected_metadata: ['description'],
      submission: { 'TEST2_2' => { 'description' => 'Retried Update' } }
    })

    retry_targets = ctrl.instance_variable_get(:@selected_ontologies)
    assert_equal 1, retry_targets.size
    assert_equal [['TEST2', '2']], retry_targets, 'Retry preview must contain ONLY the chosen known failure'

    # Verify that even if an attacker attempts to replay successes or retry unknowns without re-read:
    ctrl, req, res = dispatch(:preview, user: ADMIN_ACTOR, session_hash: req.session, params: {
      selected_ontologies: ['TEST1#1', 'TEST2#2', 'TEST3#3'],
      retry_targets: ['TEST1#1', 'TEST2#2', 'TEST3#3'], # Attempting to replay success & unknown
      active_ontology: 'TEST2#2',
      selected_metadata: ['description'],
      submission: { 'TEST2_2' => { 'description' => 'Sneaky Replay' } }
    })
    sanitized_retries = ctrl.instance_variable_get(:@selected_ontologies)
    assert_equal [['TEST2', '2']], sanitized_retries, 'Server must filter out successes and unknown outcomes from retry preview'
  end

  def render_component(component)
    lookup_context = ActionView::LookupContext.new([])
    view_context = ActionView::Base.new(lookup_context, {}, nil)
    component.render_in(view_context)
  end

  # ===========================================================================
  # 8. ViewComponent Presentation and Form Survival
  # ===========================================================================
  def test_08_view_component_rendering_and_action_controls
    # Test preview rendering
    preview_data = {
      preview_token: 'signed_test_token',
      active_ontology: 'TEST_1',
      all_metadata: 'description flag',
      targets: [
        {
          target_id: 'TEST_1',
          ontology: 'TEST',
          submission_id: '1',
          properties: {
            'description' => { current: 'Old', proposed: 'New', status: :replaced },
            'flag' => { current: false, proposed: true, status: :replaced }
          }
        }
      ]
    }

    comp = BulkMetadataPreviewComponent.new(preview: preview_data)
    html = render_component(comp)

    assert_includes html, 'bulk-metadata-preview'
    assert_includes html, 'target-inclusion-checkbox'
    assert_includes html, 'include_TEST_1'
    assert_includes html, 'preview-row-replaced'
    assert_includes html, 'replaced'
    assert_includes html, 'signed_test_token'
    assert_includes html, 'Confirm updates'
    assert_includes html, 'Cancel'

    # Test receipt rendering
    receipt_data = [
      { target: 'TEST_1', ontology: 'TEST', submission_id: '1', fields: ['description'], status: :success, message: 'Success' },
      { target: 'TEST_2', ontology: 'TEST', submission_id: '2', fields: ['description'], status: :rejected, message: 'Forbidden' },
      { target: 'TEST_3', ontology: 'TEST', submission_id: '3', fields: ['description'], status: :unknown, message: 'Timeout' }
    ]

    receipt_comp = BulkMetadataPreviewComponent.new(receipt: receipt_data)
    receipt_html = render_component(receipt_comp)

    assert_includes receipt_html, 'bulk-metadata-receipt'
    assert_includes receipt_html, 'receipt-row-success'
    assert_includes receipt_html, 'receipt-row-rejected'
    assert_includes receipt_html, 'receipt-row-unknown'
    # Retry checkbox must exist ONLY for rejected
    assert_includes receipt_html, 'id="retry_TEST_2"'
    refute_includes receipt_html, 'id="retry_TEST_1"', 'Success row must NOT have retry checkbox'
    refute_includes receipt_html, 'id="retry_TEST_3"', 'Unknown outcome must NOT have direct retry checkbox'
    assert_includes receipt_html, 'Fresh preview for failed targets'
  end

  def test_09_retry_without_receipt_and_exception_outcome_is_unknown
    Flipper.enable('BulkMetadataPreview')
    $preview_spy.submissions_by_target['TEST1#1'] = OpenStruct.new(submissionId: '1', description: 'Desc 1')

    # A retry request with no review receipt in the session selects nothing.
    _ctrl, _req, res = dispatch(:preview, user: ADMIN_ACTOR, session_hash: { session_id: 'sess_no_receipt' }, params: {
      selected_ontologies: ['TEST1#1'], active_ontology: 'TEST1#1', selected_metadata: ['description'],
      retry_targets: ['TEST1#1'], submission: { 'TEST1_1' => { 'description' => 'x' } }
    })
    assert_equal 422, res.status, 'retry without a receipt must not preview any target'

    # An exception without a response is an unknown outcome, never a retryable rejection.
    ctrl, _req, _res = dispatch(:preview, user: ADMIN_ACTOR, session_hash: { session_id: 'sess_exc' }, params: {
      selected_ontologies: ['TEST1#1'], active_ontology: 'TEST1#1', selected_metadata: ['description'],
      submission: { 'TEST1_1' => { 'description' => 'y' } }
    })
    token = ctrl.instance_variable_get(:@preview_result)[:preview_token]
    $preview_spy.raise_on_update_by_ontology['TEST1'] = StandardError.new('connection dropped mid-write')
    ctrl, _req, _res = dispatch(:confirm, user: ADMIN_ACTOR, session_hash: { session_id: 'sess_exc' }, params: {
      preview_token: token, confirmed_targets: ['TEST1#1']
    })
    row = ctrl.instance_variable_get(:@review_receipt).find { |r| r[:target] == 'TEST1#1' }
    assert_equal :unknown, row[:status]
  end
end
