# frozen_string_literal: true

require 'minitest/autorun'
require_relative '../../../app/models/search/semantic_entity_document'
require_relative '../../../app/services/search/hybrid_search_service'

class HybridSearchServiceTest < Minitest::Test
  def test_empty_query_returns_empty_results
    result = Search::HybridSearchService.call(query: '')
    assert_equal 0, result[:total_results]
    assert_empty result[:results]

    result_nil = Search::HybridSearchService.call(query: nil)
    assert_equal 0, result_nil[:total_results]
    assert_empty result_nil[:results]
  end

  def test_rrf_scoring_and_ranking_fusion
    # Mock providers for curie, bm25, vector, and mapping
    doc_a = Search::SemanticEntityDocument.new(
      iri: 'http://example.org/a',
      pref_label: 'Entity A',
      ontology_acronym: 'ONT1'
    )
    doc_b = Search::SemanticEntityDocument.new(
      iri: 'http://example.org/b',
      pref_label: 'Entity B',
      ontology_acronym: 'ONT1'
    )
    doc_c = Search::SemanticEntityDocument.new(
      iri: 'http://example.org/c',
      pref_label: 'Entity C',
      ontology_acronym: 'ONT2'
    )

    curie_provider = ->(_q, **_opts) { [doc_a] } # Rank 1 in curie
    bm25_provider  = ->(_q, **_opts) { [doc_b, doc_a] } # doc_b rank 1, doc_a rank 2
    vector_provider = ->(_q, **_opts) { [doc_c, doc_a] } # doc_c rank 1, doc_a rank 3

    result = Search::HybridSearchService.call(
      query: 'ONT1:a',
      k: 60,
      options: {
        curie_provider: curie_provider,
        bm25_provider: bm25_provider,
        vector_provider: vector_provider
      }
    )

    assert_equal 3, result[:total_results]
    top_doc = result[:results].first

    # doc_a appeared in all 3 channels:
    # curie rank 1: 1.2 / (60 + 1) = 1.2 / 61 ~= 0.019672
    # bm25 rank 2:  1.0 / (60 + 2) = 1.0 / 62 ~= 0.016129
    # vector rank 3: 1.0 / (60 + 3) = 1.0 / 63 ~= 0.015873
    # Total expected score ~= 0.051674
    assert_equal 'http://example.org/a', top_doc.iri
    assert_includes top_doc.matched_channels, :curie_exact
    assert_includes top_doc.matched_channels, :bm25
    assert_includes top_doc.matched_channels, :vector_similarity
    assert_in_delta 0.05167, top_doc.rrf_score, 0.001
  end

  def test_obsolete_discount_penalty
    active_doc = Search::SemanticEntityDocument.new(
      iri: 'http://example.org/active',
      pref_label: 'Active Term',
      ontology_acronym: 'ONT1',
      obsolete: false
    )
    obsolete_doc = Search::SemanticEntityDocument.new(
      iri: 'http://example.org/obsolete',
      pref_label: 'Obsolete Term',
      ontology_acronym: 'ONT1',
      obsolete: true
    )

    # Both rank 1 in BM25, but obsolete_doc is first in list initially
    bm25_provider = ->(_q, **_opts) { [obsolete_doc, active_doc] }

    result = Search::HybridSearchService.call(
      query: 'term',
      k: 60,
      options: { bm25_provider: bm25_provider }
    )

    # Active doc: 1.0 / 62 ~= 0.016129
    # Obsolete doc: (1.0 / 61) * 0.5 ~= 0.016393 * 0.5 = 0.008197
    assert_equal 'http://example.org/active', result[:results].first.iri
    assert_equal 'http://example.org/obsolete', result[:results].last.iri
    assert result[:results].last.obsolete?
    assert_in_delta 0.0082, result[:results].last.rrf_score, 0.0005
  end

  def test_ontology_and_slice_scope_filtering
    doc_ont1 = Search::SemanticEntityDocument.new(
      iri: 'http://example.org/1',
      pref_label: 'Term 1',
      ontology_acronym: 'ONT1'
    )
    doc_ont2 = Search::SemanticEntityDocument.new(
      iri: 'http://example.org/2',
      pref_label: 'Term 2',
      ontology_acronym: 'ONT2'
    )

    bm25_provider = ->(_q, **_opts) { [doc_ont1, doc_ont2] }

    # Filter to only ONT1
    result = Search::HybridSearchService.call(
      query: 'term',
      ontologies: ['ONT1'],
      options: { bm25_provider: bm25_provider }
    )

    assert_equal 1, result[:total_results]
    assert_equal 'ONT1', result[:results].first.ontology_acronym
  end

  def test_resilience_to_channel_provider_failure
    failing_provider = ->(_q, **_opts) { raise 'Remote dense vector service timeout' }
    working_provider = ->(_q, **_opts) do
      [Search::SemanticEntityDocument.new(iri: 'http://example.org/safe', ontology_acronym: 'SAFE')]
    end

    result = Search::HybridSearchService.call(
      query: 'term',
      options: {
        vector_provider: failing_provider,
        bm25_provider: working_provider
      }
    )

    assert_equal 1, result[:total_results]
    assert_equal 'http://example.org/safe', result[:results].first.iri
  end
end
