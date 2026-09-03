# frozen_string_literal: true

require 'minitest/autorun'
require_relative '../../app/models/blast_radius_report'

class BlastRadiusReportTest < Minitest::Test
  def test_verdict_safe_for_pure_additions
    report = BlastRadiusReport.new(
      ontology_acronym: 'TEST-ONTO',
      concept_churn: { added: ['http://example.org/c1', 'http://example.org/c2'] },
      orphaned_mappings: [],
      broken_queries: [],
      shacl_violation_delta: { delta: 0 }
    )

    assert_equal BlastRadiusReport::VERDICT_SAFE, report.verdict
    assert report.safe?
    refute report.breaking?
    assert_equal 'badge-verdict-safe', report.badge_css_class
  end

  def test_verdict_safe_with_review_for_modifications
    report = BlastRadiusReport.new(
      ontology_acronym: 'TEST-ONTO',
      concept_churn: { modified: ['http://example.org/c1'] },
      orphaned_mappings: [],
      broken_queries: [],
      shacl_violation_delta: { delta: 0 }
    )

    assert_equal BlastRadiusReport::VERDICT_SAFE_WITH_REVIEW, report.verdict
    assert report.safe_with_review?
    assert_equal 'badge-verdict-review', report.badge_css_class
  end

  def test_verdict_safe_with_review_for_shacl_regressions
    report = BlastRadiusReport.new(
      ontology_acronym: 'TEST-ONTO',
      concept_churn: { added: [] },
      orphaned_mappings: [],
      broken_queries: [],
      shacl_violation_delta: { baseline_violations: 1, candidate_violations: 3, delta: 2 }
    )

    assert_equal BlastRadiusReport::VERDICT_SAFE_WITH_REVIEW, report.verdict
    assert report.safe_with_review?
  end

  def test_verdict_breaking_for_removed_concepts
    report = BlastRadiusReport.new(
      ontology_acronym: 'TEST-ONTO',
      concept_churn: { removed: ['http://example.org/old_class'] },
      orphaned_mappings: [],
      broken_queries: []
    )

    assert_equal BlastRadiusReport::VERDICT_BREAKING, report.verdict
    assert report.breaking?
    assert_equal 'badge-verdict-breaking', report.badge_css_class
  end

  def test_verdict_breaking_for_broken_queries
    report = BlastRadiusReport.new(
      ontology_acronym: 'TEST-ONTO',
      concept_churn: { added: [] },
      orphaned_mappings: [],
      broken_queries: [{ query_id: 'Q1', reason: 'Zero results' }]
    )

    assert_equal BlastRadiusReport::VERDICT_BREAKING, report.verdict
    assert report.breaking?
  end

  def test_verdict_breaking_for_orphaned_mappings
    report = BlastRadiusReport.new(
      ontology_acronym: 'TEST-ONTO',
      concept_churn: { added: [] },
      orphaned_mappings: [{ mapping_id: 'M1', target: 'http://example.org/c1' }],
      broken_queries: []
    )

    assert_equal BlastRadiusReport::VERDICT_BREAKING, report.verdict
    assert report.breaking?
  end

  def test_verdict_policy_blocked_precedence
    report = BlastRadiusReport.new(
      ontology_acronym: 'TEST-ONTO',
      policy_violations: ['Missing SPDX license declaration'],
      concept_churn: { removed: ['http://example.org/c1'] }, # also breaking
      orphaned_mappings: []
    )

    assert_equal BlastRadiusReport::VERDICT_POLICY_BLOCKED, report.verdict
    assert report.policy_blocked?
    assert_equal 'badge-verdict-blocked', report.badge_css_class
  end

  def test_verdict_logically_invalid_precedence
    report = BlastRadiusReport.new(
      ontology_acronym: 'TEST-ONTO',
      logical_errors: ['OWL reasoner detected unsatisfiable class owl:Nothing'],
      policy_violations: ['License missing'],
      concept_churn: { removed: ['http://example.org/c1'] }
    )

    assert_equal BlastRadiusReport::VERDICT_LOGICALLY_INVALID, report.verdict
    assert report.logically_invalid?
    assert_equal 'badge-verdict-invalid', report.badge_css_class
  end

  def test_json_roundtrip_serialization
    original = BlastRadiusReport.new(
      ontology_acronym: 'SERIAL-TEST',
      baseline_submission_id: 'sub-1',
      candidate_submission_id: 'sub-2',
      concept_churn: {
        added: ['http://example.org/new1'],
        removed: ['http://example.org/old1'],
        modified: ['http://example.org/mod1']
      },
      orphaned_mappings: [{ mapping_id: 'M42', from_concept: 'http://example.org/old1' }],
      broken_queries: [{ query_id: 'Q-ROOT', reason: 'Missing root' }],
      shacl_violation_delta: { baseline_violations: 2, candidate_violations: 4, delta: 2 }
    )

    json_str = original.to_json
    deserialized = BlastRadiusReport.from_json(json_str)

    assert_equal original.id, deserialized.id
    assert_equal original.ontology_acronym, deserialized.ontology_acronym
    assert_equal original.verdict, deserialized.verdict
    assert_equal original.concept_churn[:added], deserialized.concept_churn[:added]
    assert_equal original.concept_churn[:removed], deserialized.concept_churn[:removed]
    assert_equal 1, deserialized.orphaned_mappings.size
    assert_equal 1, deserialized.broken_queries.size
    assert_equal 2, deserialized.shacl_violation_delta[:delta]
  end
end
