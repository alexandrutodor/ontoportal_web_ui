# frozen_string_literal: true

require 'test_helper'
require_relative '../../../app/models/recommender/ontology_evaluation'
require_relative '../../../app/models/recommender/pareto_frontier'
require_relative '../../../app/services/recommender/pareto_recommender_service'

class ParetoRecommenderServiceTest < ActiveSupport::TestCase
  def setup
    @mock_evaluations = [
      Recommender::OntologyEvaluation.new(
        acronym: 'CHEBI', name: 'Chemical Entities', coverage: 0.85,
        specialization: 0.80, recency: 0.90, redundancy: 0.05,
        license_spdx: 'CC-BY-4.0'
      ),
      Recommender::OntologyEvaluation.new(
        acronym: 'GO', name: 'Gene Ontology', coverage: 0.70,
        specialization: 0.85, recency: 0.95, redundancy: 0.05,
        license_spdx: 'CC0-1.0'
      ),
      Recommender::OntologyEvaluation.new(
        acronym: 'PROPR', name: 'Proprietary Onto', coverage: 0.95,
        specialization: 0.90, recency: 0.90, redundancy: 0.02,
        license_spdx: 'Proprietary'
      ),
      Recommender::OntologyEvaluation.new(
        acronym: 'POOR', name: 'Low Coverage Onto', coverage: 0.20,
        specialization: 0.20, recency: 0.20, redundancy: 0.40,
        license_spdx: 'MIT'
      )
    ]

    @provider = ->(_input, ontologies: nil) {
      list = @mock_evaluations.map(&:dup)
      list.select! { |e| ontologies.include?(e.acronym) } if ontologies&.any?
      list
    }
  end

  test 'returns empty structure when input is blank' do
    res = Recommender::ParetoRecommenderService.call(input: '')
    assert_empty res[:frontier]
    assert_equal 0, res[:total_evaluated]
  end

  test 'evaluates candidates and sorts them into Pareto frontier' do
    res = Recommender::ParetoRecommenderService.call(
      input: 'chemical compounds and molecular mechanisms',
      options: { evaluations_provider: @provider }
    )

    assert_equal 4, res[:total_evaluated]
    assert_equal 0, res[:license_gated_count]
    assert res[:frontier].any?, 'Frontier should not be empty'

    acronyms = res[:frontier].map(&:acronym)
    # PROPR has very high scores and should be on the frontier
    assert_includes acronyms, 'PROPR'
    # POOR is dominated by all others, should not be on the frontier
    refute_includes acronyms, 'POOR'
  end

  test 'applies SPDX license hard-gate when license_filter is permissive' do
    res = Recommender::ParetoRecommenderService.call(
      input: 'chemical compounds and molecular mechanisms',
      license_filter: 'permissive',
      options: { evaluations_provider: @provider }
    )

    assert_equal 4, res[:total_evaluated]
    assert_equal 1, res[:license_gated_count], 'PROPR should be gated out'

    all_acronyms = res[:all_evaluations].map(&:acronym)
    refute_includes all_acronyms, 'PROPR', 'Proprietary ontology should not appear in evaluations'

    frontier_acronyms = res[:frontier].map(&:acronym)
    assert_includes frontier_acronyms, 'CHEBI'
    assert_includes frontier_acronyms, 'GO'
  end

  test 'filters by ontologies whitelist' do
    res = Recommender::ParetoRecommenderService.call(
      input: 'compounds',
      ontologies: 'CHEBI,GO',
      options: { evaluations_provider: @provider }
    )

    assert_equal 2, res[:total_evaluated]
    evaluated_acronyms = res[:all_evaluations].map(&:acronym)
    assert_equal %w[CHEBI GO].sort, evaluated_acronyms.sort
  end

  test 'computes combinatorial sets when output_type is set' do
    res = Recommender::ParetoRecommenderService.call(
      input: 'compounds genes',
      license_filter: 'permissive',
      options: {
        evaluations_provider: @provider,
        output_type: 'set',
        max_elements_set: 2
      }
    )

    assert res[:sets].is_a?(Array)
    assert res[:sets].any?, 'Should return non-dominated sets'
    set = res[:sets].first
    assert set[:ontologies].is_a?(Array)
    assert set[:combined_coverage].positive?
  end

  test 'runs heuristic fallback when no provider is supplied' do
    res = Recommender::ParetoRecommenderService.call(
      input: 'benzene glucose metabolic pathway'
    )

    assert res[:total_evaluated].positive?
    assert res[:frontier].any?
  end
end
