# frozen_string_literal: true

require 'minitest/autorun'
require 'logger'
require 'ostruct'
require 'cgi'
require 'set'

# =============================================================================
# Standalone Offline Note & Mapping Guard Check (ONTO-T-B04)
#
# Validates the B04 authorization boundaries for:
# 1. NotesController#destroy:
#    - Admin-only access matching app/views/notes/_note_line.html.haml:2.
#    - Prepend :authorize_admin before inherited startup callbacks (:set_global_thread_values,
#      :init_trial_license) and Note model lookup/delete.
#    - Denial of anonymous and ordinary authenticated non-admin actors before lookup/delete.
#    - Admission of portal administrators and session[:admin_user] impersonation context.
#    - Note.delete return response is checked: known upstream API 401 and 403 responses
#      render alert-danger error stream and NEVER render success or row removal.
#    - Successful delete renders alert-success and turbo_stream remove.
#    - Existing create guards (:verify_note_creator and :authorize_and_redirect) remain untouched.
#
# 2. MappingsController (:update and :loader_process):
#    - Added to existing before_action :authorize_and_redirect callback list (login only).
#    - Anonymous requests to :update and :loader_process are denied with 302 to '/' before
#      any HTTP network/SDK call is executed (0 HTTP post/patch calls).
#    - Authenticated ordinary users reach the actions without operator owner/admin restriction
#      (preserving the open operator policy decision).
#
# 3. Uses finite SDK/HTTP/render doubles only with real Rails dispatch and real auth helpers.
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

LinkedData::Client.config do |config|
  config.rest_url = 'http://example.com'
  config.links_attr = 'links'
end

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
require 'notes_helper'
require 'turbo_helper'
require 'mapping_statistics'
require 'mappings_helper'
require 'application_controller'
require 'notes_controller'
require 'mappings_controller'

# Capture Pristine Callback Chains Prior to Any Test Skips
ORIGINAL_NOTES_CALLBACKS = NotesController._process_action_callbacks.dup.freeze
ORIGINAL_MAPPINGS_CALLBACKS = MappingsController._process_action_callbacks.dup.freeze

# Finite Route Helper Stubs
module StandaloneRouteHelperStubs
  def root_path(*args, **kwargs)
    '/'
  end

  def login_index_path(*args, **kwargs)
    '/login'
  end

  def notes_path(*args, **kwargs)
    '/notes'
  end

  def mappings_path(*args, **kwargs)
    '/mappings'
  end

  def ontology_path(id, *args, **kwargs)
    "/ontologies/#{id}"
  end
end
ActionController::Base.include StandaloneRouteHelperStubs

# Finite Presentation Boundary: Fixture Resolvers for offline partial rendering
FIXTURE_RESOLVER = ActionView::FixtureResolver.new(
  'mappings/bulk_loader/_loaded_mappings.html.erb' => '<div id="loaded_mappings">Loaded: <%= created %></div>',
  'mappings/_show_line.html.erb' => '<tr id="show_line_row">Updated</tr>'
)

NotesController.view_paths = [FIXTURE_RESOLVER]
MappingsController.view_paths = [FIXTURE_RESOLVER]
NotesController.layout false
MappingsController.layout false

# Finite unrelated startup boundaries skipped for offline standalone test environment
NotesController.skip_before_action :set_locale, :domain_ontology_set, :init_trial_license, raise: false
MappingsController.skip_before_action :set_locale, :domain_ontology_set, :init_trial_license, raise: false

# =============================================================================
# Spies & Finite SDK / HTTP Doubles
# =============================================================================

class BoundarySpy
  attr_accessor :note_get_calls, :note_get_args
  attr_accessor :note_delete_calls, :note_delete_response, :note_errors
  attr_accessor :http_post_calls, :http_post_args, :http_post_response
  attr_accessor :http_patch_calls, :http_patch_args, :http_patch_response
  attr_accessor :mapping_find_calls, :ontology_find_by_acronym_calls

  def initialize
    reset!
  end

  def reset!
    @note_get_calls = 0
    @note_get_args = []
    @note_delete_calls = 0
    @note_delete_response = OpenStruct.new(status: 204)
    @note_errors = nil

    @http_post_calls = 0
    @http_post_args = []
    @http_post_response = OpenStruct.new(errors: nil, created: 3)

    @http_patch_calls = 0
    @http_patch_args = []
    @http_patch_response = OpenStruct.new(status: 204, body: '')

    @mapping_find_calls = 0
    @ontology_find_by_acronym_calls = 0
  end
end

$spy = BoundarySpy.new

