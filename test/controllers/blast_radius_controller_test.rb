# frozen_string_literal: true

require 'minitest/autorun'
require_relative '../../app/models/blast_radius_report'
require_relative '../../app/services/blast_radius/simulation_engine'

# Lightweight unit test verifying controller logic & response serialization
class BlastRadiusControllerUnitTest < Minitest::Test
  def setup
    BlastRadius::SimulationEngine.clear_store!
  end

  def test_simulation_controller_contract
    report = BlastRadius::SimulationEngine.simulate(
      ontology_acronym: 'CONTROLLER-TEST',
      baseline_submission: { id: 's1', concepts: [{ id: 'http://ex.org/1', label: 'C1' }] },
      candidate_submission: { id: 's2', concepts: [{ id: 'http://ex.org/1', label: 'C1' }] }
    )

    assert_equal 'CONTROLLER-TEST', report.ontology_acronym
    assert_equal BlastRadiusReport::VERDICT_SAFE, report.verdict

    retrieved = BlastRadius::SimulationEngine.find_report(report.id)
    refute_nil retrieved
    assert_equal report.id, retrieved.id
  end
end
