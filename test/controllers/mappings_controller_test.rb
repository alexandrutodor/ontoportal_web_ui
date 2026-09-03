# frozen_string_literal: true

$REST_URL ||= 'http://localhost:8080'
$API_KEY ||= 'test-key'
$PROXY_URL ||= ''

require 'minitest/autorun'
require_relative '../../app/services/mappings/sssom_parser'
require_relative '../../app/services/mappings/sssom_serializer'
require_relative '../../app/services/mappings/sanity_guard'
require_relative '../../app/services/mappings/version_drift_reconciler'

class MappingsControllerStandaloneTest < Minitest::Test
    def test_import_sssom_payload_processing
      raw_sssom = <<~TSV
        # mapping_set_id: http://example.org/test
        subject_id\tsubject_label\tpredicate_id\tobject_id\tobject_label\tmapping_justification
        qudt:Length\tLength\tskos:exactMatch\temmo:Length\tLength\tsemapv:LexicalMatching
      TSV

      parsed = Mappings::SssomParser.parse(raw_sssom)
      assert parsed.valid?

      sanity = Mappings::SanityGuard.validate_batch(parsed.mappings)
      assert sanity.all?(&:valid?)
    end

    def test_import_sssom_detects_sanity_violations
      raw_sssom = <<~TSV
        subject_id\tsubject_label\tpredicate_id\tobject_id\tobject_label\tmapping_justification
        qudt:Temperature\tTemperature\tskos:exactMatch\temmo:Force\tForce\tsemapv:LexicalMatching
      TSV

      parsed = Mappings::SssomParser.parse(raw_sssom)
      assert parsed.valid?

      sanity = Mappings::SanityGuard.validate_batch(parsed.mappings)
      violations = sanity.select { |r| !r.valid? }.map(&:violations).flatten
      refute_empty violations
      assert violations.any? { |v| v.include?('SI physical dimension mismatch') }
    end

    def test_validate_sanity_endpoint_logic
      single_valid = Mappings::SanityGuard.validate_mapping('temperature', 'thermodynamic_temperature', relation: 'skos:exactMatch')
      assert single_valid.valid?

      single_invalid = Mappings::SanityGuard.validate_mapping('stress_tensor', 'temperature', relation: 'skos:exactMatch')
      refute single_invalid.valid?
    end

    def test_drift_report_endpoint_logic
      report = Mappings::VersionDriftReconciler.reconcile([])
      assert_equal 0, report.summary[:total_mappings]
      assert_equal 0.0, report.summary[:drift_rate]
    end
  end
