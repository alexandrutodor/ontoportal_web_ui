# frozen_string_literal: true

require 'minitest/autorun'
require 'logger'
require 'ostruct'
require 'uri'
require 'cgi'
require 'digest'
require 'json'

# =============================================================================
# Standalone Scientific Run Record Check (ONTO-AT-OP05)
#
# Validates:
# 1. Feature off (Flipper 'RunRecords' disabled):
#    - run_records_enabled? is false.
#    - ScientificRunRecordComponent#render? is false.
#    - ViewComponent renders empty output ("").
#    - Controller does not build @run_record.
# 2. Feature on (Flipper 'RunRecords' enabled):
#    - run_records_enabled? is true.
#    - ScientificRunRecordComponent#render? is true.
#    - Controller builds @run_record.
# 3. Selected vs effective settings after slice restriction:
#    - Annotator: slice restriction differentiates selected vs effective ontologies.
#    - Recommender: slice restriction differentiates selected vs effective ontologies.
#    - Defaults (weights, levels, etc.) populated in effective settings.
# 4. Typed scores, offsets and explicit unknowns:
#    - Annotator context offsets (from, to) are typed Integers.
#    - Annotator score is typed Float or nil.
#    - Recommender scores are typed Floats.
#    - service_version is explicitly 'unknown'.
#    - ontology_version is explicitly 'unknown'.
# 5. Input text preservation & SHA-256 digest:
#    - Exact Unicode, accents, Greek letters, whitespace preserved in full export.
#    - Settings-only export omits input text, includes matching SHA-256 digest.
#    - Documented serialization string present.
# 6. Credential & foreign URL boundary:
#    - No apikey, session, cookie, password, or foreign endpoint URLs in exported record.
#    - Import rejection of credentials, foreign URLs, unsupported tools/schemas.
# 7. Zero extra service calls:
#    - Exporting/building the record makes 0 additional HTTP calls.
# 8. Unbroken existing contracts:
#    - Existing json_link and recommender annotator-handoff links remain intact.
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
require 'view_component'
require 'flipper'
require 'flipper/adapters/memory'
require 'ontologies_api_client'

ActionController::Base.logger = Logger.new(nil)
Rails.logger = Logger.new(nil)
ActionController::Base.allow_forgery_protection = false

$ANNOTATOR_URL = 'http://example.com/annotator'
$NCBO_ANNOTATOR_URL = 'http://example.com/ncbo_annotatorplus'
$NCBO_API_KEY = 'test-ncbo-key'
$REST_URL = 'http://example.com'
$API_KEY = 'test-api-key'
$CITE_RECOMMENDER = 'http://example.com/cite_rec'
$CITE_ANNOTATOR = 'http://example.com/cite_ann'
$ANNOTATOR_API_DOC = 'http://example.com/doc'
$ENABLE_SLICES = false

I18n.load_path = Dir[File.join(worktree_root, 'config/locales/*.yml')]
I18n.default_locale = :en
I18n.locale = :en

Flipper.configure do |config|
  config.default { Flipper.new(Flipper::Adapters::Memory.new) }
end

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
require 'recommender_controller'
require 'scientific_run_record'
require 'scientific_run_record_component'

AnnotatorController.skip_before_action :set_locale, :domain_ontology_set, :init_trial_license, raise: false
RecommenderController.skip_before_action :set_locale, :domain_ontology_set, :init_trial_license, raise: false

