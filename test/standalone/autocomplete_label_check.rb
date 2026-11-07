# frozen_string_literal: true

require 'minitest/autorun'
require 'minitest/mock'
require 'ostruct'
require 'uri'
require 'json'

# =============================================================================
# Standalone Offline Autocomplete & Multilingual Label Check (ONTO-T-B08)
#
# Validates the B08 contract for autocomplete multilingual label selection:
# 1. Native Rails ActionController/ActionView 7.0.8 environment asserted.
# 2. Native real Rails action dispatch for SearchController#json_search.
# 3. Multilingual Hash and OpenStruct select later matching label when
#    controller @search_query is nil.
# 4. Outbound query normalization: stripped user query before backend '*'
#    wildcard append; backend Class.search receives wildcard query; label helper
#    receives stripped query.
# 5. String, Array, Hash, and OpenStruct label shapes handled without stubbing
#    helpers; uses real MultiLanguagesHelper#language_hash.
# 6. Empty labels (nil, empty string, empty array, empty hash, empty OpenStruct,
#    hash with nil/blank values) handled without nil.downcase or other errors.
# 7. No-match query and nil query fall back safely to first valid label.
# 8. Main search index aggregation path (SearchAggregator#aggregate_results /
#    search_result_elem) preserves query matching and fallback.
# 9. Legacy pipe-delimited serialization format, custom separator, obsolete class
#    ordering, and json callback wrapper preserved.
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

  class ApplicationController < ActionController::Base
    def self.skip_before_action(*); end
    def determine_layout; false; end
    def t(key, **); key; end
    def helpers; self; end
    def request_lang; 'en'; end
    def escape(val); URI.encode_www_form_component(val.to_s); end
    def link_last_part(url); url.to_s.split('/').last; end
  end

  FRAMEWORK_MODE = "real Rails ActionController/ActionView #{ActionPack::VERSION::STRING}"
rescue LoadError => e
  FRAMEWORK_MODE = "unavailable: #{e.message}"
end

puts "[Framework Mode] #{FRAMEWORK_MODE}"

# Finite stubs for unrelated helpers/modules required at load time
module OntologiesHelper; end
module ComponentsHelper; end
module UrlsHelper; end
module FederationHelper
  def federated_request?; false; end
  def class_federation_configuration(*); {}; end
end
module SearchContent; end

module LinkedData
  module Client
    module Models
      class Class
        def self.search(*); end
      end
      class Ontology
        def self.all(*); []; end
      end
    end
  end
end

# Require actual helper, concern, and controller under test
require_relative '../../app/helpers/multi_languages_helper'
require_relative '../../app/controllers/concerns/search_aggregator'
require_relative '../../app/controllers/search_controller'

class MockClassResult < OpenStruct
  def [](k)
    k == '@id' ? id : super
  end

  def obsolete?
    !!self[:obsolete]
  end
end

