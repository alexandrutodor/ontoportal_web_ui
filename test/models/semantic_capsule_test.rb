# frozen_string_literal: true

require_relative '../standalone_test_helper'

class SemanticCapsuleTest < Minitest::Test
  def setup
    SemanticCapsule.reset_registry!
  end

  def test_initialization_defaults
    capsule = SemanticCapsule.new
    assert capsule.id.start_with?('capsule-')
    assert_equal 'untitled-capsule', capsule.name
    assert_equal '1.0.0', capsule.version
    assert_equal 'locked', capsule.status
    assert_empty capsule.locked_ontologies
    assert_empty capsule.locked_shapes
    assert_empty capsule.locked_mappings
    assert_empty capsule.locked_embeddings
    refute capsule.verified?
    refute capsule.tampered?
  end

  def test_initialization_with_attributes
    capsule = SemanticCapsule.new(
      id: 'my-capsule-1',
      name: 'battery-electrolyte',
      version: '2.1.0',
      description: 'Test capsule',
      author: 'Tester',
      ontologies: [
        { acronym: 'EMMO', version_tag: '1.0.0', sha256: 'abc123def456' }
      ]
    )

    assert_equal 'my-capsule-1', capsule.id
    assert_equal 'battery-electrolyte', capsule.name
    assert_equal '2.1.0', capsule.version
    assert_equal 'Tester', capsule.author
    assert_equal 1, capsule.locked_ontologies.size
    assert_equal 'EMMO', capsule.locked_ontologies.first['acronym']
    assert capsule.persisted?
    assert_equal 'my-capsule-1', capsule.to_param
  end

  def test_status_helpers
    capsule = SemanticCapsule.new(status: 'verified')
    assert capsule.verified?
    refute capsule.tampered?

    capsule.status = 'tampered'
    refute capsule.verified?
    assert capsule.tampered?
  end

  def test_to_lockfile_generation
    capsule = SemanticCapsule.new(
      name: 'test-capsule',
      ontologies: [{ 'acronym' => 'EMMO', 'sha256' => 'aabbccddeeff' }]
    )

    yaml = capsule.to_lockfile(format: :yaml)
    assert_includes yaml, 'schema_version: semantic.lock/v1'
    assert_includes yaml, 'test-capsule'
    assert_includes yaml, 'manifest_digest'

    json = capsule.to_lockfile(format: :json)
    parsed = JSON.parse(json)
    assert_equal 'semantic.lock/v1', parsed['schema_version']
    assert_equal 'test-capsule', parsed['capsule']['name']
  end

  def test_from_lockfile_factory
    lock_yaml = <<~YAML
      schema_version: "semantic.lock/v1"
      capsule:
        id: "urn:uuid:test-1234"
        name: "imported-kg"
        version: "3.0.0"
        author: "Alice"
        description: "Imported test capsule"
      ontologies:
        - acronym: "CHEMINF"
          sha256: "0123456789abcdef"
      shapes: []
      mappings: []
      embeddings: []
      integrity:
        manifest_digest: "sha256:112233445566"
    YAML

    capsule = SemanticCapsule.from_lockfile(lock_yaml)
    assert_equal 'urn:uuid:test-1234', capsule.id
    assert_equal 'imported-kg', capsule.name
    assert_equal '3.0.0', capsule.version
    assert_equal 'Alice', capsule.author
    assert_equal 1, capsule.locked_ontologies.size
    assert_equal 'sha256:112233445566', capsule.manifest_digest
  end

  def test_registry_crud_operations
    capsule1 = SemanticCapsule.new(id: 'cap-1', name: 'First')
    capsule2 = SemanticCapsule.new(id: 'cap-2', name: 'Second')

    SemanticCapsule.save(capsule1)
    SemanticCapsule.save(capsule2)

    all_capsules = SemanticCapsule.all
    assert_includes all_capsules.map(&:id), 'cap-1'
    assert_includes all_capsules.map(&:id), 'cap-2'

    found = SemanticCapsule.find('cap-1')
    assert_equal 'First', found.name

    SemanticCapsule.delete('cap-1')
    assert_nil SemanticCapsule.find('cap-1')
    assert_equal 1, SemanticCapsule.all.size
  end

  def test_validate_integrity
    capsule = SemanticCapsule.new(
      name: 'verifiable-capsule',
      ontologies: [{ 'acronym' => 'EMMO', 'sha256' => 'aabbccddeeff' }]
    )

    result = capsule.validate_integrity
    assert result[:valid]
    assert_equal :valid, result[:status]
    assert capsule.verified?
  end
end
