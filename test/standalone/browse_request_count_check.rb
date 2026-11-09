# frozen_string_literal: true

require 'minitest/autorun'
require 'ostruct'
require 'json'
require 'request_store'
require 'active_support/all'
require 'action_controller'
require 'action_view'

# =============================================================================
# Standalone Offline Browse Request Count and Redundancy Check (ONTO-T-B18)
#
# Validates and measures the ontologies browse and filter path offline:
# 1. Real filter path execution:
#    Dispatches `SubmissionFilter#submissions_paginate_filter` with finite doubles
#    for `Ontology.all`, `OntologySubmission.all`, fairness score, and analytics
#    over a deterministic fixed fixture of 300 ontologies and submissions.
# 2. Measurement tracking:
#    Records API calls by kind, objects materialized, and page-1 vs page-2 vs
#    filtered-request behaviour.
# 3. Equivalence and redundancy audit:
#    Verifies that no provably redundant fetches exist for the same response,
#    that page 2 avoids full-collection facet counting (count_objects), and that
#    page collection, totalCount, facet counts, and ordering are deterministic
#    across sort_by (visits/fair/name), search queries, category filters, and
#    federation toggle.
# =============================================================================

module Rails
  def self.cache
    @cache ||= ActiveSupport::Cache::MemoryStore.new
  end
end

class ApiCallTracker
  attr_reader :calls

  def initialize
    reset!
  end

  def reset!
    @calls = Hash.new(0)
  end

  def record(kind)
    @calls[kind] += 1
  end

  def count(kind)
    @calls[kind]
  end

  def total
    @calls.values.sum
  end
end

$tracker = ApiCallTracker.new

module LinkedData
  module Client
    module Models
      class Ontology
        def self.all(include: 'all', also_include_views: true, display_links: false, display_context: false)
          $tracker.record(:ontology_all)
          $fixture_ontologies
        end
      end

      class OntologySubmission
        def self.all(include: nil, include_status: 'READY', also_include_views: true, display_links: false, display_context: false, acronym: nil)
          $tracker.record(:submission_all)
          $fixture_submissions
        end
      end

      class Category
        def self.all(display_links: false, display_context: false)
          $tracker.record(:category_all)
          $fixture_categories
        end
      end

      class Group
        def self.all(display_links: false, display_context: false)
          $tracker.record(:group_all)
          $fixture_groups
        end
      end
    end
  end
end

module FederationHelper
  def federation_enabled?
    $federation_enabled.nil? ? true : $federation_enabled
  end

  def portal_name
    'MatPortal'
  end

  def request_portals
    portals = RequestStore.store[:federated_portals] || []
    [portal_name] + portals
  end

  def federated_portals
    {
      matportal: { api: 'http://data.matportal.org', ui: 'http://matportal.org', name: 'MatPortal' },
      agroportal: { api: 'http://data.agroportal.lirmm.fr', ui: 'http://agroportal.lirmm.fr', name: 'AgroPortal' }
    }
  end

  def canonical_ontology(ontologies)
    ontologies.first
  end

  def federated_browse_counts(ontologies)
    ids = ontologies.flat_map do |ontology|
      [ontology[:id]] + (ontology[:sources] || [])
    end.uniq
    counts = Hash.new(0)
    current_portal, *federation_portals = request_portals
    ids.each do |id|
      counts[current_portal.downcase] += 1 if id.include?(current_portal.to_s.downcase)
    end
    counts
  end
end

require_relative '../../app/controllers/concerns/submission_filter'

