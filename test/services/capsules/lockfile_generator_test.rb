# frozen_string_literal: true

require_relative '../../standalone_test_helper'
require 'tempfile'

class LockfileGeneratorTest < Minitest::Test
  def setup
    @capsule = SemanticCapsule.new(
      'id' => 'urn:uuid:11112222-3333-4444-5555-666677778888',
      'name' => 'crystallography-kg',
      'version' => '1.2.0',
      'description' => 'Crystal structure extraction and validation',
      'author' => 'Materials Lab',
      'created_at' => '2026-09-03T12:00:00Z',
      'ontologies' => [
        {
          'acronym' => 'CIF',
          'iri' => 'http://example.org/cif',
          'submission_id' => 3,
          'version_tag' => '2026.1',
          'sha256' => 'aabbccddeeff00112233445566778899aabbccddeeff00112233445566778899',
          'triples_count' => 45_000
        }
      ],
      'shapes' => [
        {
          'name' => 'CifShape',
          'iri' => 'http://example.org/cif-shape.ttl',
          'version' => '1.0',
          'sha256' => '11223344556677889900aabbccddeeff11223344556677889900aabbccddeeff'
        }
      ],
      'mappings' => [
        {
          'id' => 'CIF-EMMO',
          'sssom_version' => '1.0',
          'source_ontology' => 'CIF',
          'target_ontology' => 'EMMO',
          'sha256' => '99887766554433221100ffeeddccbbaa99887766554433221100ffeeddccbbaa',
          'mapping_count' => 120
        }
      ],
      'embeddings' => [
        {
          'model_id' => 'sentence-transformers/all-MiniLM-L6-v2',
          'dimension' => 384,
          'distance_metric' => 'cosine',
          'checksum' => '5544332211'
        }
      ]
    )
    @generator = Capsules::LockfileGenerator.new(@capsule)
  end

  def test_generate_schema_compliance
    manifest = @generator.generate

    assert_equal 'semantic.lock/v1', manifest['schema_version']
    assert_equal 'crystallography-kg', manifest['capsule']['name']
    assert_equal '1.2.0', manifest['capsule']['version']
    assert_equal 1, manifest['ontologies'].size
    assert_equal 'CIF', manifest['ontologies'].first['acronym']
    assert_equal 1, manifest['shapes'].size
    assert_equal 1, manifest['mappings'].size
    assert_equal 1, manifest['embeddings'].size
    assert manifest['integrity'].is_a?(Hash)
    assert manifest['integrity']['manifest_digest'].start_with?('sha256:')
  end

  def test_deterministic_digest_reproducibility
    digest1 = Capsules::LockfileGenerator.compute_digest(@generator.generate)
    digest2 = Capsules::LockfileGenerator.compute_digest(@generator.generate)
    assert_equal digest1, digest2
  end

  def test_canonicalize_sorts_keys_recursively
    unsorted = {
      'z' => 1,
      'a' => { 'delta' => 4, 'alpha' => 1 },
      'm' => [ { 'k' => 2, 'b' => 1 } ]
    }
    canonical = Capsules::LockfileGenerator.canonicalize(unsorted)
    assert_equal ['a', 'm', 'z'], canonical.keys
    assert_equal ['alpha', 'delta'], canonical['a'].keys
    assert_equal ['b', 'k'], canonical['m'].first.keys
  end

  def test_to_yaml_and_to_json_output
    yaml = @generator.to_yaml
    assert_includes yaml, 'schema_version: semantic.lock/v1'
    parsed_yaml = YAML.safe_load(yaml)
    assert_equal 'crystallography-kg', parsed_yaml['capsule']['name']

    json = @generator.to_json
    parsed_json = JSON.parse(json)
    assert_equal 'crystallography-kg', parsed_json['capsule']['name']
    assert_equal parsed_yaml['integrity']['manifest_digest'], parsed_json['integrity']['manifest_digest']
  end

  def test_digest_content_and_file
    content = 'mock rdf triple store export data'
    digest = Capsules::LockfileGenerator.digest_content(content)
    assert digest.start_with?('sha256:')

    temp = Tempfile.new('sha-test')
    begin
      temp.write(content)
      temp.flush
      file_digest = Capsules::LockfileGenerator.digest_file(temp.path)
      assert_equal digest, file_digest
    ensure
      temp.close
      temp.unlink
    end
  end
end
