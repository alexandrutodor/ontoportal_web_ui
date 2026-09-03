# frozen_string_literal: true

require_relative '../../standalone_test_helper'
require 'tempfile'
require 'zip'

class RoCrateExporterTest < Minitest::Test
  def setup
    @capsule = SemanticCapsule.new(
      id: 'capsule-test-12345',
      name: 'ro-crate-test-capsule',
      version: '2.0.0',
      description: 'Capsule designed for RO-Crate export testing',
      author: 'Test Engineer',
      ontologies: [
        {
          'acronym' => 'EMMO',
          'uri' => 'http://emmo.info/emmo#',
          'version_tag' => '1.0.0',
          'sha256' => '11223344556677889900aabbccddeeff11223344556677889900aabbccddeeff'
        }
      ],
      shapes: [
        {
          'name' => 'EMMOShapes',
          'iri' => 'https://w3id.org/emmo/shapes',
          'version' => '1.0.0',
          'sha256' => 'aabbccddee11223344556677889900aabbccddee11223344556677889900aabbcc'
        }
      ],
      mappings: [
        {
          'id' => 'EMMO_CHEO_001',
          'source_ontology' => 'EMMO',
          'target_ontology' => 'CHEBI',
          'sha256' => 'ffeeddccbbaa00998877665544332211ffeeddccbbaa00998877665544332211',
          'mapping_count' => 120
        }
      ],
      embeddings: [
        {
          'model_name' => 'Onto2Vec-v1',
          'dimensions' => 256,
          'sha256' => '00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff'
        }
      ]
    )

    @exporter = Capsules::RoCrateExporter.new(@capsule)
  end

  def test_generate_metadata_json_structure
    metadata = @exporter.manifest_metadata

    assert_equal 'https://w3id.org/ro/crate/1.1/context', metadata['@context']
    assert metadata['@graph'].is_a?(Array)

    root_dataset = metadata['@graph'].find { |node| node['@id'] == './' }
    assert root_dataset
    assert_includes root_dataset['@type'], 'Dataset'
    assert_equal 'ro-crate-test-capsule', root_dataset['name']
    assert_equal '2.0.0', root_dataset['version']
    author_name = root_dataset['author'].is_a?(Hash) ? root_dataset['author']['name'] : root_dataset['author']
    assert_equal 'Test Engineer', author_name

    # Must contain parts
    parts = root_dataset['hasPart']
    assert parts.any? { |p| p['@id'] == 'semantic.lock' }
    assert parts.any? { |p| p['@id'] == 'README.md' }
    assert parts.any? { |p| p['@id'] == 'ontologies/EMMO' }
    assert parts.any? { |p| p['@id'] == 'shapes/EMMOShapes' }
    assert parts.any? { |p| p['@id'] == 'mappings/EMMO_CHEO_001' }
  end

  def test_generate_readme
    readme = @exporter.send(:generate_readme)
    assert_includes readme, 'ro-crate-test-capsule'
    assert_includes readme, 'EMMO'
    assert_includes readme, 'Test Engineer'
  end

  def test_export_creates_valid_zip_archive
    zip_data = @exporter.export
    refute_nil zip_data
    refute_empty zip_data

    # Read zip stream
    entry_names = []
    Zip::InputStream.open(StringIO.new(zip_data)) do |io|
      while (entry = io.get_next_entry)
        entry_names << entry.name
      end
    end

    assert_includes entry_names, 'ro-crate-metadata.json'
    assert_includes entry_names, 'semantic.lock'
    assert_includes entry_names, 'README.md'
  end

  def test_export_to_tempfile
    tempfile = @exporter.export_to_tempfile
    assert File.exist?(tempfile.path)
    assert File.size(tempfile.path) > 0
  ensure
    tempfile.close! if tempfile
  end
end
