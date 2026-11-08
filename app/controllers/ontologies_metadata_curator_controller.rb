class OntologiesMetadataCuratorController < ApplicationController
  include TurboHelper, SubmissionsHelper, ActionView::Helpers::FormHelper
  include SubmissionUpdater
  layout :determine_layout
  prepend_before_action :authorize_admin, only: [:result, :edit, :update, :preview, :confirm]
  before_action :ensure_bulk_metadata_preview_enabled, only: [:preview, :confirm]
  before_action :submission_metadata, only: [:result, :edit, :update, :show_metadata_by_ontology, :preview, :confirm]

  def result
    start_time = Time.now
    @ontologies_ids = params[:ontology] ? Array(params[:ontology][:ontologyId]) : []
    @metadata_sel = params[:search] ? params[:search][:metadata] : []
    @submissions = []
    @ontologies = []
    select_all_ontologies = @ontologies_ids.empty?
    show_all_submissions = !params[:show_submissions].nil?
    return if @metadata_sel.empty?
    return if select_all_ontologies && show_all_submissions # To not overwhelm our server for getting all submissions of all ontologies

    ontology_display_attribute = equivalent_ontology_properties(@metadata_sel) + %w[acronym]

    if select_all_ontologies
      @ontologies = LinkedData::Client::Models::Ontology.all(display_links: false, display_context: false, include: ontology_display_attribute.join(','))
      @ontologies_ids = @ontologies.map(&:acronym)
    elsif !@ontologies_ids.nil? || !@ontologies_ids.empty?
      @ontologies_ids.each do |data|
        @ontologies << LinkedData::Client::Models::Ontology.find_by_acronym(data, {include: ontology_display_attribute.join(',')}).first
      end
    end

    return if @ontologies.empty?
    
    submission_display_attribute = equivalent_properties(@metadata_sel) + %w[submissionId]
    @hash = build_hash_submissions(show_all_submissions: show_all_submissions, display_attribute: submission_display_attribute)
    
    Rails.logger.info "Getting ontologies submission took: #{Time.now - start_time} seconds"

    respond_to do |format|
      format.html { redirect_to admin_index_path }
      format.turbo_stream { render turbo_stream: [
          replace("selection_metadata_form", partial: "ontologies_metadata_curator/metadata_table")
        ]
      }
    end
  end

  def show_metadata_by_ontology
    @acronym = params[:ontology]
    inline_save = params[:inline_save] && params[:inline_save].eql?('true')
    display_submission_attributes(@acronym, params[:properties]&.split(','),
                                  submissionId: params[:submission_id], inline_save: inline_save)
    render partial: 'submissions/form_content', locals: { id: params[:form_id] || '', acronym: @acronym, submissionId: params[:submission_id] }
  end

  def show_metadata_value
    acronym = params[:ontology]
    attribute = params[:attribute]
    submission_id = params[:submission_id]
    @ontology = LinkedData::Client::Models::Ontology.find_by_acronym(acronym).first
    @submission = @ontology.explore.submissions({ display: "#{attribute},submissionId" }, submission_id)
    id = attribute_input_frame_id(acronym, submission_id, attribute)
    render_turbo_stream replace(id, partial: 'ontologies_metadata_curator/attribute', locals: { id: id, attribute: attribute, submission: @submission, ontology: @ontology })
  end

  def edit

    if params[:selected_acronyms].nil? || params[:selected_metadata].nil?
      render_turbo_stream alert_error(id: 'application_modal_content') { t('ontologies_metadata_curator.start_the_bulk_edit') }
      return
    end

    @selected_ontologies = params[:selected_acronyms].map { |x| ontology_and_submission_id(x) }
    @selected_metadata = params[:selected_metadata]
    @all_metadata = params[:all_metadata]
    render partial: 'ontologies_metadata_curator/form_edit'
  end

  def preview
    if params[:selected_ontologies].nil? || params[:active_ontology].nil?
      respond_to do |format|
        format.html { render plain: t('ontologies_metadata_curator.start_the_bulk_edit'), status: :unprocessable_entity }
        format.turbo_stream { render_turbo_stream alert_error(id: 'application_modal_content') { t('ontologies_metadata_curator.start_the_bulk_edit') } }
      end
      return
    end

    @selected_ontologies = params[:selected_ontologies].map { |x| ontology_and_submission_id(x) }
    @active_ontology = ontology_and_submission_id(params[:active_ontology])
    @selected_metadata = params[:selected_metadata] || (params[:all_metadata].is_a?(Array) ? params[:all_metadata] : params[:all_metadata]&.split) || []
    @all_metadata = params[:all_metadata]

    active_sub_key = "#{@active_ontology[0]}_#{@active_ontology[1]}"
    active_submission_data = params['submission'] ? params['submission'][active_sub_key] : nil

    if params[:retry_targets].present?
      # Only known failures from this session's receipt can be retried; no receipt means nothing to retry.
      allowed_retry = Array(session[:bulk_metadata_review_receipt])
                        .select { |r| (r[:status] || r['status'])&.to_sym == :rejected }
                        .map { |r| (r[:target] || r['target']).to_s }
      retry_targets = Array(params[:retry_targets]) & allowed_retry
      @selected_ontologies.select! { |onto, sub_i| retry_targets.include?("#{onto}##{sub_i}") }
    end

    if @selected_ontologies.empty?
      respond_to do |format|
        format.html { render plain: t('ontologies_metadata_curator.no_targets_selected'), status: :unprocessable_entity }
        format.turbo_stream { render_turbo_stream alert_error(id: 'application_modal_content') { t('ontologies_metadata_curator.no_targets_selected') } }
      end
      return
    end

    current_submissions = {}
    @selected_ontologies.each do |onto, sub_i|
      target_id = "#{onto}##{sub_i}"
      ontology = LinkedData::Client::Models::Ontology.find_by_acronym(onto)&.first
      current_submissions[target_id] = ontology&.explore&.submissions({ include: 'all' }, sub_i)
    end

    preview_service = BulkMetadataPreview.new(submission_metadata: submission_metadata)
    @preview_result = preview_service.generate_preview(
      selected_ontologies: @selected_ontologies,
      active_submission_data: active_submission_data,
      selected_metadata: @selected_metadata,
      current_submissions: current_submissions,
      user: current_curator_user,
      session_id: current_session_identifier,
      all_metadata: @all_metadata,
      active_ontology_label: params[:active_ontology]
    )

    respond_to do |format|
      format.html { render partial: 'ontologies_metadata_curator/preview', locals: { preview: @preview_result } }
      format.turbo_stream do
        render_turbo_stream replace('application_modal_content', partial: 'ontologies_metadata_curator/preview', locals: { preview: @preview_result })
      end
    end
  end

  def confirm
    token = params[:preview_token]
    preview_service = BulkMetadataPreview.new(submission_metadata: submission_metadata)

    active_ontology_key = params[:active_ontology] ? params[:active_ontology].tr('#', '_') : nil
    submitted_values = params['submission'] ? (params['submission'][active_ontology_key] || params['submission'][params[:active_ontology]]) : nil

    begin
      context = preview_service.verify_context(
        token,
        user: current_curator_user,
        session_id: current_session_identifier,
        proposed_values: submitted_values
      )
    rescue BulkMetadataPreview::InvalidContextError => e
      err = t('ontologies_metadata_curator.invalid_or_expired_preview')
      respond_to do |format|
        format.html { render plain: err, status: :unprocessable_entity }
        format.turbo_stream { render_turbo_stream alert_error(id: 'application_modal_content') { err } }
      end
      return
    end

    confirmed_targets = params[:confirmed_targets] ? Array(params[:confirmed_targets]) : []
    targets_to_apply = context[:target_ids] & confirmed_targets

    if targets_to_apply.empty?
      err = t('ontologies_metadata_curator.no_targets_selected')
      respond_to do |format|
        format.html { render plain: err, status: :unprocessable_entity }
        format.turbo_stream { render_turbo_stream alert_error(id: 'application_modal_content') { err } }
      end
      return
    end

    stale_target = nil
    targets_to_apply.each do |target_id|
      onto, sub_i = ontology_and_submission_id(target_id)
      ontology = LinkedData::Client::Models::Ontology.find_by_acronym(onto)&.first
      curr_sub = ontology&.explore&.submissions({ include: 'all' }, sub_i)
      old_values = (context[:displayed_old_values] || {})[target_id] || {}

      old_values.each do |attr, expected_val|
        current_val = BulkMetadataPreview.extract_attribute_value(curr_sub, attr)
        unless BulkMetadataPreview.values_equal?(current_val, expected_val)
          stale_target = target_id
          break
        end
      end
      break if stale_target
    end

    if stale_target
      err = t('ontologies_metadata_curator.stale_preview_detected', target: stale_target)
      respond_to do |format|
        format.html { render plain: err, status: :conflict }
        format.turbo_stream { render_turbo_stream alert_error(id: 'application_modal_content') { err } }
      end
      return
    end

    receipt = []
    @submissions = []
    failures = []
    active_submission_data = context[:raw_submission_data]

    targets_to_apply.each do |target_id|
      onto, sub_i = ontology_and_submission_id(target_id)
      new_data = active_submission_data ? active_submission_data.deep_dup.with_indifferent_access : {}
      new_data[:ontology] = onto
      new_data[:id] = sub_i

      begin
        response = update_submission(new_data, sub_i).last
        if response && response.status == 204
          @submissions << @submission
          receipt << {
            target: target_id,
            ontology: onto,
            submission_id: sub_i,
            fields: context[:selected_metadata],
            status: :success,
            message: t('ontologies_metadata_curator.receipt_success')
          }
        elsif response && response.status != 204
          # A received non-204 is a known rejection, even if its error body cannot be parsed.
          err_msg = (bulk_update_error_message(response) rescue nil).presence || "HTTP #{response.status}"
          failures << "#{onto}: #{err_msg}"
          receipt << {
            target: target_id,
            ontology: onto,
            submission_id: sub_i,
            fields: context[:selected_metadata],
            status: :rejected,
            message: err_msg,
            response_status: response.status
          }
        else
          receipt << {
            target: target_id,
            ontology: onto,
            submission_id: sub_i,
            fields: context[:selected_metadata],
            status: :unknown,
            message: t('ontologies_metadata_curator.receipt_unknown')
          }
        end
      rescue RestClient::Exceptions::Timeout, Net::ReadTimeout, Errno::ECONNRESET, Timeout::Error => e
        receipt << {
          target: target_id,
          ontology: onto,
          submission_id: sub_i,
          fields: context[:selected_metadata],
          status: :unknown,
          message: "#{t('ontologies_metadata_curator.receipt_unknown')}: #{e.message}"
        }
      rescue StandardError => e
        # No response was received, so the write may or may not have happened: re-read before any retry.
        receipt << {
          target: target_id,
          ontology: onto,
          submission_id: sub_i,
          fields: context[:selected_metadata],
          status: :unknown,
          message: e.message
        }
      end
    end

    session[:bulk_metadata_review_receipt] = receipt
    @review_receipt = receipt

    respond_to do |format|
      format.html { render partial: 'ontologies_metadata_curator/receipt', locals: { receipt: receipt } }
      format.turbo_stream do
        streams = [
          replace('application_modal_content', partial: 'ontologies_metadata_curator/receipt', locals: { receipt: receipt, all_metadata: context[:all_metadata] })
        ]
        @submissions.each do |submission|
          submission.ontology = OpenStruct.new({ acronym: submission.ontology }) if submission.ontology.is_a?(String)
          streams << replace("#{ontology_submission_id_label(submission.ontology.acronym, submission.submissionId)}_row", partial: 'ontologies_metadata_curator/submission', locals: { submission: submission, attributes: (context[:all_metadata].is_a?(Array) ? context[:all_metadata] : context[:all_metadata]&.split) })
        end
        render_turbo_stream(*streams)
      end
    end
  end

  def update
    @selected_ontologies = params[:selected_ontologies].map { |x| ontology_and_submission_id(x) }
    @active_ontology = ontology_and_submission_id(params[:active_ontology])
    @all_metadata = params[:all_metadata]&.split
    failures = []
    @submissions = []
    active_submission_data = params['submission']["#{@active_ontology[0]}_#{@active_ontology[1]}"]

    @selected_ontologies.each do |onto, sub_i|
      next unless active_submission_data

      # update_submission converts and deletes keys in place; each target needs its own copy.
      new_data = active_submission_data.deep_dup
      new_data[:ontology] = onto
      new_data[:id] = sub_i
      response = update_submission(new_data, sub_i).last
      if response && response.status != 204
        failures << "#{onto}: #{bulk_update_error_message(response)}"
      else
        @submissions << @submission
      end
    end

    respond_to do |format|
      format.turbo_stream do
        if failures.any? && @submissions.empty?
          render_turbo_stream(alert_error { failures.join('; ') })
        else
          streams = [failures.any? ? alert_error { failures.join('; ') } : alert_success { t('ontologies_metadata_curator.alert_success_submissions') }]
          @submissions.each do |submission|
            submission.ontology = OpenStruct.new({ acronym: submission.ontology })
            streams << replace("#{ontology_submission_id_label(submission.ontology.acronym, submission.submissionId)}_row", partial: 'ontologies_metadata_curator/submission', locals: { submission: submission, attributes: @all_metadata })
          end
          render_turbo_stream(*streams)
        end
      end
    end
  end

  private

  def ensure_bulk_metadata_preview_enabled
    head :not_found unless helpers.bulk_metadata_preview_enabled?
  end

  def current_curator_user
    session[:user] || session[:admin_user]
  end

  def current_session_identifier
    if session.respond_to?(:id) && session.id.present?
      session.id.to_s
    elsif session.respond_to?(:[]) && (session[:session_id] || session['session_id'])
      (session[:session_id] || session['session_id']).to_s
    elsif session.respond_to?(:[]) && (session[:_csrf_token] || session['_csrf_token'])
      (session[:_csrf_token] || session['_csrf_token']).to_s
    elsif session.respond_to?(:[]=)
      session[:session_id] ||= "sess_#{SecureRandom.hex(16)}"
      session[:session_id].to_s
    else
      session.to_s
    end
  end

  def bulk_update_error_message(response)
    errors = response_errors(response)
    errors[:error] || errors.map { |attr, details| "#{attr}: #{details.is_a?(Hash) ? details.values.join(', ') : details}" }.join(', ')
  end

  def build_hash_submissions(show_all_submissions: false, display_attribute: [])
    acronym_ontolog_submissions_hash = {}
    
    if show_all_submissions
      @ontologies.each do |ontology|
        submissions = ontology.explore.submissions({ include: display_attribute.join(',') })
        acronym_ontolog_submissions_hash[ontology.acronym] = {
          ontology: ontology,
          submissions: submissions
        }
      end
    else
      # Get all submissions for the selected ontologies
      submissions = LinkedData::Client::Models::OntologySubmission.all(include_status: "any", acronym: @ontologies_ids.join('|'), display_links: false, display_context: false, include: display_attribute.join(','))
      submissions.reject! { |x| !@ontologies_ids.include?(x.id.split('/')[-3]) } unless @ontologies_ids.empty?
      # Filter and group submissions by ontology acronym
      submissions_by_ontology = submissions.group_by { |sub| sub.id.split('/')[-3] }     
      # Build the hash with the same structure
      @ontologies.each do |ontology|
        acronym_ontolog_submissions_hash[ontology.acronym] = {
          ontology: ontology,
          submissions: (submissions_by_ontology[ontology.acronym] || []).sort_by(&:id)
        }
      end
    end

    return acronym_ontolog_submissions_hash
  end

end
