# frozen_string_literal: true

require 'test_helper'
require_relative '../../../app/models/recommender/ontology_evaluation'
require_relative '../../../app/models/recommender/pareto_frontier'

class ParetoFrontierTest < ActiveSupport::TestCase
  def setup
    @eval_a = Recommender::OntologyEvaluation.new(
      acronym: 'ONTO_A',
      coverage: 0.85,
      specialization: 0.70,
      recency: 0.90,
      redundancy: 0.10,
      license_spdx: 'CC-BY-4.0'
    )

    @eval_b = Recommender::OntologyEvaluation.new(
      acronym: 'ONTO_B',
      coverage: 0.60,
      specialization: 0.50,
      recency: 0.60,
      redundancy: 0.20,
      license_spdx: 'MIT'
    )

    @eval_c = Recommender::OntologyEvaluation.new(
      acronym: 'ONTO_C',
      coverage: 0.90,
      specialization: 0.60,
      recency: 0.80,
      redundancy: 0.15,
      license_spdx: 'Apache-2.0'
    )

    @eval_d = Recommender::OntologyEvaluation.new(
      acronym: 'ONTO_D',
      coverage: 0.50,
      specialization: 0.40,
      recency: 0.50,
      redundancy: 0.30,
      license_spdx: 'Proprietary'
    )
  end

  test 'dominance logic correctly detects strict dominance' do
    # ONTO_A strictly dominates ONTO_B on all 4 objectives
    assert @eval_a.dominates?(@eval_b)
    refute @eval_b.dominates?(@eval_a)

    # ONTO_A vs ONTO_C: trade-off (C has higher coverage 0.90 vs 0.85, but A has higher specialization 0.70 vs 0.60)
    refute @eval_a.dominates?(@eval_c)
    refute @eval_c.dominates?(@eval_a)
  end

  test 'non_dominated_sort partitions evaluations into Pareto fronts' do
    fronts = Recommender::ParetoFrontier.non_dominated_sort([@eval_a, @eval_b, @eval_c, @eval_d])

    assert_equal 3, fronts.size, 'Expected 3 distinct fronts'
    
    # Front 1 should contain non-dominated trade-offs A and C
    front1_acronyms = fronts[0].map(&:acronym)
    assert_includes front1_acronyms, 'ONTO_A'
    assert_includes front1_acronyms, 'ONTO_C'
    assert_equal 1, @eval_a.pareto_rank
    assert_equal 1, @eval_c.pareto_rank

    # Front 2 should contain B (dominated by A and C)
    front2_acronyms = fronts[1].map(&:acronym)
    assert_includes front2_acronyms, 'ONTO_B'
    assert_equal 2, @eval_b.pareto_rank

    # Front 3 should contain D (dominated by B)
    front3_acronyms = fronts[2].map(&:acronym)
    assert_includes front3_acronyms, 'ONTO_D'
    assert_equal 3, @eval_d.pareto_rank
  end

  test 'assign_crowding_distance assigns infinity to boundary points' do
    front = [@eval_a, @eval_c]
    Recommender::ParetoFrontier.assign_crowding_distance(front)

    # Size <= 2 assigns infinity to both boundary points
    assert_equal Float::INFINITY, @eval_a.crowding_distance
    assert_equal Float::INFINITY, @eval_c.crowding_distance
  end

  test 'assign_crowding_distance calculates finite diversity for 3+ points' do
    eval1 = Recommender::OntologyEvaluation.new(acronym: 'O1', coverage: 0.1, specialization: 0.1, recency: 0.1, redundancy: 0.9)
    eval2 = Recommender::OntologyEvaluation.new(acronym: 'O2', coverage: 0.5, specialization: 0.5, recency: 0.5, redundancy: 0.5)
    eval3 = Recommender::OntologyEvaluation.new(acronym: 'O3', coverage: 0.9, specialization: 0.9, recency: 0.9, redundancy: 0.1)

    front = [eval1, eval2, eval3]
    Recommender::ParetoFrontier.assign_crowding_distance(front)

    assert_equal Float::INFINITY, eval1.crowding_distance
    assert_equal Float::INFINITY, eval3.crowding_distance
    assert eval2.crowding_distance.positive?
    refute_equal Float::INFINITY, eval2.crowding_distance
  end

  test 'pareto_set_covering identifies non-dominated combinations' do
    evals = [
      Recommender::OntologyEvaluation.new(
        acronym: 'CHEBI', coverage: 0.60, specialization: 0.80, recency: 0.90, redundancy: 0.05,
        license_spdx: 'CC-BY-4.0', coverage_details: { covered_terms: ['c1', 'c2', 'c3'], total_terms: 5 }
      ),
      Recommender::OntologyEvaluation.new(
        acronym: 'GO', coverage: 0.50, specialization: 0.75, recency: 0.85, redundancy: 0.05,
        license_spdx: 'CC0-1.0', coverage_details: { covered_terms: ['c4', 'c5'], total_terms: 5 }
      ),
      Recommender::OntologyEvaluation.new(
        acronym: 'NCIT', coverage: 0.30, specialization: 0.60, recency: 0.70, redundancy: 0.10,
        license_spdx: 'CC-BY-4.0', coverage_details: { covered_terms: ['c1'], total_terms: 5 }
      )
    ]

    sets = Recommender::ParetoFrontier.pareto_set_covering(evals, max_set_size: 2)
    assert sets.any?, 'Expected at least one non-dominated set'

    best_set = sets.find { |s| s[:ontologies].sort == %w[CHEBI GO].sort }
    assert best_set.present?
    assert_equal 1.0, best_set[:combined_coverage], 'CHEBI + GO should cover all 5 terms'
    assert best_set[:license_permissive]
  end

  test 'handles empty and nil evaluations gracefully' do
    assert_equal [], Recommender::ParetoFrontier.non_dominated_sort([])
    assert_equal [], Recommender::ParetoFrontier.non_dominated_sort(nil)
    assert_equal [], Recommender::ParetoFrontier.pareto_set_covering([])
  end
end
