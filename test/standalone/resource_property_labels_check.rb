# frozen_string_literal: true

# Set up gem paths for native docker image if present
if Dir.exist?('/usr/local/bundle/ruby/3.1.0/gems') && (ENV['GEM_PATH'].nil? || !ENV['GEM_PATH'].include?('/usr/local/bundle/ruby/3.1.0'))
  Gem.use_paths(nil, Gem.path + ['/usr/local/bundle/ruby/3.1.0'])
end

require 'minitest/autorun'
require 'active_support/all'
require 'rails'
require 'action_controller'
require 'action_view'
require 'view_component'
require 'haml'
require 'haml/template'
require 'ostruct'
require 'nokogiri'
require 'cgi'

# =============================================================================
# Standalone Resource Property Labels Check (ONTO-T-U06 label resolution/cache)
#
# Validates property-label resolution, bounded request-local cache, and
# display preservation in ConceptDetailsComponent:
# 1. Successful label resolution uses provided acronym and escaped IRI endpoint,
#    and fetched label is visible in actual rendered HTML table.
# 2. Missing, error, and fatal distinctions:
#    - Missing / 404 / empty label falls back to local name without losing data.
#    - SDK-shaped Exception (status >= 500) and transport failures fall back
#      safely without leaking raw upstream error body.
#    - Fatal exceptions (Interrupt, SystemExit) are never swallowed.
# 3. Request-local cache bounds:
#    - Repeated lookup of same property in same request reuses cached outcome
#      (HTTP call count is 1, miss count is 1).
#    - Different request, origin, or acronym triggers separate lookup.
#    - At most 20 distinct misses per request; subsequent lookups deliberately
#      fall back to local name while retaining all property values.
# 4. Predicate preservation:
#    - Distinct predicates with identical display labels do NOT collapse fields.
#    - Multilingual values and raw IRI tooltips are retained.
# =============================================================================

$LOAD_PATH.unshift File.expand_path('../../app/components', __dir__)
$LOAD_PATH.unshift File.expand_path('../../app/helpers', __dir__)
$LOAD_PATH.unshift File.expand_path('../../app/controllers/concerns', __dir__)

$REST_URL = 'http://localhost:9393'
$API_KEY = 'dummy'

module OntologiesHelper; end
module Display; end

require 'terms_reuses'
require 'modal_helper'
require 'urls_helper'
require 'components_helper'
require 'multi_languages_helper'
require 'ontologies_helper'
require 'application_helper'

