# frozen_string_literal: true

require 'minitest/autorun'
require_relative '../../app/models/blast_radius_report'
require_relative '../../app/services/blast_radius/query_replay_service'
require_relative '../../app/services/blast_radius/shacl_replay_service'
require_relative '../../app/services/blast_radius/simulation_engine'

class BlastRadiusSimulationEngineTest < Minitest::Test
  def setup
    BlastRadius::SimulationEngine.clear_store!
  end

  def test_simulation_additive_safe
    baseline = {
      id: 'sub-1',
      concepts: [
        { id: 'http://example.org/onto#Root', label: 'Root Class', definition: 'Root node' },
        { id: 'http://example.org/onto#Child1', label: 'Child Class 1', definition: 'First child' }
      ]
    }

    candidate = {
      id: 'sub-2',
      concepts: [
        { id: 'http://example.org/onto#Root', label: 'Root Class', definition: 'Root node' },
        { id: 'http://example.org/onto#Child1', label: 'Child Class 1', definition: 'First child' },
        { id: 'http://example.org/onto#Child2', label: 'Child Class 2', definition: 'Second child' }
      ]
    }

    report = BlastRadius::SimulationEngine.simulate(
      ontology_acronym: 'ONTO-ADDITIVE',
      baseline_submission: baseline,
      candidate_submission: candidate
    )

    assert_equal BlastRadiusReport::VERDICT_SAFE, report.verdict
    assert_equal ['http://example.org/onto#Child2'], report.concept_churn[:added]
    assert_empty report.concept_churn[:removed]
    assert_empty report.orphaned_mappings
    assert_empty report.broken_queries
  end

  def test_simulation_removed_concept_breaking
    baseline = {
      id: 'sub-1',
      concepts: [
        { id: 'http://example.org/onto#ActiveA', label: 'Active A', definition: 'Class A' },
        { id: 'http://example.org/onto#ActiveB', label: 'Active B', definition: 'Class B' }
      ]
    }

    candidate = {
      id: 'sub-2',
      concepts: [
        { id: 'http://example.org/onto#ActiveA', label: 'Active A', definition: 'Class A' }
      ]
    }

    external_mappings = [
      { id: 'MAP-1', from_concept: 'http://example.org/onto#ActiveB', to_concept: 'http://other.org/B', relation: 'skos:exactMatch' }
    ]

    report = BlastRadius::SimulationEngine.simulate(
      ontology_acronym: 'ONTO-BREAKING',
      baseline_submission: baseline,
      candidate_submission: candidate,
      external_mappings: external_mappings
    )

    assert_equal BlastRadiusReport::VERDICT_BREAKING, report.verdict
    assert_includes report.concept_churn[:removed], 'http://example.org/onto#ActiveB'
    assert_equal 1, report.orphaned_mappings.size
    assert_equal 'MAP-1', report.orphaned_mappings.first[:mapping_id]
  end

  def test_simulation_modified_label_review_needed
    baseline = {
      id: 'sub-1',
      concepts: [
        { id: 'http://example.org/onto#C1', label: 'Original Label', definition: 'Def 1' }
      ]
    }

    candidate = {
      id: 'sub-2',
      concepts: [
        { id: 'http://example.org/onto#C1', label: 'Modified Label', definition: 'Def 1' }
      ]
    }

    report = BlastRadius::SimulationEngine.simulate(
      ontology_acronym: 'ONTO-MOD',
      baseline_submission: baseline,
      candidate_submission: candidate
    )

    assert_equal BlastRadiusReport::VERDICT_SAFE_WITH_REVIEW, report.verdict
    assert_includes report.concept_churn[:modified], 'http://example.org/onto#C1'
  end

  def test_simulation_policy_enforcement
    baseline = { id: 'sub-1', concepts: [] }
    candidate = { id: 'sub-2', concepts: [], license: nil }

    report = BlastRadius::SimulationEngine.simulate(
      ontology_acronym: 'ONTO-POLICY',
      baseline_submission: baseline,
      candidate_submission: candidate,
      options: { require_license: true }
    )

    assert_equal BlastRadiusReport::VERDICT_POLICY_BLOCKED, report.verdict
    assert report.policy_blocked?
    assert_match(/SPDX \/ open access license/, report.policy_violations.first)
  end

  def test_simulation_logical_inconsistency_precedence
    baseline = { id: 'sub-1', concepts: [] }
    candidate = { id: 'sub-2', concepts: [] }

    report = BlastRadius::SimulationEngine.simulate(
      ontology_acronym: 'ONTO-LOGIC',
      baseline_submission: baseline,
      candidate_submission: candidate,
      options: {
        unsatisfiable_classes: ['http://example.org/onto#InconsistentClass'],
        require_license: true # policy violation also present
      }
    )

    assert_equal BlastRadiusReport::VERDICT_LOGICALLY_INVALID, report.verdict
    assert report.logically_invalid?
    assert_match(/unsatisfiable classes/, report.logical_errors.first)
  end

  def test_store_and_lookup_latest_report
    baseline = { id: 'sub-1', concepts: [] }
    candidate = { id: 'sub-2', concepts: [] }

    report = BlastRadius::SimulationEngine.simulate(
      ontology_acronym: 'FIND-ME',
      baseline_submission: baseline,
      candidate_submission: candidate
    )

    found = BlastRadius::SimulationEngine.find_report(report.id)
    assert_equal report.id, found.id

    latest = BlastRadius::SimulationEngine.latest_report('FIND-ME')
    assert_equal report.id, latest.id
  end

  def test_query_replay_service_regression_detection
    baseline = {
      concepts: [
        { id: 'http://example.org/c1', label: 'C1' },
        { id: 'http://example.org/c2', label: 'C2' }
      ]
    }

    candidate = {
      concepts: [
        { id: 'http://example.org/c1', label: 'C1' }
      ]
    }

    service = BlastRadius::QueryReplayService.new(
      baseline_submission: baseline,
      candidate_submission: candidate
    )

    queries = [
      { id: 'Q-TEST', type: :concept_lookup, description: 'Test query', target_iris: ['http://example.org/c2'] }
    ]

    res = service.replay(queries)
    assert_equal 1, res[:total]
    assert_equal 0, res[:passed]
    assert_equal 1, res[:failed]
    assert_equal 'Q-TEST', res[:regressions].first[:query_id]
  end

  def test_shacl_replay_service_detects_violations
    baseline = {
      concepts: [
        { id: 'http://example.org/good', label: 'Valid Concept', definition: 'Valid definition' }
      ]
    }

    candidate = {
      concepts: [
        { id: 'http://example.org/good', label: 'Valid Concept', definition: 'Valid definition' },
        { id: 'http://example.org/bad_no_label', label: '', definition: 'Has def but no label' },
        { id: 'not-a-valid-iri', label: 'Invalid IRI', definition: 'Valid def' }
      ]
    }

    service = BlastRadius::ShaclReplayService.new(
      baseline_submission: baseline,
      candidate_submission: candidate
    )

    result = service.evaluate
    assert_equal 0, result[:baseline_violations]
    assert result[:candidate_violations] >= 2
    assert result[:delta] >= 2
    assert result[:new_violations].any? { |v| v[:shape_id] == 'SHACL-PREF-LABEL-REQUIRED' }
    assert result[:new_violations].any? { |v| v[:shape_id] == 'SHACL-VALID-IRI-SYNTAX' }
  end
end
