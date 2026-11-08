# frozen_string_literal: true

require 'minitest/autorun'
require 'logger'
require 'ostruct'
require 'cgi'
require 'csv'
require 'digest'
require 'json'
require 'set'

# =============================================================================
# Standalone Offline Metadata Comparison Check (ONTO-AT-OP03)
#
# Validates the OP03 MVP contract:
# 1. Feature off returns 404 (gated behind Flipper 'MetadataComparison').
# 2. Two same-acronym submissions remain distinct in displayed rows and export keys.
# 3. Missing submission ID is reported as unavailable and never replaced silently by latest.
# 4. Ontology-level fields (current at capture) are labelled separately from submission-level fields.
# 5. Unknown, empty, and unavailable states are kept strictly distinct.
# 6. JSON schema with canonical SHA-256 payload digest and structured preservation.
# 7. Companion CSV projection with unambiguous row keys and proper quoting round-trip.
# 8. Pure read-only flow: 0 write/POST/PUT/PATCH/DELETE methods called.
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

# =============================================================================
# Finite Boundary Spies and Flipper Configuration
# =============================================================================

class Flipper
  class << self
    attr_accessor :metadata_comparison_enabled_override

    def enabled?(feature, *args)
      if feature.to_s.casecmp('metadatacomparison').zero?
        return metadata_comparison_enabled_override.nil? ? false : metadata_comparison_enabled_override
      end
      false
    end
  end
end

class ComparisonBoundarySpy
  attr_accessor :write_calls, :ontology_find_calls, :submission_explore_calls

  def initialize
    reset!
  end

  def reset!
    @write_calls = 0
    @ontology_find_calls = 0
    @submission_explore_calls = 0
  end

  def record_write!(method_name)
    @write_calls += 1
  end
end

$spy = ComparisonBoundarySpy.new

# Finite LinkedData Models and Doubles
class ComparisonSubmissionMock < OpenStruct
  def save; $spy.record_write!(:save); end
  def update(*args); $spy.record_write!(:update); end
  def delete; $spy.record_write!(:delete); end
  def destroy; $spy.record_write!(:destroy); end
end

class ComparisonExplorerMock
  def initialize(ontology)
    @ontology = ontology
  end

  def submissions(options = {}, submission_id = nil)
    $spy.submission_explore_calls += 1
    case submission_id.to_s
    when '1'
      ComparisonSubmissionMock.new(
        submissionId: 1,
        version: '1.0.0',
        id: 'http://data.example.org/ontologies/ONT/submissions/1',
        description: "He said \"hi\", ok\nsecond line",
        hasLicense: 'CC-BY-4.0',
        keywords: ['k1', 'k,2', "日本語 / \u00dcni\u0308co\u0308de\u0301"],
        contact: { '@value' => 'Alice <alice@example.org>', '@language' => 'en' },
        released: '2026-01-01',
        status: 'production',
        modificationDate: '2026-01-02',
        empty_field: nil,
        links: { 'self' => 'http://data.example.org/ontologies/ONT/submissions/1' }
      )
    when '2'
      # Same acronym 'ONT' and same version '1.0.0' to test distinctness
      ComparisonSubmissionMock.new(
        submissionId: 2,
        version: '1.0.0',
        id: 'http://data.example.org/ontologies/ONT/submissions/2',
        description: 'Second submission distinct description',
        hasLicense: 'MIT',
        keywords: ['k3'],
        contact: nil,
        released: '2026-02-01',
        status: 'staging',
        modificationDate: '2026-02-02',
        empty_field: '',
        links: { 'self' => 'http://data.example.org/ontologies/ONT/submissions/2' }
      )
    when '3'
      # Submission with unknown version
      ComparisonSubmissionMock.new(
        submissionId: 3,
        version: nil,
        id: 'http://data.example.org/ontologies/ONT/submissions/3',
        description: 'Submission with unknown version',
        hasLicense: nil,
        keywords: [],
        contact: nil,
        empty_field: nil,
        links: { 'self' => 'http://data.example.org/ontologies/ONT/submissions/3' }
      )
    when '999'
      # Missing submission
      nil
    else
      nil
    end
  end

  def latest_submission(options = {})
    submissions(options, '2')
  end