class BrowseHarnessController < ActionController::Base
  include ActionView::Helpers::NumberHelper
  include FederationHelper
  include SubmissionFilter

  attr_accessor :params

  def helpers
    self
  end

  def link_last_part(val)
    val.to_s.split('/').last
  end

  def internal_ontology?(id)
    id.to_s.include?('matportal')
  end

  def current_user_admin?
    false
  end

  def current_user
    OpenStruct.new(id: 'user_1')
  end

  def fairness_service_enabled?
    true
  end

  def get_fair_score(scope = 'all')
    $tracker.record(:fair_score)
    $fixture_fair_scores
  end

  def ontologies_analytics
    $tracker.record(:analytics)
    $fixture_analytics
  end

  def submission_status2string(sub)
    sub.submissionStatus.is_a?(Array) ? sub.submissionStatus.join(', ') : sub.submissionStatus.to_s
  end

  def t(key, **_opts)
    key.to_s
  end

  def submission_metadata
    @submission_metadata ||= begin
      $tracker.record(:submission_metadata)
      [
        {
          '@id' => 'http://data.bioontology.org/metadata/naturalLanguage',
          'enforcedValues' => {
            'http://data.matportal.org/languages/en' => 'English',
            'http://data.matportal.org/languages/fr' => 'French'
          }
        },
        {
          '@id' => 'http://data.bioontology.org/metadata/hasFormalityLevel',
          'enforcedValues' => {
            'http://data.matportal.org/formality/F1' => 'Formality 1',
            'http://data.matportal.org/formality/F2' => 'Formality 2'
          }
        },
        {
          '@id' => 'http://data.bioontology.org/metadata/isOfType',
          'enforcedValues' => {
            'http://data.matportal.org/types/T1' => 'Type 1',
            'http://data.matportal.org/types/T2' => 'Type 2'
          }
        }
      ]
    end
  end
end

def setup_browse_fixtures!
  $fixture_ontologies = 300.times.map do |i|
    is_private = (i % 25 == 0)
    is_view = (i == 299)
    domain_id = "http://data.matportal.org/categories/C#{i % 7}"
    group_id = "http://data.matportal.org/groups/G#{i % 5}"

    o = OpenStruct.new(
      id: "http://data.matportal.org/ontologies/ONT#{i}",
      acronym: "ONT#{i}",
      name: "Ontology #{i} #{i.even? ? 'Material' : 'Chemical'}",
      group: [group_id],
      hasDomain: [domain_id],
      viewingRestriction: is_private ? 'private' : 'public',
      administeredBy: ["user_#{(i % 3) + 1}"],
      viewOf: is_view ? 'http://data.matportal.org/ontologies/ONT0' : nil,
      notes: Array.new(i % 4),
      projects: Array.new(i % 3),
      errors: nil
    )
    def o.private?
      viewingRestriction == 'private'
    end
    o
  end

  $fixture_submissions = 300.times.map do |i|
    is_retired = (i % 40 == 0)
    lang_uri = i.even? ? 'http://data.matportal.org/languages/en' : 'http://data.matportal.org/languages/fr'
    formality_uri = i.even? ? 'http://data.matportal.org/formality/F1' : 'http://data.matportal.org/formality/F2'
    type_uri = i.even? ? 'http://data.matportal.org/types/T1' : 'http://data.matportal.org/types/T2'
    lang_code = ['OWL', 'SKOS', 'OBO'][i % 3]

    OpenStruct.new(
      id: "http://data.matportal.org/ontologies/ONT#{i}/submissions/1",
      ontology: { id: "http://data.matportal.org/ontologies/ONT#{i}", acronym: "ONT#{i}" },
      submissionStatus: ['UPLOADED', 'RDF', 'RDF_LABELS'],
      status: is_retired ? 'retired' : 'production',
      hasOntologyLanguage: lang_code,
      isOfType: type_uri,
      hasFormalityLevel: formality_uri,
      naturalLanguage: [lang_uri],
      description: "Description for ontology #{i} with #{i.even? ? 'material' : 'crystal'} structure",
      creationDate: sprintf('2024-01-%02dT00:00:00Z', (i % 28) + 1),
      released: sprintf('2024-02-%02dT00:00:00Z', (i % 28) + 1),
      pullLocation: 'http://matportal.org',
      deprecated: false,
      contact: ["Admin #{i}|admin#{i}@example.org"],
      metrics: OpenStruct.new(classes: 100 + i, individuals: 50 + i)
    )
  end

  $fixture_categories = 7.times.map do |k|
    { 'id' => "http://data.matportal.org/categories/C#{k}", 'acronym' => "C#{k}", 'name' => "Category #{k}" }
  end

  $fixture_groups = 5.times.map do |k|
    { 'id' => "http://data.matportal.org/groups/G#{k}", 'acronym' => "G#{k}", 'name' => "Group #{k}" }
  end

  $fixture_fair_scores = 300.times.map do |i|
    score = (i * 7 + 11) % 100
    ["ONT#{i}", { 'score' => score, 'normalizedScore' => score }]
  end.to_h

  $fixture_analytics = 300.times.map do |i|
    ["ONT#{i}", (i * 13 + 17) % 1000]
  end.to_h
