# frozen_string_literal: true

# ONTO-T-B05: SubmissionUpdater#convert_values_to_types must be idempotent, so a value that
# was already converted for one bulk target is not changed again.
require 'minitest/autorun'
require 'active_support/all'
require 'action_controller'
require_relative '../../app/controllers/concerns/submission_updater'

class SubmissionValueConversionCheck < Minitest::Test
  class Host
    include SubmissionUpdater
    def submission_metadata
      [{ 'attribute' => 'flag', 'enforce' => ['boolean'] }, { 'attribute' => 'count', 'enforce' => ['integer'] }]
    end
  end

  def convert(values)
    h = ActionController::Parameters.new(values)
    Host.new.send(:convert_values_to_types, h)
    h
  end

  def test_booleans_convert_and_are_idempotent
    assert_equal true, convert(flag: 'true')[:flag]
    assert_equal true, convert(flag: true)[:flag]
    assert_equal false, convert(flag: 'false')[:flag]
    assert_equal false, convert(flag: false)[:flag]
    assert_equal true, convert(convert(flag: 'true').to_unsafe_h)[:flag], 'second conversion keeps true'
  end

  def test_unset_switch_placeholder_stays_nil_as_before
    assert_nil convert(flag: 'submission[flag]')[:flag]
  end

  def test_integers_convert_idempotently_and_keep_invalid_input
    assert_equal 5, convert(count: '5')[:count]
    assert_equal 5, convert(count: 5)[:count]
    assert_equal 'abc', convert(count: 'abc')[:count], 'invalid integer is kept for API validation instead of raising'
    assert_equal '', convert(count: '')[:count]
  end

  def test_contacts_conversion_is_idempotent
    once = convert(contact: { '0' => { name: 'A', email: 'a@x' }, '1' => { name: '', email: '' } })[:contact]
    assert_equal 1, once.length
    twice = convert(contact: once)[:contact]
    assert_equal 1, twice.length
    assert_equal 'A', twice.first[:name]
  end
end
