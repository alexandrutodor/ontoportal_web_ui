# frozen_string_literal: true

require 'securerandom'
require 'json'
require 'time'

class BlastRadiusReport
  VERDICT_SAFE              = 'SAFE'
  VERDICT_SAFE_WITH_REVIEW  = 'SAFE_WITH_REVIEW'
  VERDICT_BREAKING          = 'BREAKING'
  VERDICT_POLICY_BLOCKED    = 'POLICY_BLOCKED'
  VERDICT_LOGICALLY_INVALID = 'LOGICALLY_INVALID'

  VALID_VERDICTS = [
    VERDICT_SAFE,
    VERDICT_SAFE_WITH_REVIEW,
    VERDICT_BREAKING,
    VERDICT_POLICY_BLOCKED,
    VERDICT_LOGICALLY_INVALID
  ].freeze

  attr_accessor :id,
                :ontology_acronym,
                :baseline_submission_id,
                :candidate_submission_id,
                :verdict,
                :concept_churn,
                :orphaned_mappings,
                :broken_queries,
                :shacl_violation_delta,
                :policy_violations,
                :logical_errors,
                :rules_triggered,
                :metadata,
                :created_at

  def initialize(attributes = {})
    @id                      = attributes[:id] || attributes['id'] || SecureRandom.uuid
    @ontology_acronym        = attributes[:ontology_acronym] || attributes['ontology_acronym'] || ''
    @baseline_submission_id  = attributes[:baseline_submission_id] || attributes['baseline_submission_id']
    @candidate_submission_id = attributes[:candidate_submission_id] || attributes['candidate_submission_id']
    @verdict                 = attributes[:verdict] || attributes['verdict']
    @concept_churn           = normalize_churn(attributes[:concept_churn] || attributes['concept_churn'])
    @orphaned_mappings       = Array(attributes[:orphaned_mappings] || attributes['orphaned_mappings'])
    @broken_queries          = Array(attributes[:broken_queries] || attributes['broken_queries'])
    @shacl_violation_delta   = normalize_shacl_delta(attributes[:shacl_violation_delta] || attributes['shacl_violation_delta'])
    @policy_violations       = Array(attributes[:policy_violations] || attributes['policy_violations'])
    @logical_errors          = Array(attributes[:logical_errors] || attributes['logical_errors'])
    @rules_triggered         = Array(attributes[:rules_triggered] || attributes['rules_triggered'])
    @metadata                = attributes[:metadata] || attributes['metadata'] || {}
    @created_at              = attributes[:created_at] || attributes['created_at'] || Time.now.utc.iso8601

    compute_verdict! if @verdict.nil?
  end

  def compute_verdict!
    @rules_triggered = []

    # 1. LOGICALLY_INVALID check (syntax parse error, cycles, unsatisfiable classes)
    if @logical_errors.any?
      @verdict = VERDICT_LOGICALLY_INVALID
      @rules_triggered << "Detected #{@logical_errors.size} logical consistency / OWL satisfiability violation(s)."
      return @verdict
    end

    # 2. POLICY_BLOCKED check (licensing, base URI deviations, mandatory metadata)
    if @policy_violations.any?
      @verdict = VERDICT_POLICY_BLOCKED
      @rules_triggered << "Detected #{@policy_violations.size} governance / policy constraint violation(s)."
      return @verdict
    end

    # 3. BREAKING check (broken queries, orphaned external mappings, removed active classes)
    has_broken_queries = @broken_queries.any?
    has_orphaned_mappings = @orphaned_mappings.any?
    has_removed_classes = @concept_churn[:removed]&.any?

    if has_broken_queries || has_orphaned_mappings || has_removed_classes
      @verdict = VERDICT_BREAKING
      @rules_triggered << "Replayed queries failed with regressions (#{@broken_queries.size} broken)." if has_broken_queries
      @rules_triggered << "Active external mappings orphaned by missing concepts (#{@orphaned_mappings.size} orphaned)." if has_orphaned_mappings
      @rules_triggered << "Previously active concepts removed from ontology (#{@concept_churn[:removed].size} removed)." if has_removed_classes
      return @verdict
    end

    # 4. SAFE_WITH_REVIEW check (concept modifications, SHACL regressions, score drift)
    has_modified_classes = @concept_churn[:modified]&.any?
    has_obsoleted_classes = @concept_churn[:obsoleted]&.any?
    shacl_delta = @shacl_violation_delta[:delta].to_i
    has_shacl_regressions = shacl_delta.positive?

    if has_modified_classes || has_obsoleted_classes || has_shacl_regressions
      @verdict = VERDICT_SAFE_WITH_REVIEW
      @rules_triggered << "Concepts modified or labels changed (#{@concept_churn[:modified]&.size.to_i} modified)." if has_modified_classes
      @rules_triggered << "Concepts obsoleted/deprecated (#{@concept_churn[:obsoleted]&.size.to_i} obsoleted)." if has_obsoleted_classes
      @rules_triggered << "New SHACL constraint violations introduced (+#{shacl_delta} delta)." if has_shacl_regressions
      return @verdict
    end

    # 5. SAFE (purely additive or idempotent updates)
    @verdict = VERDICT_SAFE
    added_count = @concept_churn[:added]&.size.to_i
    if added_count.positive?
      @rules_triggered << "Purely additive update with #{added_count} new concept(s) and zero breaking regressions."
    else
      @rules_triggered << "Idempotent update with 0 breaking changes, 0 orphaned mappings, and 0 SHACL regressions."
    end
    @verdict
  end

  def safe?
    @verdict == VERDICT_SAFE
  end

  def safe_with_review?
    @verdict == VERDICT_SAFE_WITH_REVIEW
  end

  def breaking?
    @verdict == VERDICT_BREAKING
  end

  def policy_blocked?
    @verdict == VERDICT_POLICY_BLOCKED
  end

  def logically_invalid?
    @verdict == VERDICT_LOGICALLY_INVALID
  end

  def badge_css_class
    case @verdict
    when VERDICT_SAFE
      'badge-verdict-safe'
    when VERDICT_SAFE_WITH_REVIEW
      'badge-verdict-review'
    when VERDICT_BREAKING
      'badge-verdict-breaking'
    when VERDICT_POLICY_BLOCKED
      'badge-verdict-blocked'
    when VERDICT_LOGICALLY_INVALID
      'badge-verdict-invalid'
    else
      'badge-verdict-neutral'
    end
  end

  def to_h
    {
      'id'                      => @id,
      'ontology_acronym'        => @ontology_acronym,
      'baseline_submission_id'  => @baseline_submission_id,
      'candidate_submission_id' => @candidate_submission_id,
      'verdict'                 => @verdict,
      'concept_churn'           => {
        'added'     => @concept_churn[:added],
        'removed'   => @concept_churn[:removed],
        'obsoleted' => @concept_churn[:obsoleted],
        'modified'  => @concept_churn[:modified]
      },
      'orphaned_mappings'       => @orphaned_mappings,
      'broken_queries'          => @broken_queries,
      'shacl_violation_delta'   => {
        'baseline_violations'  => @shacl_violation_delta[:baseline_violations],
        'candidate_violations' => @shacl_violation_delta[:candidate_violations],
        'delta'                => @shacl_violation_delta[:delta],
        'new_violations'       => @shacl_violation_delta[:new_violations]
      },
      'policy_violations'       => @policy_violations,
      'logical_errors'          => @logical_errors,
      'rules_triggered'         => @rules_triggered,
      'metadata'                => @metadata,
      'created_at'              => @created_at
    }
  end

  def to_json(*args)
    to_h.to_json(*args)
  end

  def self.from_h(hash)
    hash = hash.transform_keys(&:to_s)
    new(
      id: hash['id'],
      ontology_acronym: hash['ontology_acronym'],
      baseline_submission_id: hash['baseline_submission_id'],
      candidate_submission_id: hash['candidate_submission_id'],
      verdict: hash['verdict'],
      concept_churn: hash['concept_churn'],
      orphaned_mappings: hash['orphaned_mappings'],
      broken_queries: hash['broken_queries'],
      shacl_violation_delta: hash['shacl_violation_delta'],
      policy_violations: hash['policy_violations'],
      logical_errors: hash['logical_errors'],
      rules_triggered: hash['rules_triggered'],
      metadata: hash['metadata'],
      created_at: hash['created_at']
    )
  end

  def self.from_json(json_str)
    from_h(JSON.parse(json_str))
  end

  private

  def normalize_churn(raw)
    raw = {} unless raw.is_a?(Hash)
    {
      added: Array(raw[:added] || raw['added']),
      removed: Array(raw[:removed] || raw['removed']),
      obsoleted: Array(raw[:obsoleted] || raw['obsoleted']),
      modified: Array(raw[:modified] || raw['modified'])
    }
  end

  def normalize_shacl_delta(raw)
    raw = {} unless raw.is_a?(Hash)
    b = (raw[:baseline_violations] || raw['baseline_violations'] || 0).to_i
    c = (raw[:candidate_violations] || raw['candidate_violations'] || 0).to_i
    d = raw.key?(:delta) ? raw[:delta].to_i : (raw.key?('delta') ? raw['delta'].to_i : (c - b))
    {
      baseline_violations: b,
      candidate_violations: c,
      delta: d,
      new_violations: Array(raw[:new_violations] || raw['new_violations'])
    }
  end
end
