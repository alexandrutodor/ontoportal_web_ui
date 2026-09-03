# frozen_string_literal: true

require 'minitest/autorun'
require_relative '../../../app/services/mappings/sssom_parser'

class SssomParserTest < Minitest::Test
  SAMPLE_SSSOM = <<~SSSOM
    # mapping_set_id: http://example.org/mappings/mat_mapping_1
    # mapping_set_title: Materials Dimension Alignments
    # mapping_set_version: "1.0.0"
    # license: https://creativecommons.org/publicdomain/zero/1.0/
    # curie_map:
    #   qudt: "http://qudt.org/schema/qudt/"
    #   emmo: "http://emmo.info/emmo#"
    subject_id\tsubject_label\tpredicate_id\tobject_id\tobject_label\tmapping_justification\tconfidence
    qudt:Temperature\tTemperature\tskos:exactMatch\temmo:ThermodynamicTemperature\tThermodynamic Temperature\tsemapv:LexicalMatching\t0.95
    qudt:Stress\tCauchy Stress\tskos:exactMatch\temmo:StressTensor\tStress Tensor\tsemapv:ManualMappingCuration\t1.0
  SSSOM

  def test_parse_valid_sssom_with_yaml_and_tsv
    result = Mappings::SssomParser.parse(SAMPLE_SSSOM)

    assert result.valid?
    assert_empty result.errors
    assert_equal 'http://example.org/mappings/mat_mapping_1', result.metadata['mapping_set_id']
    assert_equal 'Materials Dimension Alignments', result.metadata['mapping_set_title']
    assert_equal 2, result.mappings.size

    first = result.mappings[0]
    assert_equal 'qudt:Temperature', first.subject_id
    assert_equal 'http://qudt.org/schema/qudt/Temperature', first.subject_uri
    assert_equal 'skos:exactMatch', first.predicate_id
    assert_equal 'http://www.w3.org/2004/02/skos/core#exactMatch', first.predicate_uri
    assert_equal 'emmo:ThermodynamicTemperature', first.object_id
    assert_equal 'http://emmo.info/emmo#ThermodynamicTemperature', first.object_uri
    assert_equal 0.95, first.confidence
  end

  def test_parse_tsv_without_yaml_header
    tsv = <<~TSV
      subject_id\tpredicate_id\tobject_id\tmapping_justification
      ex:A\tskos:exactMatch\tex:B\tsemapv:LexicalMatching
    TSV
    result = Mappings::SssomParser.parse(tsv)

    assert result.valid?
    assert_equal 1, result.mappings.size
    assert_equal 'ex:A', result.mappings[0].subject_id
  end

  def test_parse_missing_required_headers
    tsv = <<~TSV
      subject_id\tobject_id
      ex:A\tex:B
    TSV
    result = Mappings::SssomParser.parse(tsv)

    refute result.valid?
    assert result.errors.any? { |e| e.include?('Missing required SSSOM fields') }
  end

  def test_parse_missing_row_values
    tsv = <<~TSV
      subject_id\tpredicate_id\tobject_id\tmapping_justification
      ex:A\t\tex:B\tsemapv:LexicalMatching
    TSV
    result = Mappings::SssomParser.parse(tsv)

    assert_empty result.mappings
    assert result.errors.any? { |e| e.include?('missing required values') }
  end
end
