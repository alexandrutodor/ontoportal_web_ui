# frozen_string_literal: true

require 'minitest/autorun'
require 'logger'
require 'ostruct'
require 'json'

# =============================================================================
# Standalone Offline Catalog Configuration Regression Check (ONTO-T-B11)
#
# Validates the catalog configuration read/write state contract:
# 1. Actual route helper verification: registered admin_catalog_configuration_path
#    exists; typo admin_api_configuration_index_path is absent / raises NoMethodError.
# 2. Pinned SDK characterization: Base#respond_to? is always true, missing reader
#    returns nil; response_successful? confirms status 200/204 only and rejects
#    nil, Base objects, 400, 500.
# 3. Controlled load_catalog_data failure: read timeout / network failure logs
#    safely without calling nonexistent handle_catalog_error, preserves known
#    session state, and does not erase session[:catalog_data].
# 4. Legitimate empty catalog vs malformed response: empty catalog is handled
#    cleanly without error, malformed response is rescued safely.
# 5. Absent taxonomy: nil / missing themeTaxonomy handled without nil.select NoMethodError.
# 6. Metadata failure: empty metadata does not raise secondary view error
#    (attr_metadata.enforce or attr.label on nil) during show rendering.
# 7. Failed write (400 client error): preserves submitted scalar, list, and
#    boolean UI values in @catalog_data and view, preserves last-known session state,
#    does not redirect to success, renders status 422 with flash alert.
# 8. Failed write (500 server error / transport exception): caught safely,
#    sanitizes error, prevents raw credential / config dump in log/flash.
# 9. Confirmed success (200 / 204): HTML redirects to admin_catalog_configuration_path
#    with persistent flash notice; Turbo Stream replaces catalog-config with notice.
# =============================================================================

if Dir.exist?('/usr/local/bundle/ruby/3.1.0/gems') && (ENV['GEM_PATH'].nil? || !ENV['GEM_PATH'].include?('/usr/local/bundle/ruby/3.1.0'))
  Gem.use_paths(nil, Gem.path + ['/usr/local/bundle/ruby/3.1.0'])
end

sdk_lib = '/usr/local/bundle/ruby/3.1.0/bundler/gems/ontologies_api_ruby_client-6257685e5744/lib'
$LOAD_PATH.unshift(sdk_lib) if Dir.exist?(sdk_lib) && !$LOAD_PATH.include?(sdk_lib)

worktree_root = File.expand_path('../..', __dir__)
$LOAD_PATH.unshift(File.join(worktree_root, 'app/helpers'))
$LOAD_PATH.unshift(File.join(worktree_root, 'app/components'))
$LOAD_PATH.unshift(File.join(worktree_root, 'app/controllers/concerns'))
$LOAD_PATH.unshift(File.join(worktree_root, 'app/controllers'))

require 'rails'
require 'action_controller'
require 'action_view'
require 'active_record'
require 'turbo-rails'
require 'haml'
require 'haml/template/options'
require 'haml/plugin'
require 'view_component'
require 'ontologies_api_client'

# Turbo stream and frame setup
module Turbo
  module Streams
  end
end
require '/usr/local/bundle/ruby/3.1.0/gems/turbo-rails-2.0.12/app/helpers/turbo/streams/action_helper.rb' rescue nil
require '/usr/local/bundle/ruby/3.1.0/gems/turbo-rails-2.0.12/app/models/turbo/streams/tag_builder.rb' rescue nil
require '/usr/local/bundle/ruby/3.1.0/gems/turbo-rails-2.0.12/app/controllers/turbo/streams/turbo_streams_tag_builder.rb' rescue nil
require '/usr/local/bundle/ruby/3.1.0/gems/turbo-rails-2.0.12/app/helpers/turbo/frames_helper.rb' rescue nil
require '/usr/local/bundle/ruby/3.1.0/gems/turbo-rails-2.0.12/app/helpers/turbo/streams_helper.rb' rescue nil

Mime::Type.register 'text/vnd.turbo-stream.html', :turbo_stream unless defined?(Mime::TURBO_STREAM) || Mime[:turbo_stream]
ActionController::Base.include Turbo::Streams::TurboStreamsTagBuilder if defined?(Turbo::Streams::TurboStreamsTagBuilder)
ActionController::Renderers.add :turbo_stream do |turbo_streams_html, _options|
  self.content_type = Mime[:turbo_stream] if media_type.nil?
  turbo_streams_html
end

# App configuration and route loading from actual config/routes.rb
$REST_URL = 'http://example.com'
LinkedData::Client.config do |config|
  config.rest_url = 'http://example.com'
  config.links_attr = 'links'
end

module Flipper
  def self.enabled?(*); false; end
  module UI
    def self.app(_); ->(_env) { [200, {}, ['ok']] }; end
  end
end
module Lookbook
  class Engine
    def self.call(_env); [200, {}, ['ok']]; end
  end
end

