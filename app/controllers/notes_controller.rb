class NotesController < ApplicationController
  include TurboHelper
  layout 'ontology'

  # Prepended in reverse declaration order so :authorize_and_redirect runs before
  # :verify_note_creator, and both precede ApplicationController startup callbacks.
  prepend_before_action :verify_note_creator, only: :create
  prepend_before_action :authorize_and_redirect, only: :create
 
  NOTES_PROPOSAL_TYPES = {
    ProposalNewClass:  t('notes.new_class_proposal'),
    ProposalChangeHierarchy: t('notes.new_relationship_proposal'),
    ProposalChangeProperty: t('notes.change_property_value_proposal')
  }

  def show
    id = clean_note_id(params[:id])

    @note = LinkedData::Client::Models::Note.get(id, include_threads: true)
    not_found(t('notes.note_not_found', note_id: id)) if @note.nil? || @note.errors
    @note_decorator = NoteDecorator.new(@note, view_context)
    @ontology = (@note.explore.relatedOntology || []).first

    if request.xhr?
      render :partial => 'thread'
      return
    end
  end

  def new_comment
    render partial: 'new_comment', locals: { parent_id: params[:parent_id], type: params[:parent_type],
                                             user_id: session[:user].id, ontology_id: params[:ontology_id] }
  end

  def new_proposal
    types = NOTES_PROPOSAL_TYPES.map { |x, y| [y, x.to_s] }
    render partial: 'new_proposal', locals: { parent_id: params[:parent_id], type: params[:proposal_type],
                                              parent_type: params[:parent_type], user_id: session[:user].id,
                                              ontology_id: params[:ontology_id], types: types }
  end

  def new_reply
    render 'notes/reply/new', locals: { frame_id: "#{params[:parent_id]}_new_reply",
                                           parent_id: params[:parent_id], type: 'reply',
                                           user_id: session[:user].id }
  end

  def virtual_show
    note_id = params[:noteid]
    concept_id = params[:conceptid]
    ontology_acronym = params[:ontology]

    @ontology = LinkedData::Client::Models::Ontology.find_by_acronym(ontology_acronym).first

    if note_id
      id = clean_note_id(note_id)
      @note = LinkedData::Client::Models::Note.get(id, include_threads: true)
      @note_decorator = NoteDecorator.new(@note, view_context)
    elsif concept_id
      @notes = @ontology.explore.single_class(concept_id).explore.notes
      @note_link = "/notes/virtual/#{@ontology.ontologyId}/?noteid="
      render :partial => 'list', :layout => 'ontology'
      return
    else
      @notes = @ontology.explore.notes
      @note_link = "/notes/virtual/#{@ontology.ontologyId}/?noteid="
      render :partial => 'list', :layout => 'ontology'
      return
    end

    if request.xhr?
      render partial: 'thread'
      return
    end

    render 'notes/show', layout: false
    end

  def create
    is_reply = params[:type].eql?("reply")

    if is_reply
      container_id = "#{params[:parent]}_thread_replay_container"
      alerts_container_id = "#{params[:parent]}_reply"
      partial = 'notes/reply/reply'
      note = LinkedData::Client::Models::Reply.new(values: note_params)
    else
      parent_type = params[:type].eql?("ontology") ? 'ontology' : 'class'
      container_id = "#{parent_type}_notes_table_body"
      alerts_container_id = nil
      partial = 'notes/note_line'

      values = note_params
      if params[:proposal]
        values[:proposal] ||= {}
        cast_to_list = [:synonym, :definition, :newRelationshipType]
        cast_to_list.each do |property|
          prop_val = params[:proposal][property]
          values[:proposal][property] = prop_val.is_a?(String) ? prop_val.split(',') : prop_val if prop_val.present?
        end
        proposal_type = params[:proposal][:type]
        if proposal_type.present?
          proposal_subject = "#{NOTES_PROPOSAL_TYPES[proposal_type.to_sym]}: #{params[:proposal][:reasonForChange]}"
          values[:subject] = proposal_subject
          params[:subject] = proposal_subject
        end
      end

      if params[:type].eql?("ontology")
        values[:relatedOntology] = [params[:parent]]
        values.delete(:parent)
        values.delete('parent')
      elsif params[:type].eql?("class")
        values[:relatedClass] = [{ ontology: params[:ontology_id], class: params[:parent] }]
        values[:relatedOntology] = [params[:ontology_id]]
        values.delete(:parent)
        values.delete('parent')
      end

      note = LinkedData::Client::Models::Note.new(values: values)
    end

    new_note = nil
    save_uncertain = false
    begin
      new_note = note.save
    rescue Faraday::TimeoutError, Faraday::ConnectionFailed, Timeout::Error, Errno::ETIMEDOUT, Errno::ECONNRESET, Errno::ECONNREFUSED => e
      save_uncertain = true
    end

    if note_save_confirmed_error?(new_note)
      render_turbo_stream alert_error(id: alerts_container_id) { response_errors(new_note).to_s }
    elsif !save_uncertain && note_save_confirmed_success?(new_note, is_reply: is_reply)
      if is_reply
        locals = { note: new_note, parent_id: params[:parent] }
        render_turbo_stream prepend(container_id, partial: partial, locals: locals)
      else
        ontology_acronym = new_note.relatedOntology.first.to_s.split('/').last
        locals = { note: new_note, ontology_acronym: ontology_acronym, parent_type: parent_type }
        streams = [prepend(container_id, partial: partial, locals: locals)]
        streams.unshift(alert_success { t('notes.new_comment_added') })
        render_turbo_stream *streams
      end
    else
      render_turbo_stream alert_error(id: alerts_container_id) { t('notes.save_uncertain') }
    end
  end

  def destroy
    note_id = params[:noteid]
    note = LinkedData::Client::Models::Note.get(note_id)
    response = {}
    if note
      note.delete

      if note.errors
        response[:errors] = note.errors
      else
        response[:success] = t('notes.note_deleted_successfully', note_id: note_id)
      end
    else
      response[:errors] = t('notes.note_not_found', note_id: note_id)
    end
    parent_type = params[:parent_type]
    alerts_container_id = "notes_#{parent_type}_list_table_alerts"
    if response[:errors]
      render_turbo_stream alert_error(id: alerts_container_id) { response[:errors].join(',').to_s }
    else
      render_turbo_stream(alert_success(id: alerts_container_id) { response[:success] }, remove("#{note_id}_tr_#{parent_type}"))
    end

  end

  def archive
    ontology = DataAccess.getLatestOntology(params[:ontology_virtual_id])

    unless ontology.admin?(session[:user])
      render :json => nil.to_json, :status => 500
      return
    end

    @archive = DataAccess.archiveNote(params)

    unless @archive.nil?
      render :json => @archive.to_json
    end
  end


  private

  def authenticated_actor_id
    user = session[:user]
    return nil if user.nil?

    if user.respond_to?(:id)
      user.id
    elsif user.is_a?(Hash)
      user[:id] || user['id']
    end
  end

  def verify_note_creator
    redirect_to_home if authenticated_actor_id.to_s.strip.empty?
  end

  def note_params
    p = params.permit(:parent, :type, :subject, :body, { relatedClass:[:class, :ontology] }, { relatedOntology:[] },
                      proposal: [:type, :reasonForChange, :classId, :label, { synonym:[] }, { definition:[] },
                                 :parent, :newTarget, :oldTarget, { newRelationshipType:[] }, :propertyId,
                                 :newValue, :oldValue])
    h = p.to_h
    h.delete(:creator)
    h.delete('creator')
    h[:creator] = authenticated_actor_id
    h
  end

  # Fix noteid parameters with bad prefixes (some application servers, e.g., Apache, NGINX, mangle encoded slashes).
  def clean_note_id(id)
    id = id.match(/\Ahttp:\/\w/) ? id.sub('http:/', 'http://') : id
    CGI.unescape(id)
  end

  def note_save_confirmed_error?(note_obj)
    return false if note_obj.nil?

    if note_obj.respond_to?(:errors) && note_obj.errors.present?
      return true
    end

    if note_obj.instance_variable_defined?(:@errors) && note_obj.instance_variable_get(:@errors).present?
      return true
    end

    if note_obj.respond_to?(:status) && note_obj.status && note_obj.status.to_i.between?(400, 499)
      return true
    end

    if note_obj.respond_to?(:error) && note_obj.error.present?
      return true
    end

    false
  end

  def note_save_confirmed_success?(note_obj, is_reply:)
    return false if note_obj.nil?
    return false if note_save_confirmed_error?(note_obj)
    return false if note_obj.respond_to?(:status) && note_obj.status && note_obj.status.to_i >= 400
    return false unless note_obj.respond_to?(:id) && note_obj.id.present?

    if is_reply
      true
    else
      note_obj.respond_to?(:relatedOntology) &&
        note_obj.relatedOntology.is_a?(Array) &&
        !note_obj.relatedOntology.empty? &&
        note_obj.relatedOntology.first.present?
    end
  end

end
