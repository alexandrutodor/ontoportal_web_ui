class SubscriptionsController < ApplicationController
  prepend_before_action :authorize_session_user, only: :create

  def create
    # Canonical actual lookup bound to authenticated identity, not incoming id
    canonical_user_id = session[:user].id.to_s
    canonical_user_id = session[:user].username.to_s if canonical_user_id.blank?
    u = LinkedData::Client::Models::User.get(helpers.escape(canonical_user_id), include: 'all')
    raise Exception if u.nil?

    # Try to get the ontology linked data instance
    ontology_id = params[:ontology_id]
    if ontology_id.to_s.start_with? 'http'
      ont = LinkedData::Client::Models::Ontology.find(ontology_id)
    else
      ont = LinkedData::Client::Models::Ontology.find_by_acronym(ontology_id)&.first
    end
    raise Exception if ont.nil?

    # Is this request to add or remove a subscription?
    subscribed = params[:subbed]  # string (not boolean)
    if subscribed.eql?("true")
      # Already subscribed, so this request must be a delete
      # Note that this routine removes ALL subscriptions for the ontology, regardless of type.
      all_subs = []
      (u.subscription || []).each do |subs|
        ont_val = subs.respond_to?(:ontology) ? subs.ontology : subs[:ontology]
        type_val = subs.respond_to?(:notification_type) ? subs.notification_type : subs[:notification_type]
        next if ont_val.nil?

        # Add all subscription to the array, but not the one to be deleted
        if !ont_val.to_s.split('/').last.eql?(ont.acronym)
          all_subs.push({ontology: ont_val, notification_type: type_val})
        end
      end
      u.subscription = all_subs
    else
      # Not subscribed yet, so this request must be for adding subscription
      already_subscribed = false
      all_subs = []
      (u.subscription || []).each do |subs|
        ont_val = subs.respond_to?(:ontology) ? subs.ontology : subs[:ontology]
        type_val = subs.respond_to?(:notification_type) ? subs.notification_type : subs[:notification_type]
        next if ont_val.nil?

        # add all existing subscriptions
        all_subs.push({ontology: ont_val, notification_type: type_val})
        if ont_val.to_s.split("/").last == ont.acronym && type_val == "NOTES"
          # avoid to subscribe many times to the same ontology
          already_subscribed = true
        end
      end
      if already_subscribed == false
        all_subs.push({ontology: ont.acronym, notification_type: "NOTES"})  # the new subscription
      end
      u.subscription = all_subs
    end

    # Try to update the user instance and the session user.
    begin
      error_response = u.update
    rescue StandardError => e
      error_response = OpenStruct.new(status: 500, errors: [e.message])
    end

    if error_response != false && !response_error?(error_response) && response_success?(error_response)
      updated_sub = true
      session[:user].subscription = u.subscription
    else
      updated_sub = false
    end

    render :json => { :updated_sub => updated_sub, :user_subscriptions => u.subscription }
  end

  private

  def authorize_session_user
    unless session[:user]
      render status: :unauthorized, json: { updated_sub: false, error: 'Authentication required' }
      return
    end

    incoming_id = params[:user_id]
    if incoming_id.present? && !user_matches_target?(session[:user], incoming_id)
      render status: :forbidden, json: { updated_sub: false, error: 'Unauthorized target user' }
      return
    end
  end

  def user_matches_target?(user, target)
    return false if user.nil? || target.nil?

    target_str = target.to_s.strip
    return false if target_str.empty?

    unescaped_target = CGI.unescape(target_str) rescue target_str
    user_id_str = user.id.to_s.strip
    user_uname_str = user.username.to_s.strip

    return true if user_id_str == target_str || user_uname_str == target_str
    return true if user_id_str == unescaped_target || user_uname_str == unescaped_target

    user_id_last = user_id_str.split('/').last
    target_last = unescaped_target.split('/').last

    return true if user_id_last.present? && user_id_last == target_last
    return true if user_uname_str.present? && user_uname_str == target_last
    return true if user_id_last.present? && user_id_last == target_str

    false
  end
end
