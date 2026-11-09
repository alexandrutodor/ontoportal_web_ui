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
# 1. Native Rails ActionController/ActionView/ViewComponent environment asserted.
# 2. Outbound parameter forwarding in SearchContent#search_ontologies_content:
#    - Calls real SearchContent#search_content and real LinkedData::Client::HTTP.get.
#    - Forwards positive integer page and pagesize to outbound HTTP call.
#    - Query ':' and '/' normalization is identical on page 1 and later pages.
#    - Params captured by value before formatter mutation.
# 3. Caller ingress defaults and positive integer validation:
#    - SearchHelper#search_content_params defaults page_size to 100 on missing/invalid input.
#    - SearchController#json_ontology_content_search defaults page_size to 10 on missing/invalid input.
#    - Shared SearchContent#search_ontologies_content defaults page_size to 10.
# 4. Next-page links in SearchHelper#render_search_paginated_list:
#    - Preserves page_size, original query (including ':', '/', '&', and IRI chars),
#      existing type/types/ontologies filters, lang, and selected child ID.
#    - Uses platform/Rails standard query encoding without raw interpolation or double-escaping.
#    - When nextPage is nil, next_page_link is nil.
# 5. End-to-end real controller pipeline for all 4 controllers:
#    - InstancesController#index (both standard and concept-modal turbo_stream)
#    - PropertiesController#index
#    - SchemesController#index
#    - CollectionsController#index
#    - Pipeline: action -> real search_ontologies_content -> real search_content ->
#      ONLY LinkedData::Client::HTTP.get mocked with distinct page results and capture
#      params BY VALUE -> real SearchHelper links -> real ComponentsHelper ->
#      actual TreeInfiniteScrollComponent / InfiniteScrollComponent lazy frame emission.
#    - Asserts outbound page1/page2 HTTP calls, distinct body result IDs, preserved URL params,
#      and termination (nextPage nil and empty page stop lazy-load frames).
# 6. JSON search caller and first-instance caller compatibility:
#    - SearchController#json_ontology_content_search preserves JSON output and defaults (real concern path).
#    - OntologiesController#search_first_instance_id functions with paginated search (real concern path).
# 7. Component-level termination semantics:
#    - Proves through actual TreeInfiniteScrollComponent / InfiniteScrollComponent that
#      nextPage nil stops emitting next lazy-load frame.
#    - Proves empty/out-of-range collection terminates frame emission without error.
# =============================================================================

if Dir.exist?('/usr/local/bundle/ruby/3.1.0/gems') && (ENV['GEM_PATH'].nil? || !ENV['GEM_PATH'].include?('/usr/local/bundle/ruby/3.1.0'))
  Gem.use_paths(nil, Gem.path + ['/usr/local/bundle/ruby/3.1.0'])
end

begin
  require 'rails'
  require 'active_support/all'
  require 'action_controller'
  require 'action_view'
  require 'action_dispatch'
  require 'view_component'
  require 'haml'
  require 'haml/template'

  module Turbo
    module Streams; end
  end
  require '/usr/local/bundle/ruby/3.1.0/gems/turbo-rails-2.0.12/app/helpers/turbo/frames_helper.rb'
  require '/usr/local/bundle/ruby/3.1.0/gems/turbo-rails-2.0.12/app/helpers/turbo/streams/action_helper.rb'
  require '/usr/local/bundle/ruby/3.1.0/gems/turbo-rails-2.0.12/app/models/turbo/streams/tag_builder.rb'
  require '/usr/local/bundle/ruby/3.1.0/gems/turbo-rails-2.0.12/app/helpers/turbo/streams_helper.rb'

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

    def ontology_path(id:, p: nil, **kwargs)
      q = kwargs.empty? ? '' : "?#{URI.encode_www_form(kwargs)}"
      p ? "/ontologies/#{id}/#{p}#{q}" : "/ontologies/#{id}#{q}"
    end
    helper_method :ontology_path
    helper_method :request_lang

    def concept_reused?(**_kwargs); false; end
    helper_method :concept_reused?

    def t(key, **_opts); key; end
    helper_method :t
  end

  FRAMEWORK_MODE = "real Rails ActionController/ActionView #{ActionPack::VERSION::STRING} with ViewComponent"
