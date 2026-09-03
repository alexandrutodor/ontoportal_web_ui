# frozen_string_literal: true

require 'minitest/autorun'
require_relative '../../../app/models/search/semantic_entity_document'

class SemanticEntityDocumentTest < Minitest::Test
  def test_initialization_with_basic_attributes
    doc = Search::SemanticEntityDocument.new(
      iri: 'http://purl.obolibrary.org/obo/CHEBI_15377',
      curie: 'CHEBI:15377',
      pref_label: 'water',
      synonyms: ['H2O', 'oxidane'],
      definition: 'An oxygen hydride consisting of an oxygen atom bonded to two hydrogen atoms.',
      ontology_acronym: 'CHEBI',
      obsolete: false
    )

    assert_equal 'http://purl.obolibrary.org/obo/CHEBI_15377', doc.iri
    assert_equal 'CHEBI:15377', doc.curie
    assert_equal 'water', doc.pref_label
    assert_equal ['H2O', 'oxidane'], doc.synonyms
    assert_equal 'CHEBI', doc.ontology_acronym
    refute doc.obsolete?
    assert_equal 'CHEBI:http://purl.obolibrary.org/obo/CHEBI_15377', doc.document_key
  end

  def test_obsolete_parsing
    doc1 = Search::SemanticEntityDocument.new(obsolete: true)
    assert doc1.obsolete?

    doc2 = Search::SemanticEntityDocument.new(obsolete: 'true')
    assert doc2.obsolete?

    doc3 = Search::SemanticEntityDocument.new(obsolete: false)
    refute doc3.obsolete?

    doc4 = Search::SemanticEntityDocument.new(obsolete: nil)
    refute doc4.obsolete?
  end

  def test_channel_hit_registration
    doc = Search::SemanticEntityDocument.new(
      iri: 'http://example.org/term1',
      ontology_acronym: 'TEST'
    )

    doc.register_channel_hit(:curie_exact, rank: 1, raw_score: 1.0)
    doc.register_channel_hit(:bm25, rank: 3, raw_score: 14.5)

    assert_includes doc.matched_channels, :curie_exact
    assert_includes doc.matched_channels, :bm25
    assert_equal 1, doc.channel_ranks[:curie_exact]
    assert_equal 3, doc.channel_ranks[:bm25]
    assert_equal 14.5, doc.channel_scores[:bm25]
  end

  def test_to_h_serialization
    doc = Search::SemanticEntityDocument.new(
      iri: 'http://example.org/term2',
      curie: 'EX:2',
      pref_label: 'Example Concept',
      ontology_acronym: 'EX',
      rrf_score: 0.0327868
    )
    doc.register_channel_hit(:bm25, rank: 1)

    hash = doc.to_h
    assert_equal 'http://example.org/term2', hash[:iri]
    assert_equal 'EX:2', hash[:curie]
    assert_equal 'Example Concept', hash[:pref_label]
    assert_equal 0.032787, hash[:rrf_score]
    assert_equal [:bm25], hash[:matched_channels]
  end
end
