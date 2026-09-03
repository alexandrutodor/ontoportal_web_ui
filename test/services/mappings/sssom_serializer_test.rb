# frozen_string_literal: true

require 'minitest/autorun'
require_relative '../../../app/services/mappings/sssom_serializer'
require_relative '../../../app/services/mappings/sssom_parser'

class SssomSerializerTest < Minitest::Test
  def test_serialize_hash_mappings
    mappings = [
      {
        subject_id: 'http://qudt.org/schema/qudt/Temperature',
        subject_label: 'Temperature',
        predicate_id: 'http://www.w3.org/2004/02/skos/core#exactMatch',
        object_id: 'http://emmo.info/emmo#ThermodynamicTemperature',
        object_label: 'Thermodynamic Temperature',
        confidence: 0.98,
        comment: 'Standard SI temperature match'
      }
    ]

    metadata = {
      mapping_set_id: 'http://example.org/test_set',
      mapping_set_title: 'Test Mapping Set',
      curie_map: {
        'emmo' => 'http://emmo.info/emmo#'
      }
    }

    serialized = Mappings::SssomSerializer.serialize(mappings, metadata: metadata)

    assert_includes serialized, '# mapping_set_id: http://example.org/test_set'
    assert_includes serialized, "subject_id\tsubject_label\tpredicate_id"
    # Should contract URIs using CURIE map
    assert_includes serialized, "qudt:Temperature\tTemperature\tskos:exactMatch\temmo:ThermodynamicTemperature"

    # Verify round-trip parsing
    parsed = Mappings::SssomParser.parse(serialized)
    assert parsed.valid?
    assert_equal 1, parsed.mappings.size
    assert_equal 'qudt:Temperature', parsed.mappings[0].subject_id
    assert_equal 'emmo:ThermodynamicTemperature', parsed.mappings[0].object_id
  end

  def test_serialize_mock_ontoportal_objects
    mock_source = Struct.new(:id, :prefLabel).new('http://qudt.org/schema/qudt/Length', 'Length')
    mock_target = Struct.new(:id, :prefLabel).new('http://www.w3.org/2004/02/skos/core#ConceptLength', 'Concept Length')
    mock_mapping = Struct.new(:classes, :relation, :confidence, :source, :comment).new(
      [mock_source, mock_target],
      'skos:exactMatch',
      1.0,
      'Curator',
      'Verified'
    )

    serialized = Mappings::SssomSerializer.serialize([mock_mapping])
    assert_includes serialized, 'qudt:Length'
    assert_includes serialized, 'skos:exactMatch'
    assert_includes serialized, 'semapv:ManualMappingCuration'
  end
end
