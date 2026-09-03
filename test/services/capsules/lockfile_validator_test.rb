# frozen_string_literal: true

require_relative '../../standalone_test_helper'
require 'semantic_capsule'
require 'capsules/lockfile_validator'
require 'capsules/lockfile_generator'

class LockfileValidatorTest < Minitest::Test
  def setup
    generator = Capsules::LockfileGenerator.new(
      name: 'validation-test-capsule',
      version: '1.2.0',
      description: 'Capsule for testing validation rules'
    )
    generator.add_ontology(acronym: 'CHEBI', uri: 'http://purl.obolibrary.org/obo/chebi.owl', version: '213')
    generator.add_shape(name: 'ChemicalCompoundShape', path: 'shapes/chebi.shacl.ttl', content: 'ex:Shape a sh:NodeShape .')
    @valid_yaml = generator.to_yaml
  end

  def test_validate_valid_lockfile
    validator = Capsules::LockfileValidator.new(@valid_yaml)
    result = validator.validate

    assert result[:valid]
    assert_equal :valid, result[:status]
    assert_empty result[:errors]
    assert result[:expected_digest].start_with?('sha256:')
    assert_equal result[:expected_digest], result[:computed_digest]
  end

  def test_detect_corrupted_yaml
    validator = Capsules::LockfileValidator.new("invalid: [yaml: broken: {")
    result = validator.validate

    refute result[:valid]
    assert_equal :invalid, result[:status]
    assert(result[:errors].any? { |e| e.include?('YAML parse error') })
  end

  def test_detect_missing_schema_version
    parsed = YAML.safe_load(@valid_yaml)
    parsed.delete('schema_version')
    tampered_yaml = YAML.dump(parsed)

    validator = Capsules::LockfileValidator.new(tampered_yaml)
    result = validator.validate

    refute result[:valid]
    assert(result[:errors].any? { |e| e.include?('schema_version') })
  end

  def test_detect_tampered_payload_digest_mismatch
    parsed = YAML.safe_load(@valid_yaml)
    # Tamper with ontology version without updating integrity digest
    parsed['ontologies'][0]['version'] = '999-tampered'
    tampered_yaml = YAML.dump(parsed)

    validator = Capsules::LockfileValidator.new(tampered_yaml)
    result = validator.validate

    refute result[:valid]
    assert_equal :tampered, result[:status]
    assert(result[:errors].any? { |e| e.include?('Integrity verification failed') })
    refute_equal result[:expected_digest], result[:computed_digest]
  end

  def test_detect_missing_required_capsule_metadata
    parsed = YAML.safe_load(@valid_yaml)
    parsed['capsule'].delete('name')
    tampered_yaml = YAML.dump(parsed)

    validator = Capsules::LockfileValidator.new(tampered_yaml)
    result = validator.validate

    refute result[:valid]
    assert(result[:errors].any? { |e| e.include?('Missing capsule.name') })
  end

  def test_detect_invalid_ontology_entry
    parsed = YAML.safe_load(@valid_yaml)
    parsed['ontologies'][0].delete('acronym')
    tampered_yaml = YAML.dump(parsed)

    validator = Capsules::LockfileValidator.new(tampered_yaml)
    result = validator.validate

    refute result[:valid]
    assert(result[:errors].any? { |e| e.include?('acronym') })
  end
end
