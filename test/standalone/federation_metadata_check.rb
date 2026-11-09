# frozen_string_literal: true

require 'minitest/autorun'
require 'active_support/all'

# =============================================================================
# Standalone Offline Federation Metadata Regression Suite (ONTO-T-B07)
#
# Tests actual SearchAggregator concern methods:
#   - merge_federated_results
#   - build_other_portal_entry
#   - swap_canonical_portal_results_first
#   - swap_portal_attributes
#
# Validates schema consistency between root (:portal_{name,color,light_color})
# and alternative (:name, :color, :light_color) schemas, identity/link pairing,
# ontology_id and resource URI invariance, and cross-portal merging rules.
#
# No real network, no full Rails suite, no external API/services.
# =============================================================================

# Minimal module doubles for dependencies required by SearchAggregator at load time
module UrlsHelper; end
module MultiLanguagesHelper; end
module FederationHelper; end

MockSubmission = Struct.new(:id, :pullLocation, keyword_init: true)

module LinkedData
  module Client
    module Models
      class OntologySubmission
        class << self
          attr_accessor :mock_submissions

          def all(_params = {})
            @mock_submissions || []
          end
        end
      end
    end
  end
end

require_relative '../../app/controllers/concerns/search_aggregator'

class SearchAggregatorTestHost
  include SearchAggregator

  attr_accessor :canonical_portal_choice, :color_palette, :light_color_palette

  def initialize
    @color_palette = {
      'agroportal' => '#33aa33',
      'matportal' => '#0055aa',
      'bioportal' => '#ff9900'
    }
    @light_color_palette = {
      'agroportal' => '#eef9ee',
      'matportal' => '#eef4fa',
      'bioportal' => '#fff8ee'
    }
    @canonical_portal_choice = nil
  end

  def federated_portal_color(portal_name)
    @color_palette[portal_name.to_s]
  end

  def federated_portal_light_color(portal_name)
    @light_color_palette[portal_name.to_s]
  end

  def most_referred_portal(submissions)
    return @canonical_portal_choice if @canonical_portal_choice

    # Default logic: tally pullLocation references among submissions
    counts = Hash.new(0)
    submissions.each do |sub|
      loc = sub.respond_to?(:pullLocation) ? sub.pullLocation : sub[:pullLocation]
      @color_palette.keys.each do |portal|
        counts[portal] += 1 if loc&.to_s&.include?(portal)
      end
    end
    counts.max_by { |_, c| c }&.first
  end

  # Expose private concern methods for direct boundary testing
  def test_merge_federated_results(results)
    merge_federated_results(results)
  end

  def test_build_other_portal_entry(reuse)
    build_other_portal_entry(reuse)
  end

  def test_swap_canonical_portal_results_first(results)
    swap_canonical_portal_results_first(results)
  end

  def test_swap_portal_attributes(root_portal, new_portal)
    swap_portal_attributes(root_portal, new_portal)
  end
end