app = Class.new(Rails::Application) do
  config.eager_load = false
  config.secret_key_base = ('0' * 64)
end
load File.join(worktree_root, 'config/routes.rb')

I18n.load_path = Dir[File.join(worktree_root, 'config/locales/*.yml')]
I18n.default_locale = :en
I18n.locale = :en

# Finite component doubles for template rendering fidelity
module Buttons
  class RegularButtonComponent
    def initialize(**opts); @opts = opts; end
    def render_in(_); "<button id=\"#{@opts[:id]}\">#{@opts[:value]}</button>".html_safe; end
  end
end

module Display
  class AlertComponent
    def initialize(message:, closable: true, type: 'info'); @message = message; @type = type; end
    def render_in(_); "<div class=\"alert alert-#{@type}\">#{@message}</div>".html_safe; end
  end
end

class TabsContainerComponent
  def initialize(**); @contents = []; end
  def item(**); end
  def item_content(&b)
    @contents << @view_context.capture(&b) if block_given?
  end
  def render_in(view_context, &block)
    @view_context = view_context
    view_context.capture(self, &block) if block_given?
    "<div class=\"tabs-container\">#{@contents.join}</div>".html_safe
  end
end

module Input
  class InputFieldComponent
    def initialize(**opts); @opts = opts; end
    def render_in(vc, &b)
      inner = block_given? ? vc.capture(&b) : ''
      "<div class=\"field\"><label>#{@opts[:label]}</label>#{inner}</div>".html_safe
    end
  end
  class TextInputComponent
    def initialize(**opts); @opts = opts; end
    def render_in(_); "<input type=\"text\" name=\"#{@opts[:name]}\" value=\"#{@opts[:value]}\" />".html_safe; end
  end
  class UrlComponent
    def initialize(**opts); @opts = opts; end
    def render_in(_); "<input type=\"url\" name=\"#{@opts[:name]}\" value=\"#{@opts[:value]}\" />".html_safe; end
  end
  class DateComponent
    def initialize(**opts); @opts = opts; end
    def render_in(_); "<input type=\"date\" name=\"#{@opts[:name]}\" value=\"#{@opts[:value]}\" />".html_safe; end
  end
  class NumberComponent
    def initialize(**opts); @opts = opts; end
    def render_in(_); "<input type=\"number\" name=\"#{@opts[:name]}\" value=\"#{@opts[:value]}\" />".html_safe; end
  end
end

class SwitchInputComponent
  def initialize(**opts); @opts = opts; end
  def render_in(_); "<input type=\"checkbox\" name=\"#{@opts[:name]}\" value=\"#{@opts[:value]}\" #{@opts[:checked] ? 'checked' : ''} />".html_safe; end
end

class TurboFrameComponent
  def initialize(id: nil, **); @id = id; end
  def render_in(vc, &b)
    inner = block_given? ? vc.capture(&b) : ''
    "<turbo-frame id=\"#{@id}\">#{inner}</turbo-frame>".html_safe
  end
end

class AgentSearchInputComponent
  def initialize(**opts); @opts = opts; end
  def render_in(_); '<div class="agent-search-input"></div>'.html_safe; end
end

class ChipButtonComponent
  def initialize(text: nil, **opts); @text = text; @opts = opts; end
  def render_in(vc, &b)
    content = @text || (block_given? ? vc.capture(&b) : '')
    "<span class=\"chip\">#{content}</span>".html_safe
  end
end

class SampleQueriesEditComponent
  def initialize(**); end
  def render_in(_); '<div class="sample-queries"></div>'.html_safe; end
end

class NestedFormInputsComponent
  def initialize(**); end
  def header(&b); @header = b.call if block_given?; end
  def template(&b); @template = b.call if block_given?; end
  def empty_state(&b); @empty_state = b.call if block_given?; end
  def row(&b); @rows ||= []; @rows << b.call if block_given?; end
  def render_in(vc, &b)
    @rows = []
    vc.capture(self, &b) if block_given?
    "<div class=\"nested-form\">#{@header}#{@empty_state}#{(@rows || []).join}</div>".html_safe
  end
end

# Require controllers and helpers
module Admin; end
require 'urls_helper'
require 'terms_reuses'
require 'components_helper'
require 'ontologies_helper'
require 'internationalisation_helper'
require 'multi_languages_helper'
require 'modal_helper'
require 'inputs_helper'
require 'application_helper'
require 'agent_helper'
require 'application_controller'
require 'admin/catalog_configuration_helper'
require 'admin/catalog_configuration_controller'
require 'nested_agent_search_input_component'
NestedAgentSearchInputComponent.compile