# Finite Note Model Boundary
class LinkedData::Client::Models::Note
  class << self
    def get(id, _options = {})
      $spy.note_get_calls += 1
      $spy.note_get_args << id
      return nil if id == 'missing_note'

      instance = allocate
      instance.instance_variable_set(:@id, id)
      instance
    end
  end

  def id
    @id || 'http://example.com/notes/test_note'
  end

  def errors
    $spy.note_errors
  end

  def delete
    $spy.note_delete_calls += 1
    $spy.note_delete_response
  end
end

# Finite HTTP Client Boundary
module LinkedData::Client::HTTP
  class << self
    def post(path, *args, **kwargs)
      $spy.http_post_calls += 1
      $spy.http_post_args << [path, args, kwargs]
      $spy.http_post_response
    end

    def patch(path, *args, **kwargs)
      $spy.http_patch_calls += 1
      $spy.http_patch_args << [path, args, kwargs]
      $spy.http_patch_response
    end
  end
end

# Finite Mapping Model Boundary
class LinkedData::Client::Models::Mapping
  class << self
    def find(id, _options = {})
      $spy.mapping_find_calls += 1
      OpenStruct.new(
        id: id || 'http://example.com/mappings/101',
        errors: nil,
        classes: [
          OpenStruct.new(id: 'http://example.com/cls1', links: { 'ontology' => 'http://example.com/ontologies/ONT1' }),
          OpenStruct.new(id: 'http://example.com/cls2', links: { 'ontology' => 'http://example.com/ontologies/ONT2' })
        ],
        process: { 'name' => 'manual' }
      )
    end
  end
end

# Finite Ontology Model Boundary
class ExploreMock
  def single_class(_cid)
    OpenStruct.new(id: 'http://example.com/classes/C1')
  end
end

class LinkedData::Client::Models::Ontology
  class << self
    def find_by_acronym(acronym, _options = {})
      $spy.ontology_find_by_acronym_calls += 1
      ont = OpenStruct.new(
        acronym: acronym,
        id: "http://example.com/ontologies/#{acronym}",
        explore: ExploreMock.new
      )
      [ont]
    end
  end
end

# =============================================================================
# Test Suite
# =============================================================================