end

class ComparisonOntologyMock < OpenStruct
  def explore
    ComparisonExplorerMock.new(self)
  end

  def save; $spy.record_write!(:save); end
  def update(*args); $spy.record_write!(:update); end
  def delete; $spy.record_write!(:delete); end
  def destroy; $spy.record_write!(:destroy); end
end

class LinkedData::Client::Models::Ontology
  class << self
    def find_by_acronym(acronym, _options = {})
      $spy.ontology_find_calls += 1
      if acronym.to_s.casecmp('ont').zero?
        [ComparisonOntologyMock.new(
          acronym: 'ONT',
          name: 'Ontology Name with "Quotes" & <Tags>',
          id: 'http://data.example.org/ontologies/ONT',
          viewingRestriction: 'public',
          links: { 'self' => 'http://data.example.org/ontologies/ONT' }
        )]
      else
        []
      end
    end
  end
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
require 'metadata_comparison_record'
require 'metadata_comparison_component'
require 'metadata_comparison_controller'

# Finite route stubs
module ComparisonRouteStubs
  def metadata_comparison_path(params = {})
    query = params.map { |k, v| "#{k}=#{Array(v).join(',')}" }.join('&')
    query.empty? ? '/metadata_comparison' : "/metadata_comparison?#{query}"
  end
end
ActionController::Base.include ComparisonRouteStubs

FIXTURE_RESOLVER = ActionView::FixtureResolver.new(
  'errors/not_found.html.erb' => '<div id="not_found_error"><%= @error_message %></div>',
  'errors/not_found.html.haml' => '<div id="not_found_error"><%= @error_message %></div>'
)
MetadataComparisonController.prepend_view_path(FIXTURE_RESOLVER)
MetadataComparisonController.prepend_view_path(File.join(worktree_root, 'app/views'))
MetadataComparisonController.layout false

# =============================================================================
# Standalone Test Suite
# =============================================================================