# Wire helpers to controller and view
ActionController::Base.include Rails.application.routes.url_helpers
ActionView::Base.include Rails.application.routes.url_helpers
ActionView::Base.include Turbo::FramesHelper if defined?(Turbo::FramesHelper)
ActionView::Base.include Turbo::StreamsHelper if defined?(Turbo::StreamsHelper)
ActionView::Base.include Turbo::Streams::ActionHelper if defined?(Turbo::Streams::ActionHelper)
ActionView::Base.include ActionView::Helpers::TranslationHelper
ActionView::Base.include ActionView::Helpers::TagHelper
ActionView::Base.include ActionView::Helpers::FormHelper
ActionView::Base.include ActionView::Helpers::FormTagHelper
ActionView::Base.include ActionView::Helpers::UrlHelper
ActionView::Base.include InputsHelper
ActionView::Base.include ComponentsHelper
ActionView::Base.include Admin::CatalogConfigurationHelper
ActionView::Base.include MultiLanguagesHelper
ActionView::Base.include AgentHelper

module ViewDoubles
  def rounded_button_component(*); '<button>btn</button>'.html_safe; end
  def description_tooltip(l, _d, **); "<span>#{l}</span>".html_safe; end
  def portal_name; 'MatPortal'; end
  def selected_section?(*); false; end
  def ontologies_selector(**opts); "<select name=\"#{opts[:name]}\"></select>".html_safe; end
  def agent_search_input(*); '<input type="text" />'.html_safe; end
  def current_user_admin?; true; end
  def current_user; nil; end
  def inline_svg_tag(*); '<svg></svg>'.html_safe; end
  def agents_enabled?; false; end
  def onts_for_select; []; end
end
ActionView::Base.include ViewDoubles

module ApplicationHelper
  def ontologies_selector(**opts); "<select name=\"#{opts[:name]}\"></select>".html_safe; end
  def onts_for_select; []; end
end

ActionController::Base.allow_forgery_protection = false
ActionController::Base.logger = Logger.new(nil)
Rails.logger = Logger.new(nil)

Admin::CatalogConfigurationController.prepend_view_path(File.join(worktree_root, 'app/views'))
Admin::CatalogConfigurationController.skip_before_action :set_locale, :domain_ontology_set, :init_trial_license, raise: false
Admin::CatalogConfigurationController.layout false