end

setup_browse_fixtures!

class BrowseRequestCountCheck < Minitest::Test
  def setup
    Rails.cache.clear
    RequestStore.store.clear
    $federation_enabled = true
    $tracker.reset!
  end

  def dispatch_browse(raw_params = {})
    p = ActionController::Parameters.new(raw_params)
    ctrl = BrowseHarnessController.new
    ctrl.params = p
    ctrl.submissions_paginate_filter(p)
  end

  # =========================================================================
  # 1. Page 1 Measurements (Cold vs Warm Analytics)
  # =========================================================================
  def test_01_page_1_measurements
    # Cold request: cache empty
    collection, total_count, counts, filter_params, federation_counts = dispatch_browse(page: '1')

    assert_equal 10, collection.size, 'Page 1 must return default page size (10)'
    assert_equal 291, total_count, 'Total count must reflect catalog minus retired (8) and view (1)'
    assert_operator counts.keys.size, :>, 0, 'Page 1 must compute facet counts'
    assert_equal 291, federation_counts['matportal'], 'Federation counts must cover all matching'

    # Cold API call counts
    assert_equal 1, $tracker.count(:ontology_all), 'Ontology.all called exactly once'
    assert_equal 1, $tracker.count(:submission_all), 'OntologySubmission.all called exactly once'
    assert_equal 1, $tracker.count(:fair_score), 'FAIR score fetched exactly once'
    assert_equal 1, $tracker.count(:analytics), 'Analytics fetched once on cold cache'
    assert_equal 1, $tracker.count(:category_all), 'Category.all called once for page 1 facet counts'
    assert_equal 1, $tracker.count(:group_all), 'Group.all called once for page 1 facet counts'
    assert_equal 1, $tracker.count(:submission_metadata), 'Metadata called once for facet schemas'

    puts "\n--- [Measurement: Page 1 Cold Request] ---"
    puts "API calls: #{JSON.generate($tracker.calls)} (total: #{$tracker.total})"
    puts "Objects materialized: #{$fixture_ontologies.size} ontologies, #{$fixture_submissions.size} submissions"
    puts "Page collection: #{collection.size} items, Total matching: #{total_count}"
    puts "Facet counts computed: categories=#{counts[:categories]&.size}, groups=#{counts[:groups]&.size}"

    # Warm request: analytics cached
    $tracker.reset!
    col_warm, total_warm, counts_warm, _, _ = dispatch_browse(page: '1')
    assert_equal 0, $tracker.count(:analytics), 'Analytics must be served from cache on warm request'
    assert_equal 1, $tracker.count(:ontology_all)
    assert_equal 1, $tracker.count(:submission_all)
    assert_equal collection.map { |x| x[:id] }, col_warm.map { |x| x[:id] }, 'Warm collection identical to cold'
    assert_equal total_count, total_warm
    assert_equal counts, counts_warm

    puts "--- [Measurement: Page 1 Warm Request] ---"
    puts "API calls: #{JSON.generate($tracker.calls)} (total: #{$tracker.total})"
  end

  # =========================================================================
  # 2. Page 2 Measurements (count_objects avoidance)
  # =========================================================================
  def test_02_page_2_measurements
    # Page 1 first
    col1, tot1, counts1, _, _ = dispatch_browse(page: '1')

    # Now Page 2
    $tracker.reset!
    col2, tot2, counts2, filter_params, fed2 = dispatch_browse(page: '2')

    assert_equal 10, col2.size, 'Page 2 must return 10 items'
    assert_equal tot1, tot2, 'Total matching count must be identical on page 1 and page 2'
    assert_equal({}, counts2, 'Page 2 must NOT compute count_objects (empty hash)')

    # Disjointness: Page 1 and Page 2 items must not overlap
    ids_page1 = col1.map { |x| x[:id] }
    ids_page2 = col2.map { |x| x[:id] }
    assert_empty (ids_page1 & ids_page2), 'Page 1 and Page 2 collections must be disjoint'

    # Page 2 API call counts: Category.all, Group.all, submission_metadata are NOT called!
    assert_equal 1, $tracker.count(:ontology_all), 'Ontology.all called once for page 2'
    assert_equal 1, $tracker.count(:submission_all), 'OntologySubmission.all called once for page 2'
    assert_equal 1, $tracker.count(:fair_score), 'FAIR score called once for page 2'
    assert_equal 0, $tracker.count(:analytics), 'Analytics cached from page 1'
    assert_equal 0, $tracker.count(:category_all), 'Category.all MUST NOT be called on page 2'
    assert_equal 0, $tracker.count(:group_all), 'Group.all MUST NOT be called on page 2'
    assert_equal 0, $tracker.count(:submission_metadata), 'submission_metadata MUST NOT be called on page 2'

    puts "\n--- [Measurement: Page 2 Request] ---"
    puts "API calls: #{JSON.generate($tracker.calls)} (total: #{$tracker.total})"
    puts "Facet counting avoided: Category.all=#{$tracker.count(:category_all)}, Group.all=#{$tracker.count(:group_all)}"
    puts "Page collection: #{col2.size} items, Total matching: #{tot2}"
  end

  # =========================================================================
  # 3. Filtered Request Measurements
  # =========================================================================
  def test_03_filtered_request_measurements
    # Filter by Category C1
    $tracker.reset!
    collection, total_count, counts, _, _ = dispatch_browse(page: '1', categories: 'C1')

    assert_operator total_count, :<, 291, 'Filtered count must be smaller than full catalog'
    assert_equal 42, total_count, 'Category C1 has exactly 42 non-retired, non-view ontologies'
    assert_equal 10, collection.size

    # Verify all returned items belong to C1
    collection.each do |ont|
      assert_includes ont[:categories], 'http://data.matportal.org/categories/C1',
                      "Returned ontology #{ont[:acronym]} must belong to category C1"
    end

    # Facet counts reflect the filtered subset
    assert_equal 42, counts[:categories]['C1'], 'Category C1 count must equal matching total'

    puts "\n--- [Measurement: Filtered Request (categories=C1)] ---"
    puts "API calls: #{JSON.generate($tracker.calls)} (total: #{$tracker.total})"
    puts "Filtered total: #{total_count} (out of #{$fixture_ontologies.size}), Returned: #{collection.size}"
    puts "Facet count for C1: #{counts[:categories]['C1']}"
  end

  # =========================================================================
  # 4. Sort by visits (popularity descending)
  # =========================================================================
  def test_04_sort_by_visits
    collection, total_count, _, _, _ = dispatch_browse(page: '1', sort_by: 'visits')
    assert_equal 10, collection.size

    popularities = collection.map { |x| x[:popularity] }
    assert_equal popularities.sort.reverse, popularities,
                 'Sort by visits must produce descending popularity order'

    puts "\n--- [Measurement: Sort by visits] ---"
    puts "First 5 popularities: #{popularities.take(5)}"
  end

  # =========================================================================
  # 5. Sort by fair (fairScore descending)
  # =========================================================================
  def test_05_sort_by_fair
    collection, total_count, _, _, _ = dispatch_browse(page: '1', sort_by: 'fair')
    assert_equal 10, collection.size

    scores = collection.map { |x| x[:fairScore] }
    assert_equal scores.sort.reverse, scores,
                 'Sort by fair must produce descending FAIR score order'

    puts "\n--- [Measurement: Sort by fair] ---"
    puts "First 5 FAIR scores: #{scores.take(5)}"
  end

  # =========================================================================
  # 6. Sort by ontology_name
  # =========================================================================
  def test_06_sort_by_name
    collection, total_count, _, _, _ = dispatch_browse(page: '1', sort_by: 'ontology_name')
    assert_equal 10, collection.size

    names = collection.map { |x| x[:name] }
    assert_equal names.sort, names,
                 'Sort by ontology_name must produce ascending name order'

    puts "\n--- [Measurement: Sort by ontology_name] ---"
    puts "First 5 names: #{names.take(5)}"
  end

  # =========================================================================
  # 7. Search query ranking
  # =========================================================================
  def test_07_search_query
    collection, total_count, _, _, _ = dispatch_browse(page: '1', search: 'Material')
    assert_operator total_count, :>, 0
    assert_equal 10, collection.size

    collection.each do |ont|
      text = "#{ont[:acronym]} #{ont[:name]} #{ont[:description]}".downcase
      assert_includes text, 'material', "Search result #{ont[:acronym]} must match 'material'"
      assert_operator ont[:rank], :>, 0, "Matched result #{ont[:acronym]} must have rank > 0"
    end

    ranks = collection.map { |x| x[:rank] }
    assert_equal ranks.sort.reverse, ranks, 'Search results must be ordered by rank descending'

    puts "\n--- [Measurement: Search Query ('Material')] ---"
    puts "Search total: #{total_count}, Top ranks: #{ranks.take(5)}"
  end

  # =========================================================================
  # 8. Federation Toggle (Federation Off)
  # =========================================================================
  def test_08_federation_off
    $federation_enabled = false
    collection, total_count, counts, _, fed_counts = dispatch_browse(page: '1')

    assert_equal 10, collection.size
    assert_equal 291, total_count
    assert_equal 291, fed_counts['matportal']

    puts "\n--- [Measurement: Federation Off Request] ---"
    puts "Federation disabled successfully, local collection: #{collection.size}, fed_counts: #{fed_counts}"
  end

  # =========================================================================
  # 9. Determinism, Equivalence, and Redundancy Audit
  # =========================================================================
  def test_09_equivalence_and_redundancy_audit
    # Repeated dispatches of identical requests must produce byte-for-byte identical results
    col_a, tot_a, cnt_a, _, _ = dispatch_browse(page: '1', sort_by: 'visits')
    col_b, tot_b, cnt_b, _, _ = dispatch_browse(page: '1', sort_by: 'visits')

    assert_equal tot_a, tot_b, 'TotalCount must be strictly deterministic'
    assert_equal col_a.map { |x| x[:id] }, col_b.map { |x| x[:id] }, 'Page collection IDs must be strictly deterministic'
    assert_equal col_a.map { |x| x[:name] }, col_b.map { |x| x[:name] }, 'Page collection order must be strictly deterministic'
    assert_equal cnt_a, cnt_b, 'Facet counts must be strictly deterministic'

    # Verify no duplicate calls in a single cold request
    Rails.cache.clear
    $tracker.reset!
    dispatch_browse(page: '1')
    assert_equal 1, $tracker.count(:ontology_all), 'No duplicate Ontology.all'
    assert_equal 1, $tracker.count(:submission_all), 'No duplicate OntologySubmission.all'
    assert_equal 1, $tracker.count(:fair_score), 'No duplicate get_fair_score'
    assert_equal 1, $tracker.count(:analytics), 'No duplicate analytics fetch'
    assert_equal 1, $tracker.count(:category_all), 'No duplicate Category.all'
    assert_equal 1, $tracker.count(:group_all), 'No duplicate Group.all'

    puts "\n--- [Audit: Determinism & Redundancy Verification] ---"
    puts "Deterministic equivalence verified across repeated runs."
    puts "Zero duplicate fetches observed within any single request."
    puts "Page 2 already avoids facet counting (count_objects runs only on page 1)."
    puts "Full catalog materialization is required for client-side sorting/pagination without API pagination."
  end

  # Records allocations and in-process time per page for the fixed fixture; no targets.
  def test_09_page_cost_measurements
    dispatch_browse(page: '1') # warm code paths and the analytics cache
    costs = %w[1 2].to_h do |page|
      GC.start
      before = GC.stat(:total_allocated_objects)
      t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      collection, = dispatch_browse(page: page)
      ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0) * 1000).round(1)
      assert_equal 10, collection.size
      [page, { allocated_objects: GC.stat(:total_allocated_objects) - before, ms: ms }]
    end
    payload = JSON.generate($fixture_ontologies.map(&:to_h)).bytesize + JSON.generate($fixture_submissions.map(&:to_h)).bytesize
    puts "B18_COSTS #{JSON.generate(ontologies: $fixture_ontologies.size, fixture_payload_bytes: payload, pages: costs)}"
    assert_operator costs['2'][:allocated_objects], :>, 0
  end
end
