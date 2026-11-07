# frozen_string_literal: true

require 'minitest/autorun'
require 'minitest/mock'
require 'ostruct'

# =============================================================================
# Standalone Offline Rendered Component Response Regression Test (ONTO-T-B13)
#
# Validates the B13 contract for already-rendered component HTML responses:
# 1. SubmissionsController#edit_properties renders already-rendered helper output
#    via normal Rails html rendering (render html:) ONCE without ERB re-evaluation.
# 2. SearchHelper#render_search_paginated_list returns paginated_list_component
#    directly on non-show-count branch without invoking render inline.
# 3. SearchHelper#render_search_paginated_list preserves Turbo Stream array on show_count branch.
# 4. SchemesController#index renders paginated list via render html: without ERB evaluation.
# 5. CollectionsController#index renders paginated list via render html: without ERB evaluation.
# 6. PropertiesController#index renders paginated list via render html: without ERB evaluation.
# 7. InstancesController#index renders paginated list via render html: on standard / page > 1 requests.
# 8. InstancesController#index preserves turbo_stream: branch for concept instances on page 1.
# 9. Harmless literal ERB arithmetic (<%= 7 * 6 %> / <%= 9 * 9 %>) stays literal in all responses.
# 10. Container IDs, single producer calls, content types, and HTTP statuses are preserved.
# =============================================================================

# In native container (onto-q02-proof:af254f34), gems are located in /usr/local/bundle/ruby/3.1.0
if Dir.exist?('/usr/local/bundle/ruby/3.1.0/gems') && (ENV['GEM_PATH'].nil? || !ENV['GEM_PATH'].include?('/usr/local/bundle/ruby/3.1.0'))
  Gem.use_paths(nil, Gem.path + ['/usr/local/bundle/ruby/3.1.0'])
end

NATIVE_IMAGE_ENV = Dir.exist?('/usr/local/bundle/ruby/3.1.0/gems')

begin
  require 'action_controller'
  require 'action_view'

  ActionController::Renderers.add :turbo_stream do |html, _options|
    self.content_type ||= 'text/vnd.turbo-stream.html; charset=utf-8'
    self.response_body = html.is_a?(Array) ? html.join : html.to_s
  end

  class ApplicationController < ActionController::Base
    def determine_layout; false; end
    def authorize_and_redirect; end
    def authorize_read_only; end
    def submission_metadata; end
    def ontology_not_found(_id); end
    def request_lang; 'en'; end
  end

  FRAMEWORK_MODE = "real Rails ActionController/ActionView #{ActionPack::VERSION::STRING}"
rescue LoadError => e
  raise "Native container environment detected but failed to load Rails libraries: #{e}" if NATIVE_IMAGE_ENV

  class Object
    def presence
      present? ? self : nil
    end

    def present?
      !blank?
    end

    def blank?
      respond_to?(:empty?) ? !!empty? : !self
    end
  end

  class String
    def blank?
      strip.empty?
    end

    def html_safe
      SafeBuffer.new(self)
    end
  end

  class SafeBuffer < String
    def html_safe?; true; end
    def to_s; self; end
  end

  module Rack
    module MockRequest
      def self.env_for(uri)
        { 'PATH_INFO' => uri }
      end
    end
  end

  module ActionDispatch
    class Request
      attr_reader :env, :params

      def initialize(env)
        @env = env
        @params = {}
        if (query = env['PATH_INFO']&.split('?')&.at(1))
          query.split('&').each do |pair|
            k, v = pair.split('=')
            @params[k.to_sym] = v
            @params[k] = v
          end
        end
      end
    end

    class Response
      attr_accessor :status, :content_type, :body

      def initialize
        @status = 200
        @content_type = nil
        @body = +''
      end
    end
  end

  class ApplicationController
    def self.layout(*); end
    def self.before_action(*); end

    attr_accessor :params, :response

    def render(options = {})
      @response ||= ActionDispatch::Response.new
      if options[:inline]
        @response.status = 200
        @response.content_type = 'text/html; charset=utf-8'
        @response.body = ERB.new(options[:inline].to_s).result
      elsif options[:html]
        @response.status = 200
        @response.content_type = 'text/html; charset=utf-8'
        @response.body = options[:html].to_s
      elsif options[:turbo_stream]
        @response.status = 200
        @response.content_type = 'text/vnd.turbo-stream.html; charset=utf-8'
        stream = options[:turbo_stream]
        @response.body = stream.is_a?(Array) ? stream.join : stream.to_s
      end
    end

    def dispatch(action, req, res)
      @params = req.params
      @response = res
      send(action)
    end

    def ontology_not_found(_id); end
    def request_lang; 'en'; end
  end

  module ActionView
    module Helpers
      module TagHelper
        def content_tag(tag, content = nil, &block)
          inner = block ? block.call : content
          "<#{tag}>#{inner}</#{tag}>".html_safe
        end
      end
    end
  end

  FRAMEWORK_MODE = 'host fallback (lightweight doubles)'