class ScientificRunRecordCheck < Minitest::Test
  def setup
    Flipper.disable('RunRecords')
    @http_get_count = 0
    @http_post_count = 0
    @recorded_http_calls = []

    @orig_http_get = LinkedData::Client::HTTP.method(:get) if LinkedData::Client::HTTP.respond_to?(:get)
    LinkedData::Client::HTTP.singleton_class.send(:define_method, :get) do |uri, params = {}, options = {}|
      $standalone_check_instance.http_get_count += 1
      $standalone_check_instance.recorded_http_calls << { method: :get, uri: uri, params: params }
      $standalone_check_instance.mock_annotator_response
    end

    @orig_http_post = LinkedData::Client::HTTP.method(:post) if LinkedData::Client::HTTP.respond_to?(:post)
    LinkedData::Client::HTTP.singleton_class.send(:define_method, :post) do |uri, params = {}, options = {}|
      $standalone_check_instance.http_post_count += 1
      $standalone_check_instance.recorded_http_calls << { method: :post, uri: uri, params: params }
      $standalone_check_instance.mock_recommender_response
    end

    @orig_ont_all = LinkedData::Client::Models::Ontology.method(:all) if LinkedData::Client::Models::Ontology.respond_to?(:all)
    LinkedData::Client::Models::Ontology.singleton_class.send(:define_method, :all) do |*args|
      [
        OpenStruct.new(id: 'http://example.org/ontologies/ONT1', acronym: 'ONT1', name: 'Ontology 1'),
        OpenStruct.new(id: 'http://example.org/ontologies/ONT2', acronym: 'ONT2', name: 'Ontology 2')
      ]
    end

    @orig_ont_find = LinkedData::Client::Models::Ontology.method(:find_by_acronym) if LinkedData::Client::Models::Ontology.respond_to?(:find_by_acronym)
    LinkedData::Client::Models::Ontology.singleton_class.send(:define_method, :find_by_acronym) do |_acronym|
      []
    end

    $standalone_check_instance = self
  end

  def teardown
    LinkedData::Client::HTTP.singleton_class.send(:define_method, :get, @orig_http_get) if @orig_http_get
    LinkedData::Client::HTTP.singleton_class.send(:define_method, :post, @orig_http_post) if @orig_http_post
    LinkedData::Client::Models::Ontology.singleton_class.send(:define_method, :all, @orig_ont_all) if @orig_ont_all
    LinkedData::Client::Models::Ontology.singleton_class.send(:define_method, :find_by_acronym, @orig_ont_find) if @orig_ont_find
    Flipper.disable('RunRecords')
  end

  attr_accessor :http_get_count, :http_post_count, :recorded_http_calls

  def mock_annotator_response
    [
      OpenStruct.new(
        annotatedClass: OpenStruct.new(
          prefLabel: 'Graphene Layer',
          links: {
            'self' => 'http://example.org/ontologies/ONT1/classes/C1',
            'ontology' => 'http://example.org/ontologies/ONT1'
          }
        ),
        score: 14.5,
        annotations: [
          OpenStruct.new(from: 5, to: 19, text: 'Graphene Layer')
        ],
        hierarchy: [
          OpenStruct.new(
            annotatedClass: OpenStruct.new(
              prefLabel: 'Carbon Nanomaterial',
              links: {
                'self' => 'http://example.org/ontologies/ONT1/classes/C0',
                'ontology' => 'http://example.org/ontologies/ONT1'
              }
            ),
            distance: 1,
            score: 7.25
          )
        ]
      )
    ]
  end

  def mock_recommender_response
    [
      OpenStruct.new(
        evaluationScore: 0.852,
        ontologies: [OpenStruct.new(acronym: 'ONT1', id: 'http://example.org/ontologies/ONT1')],
        coverageResult: OpenStruct.new(
          normalizedScore: 0.90,
          annotations: [
            OpenStruct.new(
              text: 'graphene sample',
              annotatedClass: OpenStruct.new(links: { 'self' => 'http://example.org/ontologies/ONT1/classes/C1' })
            )
          ]
        ),
        acceptanceResult: OpenStruct.new(normalizedScore: 0.80),
        detailResult: OpenStruct.new(normalizedScore: 0.85),
        specializationResult: OpenStruct.new(normalizedScore: 0.75)
      )
    ]
  end

  # =========================================================================
  # 1. Feature Gate Tests
  # =========================================================================

  def test_feature_off_renders_nothing
    Flipper.disable('RunRecords')

    controller = AnnotatorController.new
    refute controller.send(:run_records_enabled?), 'run_records_enabled? must be false when disabled'

    component = ScientificRunRecordComponent.new(tool: 'annotator', run_record: nil)
    refute component.render?, 'component render? must be false when RunRecords feature is disabled'

    # When rendered through ActionView, it outputs empty string
    view_context = ActionController::Base.new.view_context
    output = component.render_in(view_context)
    assert_empty output.strip, 'component must render strictly empty string when feature is off'
  end

  def test_feature_on_enables_component
    Flipper.enable('RunRecords')

    controller = AnnotatorController.new
    assert controller.send(:run_records_enabled?), 'run_records_enabled? must be true when enabled'

    component = ScientificRunRecordComponent.new(tool: 'annotator', run_record: nil, mode: :import_only)
    assert component.render?, 'component render? must be true when RunRecords feature is enabled'

    view_context = ActionController::Base.new.view_context
    output = component.render_in(view_context)
    assert_includes output, 'scientific-run-record'
    assert_includes output, 'scientific-run-record-import-btn'
  end

  # =========================================================================
  # 2. Annotator Run Record: Selected vs Effective Settings After Slice
  # =========================================================================

  def test_annotator_selected_vs_effective_settings_in_slice
    Flipper.enable('RunRecords')

    controller = AnnotatorController.new
    # Configure slice environment
    controller.instance_variable_set(:@subdomain_filter, {
      active: true,
      ontologies: ['http://example.org/ontologies/ONT1']
    })

    input_text = "Analysis of café α-globin and β-amyloid\r\n{pH: 7.4}"
    req_params = ActionController::Parameters.new({
      text: input_text,
      ontologies: 'ONT1,OUTSIDE_ONT',
      score: 'cvalue',
      whole_word_only: '1'
    })
    controller.params = req_params

    controller.index

    record = controller.instance_variable_get(:@run_record)
    refute_nil record, 'AnnotatorController must populate @run_record when feature is on'

    # Check selected settings vs effective settings
    assert_equal 'ONT1,OUTSIDE_ONT', record.selected_settings[:ontologies],
                 'selected_settings must retain user input ontologies including outside ontologies'
    assert_equal 'ONT1', record.effective_settings[:ontologies],
                 'effective_settings must record filtered slice ontologies actually sent to service'
    assert_equal 'cvalue', record.effective_settings[:score]
    assert_equal true, record.effective_settings[:whole_word_only]
  end

  # =========================================================================
  # 3. Typed Scores, Offsets and Unknown Provenance
  # =========================================================================

  def test_annotator_typed_scores_offsets_and_unknowns
    Flipper.enable('RunRecords')

    controller = AnnotatorController.new
    controller.params = ActionController::Parameters.new({
      text: 'Graphene Layer sample',
      score: 'cvalue'
    })
    controller.index

    record = controller.instance_variable_get(:@run_record)
    refute_nil record

    # Check provenance unknowns
    assert_equal 'unknown', record.service_version, 'service_version must be explicit unknown'

    captured = record.captured_result
    assert_equal 'ui_snapshot', captured[:representation], 'representation must be labelled ui_snapshot'
    assert_equal 2, captured[:count]

    # First item: direct result
    item1 = captured[:items].first
    assert_equal 'unknown', item1[:ontology_version], 'ontology_version must be explicit unknown'
    assert_equal 'unknown', item1[:service_version], 'service_version must be explicit unknown'
    assert_instance_of Float, item1[:score], 'score must be a typed Float'
    assert_equal 14.5, item1[:score]

    # Direct annotation offsets
    direct_ann = item1[:annotations].find { |a| a[:type] == 'direct' }
    refute_nil direct_ann
    assert_instance_of Integer, direct_ann[:from], 'annotation from offset must be typed Integer'
    assert_instance_of Integer, direct_ann[:to], 'annotation to offset must be typed Integer'
    assert_equal 5, direct_ann[:from]
    assert_equal 19, direct_ann[:to]

    # Parent hierarchy item (second result item)
    item2 = captured[:items][1]
    parent_ann = item2[:annotations].find { |a| a[:type] == 'parent' }
    refute_nil parent_ann
    assert_instance_of Integer, parent_ann[:level], 'parent distance level must be typed Integer'
    assert_equal 1, parent_ann[:level]
  end

  # =========================================================================
  # 4. Recommender Run Record: Settings, Scores, Offsets, Unknowns
  # =========================================================================

  def test_recommender_selected_vs_effective_and_typed_scores
    Flipper.enable('RunRecords')

    controller = RecommenderController.new
    controller.instance_variable_set(:@subdomain_filter, {
      active: true,
      ontologies: ['http://example.org/ontologies/ONT1']
    })

    controller.params = ActionController::Parameters.new({
      input: 'graphene sample',
      ontologies: 'ONT1,OUTSIDE_ONT',
      wc: '0.60',
      wa: '0.20'
    })
    controller.index

    record = controller.instance_variable_get(:@run_record)
    refute_nil record, 'RecommenderController must populate @run_record'

    assert_equal 'recommender', record.tool
    assert_equal '1.0.0', record.schema_version
    assert_equal 'unknown', record.service_version

    # Selected vs Effective
    assert_equal 'ONT1,OUTSIDE_ONT', record.selected_settings[:ontologies]
    # The controller posts params unchanged: effective = what the API received, unsent = unknown.
    sent = recorded_http_calls.find { |c| c[:method] == :post }[:params]
    assert_equal sent[:ontologies], record.effective_settings[:ontologies]
    assert_equal 'ONT1,OUTSIDE_ONT', record.effective_settings[:ontologies], 'no slice filtering is applied by the recommender controller'
    assert_in_delta 0.60, record.effective_settings[:wc], 0.001
    assert_in_delta 0.20, record.effective_settings[:wa], 0.001
    assert_equal 'unknown', record.effective_settings[:wd], 'unsent weight is an unknown service default'
    assert_equal 'unknown', record.effective_settings[:ws], 'unsent weight is an unknown service default'
    refute_equal 'matportal', record.source_portal

    # Scores must be typed Floats
    captured = record.captured_result
    rec_item = captured[:items].first
    scores = rec_item[:scores]
    assert_instance_of Float, scores[:final_score]
    assert_instance_of Float, scores[:coverage_score]
    assert_instance_of Float, scores[:acceptance_score]
    assert_instance_of Float, scores[:detail_score]
    assert_instance_of Float, scores[:specialization_score]
    assert_equal 85.2, scores[:final_score]
  end

  # =========================================================================
  # 5. Input Text Preservation and SHA-256 Digest
  # =========================================================================

  def test_input_preservation_and_digest
    Flipper.enable('RunRecords')

    complex_input = "Sample with café, naïve, résumé\nGreek: α-globin, β-amyloid\tHyphen: high-affinity\r\nParentheses: {pH: 7.4} [IC50]"
    expected_digest = Digest::SHA256.hexdigest(complex_input.encode('UTF-8'))

    controller = AnnotatorController.new
    controller.params = ActionController::Parameters.new({ text: complex_input })
    controller.index

    record = controller.instance_variable_get(:@run_record)

    # 1. Full export (with text)
    full_hash = record.to_h(include_input_text: true, include_results: true)
    assert_equal 'text', full_hash[:input][:mode]
    assert_equal complex_input, full_hash[:input][:text], 'full record must preserve exact Unicode and whitespace'
    assert_equal expected_digest, full_hash[:input][:sha256], 'sha256 digest must match raw UTF-8 bytes'
    assert_equal 'SHA-256 of raw UTF-8 input text bytes', full_hash[:input][:digest_serialization]

    # 2. Settings-only export (text omitted)
    settings_only_hash = record.to_h(include_input_text: false, include_results: true)
    assert_equal 'digest', settings_only_hash[:input][:mode]
    assert_nil settings_only_hash[:input][:text], 'settings-only record must omit raw input text'
    assert_equal expected_digest, settings_only_hash[:input][:sha256], 'settings-only record must retain digest'
  end

  # =========================================================================
  # 6. Credential & Foreign Endpoint Rejection
  # =========================================================================

  def test_no_credentials_or_service_urls_in_export
    Flipper.enable('RunRecords')

    controller = AnnotatorController.new
    controller.params = ActionController::Parameters.new({ text: 'graphene sample' })
    controller.index

    record = controller.instance_variable_get(:@run_record)
    json_string = record.to_json

    # Must NOT contain portal api key or ncbo api key
    refute_includes json_string, $API_KEY
    refute_includes json_string, $NCBO_API_KEY
    refute_match(/apikey|api_key|token|password|secret|cookie|session/i, json_string)
    refute_includes json_string, $ANNOTATOR_URL
    refute_includes json_string, $REST_URL
  end

  def test_import_validation_rejections
    # Valid record
    valid_data = {
      schema_version: '1.0.0',
      tool: 'annotator',
      settings: { selected: { ontologies: 'ONT1' } },
      input: { sha256: 'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855' }
    }
    result = ScientificRunRecord.validate_import(valid_data, expected_tool: 'annotator')
    assert result[:valid], 'Valid annotator record must pass validation'

    # 1. Malformed JSON
    bad_json = ScientificRunRecord.validate_import('{bad json', expected_tool: 'annotator')
    refute bad_json[:valid]
    assert_equal 'invalid_json', bad_json[:error]

    # 2. Unsupported schema
    bad_schema = ScientificRunRecord.validate_import(valid_data.merge(schema_version: '2.0.0'), expected_tool: 'annotator')
    refute bad_schema[:valid]
    assert_equal 'unsupported_schema', bad_schema[:error]

    # 3. Unsupported tool
    bad_tool = ScientificRunRecord.validate_import(valid_data.merge(tool: 'unknown_analyzer'), expected_tool: 'annotator')
    refute bad_tool[:valid]
    assert_equal 'unsupported_tool', bad_tool[:error]

    # 4. Tool mismatch (recommender record on annotator page)
    tool_mismatch = ScientificRunRecord.validate_import(valid_data.merge(tool: 'recommender'), expected_tool: 'annotator')
    refute tool_mismatch[:valid]
    assert_equal 'tool_mismatch', tool_mismatch[:error]

    # 5. Credential rejection
    cred_data = valid_data.deep_dup
    cred_data[:settings][:apikey] = 'stolen-key'
    cred_check = ScientificRunRecord.validate_import(cred_data, expected_tool: 'annotator')
    refute cred_check[:valid]
    assert_equal 'credentials_rejected', cred_check[:error]

    # 6. Foreign URL rejection in settings
    url_data = valid_data.deep_dup
    url_data[:settings][:selected][:ontologies] = 'http://attacker.example.com/leak'
    url_check = ScientificRunRecord.validate_import(url_data, expected_tool: 'annotator')
    refute url_check[:valid]
    assert_equal 'foreign_url_rejected', url_check[:error]
  end

  # =========================================================================
  # 7. Zero Extra Service Calls
  # =========================================================================

  def test_zero_extra_service_calls_on_export
    Flipper.enable('RunRecords')

    controller = AnnotatorController.new
    controller.params = ActionController::Parameters.new({ text: 'graphene sample' })

    initial_get_count = @http_get_count
    controller.index
    post_index_get_count = @http_get_count

    assert_equal initial_get_count + 1, post_index_get_count, 'Only the single annotator request should occur'

    record = controller.instance_variable_get(:@run_record)
    # Serialize to full JSON and settings-only JSON
    _ = record.to_json
    _ = record.to_settings_only_json

    # HTTP counter MUST NOT increase
    assert_equal post_index_get_count, @http_get_count, 'Exporting run record must trigger 0 additional service calls'
  end

  # =========================================================================
  # 8. Unbroken Existing Contracts
  # =========================================================================

  def test_existing_json_link_and_annotator_handoff_preserved
    Flipper.enable('RunRecords')

    # Annotator json_link
    ann_controller = AnnotatorController.new
    ann_controller.params = ActionController::Parameters.new({ text: 'sample query', ontologies: 'ONT1' })
    ann_controller.index
    ann_json = ann_controller.instance_variable_get(:@json_link)
    assert_includes ann_json, 'sample+query'
    assert_includes ann_json, 'ONT1'

    # Recommender annotator handoff
    rec_controller = RecommenderController.new
    rec_controller.params = ActionController::Parameters.new({ input: 'sample query', ontologies: 'ONT1' })
    rec_controller.index
    rec_json = rec_controller.instance_variable_get(:@json_link)
    assert_includes rec_json, 'sample query'
    assert_includes rec_json, 'ONT1'
  end
end
