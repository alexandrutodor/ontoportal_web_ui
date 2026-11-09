# frozen_string_literal: true

require 'digest'
require 'json'

class BulkMetadataPreview
  include SubmissionUpdater

  PURPOSE = :bulk_metadata_preview
  EXPIRY = 900

  class InvalidContextError < StandardError; end

  attr_reader :submission_metadata

  def initialize(submission_metadata: [])
    @submission_metadata = submission_metadata || []
  end

  # Generates preview diffs per target and property without performing any update calls.
  # Reuses the B05 conversion boundary (deep-dup per target, convert_values_to_types).
  def generate_preview(selected_ontologies:, active_submission_data:, selected_metadata:, current_submissions:, user:, session_id:, all_metadata: nil, active_ontology_label: nil)
    raw_data = active_submission_data ? (active_submission_data.respond_to?(:to_unsafe_h) ? active_submission_data.to_unsafe_h : active_submission_data.to_h) : {}
    targets_preview = []
    displayed_old_values = {}

    selected_ontologies.each do |onto, sub_i|
      target_id = "#{onto}##{sub_i}"
      curr_sub = current_submissions[target_id]

      # update_submission converts and deletes keys in place; each target needs its own copy.
      target_data = raw_data.deep_dup.with_indifferent_access
      target_data[:ontology] = onto
      target_data[:id] = sub_i

      convert_values_to_types(target_data)

      property_diffs = {}
      target_old_values = {}

      selected_metadata.each do |attr|
        was_provided = raw_data.key?(attr.to_s) || raw_data.key?(attr.to_sym)
        current_val = self.class.extract_attribute_value(curr_sub, attr)
        proposed_val = target_data.key?(attr.to_sym) ? target_data[attr.to_sym] : target_data[attr.to_s]

        diff = self.class.determine_diff(current_val, proposed_val, was_provided)
        property_diffs[attr] = diff
        target_old_values[attr] = current_val
      end

      displayed_old_values[target_id] = target_old_values
      targets_preview << {
        target_id: target_id,
        ontology: onto,
        submission_id: sub_i,
        properties: property_diffs
      }
    end

    target_ids = selected_ontologies.map { |o, s| "#{o}##{s}" }
    values_digest = self.class.digest_values(raw_data)

    token = generate_context_token(
      user: user,
      session_id: session_id,
      target_ids: target_ids,
      values_digest: values_digest,
      displayed_old_values: displayed_old_values,
      selected_metadata: selected_metadata,
      all_metadata: all_metadata,
      active_ontology: active_ontology_label,
      raw_submission_data: raw_data
    )

    {
      targets: targets_preview,
      selected_metadata: selected_metadata,
      all_metadata: all_metadata,
      active_ontology: active_ontology_label,
      preview_token: token,
      raw_submission_data: raw_data
    }
  end

  def generate_context_token(user:, session_id:, target_ids:, values_digest:, displayed_old_values:, selected_metadata:, all_metadata:, active_ontology:, raw_submission_data:)
    user_id = self.class.user_id_for(user)
    session_id_str = self.class.session_id_for(session_id)

    payload = {
      user_id: user_id,
      session_id: session_id_str,
      target_ids: target_ids,
      values_digest: values_digest,
      displayed_old_values: displayed_old_values,
      selected_metadata: selected_metadata,
      all_metadata: all_metadata,
      active_ontology: active_ontology,
      raw_submission_data: raw_submission_data
    }

    message_verifier.generate(payload, purpose: PURPOSE, expires_in: EXPIRY)
  end

  def verify_context(token, user:, session_id:, proposed_values: nil)
    raise InvalidContextError, 'Missing preview token' if token.blank?

    verifier = message_verifier
    payload = verifier.verify(token, purpose: PURPOSE)
    raise InvalidContextError, 'Invalid preview payload' unless payload.is_a?(Hash)

    expected_user = self.class.user_id_for(user)
    if payload[:user_id] != expected_user
      raise InvalidContextError, 'Authenticated user does not match preview context'
    end

    expected_session = self.class.session_id_for(session_id)
    if payload[:session_id] != expected_session
      raise InvalidContextError, 'Session mismatch for preview context'
    end

    if proposed_values
      submitted_digest = self.class.digest_values(proposed_values)
      if payload[:values_digest] != submitted_digest
        raise InvalidContextError, 'Proposed values tampered since preview'
      end
    end

    payload
  rescue ActiveSupport::MessageVerifier::InvalidSignature => e
    raise InvalidContextError, "Signature verification failed: #{e.message}"
  end

  def message_verifier
    if Rails.application.respond_to?(:message_verifier) && Rails.application.message_verifier(PURPOSE)
      Rails.application.message_verifier(PURPOSE)
    else
      secret = Rails.application&.secret_key_base || 'bulk_metadata_preview_secret_key_base_fallback'
      ActiveSupport::MessageVerifier.new(secret, digest: 'SHA256')
    end
  end

  # ===========================================================================
  # Class Comparison and Normalization Helpers
  # ===========================================================================

  def self.determine_diff(current_val, proposed_val, was_provided)
    unless was_provided
      return {
        current: current_val,
        proposed: nil,
        status: :omitted
      }
    end

    curr_empty = value_empty?(current_val)
    prop_empty = value_empty?(proposed_val)

    status = if curr_empty && prop_empty
      :unchanged
    elsif curr_empty && !prop_empty
      :added
    elsif !curr_empty && prop_empty
      :cleared
    elsif values_equal?(current_val, proposed_val)
      :unchanged
    else
      :replaced
    end

    {
      current: current_val,
      proposed: proposed_val,
      status: status
    }
  end

  def self.extract_attribute_value(submission, attr)
    return nil if submission.nil?
    if submission.respond_to?(attr.to_sym)
      submission.public_send(attr.to_sym)
    elsif submission.respond_to?(:[])
      submission[attr.to_s] || submission[attr.to_sym]
    else
      nil
    end
  end

  def self.value_empty?(val)
    return true if val.nil?
    return false if val == false || val == true
    return true if val.is_a?(String) && val.strip.empty?
    return true if val.respond_to?(:empty?) && val.empty?
    false
  end

  def self.values_equal?(a, b)
    if value_empty?(a) && value_empty?(b)
      true
    elsif a.is_a?(Array) && b.is_a?(Array)
      a.map(&:to_s) == b.map(&:to_s)
    elsif a.is_a?(Hash) && b.is_a?(Hash)
      a.transform_keys(&:to_s) == b.transform_keys(&:to_s)
    elsif (a == true || a == false) || (b == true || b == false)
      a == b
    else
      a.to_s == b.to_s
    end
  end

  def self.digest_values(values)
    Digest::SHA256.hexdigest(canonical_json(values))
  end

  def self.canonical_json(obj)
    case obj
    when Hash, ActionController::Parameters
      h = obj.respond_to?(:to_unsafe_h) ? obj.to_unsafe_h : obj.to_h
      sorted_keys = h.keys.map(&:to_s).sort
      "{" + sorted_keys.map { |k|
        val = h.key?(k) ? h[k] : h[k.to_sym]
        "#{k.to_json}:#{canonical_json(val)}"
      }.join(",") + "}"
    when Array
      "[" + obj.map { |el| canonical_json(el) }.join(",") + "]"
    else
      obj.to_json
    end
  end

  def self.user_id_for(user)
    return nil if user.nil?
    if user.respond_to?(:id) && user.id.present?
      user.id.to_s
    elsif user.respond_to?(:username) && user.username.present?
      user.username.to_s
    elsif user.is_a?(Hash)
      (user[:id] || user['id'] || user[:username] || user['username']).to_s
    else
      user.to_s
    end
  end

  def self.session_id_for(session)
    return '' if session.nil?
    return session if session.is_a?(String)
    if session.respond_to?(:id) && session.id.present?
      session.id.to_s
    elsif session.is_a?(Hash) || session.respond_to?(:has_key?)
      (session[:session_id] || session['session_id'] || session[:_csrf_token] || session['_csrf_token']).to_s
    else
      session.to_s
    end
  end
end