end

puts "[Framework Mode] #{FRAMEWORK_MODE}"

module SubmissionUpdater; end
module OntologyUpdater; end
module SubmissionsHelper; end
module SchemesHelper; end
module SearchContent; end
module CollectionsHelper; end
module TurboHelper; end
module TermsReuses; end
module PropertiesHelper; end
module InstancesHelper; end

module LinkedData
  module Client
    module Models
      class Ontology
        def self.find_by_acronym(_acr); end
      end
    end
  end
end

# Load actual modified files
require_relative '../../app/helpers/search_helper'
require_relative '../../app/controllers/submissions_controller'
require_relative '../../app/controllers/schemes_controller'
require_relative '../../app/controllers/collections_controller'
require_relative '../../app/controllers/properties_controller'
require_relative '../../app/controllers/instances_controller'

class TestPaginatedHelperContext
  include ActionView::Helpers::TagHelper
  include SearchHelper

  attr_accessor :controller, :producer_calls

  def initialize(controller)
    @controller = controller
    @producer_calls = 0
  end

  def params
    @controller.params
  end

  def request_lang
    'en'
  end

  def escape(val)
    val.to_s
  end

  def replace(target, content)
    %(<turbo-stream action="replace" target="#{target}"><template>#{content}</template></turbo-stream>).html_safe
  end

  def prepend(target, content)
    %(<turbo-stream action="prepend" target="#{target}"><template>#{content}</template></turbo-stream>).html_safe
  end

  def paginated_list_component(id:, results:, next_page_url:, child_url:, child_turbo_frame:, child_param:, **_kwargs)
    @producer_calls += 1
    %(<div id="#{id}">component item <%= 7 * 6 %></div>).html_safe
  end
end

class RenderedComponentResponseRegressionTest < Minitest::Test
  def setup_controller_invocation(klass, action, env_uri)
    ctrl = klass.new
    env = Rack::MockRequest.env_for(env_uri)
    req = ActionDispatch::Request.new(env)
    res = ActionDispatch::Response.new
    helper = TestPaginatedHelperContext.new(ctrl)

    ctrl.define_singleton_method(:helpers) { helper }
    ctrl.define_singleton_method(:search_ontologies_content) do |**_args|
      results = [{ name: 'TEST' }, { name: 'item1' }]
      [results, 1, 2, 10]
    end

    explore_double = Object.new
    explore_double.define_singleton_method(:latest_submission) do |*_args|
      OpenStruct.new(uriRegexPattern: nil, preferredNamespaceUri: nil)
    end
    onto = OpenStruct.new(acronym: 'TEST', explore: explore_double)

    LinkedData::Client::Models::Ontology.stub(:find_by_acronym, [onto]) do
      ctrl.dispatch(action, req, res)
    end

    [res, helper]
  end

  def test_framework_mode_asserted
    if NATIVE_IMAGE_ENV
      assert_match(/real Rails ActionController\/ActionView 7\.0\.8/, FRAMEWORK_MODE,
                   'Native container execution must use real Rails 7.0.8 libraries')
    else
      assert_match(/host fallback/, FRAMEWORK_MODE,
                   'Host execution without gems must report host fallback')
    end
  end

  def test_submissions_controller_edit_properties_renders_html_once_without_erb_evaluation
    controller = SubmissionsController.new
    env = Rack::MockRequest.env_for('/ontologies/TEST/submissions/1/edit_properties?container_id=ontology-content-0')
    req = ActionDispatch::Request.new(env)
    res = ActionDispatch::Response.new

    controller.define_singleton_method(:display_submission_attributes) do |*args, **kwargs|
      @submission = Object.new
    end

    producer_calls = 0
    mock_helpers = Object.new
    mock_helpers.define_singleton_method(:render_submission_inputs) do |frame_id, _submission|
      producer_calls += 1
      "<turbo-frame id=\"#{frame_id}\"><div class=\"field\"><%= 7 * 6 %></div></turbo-frame>".html_safe
    end

    controller.define_singleton_method(:helpers) { mock_helpers }

    controller.dispatch(:edit_properties, req, res)

    assert_equal 200, res.status, 'Expected HTTP 200 OK'
    assert_includes res.content_type, 'text/html', 'Expected text/html content-type'
    assert_equal 1, producer_calls, 'Producer helper render_submission_inputs must be invoked exactly once'
    assert_includes res.body, '<%= 7 * 6 %>', 'Harmless literal ERB arithmetic must remain literal bytes'
    refute_includes res.body, '42', 'Literal ERB must never be evaluated in already-rendered component HTML'
    assert_includes res.body, '<turbo-frame id="ontology-content-0">', 'TurboFrame ID and container structure preserved'
  end

  def test_search_helper_render_search_paginated_list_non_show_count_returns_component_without_erb_evaluation
    host_class = Class.new do
      include ActionView::Helpers::TagHelper
      include SearchHelper

      attr_accessor :params, :producer_calls

      def initialize
        @params = { search: 'test', page: 2, page_size: 10 }
        @producer_calls = 0
      end

      def request_lang; 'en'; end
      def escape(val); val.to_s; end
      def replace(target, content); [:replace, target, content]; end
      def prepend(target, content); [:prepend, target, content]; end

      def paginated_list_component(id:, results:, next_page_url:, child_url:, child_turbo_frame:, child_param:, **_kwargs)
        @producer_calls += 1
        "<div id=\"#{id}\">paginated items count: <%= 9 * 9 %></div>".html_safe
      end

      def render(*_args)
        flunk 'SearchHelper#render_search_paginated_list must not invoke render inline'
      end
    end

    host = host_class.new
    result = host.render_search_paginated_list(
      container_id: 'props_list',
      next_page_url: '/ontologies/TEST/properties',
      child_url: '/ontologies/TEST/properties/show',
      child_turbo_frame: 'prop_frame',
      child_param: :prop_id,
      results: [{ name: 'ontology' }, { name: 'prop1' }],
      next_page: 3,
      total_count: 20
    )

    assert_equal 1, host.producer_calls, 'Producer component must be invoked exactly once'
    assert_includes result, '<%= 9 * 9 %>', 'Harmless literal ERB arithmetic must remain literal bytes'
    refute_includes result, '81', 'Literal ERB must never be evaluated on component output'
    assert_includes result, '<div id="props_list">', 'Container ID must be preserved'
    assert result.html_safe?, 'SafeBuffer contract must be preserved'
  end

  def test_search_helper_render_search_paginated_list_show_count_preserves_turbo_stream_array
    host_class = Class.new do
      include ActionView::Helpers::TagHelper
      include SearchHelper

      attr_accessor :params, :producer_calls

      def initialize
        @params = { search: 'test', page: 1, page_size: 10, child_key: 'item1' }
        @producer_calls = 0
      end

      def request_lang; 'en'; end
      def escape(val); val.to_s; end
      def replace(target, content); { action: :replace, target: target, content: content }; end
      def prepend(target, content); { action: :prepend, target: target, content: content }; end

      def paginated_list_component(id:, results:, next_page_url:, child_url:, child_turbo_frame:, child_param:, **_kwargs)
        @producer_calls += 1
        "<div id=\"#{id}_list\"><%= 3 * 3 %></div>".html_safe
      end
    end

    host = host_class.new
    result = host.render_search_paginated_list(
      container_id: 'instances_sorted_list',
      next_page_url: '/ontologies/TEST/instances',
      child_url: '/ontologies/TEST/instances/show',
      child_turbo_frame: 'instance_show',
      child_param: :child_key,
      show_count: true,
      results: [{ name: 'ontology' }, { name: 'item1' }, { name: 'item2' }],
      next_page: 2,
      total_count: 2
    )

    assert_instance_of Array, result, 'Stream branch must return stream action array'
    assert_equal 2, result.size, 'Expected 2 stream actions (replace count and prepend view)'
    assert_equal :replace, result[0][:action]
    assert_equal 'instances_sorted_list_count', result[0][:target]
    assert_equal :prepend, result[1][:action]
    assert_equal 'instances_sorted_list_view-page-1', result[1][:target]
    assert_equal 1, host.producer_calls, 'Producer component must be invoked once in stream branch'
  end

  def test_schemes_controller_index_renders_html_without_erb_evaluation
    res, helper = setup_controller_invocation(SchemesController, :index, '/ontologies/TEST/schemes?ontology=TEST&search=demo')

    assert_equal 200, res.status, 'SchemesController#index expected HTTP 200'
    assert_includes res.content_type, 'text/html', 'SchemesController#index expected text/html content-type'
    assert_equal 1, helper.producer_calls, 'Producer component must be invoked exactly once'
    assert_includes res.body, '<%= 7 * 6 %>', 'Literal harmless ERB arithmetic must remain literal bytes'
    refute_includes res.body, '42', 'Literal ERB must never be evaluated in SchemesController HTML response'
    assert_includes res.body, '<div id="schemes_sorted_list">', 'Container ID schemes_sorted_list preserved'
  end

  def test_collections_controller_index_renders_html_without_erb_evaluation
    res, helper = setup_controller_invocation(CollectionsController, :index, '/ontologies/TEST/collections?ontology=TEST&search=demo')

    assert_equal 200, res.status, 'CollectionsController#index expected HTTP 200'
    assert_includes res.content_type, 'text/html', 'CollectionsController#index expected text/html content-type'
    assert_equal 1, helper.producer_calls, 'Producer component must be invoked exactly once'
    assert_includes res.body, '<%= 7 * 6 %>', 'Literal harmless ERB arithmetic must remain literal bytes'
    refute_includes res.body, '42', 'Literal ERB must never be evaluated in CollectionsController HTML response'
    assert_includes res.body, '<div id="collections_sorted_list">', 'Container ID collections_sorted_list preserved'
  end

  def test_properties_controller_index_renders_html_without_erb_evaluation
    res, helper = setup_controller_invocation(PropertiesController, :index, '/ontologies/TEST/properties?ontology=TEST&search=demo')

    assert_equal 200, res.status, 'PropertiesController#index expected HTTP 200'
    assert_includes res.content_type, 'text/html', 'PropertiesController#index expected text/html content-type'
    assert_equal 1, helper.producer_calls, 'Producer component must be invoked exactly once'
    assert_includes res.body, '<%= 7 * 6 %>', 'Literal harmless ERB arithmetic must remain literal bytes'
    refute_includes res.body, '42', 'Literal ERB must never be evaluated in PropertiesController HTML response'
    assert_includes res.body, '<div id="properties_sorted_list">', 'Container ID properties_sorted_list preserved'
  end

  def test_instances_controller_index_renders_html_without_erb_evaluation
    res, helper = setup_controller_invocation(InstancesController, :index, '/ontologies/TEST/instances?ontology=TEST&search=demo')

    assert_equal 200, res.status, 'InstancesController#index expected HTTP 200'
    assert_includes res.content_type, 'text/html', 'InstancesController#index expected text/html content-type'
    assert_equal 1, helper.producer_calls, 'Producer component must be invoked exactly once'
    assert_includes res.body, '<%= 7 * 6 %>', 'Literal harmless ERB arithmetic must remain literal bytes'
    refute_includes res.body, '42', 'Literal ERB must never be evaluated in InstancesController HTML response'
    assert_includes res.body, '<div id="instances_sorted_list">', 'Container ID instances_sorted_list preserved'
  end

  def test_instances_controller_index_concept_page_gt_1_renders_html_without_erb_evaluation
    res, helper = setup_controller_invocation(InstancesController, :index, '/ontologies/TEST/instances?ontology=TEST&type=ConceptType&page=2&search=demo')

    assert_equal 200, res.status, 'InstancesController#index page 2 expected HTTP 200'
    assert_includes res.content_type, 'text/html', 'InstancesController#index page 2 expected text/html content-type'
    assert_equal 1, helper.producer_calls, 'Producer component must be invoked exactly once'
    assert_includes res.body, '<%= 7 * 6 %>', 'Literal harmless ERB arithmetic must remain literal bytes'
    refute_includes res.body, '42', 'Literal ERB must never be evaluated on page > 1'
    assert_includes res.body, '<div id="concept_instances_sorted_list">', 'Container ID concept_instances_sorted_list preserved'
  end

  def test_instances_controller_index_preserves_concept_instance_turbo_stream_branch
    res, helper = setup_controller_invocation(InstancesController, :index, '/ontologies/TEST/instances?ontology=TEST&type=ConceptType&search=demo')

    assert_equal 200, res.status, 'InstancesController#index concept stream expected HTTP 200'
    assert_includes res.content_type, 'turbo-stream', 'Expected turbo-stream content-type on concept page 1'
    assert_equal 1, helper.producer_calls, 'Producer component must be invoked exactly once in stream branch'
    assert_includes res.body, '<%= 7 * 6 %>', 'Literal harmless ERB arithmetic must remain literal bytes in turbo stream'
    refute_includes res.body, '42', 'Literal ERB must never be evaluated in turbo stream response'
    assert_includes res.body, 'concept_instances_sorted_list_count', 'Turbo replace target preserved'
    assert_includes res.body, 'concept_instances_sorted_list_view-page-1', 'Turbo prepend target preserved'
    assert_includes res.body, '<turbo-stream action="replace"', 'Turbo stream replace tag preserved'
    assert_includes res.body, '<turbo-stream action="prepend"', 'Turbo stream prepend tag preserved'
  end
end
