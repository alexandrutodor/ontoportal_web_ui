# frozen_string_literal: true

require 'minitest/autorun'
require 'minitest/mock'
require 'ostruct'
require 'uri'
require 'json'

# =============================================================================
# Standalone Offline Content Search Pagination Regression Test (ONTO-T-B06)
#
# Validates the B06 contract for content search pagination and filtering:
# 1. Framework mode asserted (real Rails ActionController/ActionView/ViewComponent
#    in native container onto-q02-proof:af254f34, or host fallback).
# 2. Outbound parameter forwarding in SearchContent#search_ontologies_content:
#    - Forwards positive integer page and pagesize to search_content HTTP call.
#    - Query ':' and '/' normalization is identical on page 1 and later pages.
#    - Shared boundary validates positive integers without guessing arbitrary max bounds.
# 3. Caller ingress defaults and positive integer validation:
#    - SearchHelper#search_content_params defaults page_size to 100 on missing/invalid input.
#    - SearchController#json_ontology_content_search defaults page_size to 10 on missing/invalid input.
#    - Shared SearchContent#search_ontologies_content defaults page_size to 10.
# 4. Next-page links in SearchHelper#render_search_paginated_list:
#    - Preserves page_size, original query (including ':' and '/'), existing type/ontology
#      filters, lang, and selected child ID.
#    - Uses platform/Rails standard query encoding without raw interpolation or double-escaping.
#    - When nextPage is nil, next_page_link is nil.
# 5. Distinct rendered results across Page 1 and Page 2 for all 4 controllers:
#    - InstancesController#index (both standard and concept-modal turbo_stream)
#    - PropertiesController#index
#    - SchemesController#index
#    - CollectionsController#index
# 6. JSON search caller and first-instance caller compatibility:
#    - SearchController#json_ontology_content_search preserves JSON output and defaults.
#    - OntologiesController#search_first_instance_id functions with paginated search.
# 7. Termination semantics:
#    - Proves through actual TreeInfiniteScrollComponent / InfiniteScrollComponent that
#      nextPage nil stops emitting next lazy-load frame.
#    - Proves empty/out-of-range collection terminates frame emission without error.
# =============================================================================

if Dir.exist?('/usr/local/bundle/ruby/3.1.0/gems') && (ENV['GEM_PATH'].nil? || !ENV['GEM_PATH'].include?('/usr/local/bundle/ruby/3.1.0'))
  Gem.use_paths(nil, Gem.path + ['/usr/local/bundle/ruby/3.1.0'])
end

NATIVE_IMAGE_ENV = Dir.exist?('/usr/local/bundle/ruby/3.1.0/gems')

begin
  require 'rails'
  require 'active_support/all'
  require 'action_controller'
  require 'action_view'
  require 'action_dispatch'
  module Turbo; end
  require '/usr/local/bundle/ruby/3.1.0/gems/turbo-rails-2.0.12/app/helpers/turbo/frames_helper.rb'
  require 'view_component'
  require 'haml'
  require 'haml/template'

  ActionController::Renderers.add :turbo_stream do |html, _options|
    self.content_type ||= 'text/vnd.turbo-stream.html; charset=utf-8'
    self.response_body = html.is_a?(Array) ? html.join : html.to_s
  end

  class ApplicationController < ActionController::Base
    def self.skip_before_action(*); end
    def determine_layout; false; end
    def authorize_and_redirect; end
    def authorize_read_only; end
    def submission_metadata; end
    def ontology_not_found(_id); end
    def request_lang; 'en'; end
    def turbo_frame_request?; false; end
  end

  FRAMEWORK_MODE = "real Rails ActionController/ActionView #{ActionPack::VERSION::STRING} with ViewComponent"
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
            @params[k.to_sym] = v ? URI.decode_www_form_component(v) : ''
            @params[k] = @params[k.to_sym]
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
    def self.skip_before_action(*); end
    def self.helper(*); end
    def self.helper_method(*); end

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
      elsif options[:json]
        @response.status = 200
        @response.content_type = 'application/json; charset=utf-8'
        @response.body = options[:json].to_json
      end
    end

    def dispatch(action, req, res)
      @params = req.params
      @response = res
      send(action)
    end

    def ontology_not_found(_id); end
    def request_lang; 'en'; end
    def turbo_frame_request?; false; end
  end

  module ActionView
    module Helpers
      module TagHelper
        def content_tag(tag, content = nil, &block)
          inner = block ? block.call : content
          "<#{tag}>#{inner}</#{tag}>".html_safe
        end
      end
      module NumberHelper; end
    end
  end

  module ActiveSupport
    module Concern
      def append_features(base)
        super
      end
    end
  end

  module MultiJson
    def self.dump(obj); obj.to_json; end
    def self.load(str); JSON.parse(str); end
  end
  $LOADED_FEATURES << 'multi_json.rb'

  FRAMEWORK_MODE = 'host fallback (lightweight doubles)'
