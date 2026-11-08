# frozen_string_literal: true

require 'minitest/autorun'
require 'logger'
require 'ostruct'
require 'uri'
require 'cgi'

# =============================================================================
# Standalone Offline Annotator Text Preservation Check (ONTO-T-B09)
#
# Validates the B09 text preservation and parameter encoding contracts:
# 1. Real Rails ActionController dispatch of AnnotatorController#index.
# 2. Finite doubles for LinkedData::Client::HTTP.get (recording outbound params),
#    LinkedData::Client::Models::Ontology.all, Ontology.find_by_acronym, and
#    rendering.
# 3. Outbound text to HTTP client exactly preserves:
#    - Accented words (e.g. café, naïve, résumé, Schrödinger)
#    - Greek letters (e.g. α-globin, β-amyloid, γ-secretase, δ-catenin, ε-toxin)
#    - Apostrophes (e.g. patient's, Alzheimer's, Parkinson's)
#    - Hyphens (e.g. high-affinity, anti-inflammatory, multi-drug-resistant)
#    - Parentheses (e.g. (COVID-19), [IC50], {pH: 7.4})
#    - Newlines (\n, \r\n)
#    - Combined complex multilingual scientific input
# 4. Ordinary ASCII text remains unchanged.
# 5. params[:text] is NOT mutated in place (view textarea echoes identical text).
# 6. json_link and @rdf_link round-trip the text (encoded exactly once, decodes
#    back to original input without truncation or double-escaping).
# 7. AnnotatorController#remove_special_chars is completely removed.
# 8. Configured-annotator backend UTF-8 and offset behavior is explicitly recorded
#    as unverified.
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
require 'ontologies_api_client'

ActionController::Base.logger = Logger.new(nil)
Rails.logger = Logger.new(nil)
ActionController::Base.allow_forgery_protection = false

$ANNOTATOR_URL = 'http://example.com/annotator'
$NCBO_ANNOTATOR_URL = 'http://example.com/ncbo_annotatorplus'
$NCBO_API_KEY = 'test-ncbo-key'
$REST_URL = 'http://example.com'
$API_KEY = 'test-api-key'
$ENABLE_SLICES = false

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
require 'application_controller'
require 'annotator_controller'

AnnotatorController.skip_before_action :set_locale, :domain_ontology_set, :init_trial_license, raise: false