# Minimal doubling for presentation helpers
module ApplicationHelper
  def ajax_link_chip(id, ajax_src:, target: nil)
    %(<a class="ajax-chip" href="#{ajax_src}" data-target="#{target}">#{id}</a>).html_safe
  end
end

# Controllable SDK HTTP boundary double
module MockSDKHTTP
  class << self
    attr_accessor :handler, :calls

    def reset!
      @handler = nil
      @calls = []
    end

    def get(path)
      @calls << path
      if @handler
        @handler.call(path)
      else
        nil
      end
    end
  end
end

module LinkedData
  module Client
    module HTTP
      def self.get(path)
        MockSDKHTTP.get(path)
      end
    end
  end
end

require 'table_cell_component'
require 'table_row_component'
require 'table_component'
require 'display/header_component'
require 'dropdown_container_component'
require 'list_items_show_more_component'
require 'concept_details_component'

ConceptDetailsComponent.include(Module.new {
  def inline_svg(path, _opts = {})
    %(<svg data-path="#{path}"></svg>).html_safe
  end
})

class FakeRequest
  attr_accessor :env, :host

  def initialize(env = {})
    @env = env
    @host = 'localhost'
  end
end

class ResourcePropertyLabelsCheck < Minitest::Test
  def setup
    MockSDKHTTP.reset!
    @original_rest_url = $REST_URL
    $REST_URL = 'http://localhost:9393'

    @fake_env = {}
    @fake_request = FakeRequest.new(@fake_env)
    Thread.current[:request] = @fake_request

    lookup_context = ActionView::LookupContext.new([
      File.expand_path('../../app/components', __dir__),
      File.expand_path('../../app/views', __dir__)
    ])
    @view_context = ActionView::Base.new(lookup_context, {}, ActionController::Base.new)
    @view_context.extend(ActionView::Helpers::TagHelper)
    @view_context.extend(ActionView::Helpers::UrlHelper)
    @view_context.extend(ModalHelper)
    @view_context.extend(UrlsHelper)
    @view_context.extend(ComponentsHelper)
    @view_context.extend(MultiLanguagesHelper)
    @view_context.extend(ApplicationHelper)

    @view_context.define_singleton_method(:inline_svg) { |path, _opts = {}| %(<svg data-path="#{path}"></svg>).html_safe }
    @view_context.define_singleton_method(:link_to_modal) do |name, url, _opts = {}, &block|
      inner = block_given? ? block.call : name
      %(<a href="#{url}" data-modal="true">#{inner}</a>).html_safe
    end
    @view_context.define_singleton_method(:image_tag) { |src, _opts = {}| %(<img src="#{src}" />).html_safe }
    @view_context.define_singleton_method(:request_lang) { 'en' }
    @view_context.define_singleton_method(:t) { |k| k }
    @view_context.define_singleton_method(:l) { |d, _opts = {}| "FORMATTED_DATE(#{d})" }
  end

  def teardown
    Thread.current[:request] = nil
    $REST_URL = @original_rest_url
    MockSDKHTTP.reset!
  end

  def parse_doc(html)
    Nokogiri::HTML::DocumentFragment.parse(html)
  end

  # Case 1: Successful label resolution uses provided acronym & escaped IRI; visible in rendered table
  def test_successful_label_resolution_uses_provided_acronym_and_escaped_iri_endpoint
    target_iri = 'http://example.org/custom#fullTitle'
    MockSDKHTTP.handler = lambda do |path|
      if path.include?('fullTitle')
        OpenStruct.new(label: 'Full Title (Resolved Display)')
      else
        nil
      end
    end

    props_class = Struct.new(target_iri.to_sym)
    props = props_class.new(['Detailed ontology element title'])

    comp = ConceptDetailsComponent.new(
      id: 'prop-label-test',
      acronym: 'TEST-ACRO',
      concept_id: 'http://example.org/concept/1',
      properties: props,
      top_keys: [],
      bottom_keys: [],
      exclude_keys: []
    )

    html = comp.render_in(@view_context)
    doc = parse_doc(html)

    # 1. Exact endpoint called with provided acronym and escaped IRI
    expected_path = "/ontologies/TEST-ACRO/properties/#{CGI.escape(target_iri)}/label"
    assert_equal 1, MockSDKHTTP.calls.size
    assert_equal expected_path, MockSDKHTTP.calls.first

    # 2. Resolved label is visible in rendered table header
    th_span = doc.at_css('th span')
    assert th_span, 'Header span must be rendered'
    assert_equal 'Full Title (Resolved Display)', th_span.text.strip
    assert_equal target_iri, th_span['title'], 'Raw IRI must be retained in title tooltip'
    assert_equal 'tooltip', th_span['data-controller']

    # 3. Value is rendered in td
    assert_includes html, 'Detailed ontology element title'
  end

  # Case 2: Missing (nil/empty) and error (SDK-shaped Exception status >= 500) fall back to local name
  def test_missing_and_sdk_error_fall_back_to_local_name_without_exposing_upstream_body
    missing_iri = 'http://example.org/missing#unknownProp'
    error_iri = 'http://example.org/error#faultyProp'

    MockSDKHTTP.handler = lambda do |path|
      if path.include?('unknownProp')
        OpenStruct.new(label: '') # empty label (miss)
      elsif path.include?('faultyProp')
        # SDK-shaped Exception raised on HTTP status >= 500
        raise Exception, "Problem retrieving:\n#{path}\n<secret_upstream_trace_500>"
      else
        nil
      end
    end

    props_class = Struct.new(missing_iri.to_sym, error_iri.to_sym)
    props = props_class.new(
      ['Value for missing property'],
      ['Value for faulty property']
    )

    comp = ConceptDetailsComponent.new(
      id: 'error-handling-test',
      acronym: 'TEST-ACRO',
      concept_id: 'http://example.org/concept/err',
      properties: props,
      top_keys: [],
      bottom_keys: [],
      exclude_keys: []
    )

    html = comp.render_in(@view_context)
    doc = parse_doc(html)

    rows = doc.css('tbody tr').reject { |tr| tr.at_css('#content_resource_formats') }
    assert_equal 2, rows.size

    row_headers = rows.map { |r| r.at_css('th span')&.text&.strip }
    assert_includes row_headers, 'unknownProp', 'Missing property should fall back to local name'
    assert_includes row_headers, 'faultyProp', 'Faulty property should fall back to local name'

    # Ensure sensitive raw error body is never disclosed in rendered HTML
    refute_includes html, 'secret_upstream_trace_500'

    # Both values are rendered
    assert_includes html, 'Value for missing property'
    assert_includes html, 'Value for faulty property'

    # Miss count in request env reflects both lookup misses
    assert_equal 2, @fake_env['ontoportal.property_labels_miss_count']
  end

  # Case 3: Fatal exceptions (Interrupt, SystemExit) are never swallowed
  def test_fatal_exceptions_are_never_swallowed
    target_iri = 'http://example.org/fatal#sigintProp'
    MockSDKHTTP.handler = lambda do |_path|
      raise Interrupt, 'Simulated SIGINT during property lookup'
    end

    props_class = Struct.new(target_iri.to_sym)
    props = props_class.new(['Will be interrupted'])

    assert_raises(Interrupt) do
      ConceptDetailsComponent.new(
        id: 'fatal-test',
        acronym: 'TEST-ACRO',
        concept_id: 'http://example.org/concept/fatal',
        properties: props,
        top_keys: [],
        bottom_keys: [],
        exclude_keys: []
      )
    end
  end

  # Case 4: Same request repeat reuses cached negative outcome without extra HTTP call
  def test_same_request_repeat_reuses_cached_outcome_without_extra_http_lookup
    target_iri = 'http://example.org/cached#negativeProp'
    MockSDKHTTP.handler = lambda do |_path|
      OpenStruct.new(label: nil) # negative outcome
    end

    props_class = Struct.new(target_iri.to_sym)

    # First component instance in current request
    comp1 = ConceptDetailsComponent.new(
      id: 'cache-test-1',
      acronym: 'TEST-ACRO',
      concept_id: 'http://example.org/concept/c1',
      properties: props_class.new(['Val 1']),
      top_keys: [],
      bottom_keys: [],
      exclude_keys: []
    )
    comp1.render_in(@view_context)

    assert_equal 1, MockSDKHTTP.calls.size
    assert_equal 1, @fake_env['ontoportal.property_labels_miss_count']

    # Second component instance in SAME request env with SAME property
    comp2 = ConceptDetailsComponent.new(
      id: 'cache-test-2',
      acronym: 'TEST-ACRO',
      concept_id: 'http://example.org/concept/c2',
      properties: props_class.new(['Val 2']),
      top_keys: [],
      bottom_keys: [],
      exclude_keys: []
    )
    comp2.render_in(@view_context)

    # HTTP was NOT called again; miss count is NOT incremented again
    assert_equal 1, MockSDKHTTP.calls.size, 'Repeated property in same request must not trigger extra HTTP call'
    assert_equal 1, @fake_env['ontoportal.property_labels_miss_count'], 'Miss count must remain 1'
  end

  # Case 5: Different request, origin, or acronym triggers separate lookup
  def test_different_request_origin_or_acronym_not_incorrectly_reused
    target_iri = 'http://example.org/ns#sharedProp'
    MockSDKHTTP.handler = lambda do |path|
      OpenStruct.new(label: "Label for #{path}")
    end

    props_class = Struct.new(target_iri.to_sym)

    # 1. Request 1
    comp1 = ConceptDetailsComponent.new(
      id: 'req1',
      acronym: 'ONTO-1',
      concept_id: 'http://example.org/concept/1',
      properties: props_class.new(['Data 1']),
      top_keys: [],
      bottom_keys: [],
      exclude_keys: []
    )
    comp1.render_in(@view_context)
    assert_equal 1, MockSDKHTTP.calls.size

    # 2. Fresh Request 2: new request env
    Thread.current[:request] = FakeRequest.new({})
    comp2 = ConceptDetailsComponent.new(
      id: 'req2',
      acronym: 'ONTO-1',
      concept_id: 'http://example.org/concept/2',
      properties: props_class.new(['Data 2']),
      top_keys: [],
      bottom_keys: [],
      exclude_keys: []
    )
    comp2.render_in(@view_context)
    assert_equal 2, MockSDKHTTP.calls.size, 'New request must not reuse cache from previous request'

    # 3. Different acronym in current request
    comp3 = ConceptDetailsComponent.new(
      id: 'req2-acro2',
      acronym: 'ONTO-2',
      concept_id: 'http://example.org/concept/3',
      properties: props_class.new(['Data 3']),
      top_keys: [],
      bottom_keys: [],
      exclude_keys: []
    )
    comp3.render_in(@view_context)
    assert_equal 3, MockSDKHTTP.calls.size, 'Different acronym must trigger separate lookup'

    # 4. Different API origin
    $REST_URL = 'http://other-api.example.com'
    comp4 = ConceptDetailsComponent.new(
      id: 'req2-origin2',
      acronym: 'ONTO-2',
      concept_id: 'http://example.org/concept/4',
      properties: props_class.new(['Data 4']),
      top_keys: [],
      bottom_keys: [],
      exclude_keys: []
    )
    comp4.render_in(@view_context)
    assert_equal 4, MockSDKHTTP.calls.size, 'Different API origin must trigger separate lookup'
  end

  # Case 6: Bounded to 20 lookup misses per request; all values still rendered
  def test_bounded_lookup_misses_at_most_20_per_request_with_all_values_rendered
    # 25 distinct unknown property IRIs that all result in misses
    iri_list = (1..25).map { |i| "http://example.org/bounded#prop%02d" % i }
    MockSDKHTTP.handler = lambda do |_path|
      OpenStruct.new(label: nil) # all miss
    end

    props_class = Struct.new(*iri_list.map(&:to_sym))
    props_values = (1..25).map { |i| ["Value for prop %02d" % i] }
    props = props_class.new(*props_values)

    comp = ConceptDetailsComponent.new(
      id: 'bounded-miss-test',
      acronym: 'BOUNDED-ACRO',
      concept_id: 'http://example.org/concept/bounded',
      properties: props,
      top_keys: [],
      bottom_keys: [],
      exclude_keys: []
    )

    html = comp.render_in(@view_context)
    doc = parse_doc(html)

    # Assert exactly 20 HTTP calls made, bounded by MAX_PROPERTY_LABEL_MISSES_PER_REQUEST
    assert_equal 20, MockSDKHTTP.calls.size, 'Lookups must be bounded to 20 misses per request'
    assert_equal 20, @fake_env['ontoportal.property_labels_miss_count']

    # Assert ALL 25 rows are rendered in the HTML table (none dropped)
    rows = doc.css('tbody tr').reject { |tr| tr.at_css('#content_resource_formats') }
    assert_equal 25, rows.size, 'All 25 properties must be rendered despite bounded lookup'

    # Assert all 25 values are present
    (1..25).each do |i|
      val = "Value for prop %02d" % i
      assert_includes html, val, "Value '#{val}' must be rendered in table"
    end
  end

  # Case 7: Distinct predicates with equal display labels do NOT silently collapse fields
  def test_equal_display_labels_do_not_silently_collapse_fields_and_retain_values
    iri_a = 'http://example.org/predicates/alpha'
    iri_b = 'http://example.org/predicates/beta'

    MockSDKHTTP.handler = lambda do |path|
      # Both predicates resolve to the exact same display label: "Shared Description"
      if path.include?('alpha') || path.include?('beta')
        OpenStruct.new(label: 'Shared Description')
      else
        nil
      end
    end

    props_class = Struct.new(iri_a.to_sym, iri_b.to_sym)
    props = props_class.new(
      ['Unique value from Alpha predicate'],
      ['Unique value from Beta predicate']
    )

    comp = ConceptDetailsComponent.new(
      id: 'collapse-guard-test',
      acronym: 'TEST-ACRO',
      concept_id: 'http://example.org/concept/equal_labels',
      properties: props,
      top_keys: [],
      bottom_keys: [],
      exclude_keys: []
    )

    html = comp.render_in(@view_context)
    doc = parse_doc(html)

    # Must render 2 distinct rows, not 1 collapsed row
    rows = doc.css('tbody tr').reject { |tr| tr.at_css('#content_resource_formats') }
    assert_equal 2, rows.size, 'Two distinct predicates with equal labels must render as 2 rows'

    # Both row headers display "Shared Description"
    row_headers = rows.map { |r| r.at_css('th span')&.text&.strip }
    assert_equal ['Shared Description', 'Shared Description'], row_headers

    # Each row header retains its distinct raw IRI tooltip
    titles = rows.map { |r| r.at_css('th span')['title'] }
    assert_equal [iri_a, iri_b], titles

    # Distinct values from both predicates are rendered
    assert_includes html, 'Unique value from Alpha predicate'
    assert_includes html, 'Unique value from Beta predicate'
  end

  # Case 8: Multilingual values and raw IRI tooltips are retained
  def test_multilingual_values_and_raw_iri_tooltips_retained
    target_iri = 'http://example.org/ns#multilingualNote'
    MockSDKHTTP.handler = lambda do |_path|
      OpenStruct.new(label: 'Multilingual Note')
    end

    props_class = Struct.new(target_iri.to_sym)
    props = props_class.new(
      OpenStruct.new(
        en: ['English description text'],
        fr: ['Texte de description en français']
      )
    )

    comp = ConceptDetailsComponent.new(
      id: 'multilingual-label-test',
      acronym: 'TEST-ACRO',
      concept_id: 'http://example.org/concept/multi',
      properties: props,
      top_keys: [],
      bottom_keys: [],
      exclude_keys: []
    )

    html = comp.render_in(@view_context)
    doc = parse_doc(html)

    th_span = doc.at_css('th span')
    assert_equal 'Multilingual Note', th_span.text.strip
    assert_equal target_iri, th_span['title']

    en_def = doc.at_css('.definition span:contains("English description text")')
    assert en_def, 'English text must be rendered'
    en_badge = doc.at_css('.definition .badge:contains("EN")')
    assert en_badge, 'EN badge must be rendered'

    fr_def = doc.at_css('.definition span:contains("Texte de description en français")')
    assert fr_def, 'French text must be rendered'
    fr_badge = doc.at_css('.definition .badge:contains("FR")')
    assert fr_badge, 'FR badge must be rendered'
  end
end
