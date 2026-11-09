# frozen_string_literal: true

# ONTO-T-U08: curation contributions are counted as curation, not endorsement.
require 'minitest/autorun'
require 'ostruct'
require_relative '../../app/components/agent_statistics_calculator_component'

class AgentStatisticsCheck < Minitest::Test
  CURATED = 'http://purl.org/pav/curatedBy'
  ENDORSED = 'http://omv.ontoware.org/2005/05/ontology#endorsedBy'
  CREATOR = 'http://omv.ontoware.org/2005/05/ontology#hasCreator'
  PUBLISHER = 'http://purl.org/dc/terms/publisher'

  def stats_for(usages)
    AgentStatisticsCalculatorComponent.new(OpenStruct.new(usages: OpenStruct.new(usages))).stats
  end

  def test_curation_only_counts_as_curation
    s = stats_for('/ontologies/A/submissions/1' => [CURATED], '/ontologies/B/submissions/2' => [CURATED])
    assert_equal 2, s[:curated_by_count]
    assert_equal 0, s[:endorsed_by_count]
    assert_equal 2, s[:total]
  end

  def test_endorsement_only_counts_as_endorsement
    s = stats_for('/ontologies/A/submissions/1' => [ENDORSED])
    assert_equal 1, s[:endorsed_by_count]
    assert_equal 0, s[:curated_by_count]
    assert_equal 1, s[:total]
  end

  def test_mixed_roles_have_exact_per_role_counts_and_total
    s = stats_for('/ontologies/A/submissions/1' => [CURATED, ENDORSED, CREATOR],
                  '/ontologies/B/submissions/2' => [PUBLISHER, CURATED])
    assert_equal 2, s[:curated_by_count]
    assert_equal 1, s[:endorsed_by_count]
    assert_equal 1, s[:creator_count]
    assert_equal 1, s[:publisher_count]
    assert_equal 5, s[:total]
  end

  def test_missing_usages_yield_zero_total
    s = AgentStatisticsCalculatorComponent.new(OpenStruct.new(usages: nil)).stats
    assert_equal 0, s[:total]
  end
end
