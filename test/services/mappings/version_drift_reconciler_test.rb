# frozen_string_literal: true

require 'minitest/autorun'
require_relative '../../../app/services/mappings/version_drift_reconciler'

class VersionDriftReconcilerTest < Minitest::Test
  def test_reconcile_stable_mappings
    mappings = [
      { subject_id: 'http://example.org/A', object_id: 'http://example.org/B' }
    ]
    classes = {
      'http://example.org/A' => { obsolete: false, label: 'Concept A' },
      'http://example.org/B' => { obsolete: false, label: 'Concept B' }
    }

    report = Mappings::VersionDriftReconciler.reconcile(mappings, ontology_classes: classes)

    assert_equal 1, report.summary[:total_mappings]
    assert_equal 1, report.summary[:stable_count]
    assert_equal 0, report.summary[:repairable_count]
    assert_equal 0, report.summary[:obsolete_orphan_count]
    assert_empty report.repaired_mappings
  end

  def test_reconcile_repairable_drift
    mappings = [
      { subject_id: 'http://example.org/OldA', object_id: 'http://example.org/B' }
    ]
    classes = {
      'http://example.org/OldA' => {
        obsolete: true,
        replaced_by: 'http://example.org/NewA',
        label: 'Old Concept A'
      },
      'http://example.org/B' => { obsolete: false, label: 'Concept B' }
    }

    report = Mappings::VersionDriftReconciler.reconcile(mappings, ontology_classes: classes)

    assert_equal 1, report.summary[:repairable_count]
    assert_equal 0, report.summary[:stable_count]
    repaired = report.repaired_mappings.first
    assert_equal 'http://example.org/NewA', repaired.subject_id
    assert_equal 'http://example.org/OldA', repaired.original_subject
    assert report.notifications.any? { |n| n.include?('can be automatically re-anchored') }
  end

  def test_reconcile_obsolete_orphan
    mappings = [
      { subject_id: 'http://example.org/A', object_id: 'http://example.org/DeadEnd' }
    ]
    classes = {
      'http://example.org/A' => { obsolete: false, label: 'Concept A' },
      'http://example.org/DeadEnd' => { obsolete: true, replaced_by: nil, label: 'Dead End' }
    }

    report = Mappings::VersionDriftReconciler.reconcile(mappings, ontology_classes: classes)

    assert_equal 1, report.summary[:obsolete_orphan_count]
    assert_equal 0, report.summary[:repairable_count]
    assert report.notifications.any? { |n| n.include?('reference obsoleted concepts') }
  end

  def test_reconcile_missing_entity
    mappings = [
      { subject_id: 'http://example.org/A', object_id: 'http://example.org/Unknown' }
    ]
    classes = {
      'http://example.org/A' => { obsolete: false, label: 'Concept A' }
    }

    report = Mappings::VersionDriftReconciler.reconcile(mappings, ontology_classes: classes)

    assert_equal 1, report.summary[:missing_count]
    assert_equal 'http://example.org/Unknown', report.missing_mappings.first.object_id
  end
end