class MetadataComparisonCheck < Minitest::Test
  def setup
    $spy.reset!
    Flipper.metadata_comparison_enabled_override = nil
    MetadataComparisonController.skip_before_action :set_locale, :domain_ontology_set, :init_trial_license, raise: false
  end

  def teardown
    Thread.current[:request] = nil
    Thread.current[:session] = nil
  end

  def dispatch(controller_class, action, user: nil, params: {}, headers: {})
    req = ActionDispatch::TestRequest.create('rack.session' => {})
    req.session[:user] = user if user
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
  # 1. Feature Gate: Disabled by Default => 404
  # ===========================================================================
  def test_01_feature_off_returns_404
    Flipper.metadata_comparison_enabled_override = false

    _ctrl, _req, res = dispatch(
      MetadataComparisonController,
      :show,
      params: { ontology: 'ONT', submission_ids: ['1', '2'] }
    )

    assert_equal 404, res.status, 'Disabled MetadataComparison feature must return 404'
    assert_equal 0, $spy.write_calls, 'No write calls when feature is disabled'
  end

  # ===========================================================================
  # 2. Two Same-Acronym Submissions Remain Distinct in Rows and Export Keys
  # ===========================================================================
  def test_02_two_same_acronym_submissions_remain_distinct
    Flipper.metadata_comparison_enabled_override = true

    # Request two submissions from the same ontology with identical version labels
    record = MetadataComparisonRecord.build({
      ontology: 'ONT',
      submission_ids: %w[1 2],
      properties: %w[acronym name description version keywords]
    })

    assert_equal 2, record.records.size, 'Must return exactly 2 records'

    rec1 = record.records[0]
    rec2 = record.records[1]

    assert_equal 'ONT#1', rec1['row_key'], 'First record must have unambiguous key ONT#1'
    assert_equal 'ONT#2', rec2['row_key'], 'Second record must have unambiguous key ONT#2'
    assert_equal 'ONT', rec1['ontology_acronym']
    assert_equal 'ONT', rec2['ontology_acronym']
    assert_equal '1.0.0', rec1['version_identifier']
    assert_equal '1.0.0', rec2['version_identifier']
    refute_equal rec1['submission_uri'], rec2['submission_uri'], 'Submission URIs must stay distinct'

    # Check companion CSV keys
    csv_text = record.to_csv
    parsed_csv = CSV.parse(csv_text)
    row_keys = parsed_csv[1..].map { |r| r[0] }
    assert_equal ['ONT#1', 'ONT#2'], row_keys, 'CSV row keys must be distinct even with same acronym and version'

    # Check JSON package keys
    pkg = record.to_json_package
    pkg_keys = pkg['records'].map { |r| r['row_key'] }
    assert_equal ['ONT#1', 'ONT#2'], pkg_keys, 'JSON package keys must be distinct'
  end

  # ===========================================================================
  # 3. Missing Submission ID Reported Unavailable and NEVER Replaced by Latest
  # ===========================================================================
  def test_03_missing_id_reported_unavailable_and_not_replaced
    Flipper.metadata_comparison_enabled_override = true

    # Request submission 1 and non-existent submission 999
    record = MetadataComparisonRecord.build({
      ontology: 'ONT',
      submission_ids: %w[1 999],
      properties: %w[acronym description version]
    })

    assert_equal 2, record.records.size
    rec1 = record.records[0]
    rec_missing = record.records[1]

    assert_equal 'ONT#1', rec1['row_key']
    assert_equal 'available', rec1['status']

    assert_equal 'ONT#999', rec_missing['row_key'], 'Missing submission must keep requested key ONT#999'
    assert_equal 'unavailable', rec_missing['status'], 'Missing submission must be marked unavailable'
    assert_includes rec_missing['error'], 'not found', 'Missing submission must record error message'
    refute_equal rec1['submission_id'], rec_missing['submission_id'], 'Missing ID must NOT be silently replaced by latest'
    assert_nil rec_missing['submission_uri'], 'Unavailable submission must have nil URI'
  end

  def test_03b_no_explicit_selection_captures_nothing
    Flipper.metadata_comparison_enabled_override = true
    record = MetadataComparisonRecord.build({ ontology: 'ONT', properties: %w[acronym] })
    assert_empty record.records, 'without explicit submission ids nothing is captured (no latest fallback)'
  end

  # ===========================================================================
  # 4. Ontology vs Submission Level Labels and Notes
  # ===========================================================================
  def test_04_ontology_vs_submission_level_labels
    Flipper.metadata_comparison_enabled_override = true

    record = MetadataComparisonRecord.build({
      ontology: 'ONT',
      submission_ids: ['1'],
      properties: %w[acronym name description version hasLicense]
    })

    meta = record.properties_metadata.index_by { |p| p['id'] }

    # Ontology-level fields
    assert_equal 'ontology', meta['acronym']['level']
    assert_equal 'current at capture', meta['acronym']['note']
    assert_equal 'ontology', meta['name']['level']
    assert_equal 'current at capture', meta['name']['note']

    # Submission-level fields
    assert_equal 'submission', meta['description']['level']
    assert_equal 'submission-level', meta['description']['note']
    assert_equal 'submission', meta['version']['level']
    assert_equal 'submission-level', meta['version']['note']
    assert_equal 'submission', meta['hasLicense']['level']
    assert_equal 'submission-level', meta['hasLicense']['note']

    # HTML rendering check: Component renders ontology-level and submission-level tags
    component = MetadataComparisonComponent.new(record: record)
    rendered = component.call
    assert_includes rendered, 'Ontology level (current at capture)'
    assert_includes rendered, 'Submission level'
  end

  # ===========================================================================
  # 5. Unknown, Empty, and Unavailable States Remain Strictly Distinct
  # ===========================================================================
  def test_05_unknown_empty_and_unavailable_states_distinct
    Flipper.metadata_comparison_enabled_override = true

    record = MetadataComparisonRecord.build({
      ontology: 'ONT',
      submission_ids: %w[1 3 999],
      properties: %w[version description empty_field]
    })

    rec_avail = record.records[0]   # Submission 1: present values + empty_field is nil
    rec_unknown = record.records[1] # Submission 3: version is nil => unknown version
    rec_unavail = record.records[2] # Submission 999: missing => unavailable

    # 1. Available row empty property
    assert_equal 'empty', rec_avail['values']['empty_field']['state'], 'Nil/blank field on available submission must be empty'
    assert_nil rec_avail['values']['empty_field']['value']

    # 2. Unknown upstream version
    assert_equal 'unknown', rec_unknown['values']['version']['state'], 'Nil version must be classified as unknown state'
    assert_nil rec_unknown['version_identifier']
    assert record.unknowns.any? { |u| u.include?('version unknown') }, 'Record unknowns must record unknown version'

    # 3. Unavailable submission
    assert_equal 'unavailable', rec_unavail['status'], 'Missing submission status must be unavailable'
    assert_equal 'unavailable', rec_unavail['values']['version']['state'], 'Unavailable submission field state must be unavailable'
    assert_equal 'unavailable', rec_unavail['values']['description']['state']

    # 4. Strict distinctness: None of these states should equal each other
    refute_equal rec_avail['values']['empty_field']['state'], rec_unknown['values']['version']['state']
    refute_equal rec_unknown['values']['version']['state'], rec_unavail['values']['version']['state']
    refute_equal rec_avail['values']['empty_field']['state'], rec_unavail['values']['version']['state']

    # CSV projection representations
    csv_rows = CSV.parse(record.to_csv)
    # Row for submission 1 empty_field should be empty string
    empty_col_idx = csv_rows[0].index('empty_field')
    assert_equal '', csv_rows[1][empty_col_idx].to_s, 'Empty field in CSV must be empty string'

    # Row for submission 3 version should be '[UNKNOWN]'
    ver_col_idx = csv_rows[0].index('version')
    assert_equal '[UNKNOWN]', csv_rows[2][ver_col_idx]

    # Row for submission 999 version should be '[UNAVAILABLE]'
    assert_equal '[UNAVAILABLE]', csv_rows[3][ver_col_idx]
  end

  # ===========================================================================
  # 6. JSON Package Schema, Canonical Digest, and Structured Value Preservation
  # ===========================================================================
  def test_06_json_package_schema_digest_and_structured_preservation
    Flipper.metadata_comparison_enabled_override = true

    record = MetadataComparisonRecord.build({
      ontology: 'ONT',
      submission_ids: ['1'],
      properties: %w[acronym description keywords contact]
    })

    pkg = record.to_json_package

    # Required top-level schema keys
    assert_equal '1.0.0', pkg['schema_version']
    refute_nil pkg['retrieval_timestamp']
    assert_kind_of Hash, pkg['selection_criteria']
    assert_kind_of Array, pkg['properties']
    assert_kind_of Array, pkg['records']
    assert_kind_of Array, pkg['unknowns']
    assert_kind_of Hash, pkg['digest']

    # Digest verification
    payload = {
      'selection_criteria' => pkg['selection_criteria'],
      'properties' => pkg['properties'],
      'records' => pkg['records']
    }
    expected_digest = Digest::SHA256.hexdigest(JSON.generate(payload))
    assert_equal 'SHA-256', pkg['digest']['algorithm']
    assert_equal expected_digest, pkg['digest']['value'], 'Computed digest must match canonical serialization SHA-256'
    assert_includes pkg['digest']['serialization'], 'SHA-256 hex digest'

    # Structured values preservation
    rec = pkg['records'].first
    keywords_val = rec['values']['keywords']['value']
    assert_kind_of Array, keywords_val, 'Keywords array must be preserved as Array in JSON'
    assert_equal ['k1', 'k,2', "日本語 / \u00dcni\u0308co\u0308de\u0301"], keywords_val

    contact_val = rec['values']['contact']['value']
    assert_kind_of Hash, contact_val, 'Language-tagged literal must preserve hash structure'
    assert_equal 'en', contact_val['@language']
    assert_equal 'Alice <alice@example.org>', contact_val['@value']

    # Security check: No credentials or session leakage
    json_str = JSON.generate(pkg)
    refute_includes json_str, 'apikey'
    refute_includes json_str, 'userapikey'
    refute_includes json_str, 'password'
    refute_includes json_str, 'session'
  end

  # ===========================================================================
  # 7. Companion CSV Quoting Round-Trip (Commas, Quotes, Line Breaks, Unicode)
  # ===========================================================================
  def test_07_companion_csv_quoting_and_roundtrip
    Flipper.metadata_comparison_enabled_override = true

    record = MetadataComparisonRecord.build({
      ontology: 'ONT',
      submission_ids: ['1'],
      properties: %w[acronym description keywords contact]
    })

    csv_text = record.to_csv
    parsed = CSV.parse(csv_text)

    headers = parsed[0]
    row = parsed[1]

    assert_equal 'row_key', headers[0]
    assert_equal 'ONT#1', row[0], 'Unambiguous row key in CSV'

    desc_idx = headers.index('description')
    expected_desc = "He said \"hi\", ok\nsecond line"
    assert_equal expected_desc, row[desc_idx], 'CSV must cleanly round-trip quotes, commas, and line breaks'

    keywords_idx = headers.index('keywords')
    # Multi-valued array represented with pipe delimiter
    assert_includes row[keywords_idx], "k1 | k,2 | 日本語 / \u00dcni\u0308co\u0308de\u0301"

    contact_idx = headers.index('contact')
    # Language tag representation
    assert_equal 'Alice <alice@example.org>@en', row[contact_idx]
  end

  # ===========================================================================
  # 8. Read-Only Verification: Zero Write Methods Called
  # ===========================================================================
  def test_08_pure_read_only_zero_write_methods
    Flipper.metadata_comparison_enabled_override = true

    _ctrl, _req, res = dispatch(
      MetadataComparisonController,
      :show,
      params: { ontology: 'ONT', submission_ids: %w[1 2 999] }
    )

    assert_equal 200, res.status
    assert_equal 0, $spy.write_calls, 'Pure read-only comparison must invoke ZERO write methods'
    assert_operator $spy.ontology_find_calls, :>, 0, 'Must perform read lookup for ontology'
    assert_operator $spy.submission_explore_calls, :>, 0, 'Must perform read lookups for submissions'
  end

  # ===========================================================================
  # 9. Controller JSON & CSV Formats
  # ===========================================================================
  def test_09_controller_json_and_csv_format_responses
    Flipper.metadata_comparison_enabled_override = true

    # JSON format
    _ctrl, _req, res_json = dispatch(
      MetadataComparisonController,
      :show,
      params: { ontology: 'ONT', submission_ids: ['1'], format: 'json' }
    )
    assert_equal 200, res_json.status
    json_data = JSON.parse(res_json.body)
    assert_equal '1.0.0', json_data['schema_version']
    assert_equal 'ONT#1', json_data['records'][0]['row_key']

    # CSV format
    _ctrl, _req, res_csv = dispatch(
      MetadataComparisonController,
      :show,
      params: { ontology: 'ONT', submission_ids: ['1'], format: 'csv' }
    )
    assert_equal 200, res_csv.status
    assert_includes res_csv.content_type, 'text/csv'
    parsed_csv = CSV.parse(res_csv.body)
    assert_equal 'row_key', parsed_csv[0][0]
    assert_equal 'ONT#1', parsed_csv[1][0]
  end
end