class AutocompleteLabelCheck < Minitest::Test
  def build_mock_class(id: 'http://example.org/test#Cat', pref_label: 'Cat', obsolete: false, synonyms: ['Feline'], definition: ['A feline carnivore'])
    MockClassResult.new(
      id: id,
      prefLabel: pref_label,
      links: { 'ontology' => 'http://data.bioontology.org/ontologies/TEST' },
      obsolete: obsolete,
      synonym: synonyms,
      definition: definition
    )
  end

  def dispatch_json_search(query_string, class_results = [])
    ctrl = SearchController.new
    env = ActionDispatch::TestRequest.create.env
    uri = URI.parse("/search/json_search?#{query_string}")
    env['PATH_INFO'] = uri.path
    env['QUERY_STRING'] = uri.query || ''
    req = ActionDispatch::Request.new(env)
    res = ActionDispatch::Response.new

    captured_search = []
    mock_search = proc do |query, params|
      captured_search << {
        query: query,
        params: params.to_unsafe_h
      }
      OpenStruct.new(collection: class_results)
    end

    LinkedData::Client::Models::Class.stub(:search, mock_search) do
      ctrl.dispatch(:json_search, req, res)
    end

    [ctrl, res, captured_search]
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
  # Test 2: Multilingual Hash selects later matching label with nil controller @search_query
  # ===========================================================================
  def test_json_search_multilingual_hash_selects_later_matching_label_with_nil_search_query
    cls = build_mock_class(pref_label: { 'fr' => 'Chat', 'en' => 'Cat' })
    ctrl, res, captured = dispatch_json_search('q=cat', [cls])

    assert_equal 200, res.status
    assert_nil ctrl.instance_variable_get(:@search_query),
               'SearchController#json_search must not depend on controller @search_query initialization'
    assert_equal 1, captured.size
    assert_equal 'cat*', captured.first[:query], 'Outbound query must have backend wildcard appended'

    body = res.body
    assert_includes body, 'Cat|http://example.org/test#Cat',
                    'Multilingual Hash must select later matching label "Cat" instead of first label "Chat"'
    refute_includes body, 'Chat|', 'Unmatched label "Chat" must not be emitted as target value'
  end

  # ===========================================================================
  # Test 3: Multilingual OpenStruct selects later matching label
  # ===========================================================================
  def test_json_search_multilingual_open_struct_selects_later_matching_label
    open_struct_label = OpenStruct.new(
      links: { 'ontology' => 'http://example.org/test' },
      context: { 'en' => 'http://example.org/def' },
      fr: 'Chat',
      en: 'Cat'
    )
    cls = build_mock_class(pref_label: open_struct_label)
    ctrl, res, captured = dispatch_json_search('q=cat', [cls])

    assert_equal 200, res.status
    assert_nil ctrl.instance_variable_get(:@search_query)
    assert_equal 'cat*', captured.first[:query]

    body = res.body
    assert_includes body, 'Cat|http://example.org/test#Cat',
                    'OpenStruct multilingual label must select matching label "Cat" rejecting links/context metadata'
    refute_includes body, 'Chat|'
  end

  # ===========================================================================
  # Test 4: Supported String and Array label forms
  # ===========================================================================
  def test_json_search_supports_string_and_array_labels
    cls_string = build_mock_class(id: 'http://example.org/test#Dog1', pref_label: 'Canine')
    cls_array = build_mock_class(id: 'http://example.org/test#Dog2', pref_label: ['Hound', 'Canine'])

    _ctrl, res, _captured = dispatch_json_search('q=canine', [cls_string, cls_array])

    assert_equal 200, res.status
    body = res.body
    assert_includes body, 'Canine|http://example.org/test#Dog1', 'String label must be preserved directly'
    assert_includes body, 'Hound|http://example.org/test#Dog2',
                    'Array label must use first entry per real MultiLanguagesHelper#language_hash'
  end

  # ===========================================================================
  # Test 5: Empty labels handled safely without nil.downcase or other errors
  # ===========================================================================
  def test_json_search_handles_empty_labels_without_error
    empty_cases = [
      build_mock_class(id: 'http://example.org/test#E1', pref_label: ''),
      build_mock_class(id: 'http://example.org/test#E2', pref_label: []),
      build_mock_class(id: 'http://example.org/test#E3', pref_label: {}),
      build_mock_class(id: 'http://example.org/test#E4', pref_label: OpenStruct.new),
      build_mock_class(id: 'http://example.org/test#E5', pref_label: nil),
      build_mock_class(id: 'http://example.org/test#E6', pref_label: { 'en' => nil }),
      build_mock_class(id: 'http://example.org/test#E7', pref_label: { 'en' => '' })
    ]

    _ctrl, res, _captured = dispatch_json_search('q=test', empty_cases)

    assert_equal 200, res.status
    body = res.body
    (1..7).each do |i|
      assert_includes body, "|http://example.org/test#E#{i}|", "Empty label case E#{i} must serialize without error"
    end
  end

  # ===========================================================================
  # Test 6: No-match fallback without nil.downcase
  # ===========================================================================
  def test_json_search_no_match_falls_back_without_nil_downcase
    cls_hash = build_mock_class(id: 'http://example.org/test#Fallback1', pref_label: { 'fr' => 'Chat', 'en' => 'Cat' })
    cls_ostruct = build_mock_class(id: 'http://example.org/test#Fallback2', pref_label: OpenStruct.new(fr: 'Chien', en: 'Dog'))
    cls_first_blank = build_mock_class(id: 'http://example.org/test#Fallback3', pref_label: { 'fr' => '', 'en' => 'Elephant' })

    _ctrl, res, _captured = dispatch_json_search('q=zebra', [cls_hash, cls_ostruct, cls_first_blank])

    assert_equal 200, res.status
    body = res.body
    assert_includes body, 'Chat|http://example.org/test#Fallback1', 'Unmatched Hash must fall back to first valid label'
    assert_includes body, 'Chien|http://example.org/test#Fallback2', 'Unmatched OpenStruct must fall back to first valid label'
    assert_includes body, 'Elephant|http://example.org/test#Fallback3', 'Unmatched Hash must skip empty value and return first valid fallback'
  end

  # ===========================================================================
  # Test 7: Outbound q normalization before backend wildcard
  # ===========================================================================
  def test_json_search_normalizes_outbound_q_before_wildcard
    cls = build_mock_class(pref_label: { 'fr' => 'Chat', 'en' => 'Cat' })

    # Query with whitespace padding
    _ctrl, res, captured = dispatch_json_search('q=%20%20cat%20%20', [cls])
    assert_equal 200, res.status
    assert_equal 'cat*', captured.first[:query], 'Whitespace-padded query must be stripped before wildcard append'
    assert_includes res.body, 'Cat|http://example.org/test#Cat',
                    'Label matching must use stripped user query "cat" rather than "  cat  " or wildcard "cat*"'

    # Query already having wildcard
    _ctrl2, _res2, captured2 = dispatch_json_search('q=cat*', [cls])
    assert_equal 'cat*', captured2.first[:query], 'Existing wildcard must not be duplicated'
  end

  # ===========================================================================
  # Test 8: Legacy autocomplete serialization and options unaffected
  # ===========================================================================
  def test_json_search_preserves_legacy_serialization_and_options
    cls_active = build_mock_class(
      id: 'http://example.org/test#Active',
      pref_label: { 'en' => 'ActiveConcept' },
      obsolete: false,
      synonyms: ['SynA', 'SynB'],
      definition: ['Def1', 'Def2']
    )
    cls_obsolete = build_mock_class(
      id: 'http://example.org/test#Obsolete',
      pref_label: { 'en' => 'ObsoleteConcept' },
      obsolete: true,
      synonyms: ['OldSyn'],
      definition: ['OldDef']
    )

    # Standard serialization
    _ctrl, res, _captured = dispatch_json_search('q=concept', [cls_active, cls_obsolete])
    assert_equal 200, res.status
    assert_match(%r{\Atext/html\b}, res.content_type)

    body = res.body
    active_entry = "ActiveConcept|http://example.org/test#Active||TEST|http://example.org/test#Active|ActiveConcept|SynA;SynB|TEST|TEST|Def1.+Def2~!~"
    obsolete_entry = "ObsoleteConcept [obsolete]|http://example.org/test#Obsolete||TEST|http://example.org/test#Obsolete|ObsoleteConcept|OldSyn|TEST|TEST|OldDef~!~"

    assert_includes body, active_entry
    assert_includes body, obsolete_entry
    assert body.index(active_entry) < body.index(obsolete_entry), 'Obsolete entries must appear at the end'

    # Custom separator and single ontology filter
    _ctrl_sep, res_sep, _cap_sep = dispatch_json_search('q=concept&separator=%23%23%23&id=TEST', [cls_active])
    assert_includes res_sep.body, '|Def1.+Def2###'

    # JSON response with callback wrapper
    _ctrl_json, res_json, _cap_json = dispatch_json_search('q=concept&response=json&callback=portalSuggest', [cls_active])
    assert_match(%r{\Aapplication/javascript\b}, res_json.content_type)
    assert_match(/^portalSuggest\(\{data:"ActiveConcept\|.*"\}\)$/, res_json.body)
  end

  # ===========================================================================
  # Test 9: Main search aggregation preserves query matching and fallback
  # ===========================================================================
  def test_main_search_aggregation_preserves_query_matching_and_fallback
    ctrl = SearchController.new
    req = ActionDispatch::TestRequest.create
    ctrl.set_request!(req)
    ctrl.set_response!(ActionDispatch::Response.new)

    res_matching = MockClassResult.new(
      id: 'http://example.org/test#Cat',
      prefLabel: { 'fr' => 'Chat', 'en' => 'Cat' },
      links: { 'ontology' => 'http://data.bioontology.org/ontologies/TEST' },
      definition: ['Feline']
    )

    # 1. Matching case in aggregate_results
    ctrl.instance_variable_set(:@search_query, 'cat')
    results = ctrl.aggregate_results('cat', [res_matching])
    assert_equal 1, results.size
    assert_equal 'Cat - TEST', results.first[:root][:title],
                 'Main search aggregation must match query "cat" to English label "Cat"'

    # 2. Case-insensitive matching
    ctrl.instance_variable_set(:@search_query, 'CAT')
    results_upper = ctrl.aggregate_results('CAT', [res_matching])
    assert_equal 'Cat - TEST', results_upper.first[:root][:title],
                 'Main search aggregation must be case-insensitive'

    # 3. Fallback when query does not match
    ctrl.instance_variable_set(:@search_query, 'dog')
    results_nomatch = ctrl.aggregate_results('dog', [res_matching])
    assert_equal 'Chat - TEST', results_nomatch.first[:root][:title],
                 'Main search aggregation must fall back to first valid label "Chat" when query does not match'
  end

  # ===========================================================================
  # Test 10: search_concept_label direct helper contract
  # ===========================================================================
  def test_search_concept_label_direct_contract
    ctrl = SearchController.new

    # String & Array
    assert_equal 'Lion', ctrl.send(:search_concept_label, 'Lion', 'lio')
    assert_equal 'Tiger', ctrl.send(:search_concept_label, ['Tiger', 'Panther'], 'pan')

    # Hash
    hash_label = { 'de' => 'Hund', 'en' => 'Dog' }
    assert_equal 'Dog', ctrl.send(:search_concept_label, hash_label, 'dog')
    assert_equal 'Hund', ctrl.send(:search_concept_label, hash_label, 'hund')
    assert_equal 'Hund', ctrl.send(:search_concept_label, hash_label, 'cat') # no match fallback
    assert_equal 'Hund', ctrl.send(:search_concept_label, hash_label, nil)   # nil query fallback
    assert_equal 'Hund', ctrl.send(:search_concept_label, hash_label, '')    # empty query fallback

    # OpenStruct
    ostruct_label = OpenStruct.new(de: 'Hund', en: 'Dog')
    assert_equal 'Dog', ctrl.send(:search_concept_label, ostruct_label, 'dog')
    assert_equal 'Hund', ctrl.send(:search_concept_label, ostruct_label, nil)

    # Empty forms
    assert_nil ctrl.send(:search_concept_label, {}, 'test')
    assert_nil ctrl.send(:search_concept_label, OpenStruct.new, 'test')
    assert_nil ctrl.send(:search_concept_label, nil, 'test')

    # Nested Array of OpenStruct
    nested = [OpenStruct.new(de: 'Hund', en: 'Dog')]
    assert_equal 'Dog', ctrl.send(:search_concept_label, nested, 'dog')
  end

  # ===========================================================================
  # Test 11: json_search response=rows wire contract (ONTO-T-J02)
  # ===========================================================================
  def test_json_search_rows_mode_preserves_columns_ordering_and_metacharacters
    cls_active = build_mock_class(
      id: 'http://example.org/test#Complex\\Cat"1"',
      pref_label: 'Complex | "Cat" \\ \n 🌍 ~!~',
      obsolete: false,
      synonyms: ['Syn | 1', 'Syn "2"'],
      definition: ['Def | 1', 'Def ~!~ 2']
    )
    cls_obsolete = build_mock_class(
      id: 'http://example.org/test#OldCat',
      pref_label: 'OldCat',
      obsolete: true,
      synonyms: ['OldSyn'],
      definition: ['OldDef']
    )

    # 1. Multiple/all ontologies: 10 columns
    _ctrl_all, res_all, cap_all = dispatch_json_search('q=cat&response=rows', [cls_active, cls_obsolete])
    assert_equal 200, res_all.status
    assert_match(%r{\Aapplication/json\b}, res_all.content_type)
    refute cap_all.first[:params].key?('response'),
           'UI-wire mode response=rows must not be forwarded as API search semantics'

    rows_all = JSON.parse(res_all.body)
    assert_equal 2, rows_all.size
    assert_equal 10, rows_all[0].size, 'Multiple ontologies must return exactly 10 columns'
    assert_equal 10, rows_all[1].size

    # Verify column indexes, types, and raw metacharacters preservation
    row_active = rows_all[0]
    assert_equal 'Complex | "Cat" \\ \n 🌍 ~!~', row_active[0] # label / target
    assert_equal 'http://example.org/test#Complex\\Cat"1"', row_active[1] # id
    assert_equal '', row_active[2] # record_type
    assert_equal 'TEST', row_active[3] # acronym
    assert_equal 'http://example.org/test#Complex\\Cat"1"', row_active[4] # id duplicated
    assert_equal 'Complex | "Cat" \\ \n 🌍 ~!~', row_active[5] # target_value
    assert_equal 'Syn | 1;Syn "2"', row_active[6] # synonyms
    assert_equal 'TEST', row_active[7] # acronym
    assert_equal 'TEST', row_active[8] # acronym
    assert_equal CGI.escape('Def | 1. Def ~!~ 2'), row_active[9] # CGI-encoded definition
    row_active.each { |col| assert_kind_of String, col, 'Every column must be a String' }

    # Obsolete class ordering and marker
    row_obs = rows_all[1]
    assert_equal 'OldCat [obsolete]', row_obs[0]
    assert_equal CGI.escape('OldDef'), row_obs[9]

    # 2. Single ontology: 8 columns
    _ctrl_single, res_single, _cap_single = dispatch_json_search('q=cat&response=rows&id=TEST', [cls_active])
    assert_equal 200, res_single.status
    rows_single = JSON.parse(res_single.body)
    assert_equal 1, rows_single.size
    assert_equal 8, rows_single[0].size, 'Single ontology must return exactly 8 columns'
    assert_equal CGI.escape('Def | 1. Def ~!~ 2'), rows_single[0][7], '8th column must be CGI-encoded definition'
  end

  # ===========================================================================
  # Test 12: json_search callback validation and safe JSONP encoding (ONTO-T-J02)
  # ===========================================================================
  def test_json_search_callback_validation_and_safe_jsonp
    cls = build_mock_class(
      id: 'http://example.org/test#Q',
      pref_label: "Quote\" \\ \n 🌍",
      synonyms: ['Syn"quote'],
      definition: ['Def']
    )

    # Valid simple and dotted identifiers
    ['portalSuggest', 'jQuery3600123_456', 'myApp.callbacks.suggest', '$custom_cb'].each do |valid_cb|
      _ctrl, res, cap = dispatch_json_search("q=cat&response=json&callback=#{valid_cb}", [cls])
      assert_equal 200, res.status
      assert_match(%r{\Aapplication/javascript\b}, res.content_type)
      assert_equal 1, cap.size, "Valid callback #{valid_cb} must call upstream search"
      assert res.body.start_with?("#{valid_cb}({data:\"")
      assert res.body.end_with?("\"})")
      # Metacharacters roundtrip cleanly without quote substitution
      assert_includes res.body, "Quote\\\" \\\\ \\n 🌍"
    end

    # Invalid callbacks rejected with 400 BEFORE upstream search (no API calls)
    [
      'alert(1)',
      '<script>alert(1)</script>',
      'foo;bar',
      'bad"callback"',
      '123foo',
      'foo..bar',
      'foo/bar'
    ].each do |invalid_cb|
      _ctrl, res, cap = dispatch_json_search("q=cat&response=json&callback=#{CGI.escape(invalid_cb)}", [cls])
      assert_equal 400, res.status, "Invalid callback #{invalid_cb} must be rejected with 400"
      assert_equal 'Invalid callback', res.body
      assert_empty cap, "Invalid callback #{invalid_cb} must not invoke upstream search"
    end

    # response=json without callback rejected with 400 BEFORE upstream search
    _ctrl_missing, res_missing, cap_missing = dispatch_json_search('q=cat&response=json', [cls])
    assert_equal 400, res_missing.status
    assert_empty cap_missing
  end
end