class NoteMappingGuardCheck < Minitest::Test
  ADMIN_USER = OpenStruct.new(id: 'http://example.com/users/admin_user', username: 'admin_user', admin?: true).freeze
  REGULAR_USER = OpenStruct.new(id: 'http://example.com/users/regular_user', username: 'regular_user', admin?: false).freeze
  IMPERSONATED_ADMIN = OpenStruct.new(id: 'http://example.com/users/real_admin', username: 'real_admin', admin?: true).freeze

  def setup
    $spy.reset!
  end

  def teardown
    Thread.current[:request] = nil
    Thread.current[:session] = nil
  end

  def dispatch(controller_class, action, user: nil, admin_user: nil, params: {}, headers: {})
    req = ActionDispatch::TestRequest.create('rack.session' => {})
    req.session[:user] = user if user
    req.session[:admin_user] = admin_user if admin_user
    headers.each { |k, v| req.headers[k] = v }
    params.each { |k, v| req.params[k] = v }

    res = ActionDispatch::TestResponse.create
    ctrl = controller_class.new
    ctrl.set_request!(req)
    ctrl.set_response!(res)
    ctrl.process(action)
    [ctrl, req, res]
  end

  # ===========================================================================
  # 1. NotesController Callback Ordering, Scope, and Create Guard Retention
  # ===========================================================================
  def test_01_notes_controller_callback_ordering_and_scope
    callbacks = ORIGINAL_NOTES_CALLBACKS
    filter_names = callbacks.map(&:filter)

    auth_idx = filter_names.index(:authorize_admin)
    thread_idx = filter_names.index(:set_global_thread_values)
    license_idx = filter_names.index(:init_trial_license)

    refute_nil auth_idx, 'NotesController must declare prepended :authorize_admin callback'
    assert_operator auth_idx, :<, thread_idx, ':authorize_admin must precede inherited :set_global_thread_values'
    assert_operator auth_idx, :<, license_idx, ':authorize_admin must precede inherited :init_trial_license'

    # Scope verification: authorize_admin must be strictly scoped to :destroy
    auth_cb = callbacks.find { |c| c.filter == :authorize_admin }
    auth_filter_obj = auth_cb.instance_variable_get(:@if)&.first
    auth_actions = auth_filter_obj&.instance_variable_get(:@actions)
    assert_equal Set['destroy'], auth_actions, ':authorize_admin must be scoped strictly to [:destroy]'

    # Create guards (:verify_note_creator, :authorize_and_redirect) must remain present and scoped to :create
    create_auth_cb = callbacks.find { |c| c.filter == :authorize_and_redirect }
    refute_nil create_auth_cb, 'NotesController must retain :authorize_and_redirect for create'
    create_auth_actions = create_auth_cb.instance_variable_get(:@if)&.first&.instance_variable_get(:@actions)
    assert_equal Set['create'], create_auth_actions, ':authorize_and_redirect must remain scoped to [:create]'

    creator_verify_cb = callbacks.find { |c| c.filter == :verify_note_creator }
    refute_nil creator_verify_cb, 'NotesController must retain :verify_note_creator for create'
    creator_verify_actions = creator_verify_cb.instance_variable_get(:@if)&.first&.instance_variable_get(:@actions)
    assert_equal Set['create'], creator_verify_actions, ':verify_note_creator must remain scoped to [:create]'
  end

  # ===========================================================================
  # 2. NotesController#destroy: Anonymous Denied Before Startup, Lookup, Delete
  # ===========================================================================
  def test_02_anonymous_note_destroy_denied_before_thread_startup_lookup_delete
    sentinel_req = Object.new
    sentinel_sess = Object.new
    Thread.current[:request] = sentinel_req
    Thread.current[:session] = sentinel_sess

    _ctrl, _req, res = dispatch(
      NotesController,
      :destroy,
      user: nil,
      params: { noteid: 'http://example.com/notes/n1', parent_type: 'ontology' }
    )

    assert_equal 302, res.status, 'Anonymous note destroy must be redirected'
    assert_equal 'http://test.host/', res.location, 'Anonymous note destroy must redirect to home (/)'

    # Startup sentinel verification
    assert_same sentinel_req, Thread.current[:request],
                'Anonymous note destroy must NOT execute :set_global_thread_values'
    assert_same sentinel_sess, Thread.current[:session],
                'Anonymous note destroy must NOT mutate Thread.current[:session]'

    # SDK call verification
    assert_equal 0, $spy.note_get_calls, 'Anonymous note destroy must make ZERO Note.get calls'
    assert_equal 0, $spy.note_delete_calls, 'Anonymous note destroy must make ZERO Note#delete calls'
  end

  # ===========================================================================
  # 3. NotesController#destroy: Non-Admin Authenticated Denied Before Lookup/Delete
  # ===========================================================================
  def test_03_non_admin_note_destroy_denied_before_thread_startup_lookup_delete
    sentinel_req = Object.new
    sentinel_sess = Object.new
    Thread.current[:request] = sentinel_req
    Thread.current[:session] = sentinel_sess

    _ctrl, _req, res = dispatch(
      NotesController,
      :destroy,
      user: REGULAR_USER,
      params: { noteid: 'http://example.com/notes/n1', parent_type: 'ontology' }
    )

    assert_equal 302, res.status, 'Non-admin note destroy must be redirected'
    assert_equal 'http://test.host/', res.location, 'Non-admin note destroy must redirect to home (/)'

    # Startup sentinel verification
    assert_same sentinel_req, Thread.current[:request],
                'Non-admin note destroy must NOT execute :set_global_thread_values'
    assert_same sentinel_sess, Thread.current[:session],
                'Non-admin note destroy must NOT mutate Thread.current[:session]'

    # SDK call verification
    assert_equal 0, $spy.note_get_calls, 'Non-admin note destroy must make ZERO Note.get calls'
    assert_equal 0, $spy.note_delete_calls, 'Non-admin note destroy must make ZERO Note#delete calls'
  end

  # ===========================================================================
  # 4. NotesController#destroy: Administrator Destroy Succeeds
  # ===========================================================================
  def test_04_admin_note_destroy_succeeds
    $spy.note_delete_response = OpenStruct.new(status: 204)

    _ctrl, _req, res = dispatch(
      NotesController,
      :destroy,
      user: ADMIN_USER,
      params: { noteid: 'http://example.com/notes/n1', parent_type: 'ontology' },
      headers: { 'Accept' => 'text/vnd.turbo-stream.html' }
    )

    assert_equal 200, res.status, 'Admin note destroy must succeed with 200 OK'
    assert_equal 1, $spy.note_get_calls, 'Admin note destroy must invoke Note.get exactly once'
    assert_equal 'http://example.com/notes/n1', $spy.note_get_args.last
    assert_equal 1, $spy.note_delete_calls, 'Admin note destroy must invoke Note#delete exactly once'

    assert_includes res.body, 'alert-success', 'Admin destroy must render alert-success stream'
    assert_includes res.body, 'action="remove"', 'Admin destroy must render turbo-stream remove'
    assert_includes res.body, 'target="http://example.com/notes/n1_tr_ontology"'
    refute_includes res.body, 'alert-danger', 'Admin successful destroy must NOT render error'
  end

  # ===========================================================================
  # 5. NotesController#destroy: Supported Impersonation Admin Succeeds
  # ===========================================================================
  def test_05_impersonation_admin_note_destroy_succeeds
    $spy.note_delete_response = OpenStruct.new(status: 204)

    _ctrl, _req, res = dispatch(
      NotesController,
      :destroy,
      user: REGULAR_USER,
      admin_user: IMPERSONATED_ADMIN,
      params: { noteid: 'http://example.com/notes/n2', parent_type: 'class' },
      headers: { 'Accept' => 'text/vnd.turbo-stream.html' }
    )

    assert_equal 200, res.status, 'Impersonation admin note destroy must succeed with 200'
    assert_equal 1, $spy.note_get_calls, 'Impersonation admin must invoke Note.get'
    assert_equal 1, $spy.note_delete_calls, 'Impersonation admin must invoke Note#delete'
    assert_includes res.body, 'alert-success'
    assert_includes res.body, 'action="remove"'
    assert_includes res.body, 'target="http://example.com/notes/n2_tr_class"'
  end

  # ===========================================================================
  # 6. NotesController#destroy: Upstream API 401 Delete Shows NO Success
  # ===========================================================================
  def test_06_note_delete_api_401_renders_error_and_never_success
    $spy.note_delete_response = OpenStruct.new(status: 401, body: '{"errors": ["Unauthorized delete request"]}')

    _ctrl, _req, res = dispatch(
      NotesController,
      :destroy,
      user: ADMIN_USER,
      params: { noteid: 'http://example.com/notes/n_401', parent_type: 'ontology' },
      headers: { 'Accept' => 'text/vnd.turbo-stream.html' }
    )

    assert_equal 200, res.status, 'Delete 401 must return 200 turbo-stream response'
    assert_equal 1, $spy.note_get_calls
    assert_equal 1, $spy.note_delete_calls

    assert_includes res.body, 'alert-danger', 'API 401 delete must render alert-danger stream'
    refute_includes res.body, 'alert-success', 'API 401 delete MUST NEVER render alert-success'
    refute_includes res.body, 'action="remove"', 'API 401 delete MUST NEVER render row removal'
  end

  # ===========================================================================
  # 7. NotesController#destroy: Upstream API 403 Delete Shows NO Success
  # ===========================================================================
  def test_07_note_delete_api_403_renders_error_and_never_success
    $spy.note_delete_response = OpenStruct.new(status: 403, body: '{"errors": ["Forbidden note delete"]}')

    _ctrl, _req, res = dispatch(
      NotesController,
      :destroy,
      user: ADMIN_USER,
      params: { noteid: 'http://example.com/notes/n_403', parent_type: 'ontology' },
      headers: { 'Accept' => 'text/vnd.turbo-stream.html' }
    )

    assert_equal 200, res.status, 'Delete 403 must return 200 turbo-stream response'
    assert_equal 1, $spy.note_get_calls
    assert_equal 1, $spy.note_delete_calls

    assert_includes res.body, 'alert-danger', 'API 403 delete must render alert-danger stream'
    refute_includes res.body, 'alert-success', 'API 403 delete MUST NEVER render alert-success'
    refute_includes res.body, 'action="remove"', 'API 403 delete MUST NEVER render row removal'
  end

  # ===========================================================================
  # 8. MappingsController Callback Declaration and Operator Boundary Verification
  # ===========================================================================
  def test_08_mappings_controller_callback_declaration_and_operator_boundary
    callbacks = ORIGINAL_MAPPINGS_CALLBACKS
    auth_cb = callbacks.find { |c| c.filter == :authorize_and_redirect }
    refute_nil auth_cb, 'MappingsController must declare :authorize_and_redirect callback'

    auth_actions = auth_cb.instance_variable_get(:@if)&.first&.instance_variable_get(:@actions)
    assert_includes auth_actions, 'update', ':authorize_and_redirect must include :update'
    assert_includes auth_actions, 'loader_process', ':authorize_and_redirect must include :loader_process'
    assert_includes auth_actions, 'create', ':authorize_and_redirect must include :create'
    assert_includes auth_actions, 'new', ':authorize_and_redirect must include :new'
    assert_includes auth_actions, 'destroy', ':authorize_and_redirect must include :destroy'

    # Operator policy check: MappingsController must NOT declare owner or admin filters
    filter_names = callbacks.map(&:filter)
    refute_includes filter_names, :authorize_admin,
                    'MappingsController must NOT impose admin-only restriction (open operator decision)'
    refute_includes filter_names, :verify_owner,
                    'MappingsController must NOT impose unapproved owner filter (open operator decision)'
  end

  # ===========================================================================
  # 9. MappingsController#update: Anonymous Denied Before Any HTTP Call
  # ===========================================================================
  def test_09_anonymous_mapping_update_denied_before_http_call
    _ctrl, _req, res = dispatch(
      MappingsController,
      :update,
      user: nil,
      params: { id: 'http://example.com/mappings/101' },
      headers: { 'Accept' => 'text/vnd.turbo-stream.html' }
    )

    assert_equal 302, res.status, 'Anonymous mapping update must redirect'
    assert_equal 'http://test.host/', res.location, 'Anonymous mapping update must redirect to home (/)'

    assert_equal 0, $spy.http_patch_calls, 'Anonymous mapping update must make ZERO HTTP patch calls'
    assert_equal 0, $spy.mapping_find_calls, 'Anonymous mapping update must make ZERO Mapping find calls'
  end

  # ===========================================================================
  # 10. MappingsController#loader_process: Anonymous Denied Before Any HTTP Call
  # ===========================================================================
  def test_10_anonymous_mapping_loader_process_denied_before_http_call
    _ctrl, _req, res = dispatch(
      MappingsController,
      :loader_process,
      user: nil,
      params: { file: 'mappings.csv' },
      headers: { 'Accept' => 'text/vnd.turbo-stream.html' }
    )

    assert_equal 302, res.status, 'Anonymous mapping loader must redirect'
    assert_equal 'http://test.host/', res.location, 'Anonymous mapping loader must redirect to home (/)'

    assert_equal 0, $spy.http_post_calls, 'Anonymous mapping loader must make ZERO HTTP post calls'
  end

  # ===========================================================================
  # 11. MappingsController#loader_process: Authenticated User Reaches Action
  # ===========================================================================
  def test_11_authenticated_mapping_loader_process_reaches_action
    $spy.http_post_response = OpenStruct.new(errors: nil, created: 7)

    _ctrl, _req, res = dispatch(
      MappingsController,
      :loader_process,
      user: REGULAR_USER,
      params: { file: 'sample_mappings.csv' },
      headers: { 'Accept' => 'text/vnd.turbo-stream.html' }
    )

    assert_equal 200, res.status, 'Authenticated mapping loader must return 200 turbo-stream response'
    assert_equal 1, $spy.http_post_calls, 'Authenticated mapping loader MUST reach action and invoke HTTP.post'
    assert_equal '/mappings/load', $spy.http_post_args.last[0]
    assert_includes res.body, 'file_loader_result', 'Response must replace file_loader_result target'
    assert_includes res.body, 'Loaded: 7', 'Response must render fixture content with created count'
  end

  # ===========================================================================
  # 12. MappingsController#update: Authenticated User Reaches Action
  # ===========================================================================
  def test_12_authenticated_mapping_update_reaches_action
    $spy.http_patch_response = OpenStruct.new(status: 204, body: '')

    update_params = {
      id: 'http://example.com/mappings/101',
      mapping_type: 'external',
      map_to_external_ontology: 'http://example.com/ontologies/EXT',
      map_to_external_class: 'http://example.com/classes/C2',
      map_from_bioportal_ontology_id: 'ONT1',
      map_from_bioportal_full_id: 'http://example.com/classes/C1',
      mapping: {
        relation: ['http://www.w3.org/2004/02/skos/core#exactMatch'],
        source_contact_info: 'test@example.com',
        source_name: 'test_user',
        name: 'Mapping Test',
        comment: 'Testing update'
      }
    }

    _ctrl, _req, res = dispatch(
      MappingsController,
      :update,
      user: REGULAR_USER,
      params: update_params,
      headers: { 'Accept' => 'text/vnd.turbo-stream.html' }
    )

    assert_equal 200, res.status, 'Authenticated mapping update must return 200 turbo-stream response'
    assert_equal 1, $spy.http_patch_calls, 'Authenticated mapping update MUST reach action and invoke HTTP.patch'
    assert_equal 'http://example.com/mappings/101', $spy.http_patch_args.last[0]
    assert_includes res.body, 'alert-success', 'Successful update must render alert-success'
  end
end