# Test Harness
class CatalogConfigCheck < Minitest::Test
  def setup
    I18n.locale = :en
    @orig_get = LinkedData::Client::HTTP.method(:get) if LinkedData::Client::HTTP.respond_to?(:get)
    @orig_patch = LinkedData::Client::HTTP.method(:patch) if LinkedData::Client::HTTP.respond_to?(:patch)
  end

  def teardown
    # Restore singleton methods if patched
    LinkedData::Client::HTTP.singleton_class.send(:define_method, :get, @orig_get) if @orig_get
    LinkedData::Client::HTTP.singleton_class.send(:define_method, :patch, @orig_patch) if @orig_patch
  end

  # Helper to dispatch an action against Admin::CatalogConfigurationController
  def dispatch(action, method: :get, params: {}, headers: {}, session: {})
    ctrl = Admin::CatalogConfigurationController.new
    req = ActionDispatch::TestRequest.create
    req.request_method = method.to_s.upcase
    headers.each { |k, v| req.headers[k] = v }
    params.each { |k, v| req.params[k] = v }
    req.set_header 'rack.session', session.merge(user: OpenStruct.new(admin?: true))
    req.set_header 'action_dispatch.request.flash_hash', ActionDispatch::Flash::FlashHash.new
    res = ActionDispatch::TestResponse.create
    ctrl.set_request!(req)
    ctrl.set_response!(res)
    ctrl.process(action)
    [ctrl, req, res]
  end

  # ===========================================================================
  # 1. Route Verification & Registered Helper Contract
  # ===========================================================================

  def test_routes_defines_admin_catalog_configuration_path
    url_helpers = Rails.application.routes.url_helpers
    assert url_helpers.respond_to?(:admin_catalog_configuration_path),
           'Expected registered route helper admin_catalog_configuration_path to exist'
    assert_equal '/admin/catalog_configuration', url_helpers.admin_catalog_configuration_path
  end

  def test_routes_does_not_define_admin_api_configuration_index_path
    url_helpers = Rails.application.routes.url_helpers
    refute url_helpers.respond_to?(:admin_api_configuration_index_path),
           'admin_api_configuration_index_path should not be defined in actual routes'
    assert_raises(NoMethodError) do
      url_helpers.admin_api_configuration_index_path
    end
  end

  # ===========================================================================
  # 2. Pinned SDK HTTP Behavior & Confirmation Characterization
  # ===========================================================================

  def test_sdk_base_respond_to_always_true_and_missing_returns_nil
    base_instance = LinkedData::Client::Base.new(values: { title: 'Test' })
    assert base_instance.respond_to?(:status), 'Base#respond_to? is always true by design'
    assert_nil base_instance.status, 'Missing reader on Base must return nil'
    assert base_instance.respond_to?(:nonexistent_method)
    assert_nil base_instance.nonexistent_method
  end

  def test_response_successful_boundary_check
    ctrl = Admin::CatalogConfigurationController.new

    # nil or Base objects must not be treated as success
    refute ctrl.send(:response_successful?, nil), 'nil response must not be successful'
    base_instance = LinkedData::Client::Base.new(values: { title: 'Test' })
    refute ctrl.send(:response_successful?, base_instance), 'Base instance without status must not be successful'

    # Non-200/204 Faraday / OpenStruct responses must be rejected
    refute ctrl.send(:response_successful?, OpenStruct.new(status: 400)), 'Status 400 must fail'
    refute ctrl.send(:response_successful?, OpenStruct.new(status: 422)), 'Status 422 must fail'
    refute ctrl.send(:response_successful?, OpenStruct.new(status: 500)), 'Status 500 must fail'

    # Confirmed 200 and 204 are the only accepted successes
    assert ctrl.send(:response_successful?, OpenStruct.new(status: 200)), 'Status 200 must succeed'
    assert ctrl.send(:response_successful?, OpenStruct.new(status: 204)), 'Status 204 must succeed'
    assert ctrl.send(:response_successful?, OpenStruct.new(status: '200')), 'String status 200 must succeed'
    assert ctrl.send(:response_successful?, OpenStruct.new(status: '204')), 'String status 204 must succeed'
  end

  # ===========================================================================
  # 3. Controlled load_catalog_data Failure & Session Preservation
  # ===========================================================================

  def test_load_catalog_data_timeout_rescues_and_preserves_session_data
    LinkedData::Client::HTTP.singleton_class.send(:define_method, :get) do |_url, _params|
      raise StandardError, 'execution expired (timeout)'
    end

    session_before = { title: 'Prior Known Title', acronym: 'PKT' }
    ctrl, _req, res = dispatch(:show, session: { catalog_data: session_before })

    assert_equal 200, res.status
    # Verify nonexistent handle_catalog_error was not called (would raise NoMethodError)
    assert_equal 'Prior Known Title', ctrl.instance_variable_get(:@catalog_data)[:title]
    assert_equal session_before, ctrl.session[:catalog_data],
                 'load_catalog_data rescue must not overwrite session[:catalog_data] with {}'
    assert ctrl.flash.now[:alert].present?, 'Alert flash must be set on load failure'
  end

  # ===========================================================================
  # 4. Legitimate Empty Catalog vs Malformed Response
  # ===========================================================================

  def test_load_catalog_data_legitimate_empty_catalog
    # When API returns 200 with {}, SDK recursive_struct returns nil or empty
    LinkedData::Client::HTTP.singleton_class.send(:define_method, :get) do |_url, _params|
      nil
    end

    ctrl, _req, res = dispatch(:show, session: {})
    assert_equal 200, res.status
    data = ctrl.instance_variable_get(:@catalog_data)
    assert_kind_of Hash, data
    assert_equal [], data[:themeTaxonomy]
    assert_nil ctrl.flash.now[:alert], 'Legitimate empty catalog should not set alert flash'
  end

  def test_load_catalog_data_malformed_response_handled_cleanly
    LinkedData::Client::HTTP.singleton_class.send(:define_method, :get) do |_url, _params|
      raise JSON::ParserError, 'unexpected token at bad json'
    end

    ctrl, _req, res = dispatch(:show, session: { catalog_data: { acronym: 'SAVED' } })
    assert_equal 200, res.status
    assert_equal 'SAVED', ctrl.instance_variable_get(:@catalog_data)[:acronym]
    assert_equal({ acronym: 'SAVED' }, ctrl.session[:catalog_data])
    assert ctrl.flash.now[:alert].present?
  end

  def test_load_catalog_data_rejects_parsed_sdk_error_and_preserves_session
    # When API returns 4xx with { errors: [...] }, SDK parses it to OpenStruct
    LinkedData::Client::HTTP.singleton_class.send(:define_method, :get) do |_url, params|
      if params && params[:include] && params[:include].include?('creator')
        []
      else
        OpenStruct.new(errors: ['Catalog unavailable'])
      end
    end

    session_before = { title: 'Known title', acronym: 'KT' }
    ctrl, _req, res = dispatch(:show, session: { catalog_data: session_before })

    assert_equal 200, res.status
    assert_equal 'Known title', ctrl.instance_variable_get(:@catalog_data)[:title]
    assert_equal session_before, ctrl.session[:catalog_data],
                 'Parsed SDK error response must not overwrite session[:catalog_data]'
    assert ctrl.flash.now[:alert].present?, 'Alert flash must be set when SDK returns parsed error'
    assert_includes ctrl.flash.now[:alert], 'Problem retrieving catalog data'
  end

  # ===========================================================================
  # 5. Absent Taxonomy Handling
  # ===========================================================================

  def test_absent_taxonomy_does_not_raise_nil_select
    ctrl = Admin::CatalogConfigurationController.new
    # themeTaxonomy missing or nil
    sanitized = ctrl.send(:sanitize_catalog_data, { title: 'No Taxonomy', themeTaxonomy: nil })
    assert_equal [], sanitized[:themeTaxonomy], 'nil themeTaxonomy must sanitize to [] without raising nil.select'

    sanitized_empty = ctrl.send(:sanitize_catalog_data, {})
    assert_equal [], sanitized_empty[:themeTaxonomy]
  end

  # ===========================================================================
  # 6. Metadata Failure and Secondary View Error Prevention
  # ===========================================================================

  def test_metadata_load_failure_renders_show_without_view_error
    LinkedData::Client::HTTP.singleton_class.send(:define_method, :get) do |url, _params|
      if url.include?('catalog_metadata')
        raise StandardError, 'Metadata service unavailable'
      else
        { title: 'My Site', acronym: 'MS' }
      end
    end

    ctrl, _req, res = dispatch(:show, session: {})
    assert_equal 200, res.status
    assert_equal({}, ctrl.instance_variable_get(:@catalog_metadata))
    # Crucial check: show.html.haml renders without raising NoMethodError on attr_metadata.enforce or attr.label
    assert res.body.include?('turbo-frame id="catalog-config"'), 'Show template should render successfully'
    assert ctrl.flash.now[:alert].present?
  end

  # ===========================================================================
  # 7. Failed Write (400 Client Error): Preserves Submitted State
  # ===========================================================================

  def test_failed_patch_400_preserves_submitted_inputs_in_html_and_turbo
    # Provide mock metadata for show rendering
    attr_metadata_mock = {
      'title' => OpenStruct.new(attribute: 'title', enforce: ['string']),
      'keyword' => OpenStruct.new(attribute: 'keyword', enforce: ['list']),
      'status' => OpenStruct.new(attribute: 'status', enforce: ['boolean']),
      'themeTaxonomy' => OpenStruct.new(attribute: 'themeTaxonomy', enforce: ['list']),
      'creator' => OpenStruct.new(attribute: 'creator', enforce: ['Agent']),
      'rightsHolder' => OpenStruct.new(attribute: 'rightsHolder', enforce: ['Agent', 'no_list'])
    }

    LinkedData::Client::HTTP.singleton_class.send(:define_method, :get) do |url, _params|
      if url.include?('catalog_metadata')
        attr_metadata_mock.values
      else
        []
      end
    end
    LinkedData::Client::HTTP.singleton_class.send(:define_method, :patch) do |_url, _body|
      OpenStruct.new(status: 400, body: JSON.dump({ error: 'Acronym format invalid' }))
    end

    cached_agent_1 = OpenStruct.new(id: 'http://example.com/Agents/1', name: 'Alice', agentType: 'person', usages: [])
    cached_agent_2 = OpenStruct.new(id: 'http://example.com/Agents/2', name: 'Org', agentType: 'organization', usages: [])
    prior_session = {
      acronym: 'PRIOR_ACR',
      title: 'Prior Title',
      creator: [cached_agent_1],
      rightsHolder: cached_agent_2
    }

    submitted_config = {
      title: 'Submitted Title',
      keyword: ['scalar_val', 'second_val'],
      status: 'true',
      themeTaxonomy: ['', 'MESH', 'GO'],
      creator: {
        '0' => { 'id' => 'http://example.com/Agents/1' },
        '1' => { 'id' => 'http://example.com/Agents/999' }
      },
      rightsHolder: {
        '0' => { 'id' => 'http://example.com/Agents/2' }
      }
    }

    # Test HTML format
    ctrl_html, _req_html, res_html = dispatch(
      :update,
      method: :patch,
      params: { config: submitted_config },
      headers: { 'Accept' => 'text/html' },
      session: { catalog_data: prior_session, catalog_metadata: attr_metadata_mock }
    )
    assert_equal 422, res_html.status, 'Failed HTML update must return status 422'
    assert_nil res_html.headers['Location'], 'Failed HTML update must not redirect'
    assert_equal 'Submitted Title', ctrl_html.instance_variable_get(:@catalog_data)[:title]
    assert_equal ['scalar_val', 'second_val'], ctrl_html.instance_variable_get(:@catalog_data)[:keyword]
    assert_equal true, ctrl_html.instance_variable_get(:@catalog_data)[:status]
    assert_equal ['MESH', 'GO'], ctrl_html.instance_variable_get(:@catalog_data)[:themeTaxonomy]

    # Verify agent preservation in controller data
    creators = ctrl_html.instance_variable_get(:@catalog_data)[:creator]
    assert_kind_of Array, creators
    assert_equal 2, creators.size
    assert_equal 'http://example.com/Agents/1', creators[0].id
    assert_equal 'Alice', creators[0].name
    assert_equal 'http://example.com/Agents/999', creators[1].id
    rights_holder = ctrl_html.instance_variable_get(:@catalog_data)[:rightsHolder]
    assert_equal 'http://example.com/Agents/2', rights_holder.id
    assert_equal 'Org', rights_holder.name, 'Known singleton OpenStruct name must be retained'
    assert_equal 'organization', rights_holder.agentType, 'Known singleton OpenStruct agentType must be retained'

    assert_equal prior_session, ctrl_html.session[:catalog_data],
                 'Session catalog data must remain unpolluted by rejected update'
    assert_includes ctrl_html.flash.now[:alert], 'HTTP 400'
    refute_includes ctrl_html.flash.now[:alert], 'Acronym format invalid', 'Raw response body must not leak into flash'

    # Verify rendered HTML contains submitted fields and nested agent inputs without rendering crash
    assert res_html.body.include?('Submitted Title'), 'Rendered HTML form must retain submitted title'
    assert res_html.body.include?('name="config[creator][0][id]"'), 'Rendered HTML must retain first creator hidden input'
    assert res_html.body.include?('value="http://example.com/Agents/1"'), 'Rendered HTML must retain first creator ID'
    assert res_html.body.include?('Alice'), 'Rendered HTML must retain first creator name'
    assert res_html.body.include?('name="config[creator][1][id]"'), 'Rendered HTML must retain second creator hidden input'
    assert res_html.body.include?('value="http://example.com/Agents/999"'), 'Rendered HTML must retain unresolved creator ID'
    assert res_html.body.include?('name="config[rightsHolder][0][id]"'), 'Rendered HTML must retain rightsHolder hidden input'
    assert res_html.body.include?('value="http://example.com/Agents/2"'), 'Rendered HTML must retain rightsHolder ID'
    assert res_html.body.include?('Org'), 'Rendered HTML must retain known singleton agent name'
    assert res_html.body.include?('parent_id=rightsHolder') && res_html.body.include?('agent_type=organization'),
           'Rendered HTML must retain known singleton replacement link'

    # Test Turbo Stream format
    ctrl_turbo, _req_turbo, res_turbo = dispatch(
      :update,
      method: :patch,
      params: { config: submitted_config },
      headers: { 'Accept' => 'text/vnd.turbo-stream.html' },
      session: { catalog_data: prior_session, catalog_metadata: attr_metadata_mock }
    )
    assert_equal 422, res_turbo.status, 'Failed Turbo update must return status 422'
    assert res_turbo.body.include?('target="catalog-config"'), 'Turbo stream must target catalog-config'
    assert res_turbo.body.include?('action="replace"'), 'Turbo stream must replace catalog-config'
    assert res_turbo.body.include?('Submitted Title'), 'Turbo stream must contain submitted title'
    assert res_turbo.body.include?('name="config[creator][0][id]"')
    assert res_turbo.body.include?('value="http://example.com/Agents/1"')
    assert res_turbo.body.include?('Alice')
    assert res_turbo.body.include?('name="config[creator][1][id]"')
    assert res_turbo.body.include?('value="http://example.com/Agents/999"')
    assert res_turbo.body.include?('name="config[rightsHolder][0][id]"')
    assert res_turbo.body.include?('value="http://example.com/Agents/2"')
    assert res_turbo.body.include?('Org')
    assert res_turbo.body.include?('parent_id=rightsHolder') && res_turbo.body.include?('agent_type=organization')
    assert_includes ctrl_turbo.flash.now[:alert], 'HTTP 400'

    # Verify cached Hash agent normalization and rendering for both list and singleton shapes
    hash_creator = { 'id' => 'http://example.com/Agents/3', 'name' => 'Carol Hash', 'agentType' => 'person' }
    hash_rights_holder = { 'id' => 'http://example.com/Agents/4', 'name' => 'Hash Org', 'agentType' => 'organization' }
    hash_minimal = { 'id' => 'http://example.com/Agents/5' }
    hash_session = {
      acronym: 'HASH_ACR',
      title: 'Hash Prior Title',
      creator: [hash_creator, hash_minimal],
      rightsHolder: hash_rights_holder
    }
    submitted_hash_config = {
      title: 'Submitted Hash Title',
      creator: {
        '0' => { 'id' => 'http://example.com/Agents/3' },
        '1' => { 'id' => 'http://example.com/Agents/5' }
      },
      rightsHolder: {
        '0' => { 'id' => 'http://example.com/Agents/4' }
      }
    }

    ctrl_h_html, _req_h_html, res_h_html = dispatch(
      :update,
      method: :patch,
      params: { config: submitted_hash_config },
      headers: { 'Accept' => 'text/html' },
      session: { catalog_data: hash_session, catalog_metadata: attr_metadata_mock }
    )
    assert_equal 422, res_h_html.status

    h_creators = ctrl_h_html.instance_variable_get(:@catalog_data)[:creator]
    assert_kind_of Array, h_creators
    assert_equal 2, h_creators.size
    refute h_creators[0].is_a?(Hash), 'Cached Hash creator must be normalized out of raw Hash representation'
    assert_equal 'http://example.com/Agents/3', h_creators[0].id
    assert_equal 'Carol Hash', h_creators[0].name
    assert_equal 'person', h_creators[0].agentType
    assert_equal 'http://example.com/Agents/5', h_creators[1].id

    h_rh = ctrl_h_html.instance_variable_get(:@catalog_data)[:rightsHolder]
    refute h_rh.is_a?(Hash), 'Cached Hash rightsHolder must be normalized out of raw Hash representation'
    assert_equal 'http://example.com/Agents/4', h_rh.id
    assert_equal 'Hash Org', h_rh.name
    assert_equal 'organization', h_rh.agentType

    # Rendered HTML preservation for cached Hash agents
    assert res_h_html.body.include?('name="config[creator][0][id]"'), 'Rendered HTML must retain cached Hash creator hidden input'
    assert res_h_html.body.include?('value="http://example.com/Agents/3"'), 'Rendered HTML must retain cached Hash creator ID'
    assert res_h_html.body.include?('Carol Hash'), 'Rendered HTML must retain cached Hash creator name'
    assert res_h_html.body.include?('name="config[creator][1][id]"'), 'Rendered HTML must retain minimal cached Hash hidden input'
    assert res_h_html.body.include?('value="http://example.com/Agents/5"'), 'Rendered HTML must retain minimal cached Hash ID'
    assert res_h_html.body.include?('name="config[rightsHolder][0][id]"'), 'Rendered HTML must retain cached Hash rightsHolder hidden input'
    assert res_h_html.body.include?('value="http://example.com/Agents/4"'), 'Rendered HTML must retain cached Hash rightsHolder ID'
    assert res_h_html.body.include?('Hash Org'), 'Rendered HTML must retain cached Hash rightsHolder name'
    assert res_h_html.body.include?('parent_id=rightsHolder') && res_h_html.body.include?('agent_type=organization'),
           'Rendered HTML must retain cached Hash replacement link'

    # Turbo format for cached Hash agents
    _ctrl_h_turbo, _req_h_turbo, res_h_turbo = dispatch(
      :update,
      method: :patch,
      params: { config: submitted_hash_config },
      headers: { 'Accept' => 'text/vnd.turbo-stream.html' },
      session: { catalog_data: hash_session, catalog_metadata: attr_metadata_mock }
    )
    assert_equal 422, res_h_turbo.status
    assert res_h_turbo.body.include?('name="config[creator][0][id]"')
    assert res_h_turbo.body.include?('value="http://example.com/Agents/3"')
    assert res_h_turbo.body.include?('Carol Hash')
    assert res_h_turbo.body.include?('name="config[creator][1][id]"')
    assert res_h_turbo.body.include?('value="http://example.com/Agents/5"')
    assert res_h_turbo.body.include?('name="config[rightsHolder][0][id]"')
    assert res_h_turbo.body.include?('value="http://example.com/Agents/4"')
    assert res_h_turbo.body.include?('Hash Org')
    assert res_h_turbo.body.include?('parent_id=rightsHolder') && res_h_turbo.body.include?('agent_type=organization')
  end

  # ===========================================================================
  # 8. Failed Write (500 Server Error / Transport Exception): Error Sanitization
  # ===========================================================================

  def test_failed_patch_500_transport_exception_sanitizes_error_and_preserves_inputs
    LinkedData::Client::HTTP.singleton_class.send(:define_method, :get) do |_url, _params|
      []
    end
    LinkedData::Client::HTTP.singleton_class.send(:define_method, :patch) do |_url, _body|
      # Simulate server error body containing sensitive internals / credentials
      raise StandardError, '{"db_password":"secret","internal_url":"http://secret.internal"}'
    end

    ctrl, _req, res = dispatch(
      :update,
      method: :patch,
      params: { config: { title: 'Attempted Write' } },
      headers: { 'Accept' => 'text/html' }
    )
    assert_equal 422, res.status
    alert_msg = ctrl.flash.now[:alert]
    refute_includes alert_msg, 'secret', 'Raw credentials/internals must not leak into visible error'
    assert_includes alert_msg, 'HTTP 500'
    assert_equal 'Attempted Write', ctrl.instance_variable_get(:@catalog_data)[:title]
  end

  def test_failed_patch_400_sanitizes_credentials_in_json_and_plain_body
    LinkedData::Client::HTTP.singleton_class.send(:define_method, :get) do |_url, _params|
      []
    end

    # Case A: JSON body with credential sentinel
    LinkedData::Client::HTTP.singleton_class.send(:define_method, :patch) do |_url, _body|
      OpenStruct.new(status: 400, body: JSON.dump({ error: 'api_key=SENTINEL_JSON_SECRET', token: 'SECRET_TOKEN' }))
    end

    ctrl_json, _req_json, res_json = dispatch(
      :update,
      method: :patch,
      params: { config: { title: 'Test Write' } },
      headers: { 'Accept' => 'text/html' }
    )
    assert_equal 422, res_json.status
    alert_json = ctrl_json.flash.now[:alert]
    refute_includes alert_json, 'SENTINEL_JSON_SECRET', 'Upstream JSON error sentinel must not leak into flash'
    refute_includes alert_json, 'api_key', 'Credential param names must not leak into flash'
    assert_includes alert_json, 'HTTP 400'

    # Case B: Plain text body with credential sentinel
    LinkedData::Client::HTTP.singleton_class.send(:define_method, :patch) do |_url, _body|
      OpenStruct.new(status: 400, body: 'api_key=SENTINEL_PLAIN_SECRET rejected by gateway')
    end

    ctrl_plain, _req_plain, res_plain = dispatch(
      :update,
      method: :patch,
      params: { config: { title: 'Test Write 2' } },
      headers: { 'Accept' => 'text/html' }
    )
    assert_equal 422, res_plain.status
    alert_plain = ctrl_plain.flash.now[:alert]
    refute_includes alert_plain, 'SENTINEL_PLAIN_SECRET', 'Upstream plain error sentinel must not leak into flash'
    refute_includes alert_plain, 'api_key'
    assert_includes alert_plain, 'HTTP 400'
  end

  # ===========================================================================
  # 9. Confirmed Success (200 OK)
  # ===========================================================================

  def test_confirmed_success_200_html_redirect_and_turbo_replace
    remote_data = { title: 'Confirmed Remote Title', acronym: 'CRT' }
    LinkedData::Client::HTTP.singleton_class.send(:define_method, :get) do |_url, _params|
      remote_data
    end
    LinkedData::Client::HTTP.singleton_class.send(:define_method, :patch) do |_url, _body|
      OpenStruct.new(status: 200, body: JSON.dump(remote_data))
    end

    # HTML format
    ctrl_html, _req_html, res_html = dispatch(
      :update,
      method: :patch,
      params: { config: { title: 'New Title' } },
      headers: { 'Accept' => 'text/html' }
    )
    assert_equal 302, res_html.status, 'HTML confirmed success must redirect'
    assert_equal 'http://test.host/admin/catalog_configuration', res_html.headers['Location'],
                 'Must redirect to registered admin_catalog_configuration_path'
    assert_equal 'Configuration updated successfully', ctrl_html.flash[:notice],
                 'Notice must be in persistent flash for redirect'

    # Turbo Stream format
    ctrl_turbo, _req_turbo, res_turbo = dispatch(
      :update,
      method: :patch,
      params: { config: { title: 'New Title' } },
      headers: { 'Accept' => 'text/vnd.turbo-stream.html' }
    )
    assert_equal 200, res_turbo.status
    assert res_turbo.body.include?('target="catalog-config"')
    assert res_turbo.body.include?('action="replace"')
    assert_equal 'Configuration updated successfully', ctrl_turbo.flash.now[:notice]
  end

  # ===========================================================================
  # 10. Confirmed Success (204 No Content)
  # ===========================================================================

  def test_confirmed_success_204_html_redirect_and_turbo_replace
    remote_data = { title: 'Refreshed 204 Title' }
    LinkedData::Client::HTTP.singleton_class.send(:define_method, :get) do |_url, _params|
      remote_data
    end
    LinkedData::Client::HTTP.singleton_class.send(:define_method, :patch) do |_url, _body|
      OpenStruct.new(status: 204, body: '')
    end

    ctrl_html, _req_html, res_html = dispatch(
      :update,
      method: :patch,
      params: { config: { title: 'Update 204' } },
      headers: { 'Accept' => 'text/html' }
    )
    assert_equal 302, res_html.status
    assert_equal 'http://test.host/admin/catalog_configuration', res_html.headers['Location']
    assert_equal 'Configuration updated successfully', ctrl_html.flash[:notice]

    ctrl_turbo, _req_turbo, res_turbo = dispatch(
      :update,
      method: :patch,
      params: { config: { title: 'Update 204' } },
      headers: { 'Accept' => 'text/vnd.turbo-stream.html' }
    )
    assert_equal 200, res_turbo.status
    assert res_turbo.body.include?('target="catalog-config"')
    assert res_turbo.body.include?('action="replace"')
  end

  # ===========================================================================
  # 11. Absent and Empty Config Validation (R4)
  # ===========================================================================

  def test_absent_and_empty_config_rejected_without_patch
    patch_called = false
    LinkedData::Client::HTTP.singleton_class.send(:define_method, :patch) do |_url, _body|
      patch_called = true
      OpenStruct.new(status: 200, body: '{}')
    end

    # Case A: Absent config parameter
    assert_raises(ActionController::ParameterMissing) do
      dispatch(:update, method: :patch, params: {})
    end
    refute patch_called, 'PATCH must not be called when config is absent'

    # Case B: Empty config parameter
    assert_raises(ActionController::ParameterMissing) do
      dispatch(:update, method: :patch, params: { config: {} })
    end
    refute patch_called, 'PATCH must not be called when config is empty'
  end
end