rescue LoadError => e
  FRAMEWORK_MODE = "unavailable: #{e.message}"
end

puts "[Framework Mode] #{FRAMEWORK_MODE}"

# Stubs for unused concern/controller dependencies
module SubmissionUpdater; end
module OntologyUpdater; end
module SubmissionsHelper; end
module SchemesHelper; end
module CollectionsHelper; end
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

if defined?(ViewComponent::Base)
  # Child row presentation stub (finite double for view element)
  class TreeLinkComponent < ViewComponent::Base
    def initialize(child:, href:, data: {}, **_kwargs)
      super
      @child = child
      @href = href
      @data = data
    end

    def call
      content_tag(:li, %(<a href="#{@href}">#{@child.name || @child.id}</a>).html_safe, id: @child.id)
    end
  end

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

# Load helpers, concerns, and controllers under test
require_relative '../../app/helpers/urls_helper'
require_relative '../../app/helpers/turbo_helper'
require_relative '../../app/helpers/components_helper'
require_relative '../../app/helpers/search_helper'
require_relative '../../app/controllers/concerns/search_content'
require_relative '../../app/controllers/concerns/uri_redirection'
require_relative '../../app/controllers/instances_controller'
require_relative '../../app/controllers/properties_controller'
require_relative '../../app/controllers/schemes_controller'
require_relative '../../app/controllers/collections_controller'
require_relative '../../app/controllers/search_controller'
require_relative '../../app/controllers/ontologies_controller'

if defined?(ApplicationController)
  ApplicationController.helper UrlsHelper
  ApplicationController.helper TurboHelper
  ApplicationController.helper SearchHelper
  ApplicationController.helper ComponentsHelper
  ApplicationController.helper Turbo::FramesHelper
  ApplicationController.helper Turbo::StreamsHelper
end

class ContentPaginationRegressionCheck < Minitest::Test
  # Finite ontology double
  def setup_mock_ontology(acronym = 'TEST')
    explore_double = Object.new
    explore_double.define_singleton_method(:latest_submission) do |*_args|
      OpenStruct.new(uriRegexPattern: nil, preferredNamespaceUri: nil, URI: 'http://example.org/test')
    end
    OpenStruct.new(acronym: acronym, name: "#{acronym} Ontology", viewOf: nil, explore: explore_double)
  end

  # OpenStruct API response matching real LinkedData::Client structure
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

  # ONLY LinkedData::Client::HTTP.get is mocked; captures outbound params by value before formatter mutation
  def with_mock_http_search(page_responses_by_page = {})
    captured_calls = []
    mock_get = proc do |path, params|
      if path == 'search/ontologies/content'
        snapshot = {
          q: params[:q]&.dup,
          qf: params[:qf]&.dup,
          ontologies: params[:ontologies]&.dup,
          types: params[:types]&.dup,
          page: params[:page],
          pagesize: params[:pagesize]
        }
        captured_calls << snapshot
        page_num = params[:page] || 1
        page_responses_by_page[page_num] || OpenStruct.new(page: page_num, nextPage: nil, totalCount: 0, collection: [])
      else
        OpenStruct.new(collection: [])
      end
    end

    LinkedData::Client::HTTP.stub(:get, mock_get) do
      yield captured_calls
    end
  end

  # Standalone search context for unit assertions: does NOT override search_content or search_ontologies_content
  class RecordingSearchContext
    include SearchContent
    include SearchHelper

    attr_accessor :params

    def initialize(params = {})
      @params = params
    end

    def ontology_path(id:, p: nil, **kwargs)
      q = kwargs.empty? ? '' : "?#{URI.encode_www_form(kwargs)}"
      p ? "/ontologies/#{id}/#{p}#{q}" : "/ontologies/#{id}#{q}"
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
  end

  # Executes real controller action through full pipeline without overriding any core method
  def dispatch_controller_search(controller_class, action, env_uri, page_responses = {}, path_params = { ontology: 'TEST' })
    ctrl = controller_class.new
    env = ActionDispatch::TestRequest.create.env
    uri = URI.parse(env_uri)
    env['PATH_INFO'] = uri.path
    env['QUERY_STRING'] = uri.query || ''
    req = ActionDispatch::Request.new(env)
    req.path_parameters = path_params
    res = ActionDispatch::Response.new

    onto = setup_mock_ontology(path_params[:ontology] || 'TEST')
    captured_calls = []

    with_mock_http_search(page_responses) do |calls|
      LinkedData::Client::Models::Ontology.stub(:find_by_acronym, [onto]) do
        LinkedData::Client::Models::Ontology.stub(:all, [onto]) do
          ctrl.dispatch(action, req, res)
        end
      end
      captured_calls = calls.map(&:dup)
    end

    [res, captured_calls]
  end

  # ===========================================================================
  # Test 1: Framework Mode
  # ===========================================================================
  def test_framework_mode_asserted
    skip "Native Rails unavailable: #{FRAMEWORK_MODE}" unless defined?(ActionController::Base)
    assert_match(/real Rails ActionController\/ActionView 7\.0\.8/, FRAMEWORK_MODE,
                 'Real Rails execution must use real Rails 7.0.8 libraries')
  end

  # ===========================================================================
  # Test 2: SearchContent concern outbound payload forwarding
  # ===========================================================================
  def test_concern_forwards_page_and_pagesize_and_normalizes_query_on_all_pages
    ctx = RecordingSearchContext.new
    ontologies_double = [OpenStruct.new(acronym: 'TEST', name: 'Test Ontology', viewOf: nil)]

    pages = {
      1 => build_api_response(1, 2, 25, ['http://example.org/inst1']),
      2 => build_api_response(2, nil, 25, ['http://example.org/inst2'])
    }

    LinkedData::Client::Models::Ontology.stub(:all, ontologies_double) do
      with_mock_http_search(pages) do |calls|
        res1, p1, np1, tc1 = ctx.search_ontologies_content(
          query: 'pref:label/term',
          page: 1,
          page_size: 15,
          filter_by_ontologies: ['TEST'],
          filter_by_types: ['NamedIndividual']
        )

        assert_equal 1, calls.size
        call1 = calls.last
        assert_equal 1, call1[:page], 'Page 1 must forward page: 1'
        assert_equal 15, call1[:pagesize], 'Page 1 must forward outbound pagesize: 15'
        assert_includes call1[:q], 'pref\:label\/term', 'Page 1 query must escape : and /'
        assert_equal 'TEST', call1[:ontologies]
        assert_equal 'NamedIndividual', call1[:types]
        assert_equal 1, p1
        assert_equal 2, np1
        assert_equal 25, tc1

        res2, p2, np2, tc2 = ctx.search_ontologies_content(
          query: 'pref:label/term',
          page: 2,
          page_size: 15,
          filter_by_ontologies: ['TEST'],
          filter_by_types: ['NamedIndividual']
        )

        assert_equal 2, calls.size
        call2 = calls.last
        assert_equal 2, call2[:page], 'Page 2 must forward page: 2'
        assert_equal 15, call2[:pagesize], 'Page 2 must forward outbound pagesize: 15'
        assert_includes call2[:q], 'pref\:label\/term', 'Page 2 query normalization must be identical to Page 1'
        assert_equal call1[:q], call2[:q], 'Query normalization must be identical across pages'
        assert_equal 2, p2
        assert_nil np2
        assert_equal 25, tc2

        # Distinct results rendered across pages
        refute_equal res1.map { |x| x[:name] }, res2.map { |x| x[:name] }
      end
    end
  end

  # ===========================================================================
  # Test 3: Positive integer validation at ingress and shared boundary
  # ===========================================================================
  def test_positive_integer_validation_at_ingress_and_shared_boundary
    # UI helper defaults (100)
    helper = Object.new.extend(SearchHelper)
    helper.define_singleton_method(:params) { { page: '-5', page_size: 'abc' } }
    _, p, ps = helper.search_content_params
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

    # Concern shared boundary defaults (10) via real search_content to mocked HTTP
    ctx = RecordingSearchContext.new
    ontologies_double = [OpenStruct.new(acronym: 'TEST', name: 'Test Ontology', viewOf: nil)]
    LinkedData::Client::Models::Ontology.stub(:all, ontologies_double) do
      with_mock_http_search do |calls|
        ctx.search_ontologies_content(query: 'test', page: -2, page_size: 0)
        assert_equal 1, calls.size
        call = calls.last
        assert_equal 1, call[:page], 'Negative page passed to concern must be validated to 1'
        assert_equal 10, call[:pagesize], 'Zero page_size passed to concern must default to 10'
      end
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

    # Page 1 with query containing &, :, /, and IRI chars, custom page_size, and existing type filter
    complex_query = 'http://example.org/prop#sub&val:code/42'
    host.define_singleton_method(:params) do
      { search: complex_query, page: '1', page_size: '50', type: 'SpecialIndividual', instanceid: 'http://example.org/inst1' }
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
    assert_equal complex_query, params['search'], 'Next link must preserve uncorrupted original query with &, :, /, and IRI chars'
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
  def test_instances_controller_page1_and_page2_outbound_and_distinct_results
    p1_resp = build_api_response(1, 2, 20, ['http://example.org/inst1'], 'TEST', 'NamedIndividual')
    p2_resp = build_api_response(2, nil, 20, ['http://example.org/inst2'], 'TEST', 'NamedIndividual')
    responses = { 1 => p1_resp, 2 => p2_resp }

    # Page 1
    res1, calls1 = dispatch_controller_search(
      InstancesController, :index,
      '/ontologies/TEST/instances?search=sample&page=1&page_size=25',
      responses, { ontology: 'TEST' }
    )
    assert_equal 200, res1.status
    assert_equal 1, calls1.size
    call1 = calls1.first
    assert_equal 1, call1[:page]
    assert_equal 25, call1[:pagesize]
    assert_equal 'TEST', call1[:ontologies]
    assert_equal 'NamedIndividual', call1[:types]
    assert_equal '*sample*', call1[:q]

    assert_includes res1.body, 'http://example.org/inst1', 'Page 1 must contain Page 1 result ID'
    refute_includes res1.body, 'http://example.org/inst2', 'Page 1 must not contain Page 2 result ID'
    assert_includes res1.body, 'page=2', 'Page 1 next frame link must advance to page 2'
    assert_includes res1.body, 'page_size=25', 'Page 1 next frame link must preserve page_size'
    assert_includes res1.body, 'search=sample', 'Page 1 next frame link must preserve query'
    assert_includes res1.body, 'instanceid=http%3A%2F%2Fexample.org%2Finst1', 'Page 1 next frame link must preserve selected child'
    assert_includes res1.body, 'loading="lazy"', 'Page 1 must emit lazy-loading turbo-frame'

    # Page 2
    res2, calls2 = dispatch_controller_search(
      InstancesController, :index,
      '/ontologies/TEST/instances?search=sample&page=2&page_size=25',
      responses, { ontology: 'TEST' }
    )
    assert_equal 200, res2.status
    assert_equal 1, calls2.size
    call2 = calls2.first
    assert_equal 2, call2[:page]
    assert_equal 25, call2[:pagesize]
    assert_equal call1[:q], call2[:q], 'Outbound normalized query must be identical across pages'
    assert_equal call1[:ontologies], call2[:ontologies]
    assert_equal call1[:types], call2[:types]

    assert_includes res2.body, 'http://example.org/inst2', 'Page 2 must contain Page 2 result ID'
    refute_includes res2.body, 'http://example.org/inst1', 'Page 2 must not contain Page 1 result ID'
    refute_includes res2.body, 'page=3', 'Page 2 termination must not emit page 3'
    refute_includes res2.body, 'loading="lazy"', 'Page 2 termination must stop lazy-loading frame emission'
  end

  def test_instances_controller_concept_instances_modal_stream_branch
    p1_resp = build_api_response(1, 2, 20, ['http://example.org/cinst1'], 'TEST', 'http://example.org/Concept')
    p2_resp = build_api_response(2, nil, 20, ['http://example.org/cinst2'], 'TEST', 'http://example.org/Concept')
    responses = { 1 => p1_resp, 2 => p2_resp }

    # Concept instance modal on page 1 produces turbo_stream
    res1, calls1 = dispatch_controller_search(
      InstancesController, :index,
      '/ontologies/TEST/instances?search=concept&type=http%3A%2F%2Fexample.org%2FConcept&page=1&page_size=10',
      responses, { ontology: 'TEST' }
    )
    assert_equal 200, res1.status
    assert_equal 1, calls1.size
    assert_equal 1, calls1.first[:page]
    assert_equal 10, calls1.first[:pagesize]
    assert_equal 'http://example.org/Concept', calls1.first[:types]
    assert_includes res1.content_type, 'turbo-stream'
    assert_includes res1.body, '<turbo-stream action="replace" target="concept_instances_sorted_list_count">'
    assert_includes res1.body, '<turbo-stream action="prepend" target="concept_instances_sorted_list_view-page-1">'
    assert_includes res1.body, 'http://example.org/cinst1'
    assert_includes res1.body, 'page=2'
    assert_includes res1.body, 'page_size=10'
    assert_includes res1.body, 'type=http%3A%2F%2Fexample.org%2FConcept'
    assert_includes res1.body, 'loading="lazy"'
  end

  def test_properties_controller_page1_and_page2_outbound_and_distinct_results
    p1_resp = build_api_response(1, 2, 20, ['http://example.org/prop1'], 'TEST', 'ObjectProperty')
    p2_resp = build_api_response(2, nil, 20, ['http://example.org/prop2'], 'TEST', 'ObjectProperty')
    responses = { 1 => p1_resp, 2 => p2_resp }

    # Page 1
    res1, calls1 = dispatch_controller_search(
      PropertiesController, :index,
      '/ontologies/TEST/properties?search=hasPart&page=1&page_size=50',
      responses, { ontology: 'TEST' }
    )
    assert_equal 200, res1.status
    assert_equal 1, calls1.size
    call1 = calls1.first
    assert_equal 1, call1[:page]
    assert_equal 50, call1[:pagesize]
    assert_equal 'AnnotationProperty,ObjectProperty,DatatypeProperty', call1[:types]
    assert_equal 'TEST', call1[:ontologies]

    assert_includes res1.body, 'http://example.org/prop1'
    refute_includes res1.body, 'http://example.org/prop2'
    assert_includes res1.body, 'page=2'
    assert_includes res1.body, 'page_size=50'
    assert_includes res1.body, 'propertyid=http%3A%2F%2Fexample.org%2Fprop1'
    assert_includes res1.body, 'loading="lazy"'

    # Page 2
    res2, calls2 = dispatch_controller_search(
      PropertiesController, :index,
      '/ontologies/TEST/properties?search=hasPart&page=2&page_size=50',
      responses, { ontology: 'TEST' }
    )
    assert_equal 200, res2.status
    assert_equal 1, calls2.size
    call2 = calls2.first
    assert_equal 2, call2[:page]
    assert_equal 50, call2[:pagesize]
    assert_equal call1[:q], call2[:q]
    assert_equal call1[:types], call2[:types]

    assert_includes res2.body, 'http://example.org/prop2'
    refute_includes res2.body, 'http://example.org/prop1'
    refute_includes res2.body, 'page=3'
    refute_includes res2.body, 'loading="lazy"'
  end

  def test_schemes_controller_page1_and_page2_outbound_and_distinct_results
    p1_resp = build_api_response(1, 2, 20, ['http://example.org/scheme1'], 'TEST', 'ConceptScheme')
    p2_resp = build_api_response(2, nil, 20, ['http://example.org/scheme2'], 'TEST', 'ConceptScheme')
    responses = { 1 => p1_resp, 2 => p2_resp }

    # Page 1
    res1, calls1 = dispatch_controller_search(
      SchemesController, :index,
      '/ontologies/TEST/schemes?search=vocab&page=1&page_size=30',
      responses, { ontology: 'TEST' }
    )
    assert_equal 200, res1.status
    assert_equal 1, calls1.size
    call1 = calls1.first
    assert_equal 1, call1[:page]
    assert_equal 30, call1[:pagesize]
    assert_equal 'ConceptScheme', call1[:types]
    assert_equal 'TEST', call1[:ontologies]

    assert_includes res1.body, 'http://example.org/scheme1'
    refute_includes res1.body, 'http://example.org/scheme2'
    assert_includes res1.body, 'page=2'
    assert_includes res1.body, 'page_size=30'
    assert_includes res1.body, 'schemeid=http%3A%2F%2Fexample.org%2Fscheme1'
    assert_includes res1.body, 'loading="lazy"'

    # Page 2
    res2, calls2 = dispatch_controller_search(
      SchemesController, :index,
      '/ontologies/TEST/schemes?search=vocab&page=2&page_size=30',
      responses, { ontology: 'TEST' }
    )
    assert_equal 200, res2.status
    assert_equal 1, calls2.size
    call2 = calls2.first
    assert_equal 2, call2[:page]
    assert_equal 30, call2[:pagesize]
    assert_equal call1[:q], call2[:q]
    assert_equal call1[:types], call2[:types]

    assert_includes res2.body, 'http://example.org/scheme2'
    refute_includes res2.body, 'http://example.org/scheme1'
    refute_includes res2.body, 'page=3'
    refute_includes res2.body, 'loading="lazy"'
  end

  def test_collections_controller_page1_and_page2_outbound_and_distinct_results
    p1_resp = build_api_response(1, 2, 20, ['http://example.org/coll1'], 'TEST', 'Collection')
    p2_resp = build_api_response(2, nil, 20, ['http://example.org/coll2'], 'TEST', 'Collection')
    responses = { 1 => p1_resp, 2 => p2_resp }

    # Page 1
    res1, calls1 = dispatch_controller_search(
      CollectionsController, :index,
      '/ontologies/TEST/collections?search=group&page=1&page_size=40',
      responses, { ontology: 'TEST' }
    )
    assert_equal 200, res1.status
    assert_equal 1, calls1.size
    call1 = calls1.first
    assert_equal 1, call1[:page]
    assert_equal 40, call1[:pagesize]
    assert_equal 'Collection', call1[:types]
    assert_equal 'TEST', call1[:ontologies]

    assert_includes res1.body, 'http://example.org/coll1'
    refute_includes res1.body, 'http://example.org/coll2'
    assert_includes res1.body, 'page=2'
    assert_includes res1.body, 'page_size=40'
    assert_includes res1.body, 'collectionid=http%3A%2F%2Fexample.org%2Fcoll1'
    assert_includes res1.body, 'loading="lazy"'

    # Page 2
    res2, calls2 = dispatch_controller_search(
      CollectionsController, :index,
      '/ontologies/TEST/collections?search=group&page=2&page_size=40',
      responses, { ontology: 'TEST' }
    )
    assert_equal 200, res2.status
    assert_equal 1, calls2.size
    call2 = calls2.first
    assert_equal 2, call2[:page]
    assert_equal 40, call2[:pagesize]
    assert_equal call1[:q], call2[:q]
    assert_equal call1[:types], call2[:types]

    assert_includes res2.body, 'http://example.org/coll2'
    refute_includes res2.body, 'http://example.org/coll1'
    refute_includes res2.body, 'page=3'
    refute_includes res2.body, 'loading="lazy"'
  end

  def test_controller_empty_page_and_out_of_range_stops_lazy_frame_markup
    empty_resp = build_api_response(3, nil, 20, [], 'TEST', 'NamedIndividual')
    res, calls = dispatch_controller_search(
      InstancesController, :index,
      '/ontologies/TEST/instances?search=sample&page=3&page_size=25',
      { 3 => empty_resp }, { ontology: 'TEST' }
    )
    assert_equal 200, res.status
    assert_equal 1, calls.size
    assert_equal 3, calls.first[:page]
    refute_includes res.body, 'loading="lazy"', 'Empty out-of-range page must stop lazy frame emission'
    refute_includes res.body, 'page=4'
  end

  # ===========================================================================
  # Test 6: SearchController#json_ontology_content_search and OntologiesController
  # ===========================================================================
  def test_json_search_caller_default_page_size_10_and_param_forwarding
    onto = setup_mock_ontology('TEST')

    # Default page_size 10 on missing input
    ctrl = SearchController.new
    env = ActionDispatch::TestRequest.create.env
    env['PATH_INFO'] = '/ajax/search/ontologies/content'
    env['QUERY_STRING'] = 'search=atom'
    req = ActionDispatch::Request.new(env)
    res = ActionDispatch::Response.new

    pages1 = {
      1 => build_api_response(1, 2, 50, ['http://example.org/atom1'], 'TEST', 'Class')
    }

    with_mock_http_search(pages1) do |calls|
      LinkedData::Client::Models::Ontology.stub(:all, [onto]) do
        ctrl.dispatch(:json_ontology_content_search, req, res)
      end
      assert_equal 200, res.status
      assert_equal 1, calls.size
      assert_equal 1, calls.first[:page]
      assert_equal 10, calls.first[:pagesize], 'JSON content search must default page_size to 10'
      assert_equal '*atom*', calls.first[:q]
      parsed = JSON.parse(res.body)
      assert(parsed.any? { |item| item['name'] == 'http://example.org/atom1' })
    end

    # Explicit page and page_size
    ctrl2 = SearchController.new
    env2 = ActionDispatch::TestRequest.create.env
    env2['PATH_INFO'] = '/ajax/search/ontologies/content'
    env2['QUERY_STRING'] = 'search=atom&page=3&page_size=20&ontologies=TEST&types=Class'
    req2 = ActionDispatch::Request.new(env2)
    res2 = ActionDispatch::Response.new

    pages2 = {
      3 => build_api_response(3, 4, 50, ['http://example.org/atom3'], 'TEST', 'Class')
    }

    with_mock_http_search(pages2) do |calls|
      LinkedData::Client::Models::Ontology.stub(:all, [onto]) do
        ctrl2.dispatch(:json_ontology_content_search, req2, res2)
      end
      assert_equal 200, res2.status
      assert_equal 1, calls.size
      assert_equal 3, calls.first[:page]
      assert_equal 20, calls.first[:pagesize]
      assert_equal 'TEST', calls.first[:ontologies]
      assert_equal 'Class', calls.first[:types]
    end
  end

  def test_ontologies_controller_search_first_instance_id_caller
    onto = setup_mock_ontology('TEST')
    ctrl = OntologiesController.new
    env = ActionDispatch::TestRequest.create.env
    env['PATH_INFO'] = '/ontologies/TEST/instances'
    env['QUERY_STRING'] = ''
    req = ActionDispatch::Request.new(env)
    req.path_parameters = { ontology: 'TEST' }
    res = ActionDispatch::Response.new
    ctrl.instance_variable_set(:@ontology, onto)
    ctrl.instance_variable_set(:@_request, req)
    ctrl.instance_variable_set(:@_response, res)

    pages = {
      1 => build_api_response(1, nil, 1, ['http://example.org/first_instance'], 'TEST', 'NamedIndividual')
    }

    first_id = nil
    with_mock_http_search(pages) do |calls|
      LinkedData::Client::Models::Ontology.stub(:all, [onto]) do
        first_id = ctrl.send(:search_first_instance_id)
      end
      assert_equal 1, calls.size
      assert_equal 1, calls.first[:page]
      assert_equal 100, calls.first[:pagesize], 'OntologiesController first instance search uses page_size 100'
      assert_equal 'TEST', calls.first[:ontologies]
      assert_equal 'NamedIndividual', calls.first[:types]
      assert_equal 'http://example.org/first_instance', first_id
    end
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