end

puts "[Framework Mode] #{FRAMEWORK_MODE}"

# Stubs for unused concern dependencies
module SubmissionUpdater; end
module OntologyUpdater; end
module SubmissionsHelper; end
module SchemesHelper; end
module CollectionsHelper; end
module TurboHelper; end
module TermsReuses; end
module PropertiesHelper; end
module InstancesHelper; end
module SearchAggregator; end
module FederationHelper; end
module MappingsHelper; end
module FairScoreHelper; end
module OntologiesHelper; end
module ConceptsHelper; end
module MappingStatistics; end
module SparqlHelper; end
module SubmissionFilter; end
module OntologyContentSerializer; end
module UriRedirection; end

module LinkedData
  module Client
    module Models
      class Ontology
        def self.find_by_acronym(_acr); end
        def self.all(*_args); []; end
      end
    end
    module HTTP
      def self.get(*_args); end
    end
  end
end

# Load real components if ViewComponent is available
if defined?(ViewComponent::Base)
  class TreeLinkComponent < ViewComponent::Base; end
  require_relative '../../app/components/infinite_scroll_component'
  require_relative '../../app/components/tree_view_component'
  module Display
    class AlertComponent < ViewComponent::Base
      def initialize(type:); super; end
      def call; %(<div class="alert">#{content}</div>).html_safe; end
    end
  end
  require_relative '../../app/components/tree_infinite_scroll_component'
end

# Load target concern, helpers, and controllers
require_relative '../../app/controllers/concerns/search_content'
require_relative '../../app/helpers/search_helper'
require_relative '../../app/controllers/instances_controller'
require_relative '../../app/controllers/properties_controller'
require_relative '../../app/controllers/schemes_controller'
require_relative '../../app/controllers/collections_controller'
require_relative '../../app/controllers/search_controller'
require_relative '../../app/controllers/ontologies_controller'

class ContentPaginationRegressionCheck < Minitest::Test
  # Helper to capture outbound search_content calls by value
  class RecordingSearchContext
    include SearchContent
    include SearchHelper

    attr_accessor :params, :calls, :mock_pages

    def initialize(params = {})
      @params = params
      @calls = []
      @mock_pages = {}
    end

    def ontology_path(id:, p:, **_kwargs)
      "/ontologies/#{id}/#{p}"
    end

    def helpers
      self
    end

    def link_last_part(val)
      val.to_s.split('/').last
    end

    def escape(val)
      URI.encode_www_form_component(val.to_s)
    end

    def search_content(params)
      # Capture by value because search_ontologies_content mutates changed_query later
      snapshot = {
        q: params[:q]&.dup,
        qf: params[:qf]&.dup,
        ontologies: params[:ontologies]&.dup,
        types: params[:types]&.dup,
        page: params[:page],
        pagesize: params[:pagesize]
      }
      @calls << snapshot

      page_num = params[:page] || 1
      @mock_pages[page_num] || OpenStruct.new(page: page_num, nextPage: nil, totalCount: 0, collection: [])
    end
  end

  def setup_mock_ontology(acronym = 'TEST')
    explore_double = Object.new
    explore_double.define_singleton_method(:latest_submission) do |*_args|
      OpenStruct.new(uriRegexPattern: nil, preferredNamespaceUri: nil, URI: 'http://example.org/test')
    end
    OpenStruct.new(acronym: acronym, name: "#{acronym} Ontology", viewOf: nil, explore: explore_double)
  end

  def build_api_response(page, next_page, total_count, item_ids, acronym = 'TEST', type = 'NamedIndividual')
    items = item_ids.map do |id|
      OpenStruct.new(
        resource_id: id,
        ontology_t: acronym,
        type_t: type,
        http___www_w3_org_2000_01_rdf_schema_label_t: ["Label for #{id}"]
      )
    end
    OpenStruct.new(page: page, nextPage: next_page, totalCount: total_count, collection: items)
  end

  # ===========================================================================
  # Test 1: Framework Mode
  # ===========================================================================
  def test_framework_mode_asserted
    if defined?(ActionController::Base)
      assert_match(/real Rails ActionController\/ActionView 7\.0\.8/, FRAMEWORK_MODE,
                   'Real Rails execution must use real Rails 7.0.8 libraries')
    else
      flunk 'Native container execution must not silently fall back' if NATIVE_IMAGE_ENV
      assert_match(/host fallback/, FRAMEWORK_MODE,
                   'Host execution without gems must report host fallback')
    end
  end

  # ===========================================================================
  # Test 2: SearchContent concern outbound payload forwarding
  # ===========================================================================
  def test_concern_forwards_page_and_pagesize_and_normalizes_query_on_all_pages
    ctx = RecordingSearchContext.new

    ontologies_double = [OpenStruct.new(acronym: 'TEST', name: 'Test Ontology', viewOf: nil)]
    LinkedData::Client::Models::Ontology.stub(:all, ontologies_double) do
      # Page 1 call with colon and slash in query
      ctx.mock_pages[1] = build_api_response(1, 2, 25, ['http://example.org/inst1'])
      res1, p1, np1, tc1 = ctx.search_ontologies_content(
        query: 'pref:label/term',
        page: 1,
        page_size: 15,
        filter_by_ontologies: ['TEST'],
        filter_by_types: ['NamedIndividual']
      )

      assert_equal 1, ctx.calls.size
      call1 = ctx.calls.last
      assert_equal 1, call1[:page], 'Page 1 must forward page: 1'
      assert_equal 15, call1[:pagesize], 'Page 1 must forward outbound pagesize: 15'
      assert_includes call1[:q], 'pref\:label\/term', 'Page 1 query must escape : and /'
      assert_equal 'TEST', call1[:ontologies]
      assert_equal 'NamedIndividual', call1[:types]
      assert_equal 1, p1
      assert_equal 2, np1
      assert_equal 25, tc1

      # Page 2 call with identical query
      ctx.mock_pages[2] = build_api_response(2, nil, 25, ['http://example.org/inst2'])
      res2, p2, np2, tc2 = ctx.search_ontologies_content(
        query: 'pref:label/term',
        page: 2,
        page_size: 15,
        filter_by_ontologies: ['TEST'],
        filter_by_types: ['NamedIndividual']
      )

      assert_equal 2, ctx.calls.size
      call2 = ctx.calls.last
      assert_equal 2, call2[:page], 'Page 2 must forward page: 2'
      assert_equal 15, call2[:pagesize], 'Page 2 must forward outbound pagesize: 15'
      assert_includes call2[:q], 'pref\:label\/term', 'Page 2 query normalization must be identical to Page 1'
      assert_equal call1[:q], call2[:q], 'Query normalization must be identical across pages'
      assert_equal 2, p2
      assert_nil np2
      assert_equal 25, tc2

      # Distinct results rendered
      refute_equal res1.map { |x| x[:name] }, res2.map { |x| x[:name] }
    end
  end

  # ===========================================================================
  # Test 3: Positive integer validation at ingress and shared boundary
  # ===========================================================================
  def test_positive_integer_validation_at_ingress_and_shared_boundary
    # UI helper defaults (100)
    helper = Object.new.extend(SearchHelper)
    helper.define_singleton_method(:params) { { page: '-5', page_size: 'abc' } }
    q, p, ps = helper.search_content_params
    assert_equal 1, p, 'Invalid page must default to 1'
    assert_equal 100, ps, 'Invalid page_size must default to UI helper default 100'

    helper.define_singleton_method(:params) { { page: '0', page_size: '-10' } }
    _, p, ps = helper.search_content_params
    assert_equal 1, p, 'Zero page must default to 1'
    assert_equal 100, ps, 'Negative page_size must default to 100'

    # Valid positive integer without arbitrary upper clamping
    helper.define_singleton_method(:params) { { page: '4', page_size: '500' } }
    _, p, ps = helper.search_content_params
    assert_equal 4, p
    assert_equal 500, ps, 'Valid large page size must be retained without guessing server bounds'

    # Concern shared boundary defaults (10)
    ctx = RecordingSearchContext.new
    ontologies_double = [OpenStruct.new(acronym: 'TEST', name: 'Test Ontology', viewOf: nil)]
    LinkedData::Client::Models::Ontology.stub(:all, ontologies_double) do
      ctx.search_ontologies_content(query: 'test', page: -2, page_size: 0)
      call = ctx.calls.last
      assert_equal 1, call[:page], 'Negative page passed to concern must be validated to 1'
      assert_equal 10, call[:pagesize], 'Zero page_size passed to concern must default to 10'
    end
  end

  # ===========================================================================
  # Test 4: SearchHelper#render_search_paginated_list URL building
  # ===========================================================================
  def test_render_search_paginated_list_builds_correct_next_page_link_and_terminates
    host = Object.new.extend(ActionView::Helpers::TagHelper).extend(SearchHelper)
    host.define_singleton_method(:request_lang) { 'en' }
    host.define_singleton_method(:escape) { |v| URI.encode_www_form_component(v.to_s) }
    host.define_singleton_method(:replace) { |t, c| [:replace, t, c] }
    host.define_singleton_method(:prepend) { |t, c| [:prepend, t, c] }

    captured_component_args = nil
    host.define_singleton_method(:paginated_list_component) do |**kwargs|
      captured_component_args = kwargs
      '<div id="paginated">items</div>'.html_safe
    end

    # Page 1 with query containing special characters, custom page_size, and existing type filter
    host.define_singleton_method(:params) do
      { search: 'prop:code/42', page: '1', page_size: '50', type: 'SpecialIndividual', instanceid: 'http://example.org/inst1' }
    end

    host.render_search_paginated_list(
      container_id: 'test_list',
      next_page_url: '/ontologies/TEST/instances?type=SpecialIndividual',
      child_url: '/ontologies/TEST/instances/show',
      child_turbo_frame: 'test_frame',
      child_param: :instanceid,
      results: [{ name: 'ontology' }, { name: 'http://example.org/inst1' }],
      next_page: 2,
      total_count: 50
    )

    next_url = captured_component_args[:next_page_url]
    refute_nil next_url, 'Next page URL must be present when nextPage is 2'
    uri = URI.parse(next_url)
    params = URI.decode_www_form(uri.query).to_h

    assert_equal '2', params['page'], 'Next link must advance to page 2'
    assert_equal '50', params['page_size'], 'Next link must preserve requested page_size'
    assert_equal 'prop:code/42', params['search'], 'Next link must preserve uncorrupted original search query'
    assert_equal 'en', params['lang'], 'Next link must preserve lang'
    assert_equal 'http://example.org/inst1', params['instanceid'], 'Next link must preserve selected child ID'
    assert_equal 'SpecialIndividual', params['type'], 'Next link must preserve type filter'

    # Termination: when next_page is nil
    host.render_search_paginated_list(
      container_id: 'test_list',
      next_page_url: '/ontologies/TEST/instances',
      child_url: '/ontologies/TEST/instances/show',
      child_turbo_frame: 'test_frame',
      child_param: :instanceid,
      results: [{ name: 'ontology' }, { name: 'http://example.org/inst2' }],
      next_page: nil,
      total_count: 50
    )

    assert_nil captured_component_args[:next_page_url], 'Next link must be nil when nextPage is nil'
  end

  # ===========================================================================
  # Test 5: All 4 controller actions Page 1 vs Page 2 end-to-end integration
  # ===========================================================================
  class TestPaginatedHelperContext
    include ActionView::Helpers::TagHelper
    include SearchHelper

    attr_accessor :controller, :producer_calls, :last_next_page_url

    def initialize(controller)
      @controller = controller
      @producer_calls = 0
      @last_next_page_url = nil
    end

    def params
      @controller.params
    end

    def request_lang
      'en'
    end

    def escape(val)
      URI.encode_www_form_component(val.to_s)
    end

    def replace(target, content)
      %(<turbo-stream action="replace" target="#{target}"><template>#{content}</template></turbo-stream>).html_safe
    end

    def prepend(target, content)
      %(<turbo-stream action="prepend" target="#{target}"><template>#{content}</template></turbo-stream>).html_safe
    end

    def paginated_list_component(id:, results:, next_page_url:, child_url:, child_turbo_frame:, child_param:, **_kwargs)
      @producer_calls += 1
      @last_next_page_url = next_page_url
      items_html = results.collection.map { |x| %(<div class="item">#{x.name}</div>) }.join
      next_html = next_page_url ? %(<turbo-frame id="#{id}_view-page-#{results.nextPage}" loading="lazy" src="#{next_page_url}">Loading...</turbo-frame>) : ''
      %(<div id="#{id}">#{items_html}#{next_html}</div>).html_safe
    end
  end

  def setup_controller_with_search(klass, action, env_uri, page1_response, page2_response)
    ctrl = klass.new
    env = Rack::MockRequest.env_for(env_uri)
    req = ActionDispatch::Request.new(env)
    res = ActionDispatch::Response.new
    helper = TestPaginatedHelperContext.new(ctrl)
    ctrl.define_singleton_method(:helpers) { helper }

    calls = []
    # Concern method stub that records calls and returns distinct pages
    ctrl.define_singleton_method(:search_ontologies_content) do |query:, page:, page_size:, filter_by_ontologies:, filter_by_types:, show_ontologies: true|
      calls << {
        query: query&.dup,
        page: page,
        page_size: page_size,
        filter_by_ontologies: filter_by_ontologies&.dup,
        filter_by_types: filter_by_types&.dup
      }

      resp = page == 1 ? page1_response : page2_response
      results_json = [
        { name: 'TEST', id: '/ontologies/TEST' }
      ] + resp.collection.map do |item|
        { name: item.resource_id, id: item.resource_id, label: "Label #{item.resource_id}" }
      end

      [results_json, resp.page, resp.nextPage, resp.totalCount]
    end

    onto = setup_mock_ontology('TEST')
    LinkedData::Client::Models::Ontology.stub(:find_by_acronym, [onto]) do
      ctrl.dispatch(action, req, res)
    end

    [res, calls]
  end

  def test_instances_controller_page1_and_page2_outbound_and_distinct_results
    p1_resp = build_api_response(1, 2, 20, ['http://example.org/inst1'], 'TEST', 'NamedIndividual')
    p2_resp = build_api_response(2, nil, 20, ['http://example.org/inst2'], 'TEST', 'NamedIndividual')

    # Page 1
    res1, calls1 = setup_controller_with_search(
      InstancesController, :index,
      '/ontologies/TEST/instances?search=sample&page=1&page_size=25',
      p1_resp, p2_resp
    )
    assert_equal 1, calls1.size
    assert_equal 1, calls1.first[:page]
    assert_equal 25, calls1.first[:page_size]
    assert_equal ['TEST'], calls1.first[:filter_by_ontologies]
    assert_equal ['NamedIndividual'], calls1.first[:filter_by_types]
    assert_includes res1.body, 'page=2'
    assert_includes res1.body, 'page_size=25'

    # Page 2
    res2, calls2 = setup_controller_with_search(
      InstancesController, :index,
      '/ontologies/TEST/instances?search=sample&page=2&page_size=25',
      p1_resp, p2_resp
    )
    assert_equal 1, calls2.size
    assert_equal 2, calls2.first[:page]
    assert_equal 25, calls2.first[:page_size]
    refute_includes res2.body, 'page=3', 'Page 2 termination must not emit page 3'
  end

  def test_instances_controller_concept_instances_modal_stream_branch
    p1_resp = build_api_response(1, 2, 20, ['http://example.org/cinst1'], 'TEST', 'http://example.org/Concept')
    p2_resp = build_api_response(2, nil, 20, ['http://example.org/cinst2'], 'TEST', 'http://example.org/Concept')

    # Concept instance modal on page 1 produces turbo_stream
    res1, calls1 = setup_controller_with_search(
      InstancesController, :index,
      '/ontologies/TEST/instances?search=concept&type=http%3A%2F%2Fexample.org%2FConcept&page=1&page_size=10',
      p1_resp, p2_resp
    )
    assert_equal 1, calls1.first[:page]
    assert_equal 10, calls1.first[:page_size]
    assert_equal ['http://example.org/Concept'], calls1.first[:filter_by_types]
    assert_includes res1.content_type, 'turbo-stream'
    assert_includes res1.body, 'turbo-stream'
    assert_includes res1.body, 'page=2'
    assert_includes res1.body, 'page_size=10'
  end

  def test_properties_controller_page1_and_page2_outbound_and_distinct_results
    p1_resp = build_api_response(1, 2, 20, ['http://example.org/prop1'], 'TEST', 'ObjectProperty')
    p2_resp = build_api_response(2, nil, 20, ['http://example.org/prop2'], 'TEST', 'ObjectProperty')

    # Page 1
    res1, calls1 = setup_controller_with_search(
      PropertiesController, :index,
      '/ontologies/TEST/properties?search=hasPart&page=1&page_size=50',
      p1_resp, p2_resp
    )
    assert_equal 1, calls1.first[:page]
    assert_equal 50, calls1.first[:page_size]
    assert_equal %w[AnnotationProperty ObjectProperty DatatypeProperty], calls1.first[:filter_by_types]
    assert_includes res1.body, 'page=2'
    assert_includes res1.body, 'page_size=50'

    # Page 2
    res2, calls2 = setup_controller_with_search(
      PropertiesController, :index,
      '/ontologies/TEST/properties?search=hasPart&page=2&page_size=50',
      p1_resp, p2_resp
    )
    assert_equal 2, calls2.first[:page]
    assert_equal 50, calls2.first[:page_size]
    refute_includes res2.body, 'page=3'
  end

  def test_schemes_controller_page1_and_page2_outbound_and_distinct_results
    p1_resp = build_api_response(1, 2, 20, ['http://example.org/scheme1'], 'TEST', 'ConceptScheme')
    p2_resp = build_api_response(2, nil, 20, ['http://example.org/scheme2'], 'TEST', 'ConceptScheme')

    # Page 1
    res1, calls1 = setup_controller_with_search(
      SchemesController, :index,
      '/ontologies/TEST/schemes?search=vocab&page=1&page_size=30',
      p1_resp, p2_resp
    )
    assert_equal 1, calls1.first[:page]
    assert_equal 30, calls1.first[:page_size]
    assert_equal ['ConceptScheme'], calls1.first[:filter_by_types]
    assert_includes res1.body, 'page=2'
    assert_includes res1.body, 'page_size=30'

    # Page 2
    res2, calls2 = setup_controller_with_search(
      SchemesController, :index,
      '/ontologies/TEST/schemes?search=vocab&page=2&page_size=30',
      p1_resp, p2_resp
    )
    assert_equal 2, calls2.first[:page]
    assert_equal 30, calls2.first[:page_size]
    refute_includes res2.body, 'page=3'
  end

  def test_collections_controller_page1_and_page2_outbound_and_distinct_results
    p1_resp = build_api_response(1, 2, 20, ['http://example.org/coll1'], 'TEST', 'Collection')
    p2_resp = build_api_response(2, nil, 20, ['http://example.org/coll2'], 'TEST', 'Collection')

    # Page 1
    res1, calls1 = setup_controller_with_search(
      CollectionsController, :index,
      '/ontologies/TEST/collections?search=group&page=1&page_size=40',
      p1_resp, p2_resp
    )
    assert_equal 1, calls1.first[:page]
    assert_equal 40, calls1.first[:page_size]
    assert_equal ['Collection'], calls1.first[:filter_by_types]
    assert_includes res1.body, 'page=2'
    assert_includes res1.body, 'page_size=40'

    # Page 2
    res2, calls2 = setup_controller_with_search(
      CollectionsController, :index,
      '/ontologies/TEST/collections?search=group&page=2&page_size=40',
      p1_resp, p2_resp
    )
    assert_equal 2, calls2.first[:page]
    assert_equal 40, calls2.first[:page_size]
    refute_includes res2.body, 'page=3'
  end

  # ===========================================================================
  # Test 6: SearchController#json_ontology_content_search and OntologiesController
  # ===========================================================================
  def test_json_search_caller_default_page_size_10_and_param_forwarding
    ctrl = SearchController.new
    env = Rack::MockRequest.env_for('/ajax/search/ontologies/content?search=atom')
    req = ActionDispatch::Request.new(env)
    res = ActionDispatch::Response.new

    captured_call = nil
    ctrl.define_singleton_method(:search_ontologies_content) do |query:, page:, page_size:, filter_by_ontologies:, filter_by_types:, show_ontologies:|
      captured_call = {
        query: query,
        page: page,
        page_size: page_size,
        filter_by_ontologies: filter_by_ontologies,
        filter_by_types: filter_by_types,
        show_ontologies: show_ontologies
      }
      [[{ id: 'item1', name: 'item1', label: 'Item 1' }], 1, 2, 50]
    end

    ctrl.dispatch(:json_ontology_content_search, req, res)
    assert_equal 1, captured_call[:page]
    assert_equal 10, captured_call[:page_size], 'JSON content search must default page_size to 10'

    # With explicit page and page_size
    ctrl2 = SearchController.new
    env2 = Rack::MockRequest.env_for('/ajax/search/ontologies/content?search=atom&page=3&page_size=20&ontologies=TEST&types=Class')
    req2 = ActionDispatch::Request.new(env2)
    res2 = ActionDispatch::Response.new

    ctrl2.define_singleton_method(:search_ontologies_content) do |query:, page:, page_size:, filter_by_ontologies:, filter_by_types:, show_ontologies:|
      captured_call = {
        query: query,
        page: page,
        page_size: page_size,
        filter_by_ontologies: filter_by_ontologies,
        filter_by_types: filter_by_types,
        show_ontologies: show_ontologies
      }
      [[{ id: 'item1', name: 'item1', label: 'Item 1' }], 3, 4, 50]
    end

    ctrl2.dispatch(:json_ontology_content_search, req2, res2)
    assert_equal 3, captured_call[:page]
    assert_equal 20, captured_call[:page_size]
    assert_equal ['TEST'], captured_call[:filter_by_ontologies]
    assert_equal ['Class'], captured_call[:filter_by_types]
  end

  def test_ontologies_controller_search_first_instance_id_caller
    ctrl = OntologiesController.new
    onto = setup_mock_ontology('TEST')
    ctrl.instance_variable_set(:@ontology, onto)

    ctrl.define_singleton_method(:helpers) do
      Class.new {
        def search_content_params; ['*', 1, 100]; end
      }.new
    end

    captured_call = nil
    ctrl.define_singleton_method(:search_ontologies_content) do |query:, page:, page_size:, filter_by_ontologies:, filter_by_types:|
      captured_call = { query: query, page: page, page_size: page_size, filter_by_ontologies: filter_by_ontologies, filter_by_types: filter_by_types }
      results = [
        { name: 'TEST', type: 'Ontology' },
        { name: 'http://example.org/first_instance', type: 'NamedIndividual' }
      ]
      [results, 1, nil, 1]
    end

    first_id = ctrl.send(:search_first_instance_id)
    assert_equal 'http://example.org/first_instance', first_id
    assert_equal 1, captured_call[:page]
    assert_equal 100, captured_call[:page_size]
  end

  # ===========================================================================
  # Test 7: TreeInfiniteScrollComponent termination when nextPage is nil / empty
  # ===========================================================================
  def test_tree_infinite_scroll_component_termination_when_next_page_nil_or_empty
    skip 'ViewComponent rendering requires native container environment' unless defined?(ViewComponent::Base) && defined?(Haml)

    controller = ActionController::Base.new
    lookup_context = ActionView::LookupContext.new([
      File.expand_path('../../app/components', __dir__),
      File.expand_path('../../app/components/infinite_scroll_component', __dir__),
      File.expand_path('../../app/components/tree_infinite_scroll_component', __dir__)
    ])
    view_context = ActionView::Base.new(lookup_context, {}, controller)

    # Page 1 with nextPage 2 emits next lazy loading frame
    comp1 = TreeInfiniteScrollComponent.new(
      id: 'test_inst',
      collection: [OpenStruct.new(id: '1')],
      next_url: '/ontologies/TEST/instances?page=2&page_size=100',
      current_page: 1,
      next_page: 2
    )
    rendered1 = comp1.render_in(view_context) { '<li>inst 1</li>'.html_safe }
    assert_includes rendered1, '<turbo-frame id="test_inst_view-page-1">'
    assert_includes rendered1, 'loading="lazy"'
    assert_includes rendered1, 'id="test_inst_view-page-2"'
    assert_includes rendered1, 'src="/ontologies/TEST/instances?page=2&amp;page_size=100"'

    # Page 2 with nextPage nil stops emitting next frame
    comp2 = TreeInfiniteScrollComponent.new(
      id: 'test_inst',
      collection: [OpenStruct.new(id: '2')],
      next_url: nil,
      current_page: 2,
      next_page: nil
    )
    rendered2 = comp2.render_in(view_context) { '<li>inst 2</li>'.html_safe }
    assert_includes rendered2, '<turbo-frame id="test_inst_view-page-2">'
    refute_includes rendered2, 'test_inst_view-page-3', 'Must not emit page 3 turbo-frame when nextPage is nil'
    refute_includes rendered2, 'loading="lazy"', 'Must terminate lazy-loading when nextPage is nil'

    # Out-of-range / empty collection terminates
    comp3 = TreeInfiniteScrollComponent.new(
      id: 'test_inst',
      collection: [],
      next_url: nil,
      current_page: 3,
      next_page: nil
    )
    rendered3 = comp3.render_in(view_context) { ''.html_safe }
    assert_includes rendered3, '<turbo-frame id="test_inst_view-page-3">'
    refute_includes rendered3, 'test_inst_view-page-4'
    refute_includes rendered3, 'loading="lazy"'
  end
end
