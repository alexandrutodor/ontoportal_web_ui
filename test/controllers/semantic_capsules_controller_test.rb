# frozen_string_literal: true

require_relative '../standalone_test_helper'

class SemanticCapsulesControllerTest < Minitest::Test
  def setup
    SemanticCapsule.reset_registry!

    @capsule = SemanticCapsule.new(
      id: 'capsule-ctrl-test',
      name: 'controller-test-capsule',
      version: '1.0.0',
      description: 'Capsule for controller testing',
      author: 'Tester',
      ontologies: [{ 'acronym' => 'TESTO', 'uri' => 'http://example.org/testo', 'version_tag' => '1.0' }]
    )
    SemanticCapsule.save(@capsule)
  end

  def test_index_listing
    capsules = SemanticCapsule.all
    assert_equal 1, capsules.size
    assert_equal 'capsule-ctrl-test', capsules.first.id
  end

  def test_create_and_find
    new_capsule = SemanticCapsule.new(
      id: 'capsule-created-1',
      name: 'new-capsule',
      version: '2.0.0'
    )
    SemanticCapsule.save(new_capsule)

    found = SemanticCapsule.find('capsule-created-1')
    refute_nil found
    assert_equal 'new-capsule', found.name
    assert_equal 2, SemanticCapsule.all.size
  end

  def test_download_lock_generation
    capsule = SemanticCapsule.find('capsule-ctrl-test')
    generator = Capsules::LockfileGenerator.new(capsule)
    yaml = generator.to_yaml
    json = generator.to_json

    refute_empty yaml
    refute_empty json
    assert_includes yaml, 'TESTO'
    assert_includes json, 'TESTO'
  end

  def test_download_bundle_generation
    capsule = SemanticCapsule.find('capsule-ctrl-test')
    exporter = Capsules::RoCrateExporter.new(capsule)
    zip_data = exporter.export

    refute_nil zip_data
    assert zip_data.bytesize > 100
  end

  def test_verify_action_workflow
    capsule = SemanticCapsule.find('capsule-ctrl-test')
    res = capsule.validate_integrity

    assert res[:valid]
    assert_equal :valid, res[:status]
    assert_equal 'verified', capsule.status
  end

  def test_validate_arbitrary_lockfile
    generator = Capsules::LockfileGenerator.new(
      name: 'ad-hoc-validation',
      version: '1.0.0',
      ontologies: [{ 'acronym' => 'SAMPLE', 'uri' => 'http://example.org/sample' }]
    )
    yaml_content = generator.to_yaml

    validation = Capsules::LockfileValidator.validate(yaml_content)
    assert validation[:valid]
    assert_empty validation[:errors]
  end
end
