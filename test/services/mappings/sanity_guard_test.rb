# frozen_string_literal: true

require 'minitest/autorun'
require_relative '../../../app/services/mappings/sanity_guard'

class SanityGuardTest < Minitest::Test
  def test_compatible_dimensions_and_ranks
    res = Mappings::SanityGuard.validate_mapping('temperature_sensor_reading', 'thermodynamic_temperature', relation: 'skos:exactMatch')
    assert res.valid?
    assert_empty res.violations
  end

  def test_si_dimension_mismatch_violation
    res = Mappings::SanityGuard.validate_mapping('thermodynamic_temperature', 'tensile_force', relation: 'skos:exactMatch')
    refute res.valid?
    assert res.violations.any? { |v| v.include?('SI physical dimension mismatch') }
  end

  def test_tensor_rank_mismatch_violation
    # Temperature (rank 0 scalar) vs Cauchy Stress (rank 2 tensor)
    res = Mappings::SanityGuard.validate_mapping('operating_temperature', 'stress_tensor', relation: 'skos:exactMatch')
    refute res.valid?
    assert res.violations.any? { |v| v.include?('Tensor rank mismatch') }
  end

  def test_4th_order_stiffness_tensor_mismatch
    # 2nd order stress tensor vs 4th order elasticity tensor
    res = Mappings::SanityGuard.validate_mapping('stress_tensor', 'elasticity_tensor', relation: 'skos:exactMatch')
    refute res.valid?
    assert res.violations.any? { |v| v.include?('Tensor rank mismatch') }
  end

  def test_disjoint_category_violation
    # Process vs Material Entity
    res = Mappings::SanityGuard.validate_mapping('annealing_process', 'steel_specimen', relation: 'skos:exactMatch')
    refute res.valid?
    assert res.violations.any? { |v| v.include?('Disjoint category violation') }
  end

  def test_relaxed_relation_generates_warnings_not_violations
    res = Mappings::SanityGuard.validate_mapping('temperature', 'force', relation: 'skos:relatedMatch')
    assert res.valid?
    refute_empty res.warnings
    assert res.warnings.any? { |w| w.include?('SI physical dimension mismatch') }
  end

  def test_batch_validation
    batch = [
      { subject_id: 'temperature', object_id: 'temp', predicate_id: 'skos:exactMatch' },
      { subject_id: 'temperature', object_id: 'force', predicate_id: 'skos:exactMatch' }
    ]

    results = Mappings::SanityGuard.validate_batch(batch)
    assert_equal 2, results.size
    assert results[0].valid?
    refute results[1].valid?
  end
end