class FederationMetadataCheck < Minitest::Test
  def setup
    @host = SearchAggregatorTestHost.new
    LinkedData::Client::Models::OntologySubmission.mock_submissions = []
  end

  # --- 1. Direct Schema Swapping & Attribute Mapping ---

  def test_swap_portal_attributes_maps_root_and_alternative_schemas_correctly
    root_portal = {
      portal_name: 'agroportal',
      portal_color: '#33aa33',
      portal_light_color: '#eef9ee',
      link: 'https://agroportal.example.org/ontologies/AGRO?conceptid=http%3A%2F%2Fexample.org%2Fc1',
      ontology_id: 'http://data.agroportal.example.org/ontologies/AGRO',
      uri: 'http://example.org/c1',
      title: 'Concept One - AGRO'
    }

    alt_portal = {
      name: 'matportal',
      color: '#0055aa',
      light_color: '#eef4fa',
      link: 'https://matportal.example.org/ontologies/AGRO?conceptid=http%3A%2F%2Fexample.org%2Fc1',
      ontology_id: 'http://data.matportal.example.org/ontologies/AGRO'
    }

    @host.test_swap_portal_attributes(root_portal, alt_portal)

    # Promoted root receives alternative metadata under root schema
    assert_equal 'matportal', root_portal[:portal_name]
    assert_equal '#0055aa', root_portal[:portal_color]
    assert_equal '#eef4fa', root_portal[:portal_light_color]
    assert_equal 'https://matportal.example.org/ontologies/AGRO?conceptid=http%3A%2F%2Fexample.org%2Fc1', root_portal[:link]

    # Invariants on root: ontology_id, uri, title unchanged
    assert_equal 'http://data.agroportal.example.org/ontologies/AGRO', root_portal[:ontology_id]
    assert_equal 'http://example.org/c1', root_portal[:uri]
    assert_equal 'Concept One - AGRO', root_portal[:title]

    # Outward schema: root must NOT acquire alternative schema keys
    refute root_portal.key?(:name), 'Root portal must not acquire :name key'
    refute root_portal.key?(:color), 'Root portal must not acquire :color key'
    refute root_portal.key?(:light_color), 'Root portal must not acquire :light_color key'

    # Displaced alternative receives old root metadata under alternative schema
    assert_equal 'agroportal', alt_portal[:name]
    assert_equal '#33aa33', alt_portal[:color]
    assert_equal '#eef9ee', alt_portal[:light_color]
    assert_equal 'https://agroportal.example.org/ontologies/AGRO?conceptid=http%3A%2F%2Fexample.org%2Fc1', alt_portal[:link]

    # Invariant on alternative: ontology_id unchanged
    assert_equal 'http://data.matportal.example.org/ontologies/AGRO', alt_portal[:ontology_id]

    # Outward schema: alternative must NOT acquire root portal_* keys
    refute alt_portal.key?(:portal_name), 'Alternative portal must not acquire :portal_name key'
    refute alt_portal.key?(:portal_color), 'Alternative portal must not acquire :portal_color key'
    refute alt_portal.key?(:portal_light_color), 'Alternative portal must not acquire :portal_light_color key'
  end

  # --- 2. Alternative Entry Construction Schema ---

  def test_build_other_portal_entry_produces_alternative_schema
    reuse_entry = {
      root: {
        portal_name: 'matportal',
        link: 'https://matportal.example.org/ontologies/MATONT?conceptid=http%3A%2F%2Fexample.org%2Fm1',
        ontology_id: 'http://data.matportal.example.org/ontologies/MATONT',
        uri: 'http://example.org/m1'
      }
    }

    entry = @host.test_build_other_portal_entry(reuse_entry)

    assert_equal 'matportal', entry[:name]
    assert_equal '#0055aa', entry[:color]
    assert_equal '#eef4fa', entry[:light_color]
    assert_equal 'https://matportal.example.org/ontologies/MATONT?conceptid=http%3A%2F%2Fexample.org%2Fm1', entry[:link]
    assert_equal 'http://data.matportal.example.org/ontologies/MATONT', entry[:ontology_id]

    # Must conform strictly to alternative schema (no portal_* prefixes)
    refute entry.key?(:portal_name)
    refute entry.key?(:portal_color)
    refute entry.key?(:portal_light_color)
  end

  # --- 3. Merging Rules Across Portals and Ontology Boundaries ---

  def test_merge_federated_results_same_ontology_and_uri_across_portals_merges
    result1 = {
      root: {
        ontology_id: 'http://data.agroportal.example.org/ontologies/SHARED_ONT',
        uri: 'http://example.org/shared_concept',
        portal_name: 'agroportal',
        link: 'https://agroportal.example.org/shared'
      },
      reuses: []
    }
    result2 = {
      root: {
        ontology_id: 'http://data.matportal.example.org/ontologies/SHARED_ONT',
        uri: 'http://example.org/shared_concept',
        portal_name: 'matportal',
        link: 'https://matportal.example.org/shared'
      },
      reuses: []
    }

    search_results = [result1, result2]
    @host.test_merge_federated_results(search_results)

    # Secondary entry merged into primary; remaining list has 1 element
    assert_equal 1, search_results.size
    merged = search_results.first
    assert_equal 'agroportal', merged[:root][:portal_name]
    assert_equal 1, merged[:root][:other_portals].size

    alt = merged[:root][:other_portals].first
    assert_equal 'matportal', alt[:name]
    assert_equal '#0055aa', alt[:color]
    assert_equal '#eef4fa', alt[:light_color]
    assert_equal 'https://matportal.example.org/shared', alt[:link]
  end

  def test_merge_federated_results_same_uri_different_ontology_does_not_merge
    result1 = {
      root: {
        ontology_id: 'http://data.example.org/ontologies/ONT_ALPHA',
        uri: 'http://example.org/common_id',
        portal_name: 'agroportal',
        link: 'https://agroportal.example.org/a'
      },
      reuses: []
    }
    result2 = {
      root: {
        ontology_id: 'http://data.example.org/ontologies/ONT_BETA',
        uri: 'http://example.org/common_id',
        portal_name: 'matportal',
        link: 'https://matportal.example.org/b'
      },
      reuses: []
    }

    search_results = [result1, result2]
    @host.test_merge_federated_results(search_results)

    # Distinct ontology acronyms must not merge despite identical URI
    assert_equal 2, search_results.size
    assert_empty search_results[0][:root][:other_portals]
    assert_empty search_results[1][:root][:other_portals]
  end

  # --- 4. Canonical Promotion Flow (swap_canonical_portal_results_first) ---

  def test_canonical_promotion_swaps_metadata_and_preserves_both_schemas
    search_results = [
      {
        root: {
          ontology_id: 'http://data.agroportal.example.org/ontologies/SHARED_ONT',
          uri: 'http://example.org/concept1',
          portal_name: 'agroportal',
          portal_color: '#33aa33',
          portal_light_color: '#eef9ee',
          link: 'https://agroportal.example.org/concept1',
          title: 'Shared Concept - SHARED_ONT',
          other_portals: [
            {
              name: 'matportal',
              color: '#0055aa',
              light_color: '#eef4fa',
              link: 'https://matportal.example.org/concept1',
              ontology_id: 'http://data.matportal.example.org/ontologies/SHARED_ONT'
            }
          ]
        }
      }
    ]

    LinkedData::Client::Models::OntologySubmission.mock_submissions = [
      MockSubmission.new(
        id: 'http://data.matportal.example.org/ontologies/SHARED_ONT/submissions/1',
        pullLocation: 'https://data.matportal.example.org'
      )
    ]
    @host.canonical_portal_choice = 'matportal'

    @host.test_swap_canonical_portal_results_first(search_results)

    root = search_results.first[:root]
    # Root now carries promoted canonical metadata
    assert_equal 'matportal', root[:portal_name]
    assert_equal '#0055aa', root[:portal_color]
    assert_equal '#eef4fa', root[:portal_light_color]
    assert_equal 'https://matportal.example.org/concept1', root[:link]

    # Invariants
    assert_equal 'http://data.agroportal.example.org/ontologies/SHARED_ONT', root[:ontology_id]
    assert_equal 'http://example.org/concept1', root[:uri]
    refute root.key?(:name)
    refute root.key?(:color)
    refute root.key?(:light_color)

    # other_portals now holds displaced agroportal metadata under alternative schema
    assert_equal 1, root[:other_portals].size
    displaced = root[:other_portals].first
    assert_equal 'agroportal', displaced[:name]
    assert_equal '#33aa33', displaced[:color]
    assert_equal '#eef9ee', displaced[:light_color]
    assert_equal 'https://agroportal.example.org/concept1', displaced[:link]
    assert_equal 'http://data.matportal.example.org/ontologies/SHARED_ONT', displaced[:ontology_id]

    refute displaced.key?(:portal_name)
    refute displaced.key?(:portal_color)
    refute displaced.key?(:portal_light_color)
  end

  def test_canonical_promotion_no_op_when_root_is_already_canonical
    original_root = {
      ontology_id: 'http://data.matportal.example.org/ontologies/SHARED_ONT',
      uri: 'http://example.org/concept1',
      portal_name: 'matportal',
      portal_color: '#0055aa',
      portal_light_color: '#eef4fa',
      link: 'https://matportal.example.org/concept1',
      other_portals: [
        {
          name: 'agroportal',
          color: '#33aa33',
          light_color: '#eef9ee',
          link: 'https://agroportal.example.org/concept1',
          ontology_id: 'http://data.agroportal.example.org/ontologies/SHARED_ONT'
        }
      ]
    }
    search_results = [{ root: original_root.deep_dup }]

    @host.canonical_portal_choice = 'matportal'
    @host.test_swap_canonical_portal_results_first(search_results)

    root = search_results.first[:root]
    assert_equal 'matportal', root[:portal_name]
    assert_equal 'https://matportal.example.org/concept1', root[:link]
    assert_equal 'agroportal', root[:other_portals].first[:name]
    assert_equal 'https://agroportal.example.org/concept1', root[:other_portals].first[:link]
  end

  def test_canonical_promotion_no_op_when_no_canonical_found_or_no_match
    original_root = {
      ontology_id: 'http://data.agroportal.example.org/ontologies/SHARED_ONT',
      uri: 'http://example.org/concept1',
      portal_name: 'agroportal',
      portal_color: '#33aa33',
      portal_light_color: '#eef9ee',
      link: 'https://agroportal.example.org/concept1',
      other_portals: [
        {
          name: 'matportal',
          color: '#0055aa',
          light_color: '#eef4fa',
          link: 'https://matportal.example.org/concept1',
          ontology_id: 'http://data.matportal.example.org/ontologies/SHARED_ONT'
        }
      ]
    }

    # Case A: canonical portal is nil
    results_a = [{ root: original_root.deep_dup }]
    @host.canonical_portal_choice = nil
    @host.test_swap_canonical_portal_results_first(results_a)
    assert_equal 'agroportal', results_a.first[:root][:portal_name]
    assert_equal 'matportal', results_a.first[:root][:other_portals].first[:name]

    # Case B: canonical portal points to an external portal not in other_portals
    results_b = [{ root: original_root.deep_dup }]
    @host.canonical_portal_choice = 'bioportal'
    @host.test_swap_canonical_portal_results_first(results_b)
    assert_equal 'agroportal', results_b.first[:root][:portal_name]
    assert_equal 'matportal', results_b.first[:root][:other_portals].first[:name]
  end

  def test_canonical_promotion_guards_against_missing_portal_name_or_empty_other_portals
    # Nil portal_name
    no_portal = {
      root: {
        ontology_id: 'http://data.example.org/ontologies/LOCAL',
        uri: 'http://example.org/c1',
        portal_name: nil,
        link: '/ontologies/LOCAL?conceptid=c1',
        other_portals: [{ name: 'matportal', link: 'https://matportal.example/c1' }]
      }
    }
    @host.canonical_portal_choice = 'matportal'
    @host.test_swap_canonical_portal_results_first([no_portal])
    assert_nil no_portal[:root][:portal_name]

    # Blank other_portals
    empty_alt = {
      root: {
        ontology_id: 'http://data.example.org/ontologies/LOCAL',
        uri: 'http://example.org/c1',
        portal_name: 'agroportal',
        link: 'https://agroportal.example/c1',
        other_portals: []
      }
    }
    @host.test_swap_canonical_portal_results_first([empty_alt])
    assert_equal 'agroportal', empty_alt[:root][:portal_name]
    assert_empty empty_alt[:root][:other_portals]
  end
end