class AnnotatorTextPreservationCheck < Minitest::Test
  def setup
    @recorded_http_calls = []
    @test_ont = OpenStruct.new(id: 'http://example.org/ontologies/TEST', acronym: 'TEST', name: 'Test Ontology')

    # Finite double for LinkedData::Client::HTTP.get (records params by value)
    @orig_http_get = LinkedData::Client::HTTP.method(:get) if LinkedData::Client::HTTP.respond_to?(:get)
    LinkedData::Client::HTTP.singleton_class.send(:define_method, :get) do |uri, params = {}, options = {}|
      deep_copied_params = params.is_a?(Hash) ? Marshal.load(Marshal.dump(params)) : params.dup
      AnnotatorTextPreservationCheck.recorded_http_calls << { uri: uri, params: deep_copied_params, options: options }
      []
    end

    # Finite double for LinkedData::Client::Models::Ontology.all
    @orig_ont_all = LinkedData::Client::Models::Ontology.method(:all) if LinkedData::Client::Models::Ontology.respond_to?(:all)
    LinkedData::Client::Models::Ontology.singleton_class.send(:define_method, :all) do |*args|
      [OpenStruct.new(id: 'http://example.org/ontologies/TEST', acronym: 'TEST', name: 'Test Ontology')]
    end

    # Finite double for LinkedData::Client::Models::Ontology.find_by_acronym
    @orig_ont_find = LinkedData::Client::Models::Ontology.method(:find_by_acronym) if LinkedData::Client::Models::Ontology.respond_to?(:find_by_acronym)
    LinkedData::Client::Models::Ontology.singleton_class.send(:define_method, :find_by_acronym) do |*args|
      []
    end
  end

  def teardown
    LinkedData::Client::HTTP.singleton_class.send(:define_method, :get, @orig_http_get) if @orig_http_get
    LinkedData::Client::Models::Ontology.singleton_class.send(:define_method, :all, @orig_ont_all) if @orig_ont_all
    LinkedData::Client::Models::Ontology.singleton_class.send(:define_method, :find_by_acronym, @orig_ont_find) if @orig_ont_find
  end

  class << self
    attr_accessor :recorded_http_calls
  end
  self.recorded_http_calls = []

  # Helper to dispatch AnnotatorController#index through real Rails ActionPack controller stack
  def dispatch_index(submitted_text, extra_params = {})
    self.class.recorded_http_calls.clear

    ctrl = AnnotatorController.new
    req = ActionDispatch::TestRequest.create
    req.request_method = 'GET'
    req.params[:text] = submitted_text
    extra_params.each { |k, v| req.params[k] = v }
    req.set_header 'rack.session', {}
    req.set_header 'action_dispatch.request.flash_hash', ActionDispatch::Flash::FlashHash.new
    res = ActionDispatch::TestResponse.create
    ctrl.set_request!(req)
    ctrl.set_response!(res)

    # Finite double for rendering: captures view assigns and fulfills default_render
    rendered_data = nil
    ctrl.define_singleton_method(:default_render) do |*args|
      rendered_data = {
        action: action_name,
        text_param: params[:text],
        json_link: @json_link,
        rdf_link: @rdf_link,
        results: @results,
        direct_results: @direct_results,
        parents_results: @parents_results
      }
      render plain: "rendered #{action_name} with text=#{params[:text]}"
    end

    ctrl.process(:index)
    [ctrl, req, res, rendered_data]
  end

  # ===========================================================================
  # 1. Removal of Destructive Helper Method
  # ===========================================================================

  def test_remove_special_chars_helper_removed
    ctrl = AnnotatorController.new
    refute ctrl.respond_to?(:remove_special_chars, true),
           'AnnotatorController must not define or expose remove_special_chars helper'
  end

  # ===========================================================================
  # 2. Text Preservation: Accents, Greek Letters, Apostrophes, Hyphens, Parens, Newlines
  # ===========================================================================

  def test_outbound_text_preserves_accented_words
    input = 'café naïve résumé Schrödinger Brüsk Über'
    original_copy = input.dup

    ctrl, req, res, rendered = dispatch_index(input)

    assert_equal 200, res.status
    assert_equal 1, self.class.recorded_http_calls.length
    outbound_text = self.class.recorded_http_calls.first[:params][:text]

    assert_equal original_copy, outbound_text, 'Outbound HTTP text must preserve accented words exactly'
    assert_equal original_copy, input, 'Input text variable must not be mutated in place'
    assert_equal original_copy, ctrl.params[:text], 'Controller params[:text] must remain unmutated for view echo'
    assert_equal original_copy, rendered[:text_param], 'Rendered text_param must reflect unmutated original text'
  end

  def test_outbound_text_preserves_greek_letters
    input = 'α-globin, β-amyloid, γ-secretase, δ-catenin, ε-toxin'
    original_copy = input.dup

    ctrl, req, res, _rendered = dispatch_index(input)

    assert_equal 200, res.status
    outbound_text = self.class.recorded_http_calls.first[:params][:text]

    assert_equal original_copy, outbound_text, 'Outbound HTTP text must preserve Greek letters exactly'
    assert_equal original_copy, input, 'Input text variable must not be mutated in place'
    assert_equal original_copy, ctrl.params[:text], 'Controller params[:text] must remain unmutated'
  end

  def test_outbound_text_preserves_apostrophes
    input = "patient's symptoms, Alzheimer's disease, and Parkinson's diagnosis"
    original_copy = input.dup

    ctrl, req, res, _rendered = dispatch_index(input)

    assert_equal 200, res.status
    outbound_text = self.class.recorded_http_calls.first[:params][:text]

    assert_equal original_copy, outbound_text, 'Outbound HTTP text must preserve apostrophes exactly'
    assert_equal original_copy, input, 'Input text variable must not be mutated in place'
    assert_equal original_copy, ctrl.params[:text], 'Controller params[:text] must remain unmutated'
  end

  def test_outbound_text_preserves_hyphens
    input = 'high-affinity anti-inflammatory multi-drug-resistant SARS-CoV-2 single-cell'
    original_copy = input.dup

    ctrl, req, res, _rendered = dispatch_index(input)

    assert_equal 200, res.status
    outbound_text = self.class.recorded_http_calls.first[:params][:text]

    assert_equal original_copy, outbound_text, 'Outbound HTTP text must preserve hyphens exactly'
    assert_equal original_copy, input, 'Input text variable must not be mutated in place'
    assert_equal original_copy, ctrl.params[:text], 'Controller params[:text] must remain unmutated'
  end

  def test_outbound_text_preserves_parentheses_and_brackets
    input = '(SARS-CoV-2) [binding affinity] {IC50 = 2.5 nM} <target: ACE2>'
    original_copy = input.dup

    ctrl, req, res, _rendered = dispatch_index(input)

    assert_equal 200, res.status
    outbound_text = self.class.recorded_http_calls.first[:params][:text]

    assert_equal original_copy, outbound_text, 'Outbound HTTP text must preserve parentheses and brackets exactly'
    assert_equal original_copy, input, 'Input text variable must not be mutated in place'
    assert_equal original_copy, ctrl.params[:text], 'Controller params[:text] must remain unmutated'
  end

  def test_outbound_text_preserves_newlines_and_whitespace
    input = "First paragraph: overview.\nSecond line with indentation.\r\nThird line after CRLF.\n"
    original_copy = input.dup

    ctrl, req, res, _rendered = dispatch_index(input)

    assert_equal 200, res.status
    outbound_text = self.class.recorded_http_calls.first[:params][:text]

    assert_equal original_copy, outbound_text, 'Outbound HTTP text must preserve newlines exactly'
    assert_equal original_copy, input, 'Input text variable must not be mutated in place'
    assert_equal original_copy, ctrl.params[:text], 'Controller params[:text] must remain unmutated'
  end

  def test_outbound_text_preserves_combined_complex_multilingual_scientific_text
    input = "Café au lait spot observed in patient's dermis.\nTarget: α-1 antitrypsin & β-globin mutation (variant: [rs1234]).\nHigh-affinity binding: IC50 < 0.5 μM."
    original_copy = input.dup

    ctrl, req, res, rendered = dispatch_index(input)

    assert_equal 200, res.status
    outbound_text = self.class.recorded_http_calls.first[:params][:text]

    assert_equal original_copy, outbound_text, 'Outbound HTTP text must preserve complex scientific text exactly'
    assert_equal original_copy, input, 'Input text variable must not be mutated in place'
    assert_equal original_copy, ctrl.params[:text], 'Controller params[:text] must remain unmutated'
    assert_equal original_copy, rendered[:text_param], 'Rendered text must match original input'
  end

  # ===========================================================================
  # 3. Ordinary ASCII Input Unchanged
  # ===========================================================================

  def test_ordinary_ascii_input_unchanged
    input = 'Standard plain ASCII text with numbers 12345 and simple words only.'
    original_copy = input.dup

    ctrl, req, res, _rendered = dispatch_index(input)

    assert_equal 200, res.status
    outbound_text = self.class.recorded_http_calls.first[:params][:text]

    assert_equal original_copy, outbound_text, 'Ordinary ASCII input must remain unchanged'
    assert_equal original_copy, ctrl.params[:text], 'Controller params[:text] must remain unchanged'
  end

  # ===========================================================================
  # 4. json_link and @rdf_link Single-Encoding and Round-Trip
  # ===========================================================================

  def test_json_link_round_trips_multilingual_and_punctuated_text
    input = "Café & α-globin: patient's (high-affinity) test - \nnewline"

    ctrl, _req, res, rendered = dispatch_index(input)

    assert_equal 200, res.status
    json_link = rendered[:json_link]
    refute_nil json_link, '@json_link must be assigned'

    # Ensure json_link is a valid parseable URI
    parsed_uri = URI.parse(json_link)
    assert_equal 'example.com', parsed_uri.host
    assert_equal '/annotator', parsed_uri.path

    # Parse query parameters using standard URI www_form decoding
    decoded_params = URI.decode_www_form(parsed_uri.query).to_h
    assert_equal input, decoded_params['text'], 'json_link query param "text" must decode back to exact input'
    assert_equal 'test-api-key', decoded_params['apikey'], 'json_link must include configured apikey'

    # Parse query parameters using CGI.parse
    cgi_decoded = CGI.parse(parsed_uri.query)
    assert_equal input, cgi_decoded['text'].first, 'CGI.parse must also decode back to exact input'

    # Assert exactly once encoded (no double-escaping of percent sign: %25)
    refute_includes json_link, '%25C3', 'Text must not be double-encoded in json_link'
    refute_includes json_link, '%2526', 'Ampersand must not be double-encoded in json_link'
  end

  def test_rdf_link_round_trips_and_preserves_format
    input = "Café & α-globin: patient's (high-affinity) test - \nnewline"

    ctrl, _req, res, rendered = dispatch_index(input)

    assert_equal 200, res.status
    rdf_link = rendered[:rdf_link]
    refute_nil rdf_link, '@rdf_link must be assigned'

    parsed_uri = URI.parse(rdf_link)
    decoded_params = URI.decode_www_form(parsed_uri.query).to_h
    assert_equal input, decoded_params['text'], 'rdf_link query param "text" must decode back to exact input'
    assert_equal 'rdf', decoded_params['format'], 'rdf_link must specify format=rdf'
    assert_equal 'test-api-key', decoded_params['apikey'], 'rdf_link must include configured apikey'
  end

  def test_json_link_direct_call_preserves_roundtrip
    ctrl = AnnotatorController.new
    input = "Greek: α, β; Accents: résumé; Quotes: 'single' \"double\"; Parens: (test) [brackets]"
    result_url = ctrl.json_link('http://example.com/api', { text: input, ontologies: 'NCIT,GO' })

    parsed_uri = URI.parse(result_url)
    decoded_params = URI.decode_www_form(parsed_uri.query).to_h
    assert_equal input, decoded_params['text'], 'Direct json_link invocation must round-trip text parameter'
    assert_equal 'NCIT,GO', decoded_params['ontologies'], 'Other parameters must be preserved'
  end

  # ===========================================================================
  # 5. External Annotator Contract Boundary Characterization
  # ===========================================================================

  def test_configured_annotator_offset_convention_recorded_as_unverified
    # Characterization of the boundary: the client UI/controller sends the exact Unicode
    # string, but external annotator backend behavior (whether offsets represent UTF-8 byte
    # offsets, Unicode code point offsets, or UTF-16 code units) cannot be verified offline.
    unverified_contract = {
      annotator_backend_utf8_acceptance: 'UNVERIFIED',
      annotator_offset_unit: 'UNVERIFIED (character vs code point vs byte offset is external service contract)',
      annotator_tokenization_rules: 'UNVERIFIED (external annotator service convention)'
    }

    assert_equal 'UNVERIFIED', unverified_contract[:annotator_backend_utf8_acceptance]
    assert_includes unverified_contract[:annotator_offset_unit], 'UNVERIFIED'
  end

  # Direct matches without context annotations, and annotations from an ontology that is not in the
  # visible list, must render a result row instead of failing the whole page.
  def test_direct_match_and_unlisted_ontology_render_rows
    cls = lambda do |acr, id|
      OpenStruct.new(prefLabel: "Label #{id}", links: { 'self' => "http://example.org/ontologies/#{acr}/classes/#{id}",
                                                       'ontology' => "http://example.org/ontologies/#{acr}" })
    end
    annotations = [
      OpenStruct.new(annotatedClass: cls.call('TEST', 'C1'), annotations: [], hierarchy: [], mappings: []),
      OpenStruct.new(annotatedClass: cls.call('HIDDEN', 'C2'), hierarchy: [], mappings: [],
                     annotations: [OpenStruct.new(from: 1, to: 4, matchType: 'PREF', text: 'word')])
    ]
    LinkedData::Client::HTTP.singleton_class.send(:define_method, :get) do |uri, params = {}, options = {}|
      uri.to_s.include?('/annotator') ? annotations : []
    end

    _ctrl, _req, res, data = dispatch_index('some text')
    assert_equal 200, res.status
    rows = data[:results]
    assert_equal 2, rows.size
    assert_equal 'Test Ontology', rows[0][:ontology][:text]
    assert_equal 'HIDDEN', rows[1][:ontology][:text]
  end
end
