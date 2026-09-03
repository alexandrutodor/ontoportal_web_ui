# frozen_string_literal: true

class BlastRadiusController < ApplicationController
  before_action :load_ontology
  before_action :authorize_curator, only: [:simulate]

  layout 'ontology_viewer'

  # GET /ontologies/:ontology_id/blast_radius
  def show
    @report = if params[:report_id].present?
                BlastRadius::SimulationEngine.find_report(params[:report_id])
              else
                BlastRadius::SimulationEngine.latest_report(params[:ontology_id])
              end

    if @report.nil?
      latest_sub = extract_latest_submission
      @report = BlastRadius::SimulationEngine.simulate(
        ontology_acronym: params[:ontology_id],
        baseline_submission: latest_sub,
        candidate_submission: latest_sub,
        options: { simulation_mode: 'baseline_health_check' }
      )
    end

    respond_to do |format|
      format.html do
        if request.xhr?
          render partial: 'blast_radius/show', layout: false
        else
          render 'blast_radius/show'
        end
      end
      format.json { render json: @report.to_h }
    end
  end

  # POST /ontologies/:ontology_id/blast_radius/simulate
  def simulate
    candidate_sub = build_candidate_submission
    mappings = fetch_external_mappings

    options = {
      require_license: params[:require_license].to_s == 'true' || params[:require_license] == '1',
      expected_base_uri: params[:expected_base_uri].presence,
      simulation_mode: 'pre_activation_candidate_simulation',
      curator: current_user_name
    }

    if params[:candidate_data].present?
      begin
        parsed_data = JSON.parse(params[:candidate_data])
        options.merge!(parsed_data.symbolize_keys) if parsed_data.is_a?(Hash)
      rescue JSON::ParserError
        # Use raw candidate data
      end
    end

    @report = BlastRadius::SimulationEngine.simulate(
      ontology_acronym: params[:ontology_id],
      baseline_submission: extract_latest_submission,
      candidate_submission: candidate_sub,
      external_mappings: mappings,
      options: options
    )

    respond_to do |format|
      format.html do
        flash[:notice] = "Blast radius simulation completed with verdict: #{@report.verdict}"
        redirect_to ontology_blast_radius_path(ontology_id: params[:ontology_id], report_id: @report.id)
      end
      format.json do
        render json: {
          status: 'success',
          verdict: @report.verdict,
          report_id: @report.id,
          report: @report.to_h
        }
      end
    end
  end

  # GET /ontologies/:ontology_id/blast_radius/reports/:report_id
  def report
    @report = BlastRadius::SimulationEngine.find_report(params[:report_id])

    if @report.nil?
      respond_to do |format|
        format.html { render plain: 'Report not found', status: :not_found }
        format.json { render json: { error: 'Report not found' }, status: :not_found }
      end
      return
    end

    respond_to do |format|
      format.html do
        if request.xhr?
          render partial: 'blast_radius/show', layout: false
        else
          render 'blast_radius/show'
        end
      end
      format.json { render json: @report.to_h }
    end
  end

  private

  def load_ontology
    @ontology = if defined?(LinkedData::Client::Models::Ontology)
                  begin
                    LinkedData::Client::Models::Ontology.find_by_acronym(params[:ontology_id], { include: 'all' }).first
                  rescue StandardError
                    nil
                  end
                end

    # Fallback placeholder if API client is not connected
    @ontology ||= Struct.new(:acronym, :name, :summaryOnly).new(params[:ontology_id], params[:ontology_id], false)
    @submission_latest = extract_latest_submission
  end

  def extract_latest_submission
    if @ontology.respond_to?(:explore)
      begin
        @ontology.explore.latest_submission
      rescue StandardError
        nil
      end
    else
      nil
    end
  end

  def build_candidate_submission
    if params[:candidate_submission_id].present?
      return { id: params[:candidate_submission_id], concepts: [] }
    end

    if params[:candidate_concepts].present?
      concepts = begin
                   JSON.parse(params[:candidate_concepts])
                 rescue StandardError
                   []
                 end
      return { id: 'candidate-upload', concepts: concepts }
    end

    # Default to baseline if no explicit candidate payload supplied
    extract_latest_submission || { id: 'candidate-mock', concepts: [] }
  end

  def fetch_external_mappings
    if defined?(LinkedData::Client::Models::Mapping)
      begin
        LinkedData::Client::Models::Mapping.where(ontology: params[:ontology_id])
      rescue StandardError
        []
      end
    else
      []
    end
  end

  def authorize_curator
    return if current_user_admin? || (session[:user] && session[:user].respond_to?(:custom_ontologies) && session[:user].custom_ontologies.include?(params[:ontology_id]))

    # In development/test or if anonymous curation permitted for demo:
    return if Rails.env.development? || Rails.env.test?

    redirect_to "/ontologies/#{params[:ontology_id]}", alert: 'Unauthorized access to ontology digital twin simulation'
  end

  def current_user_name
    if session[:user].respond_to?(:username)
      session[:user].username
    elsif session[:user].is_a?(Hash)
      session[:user][:username] || session[:user]['username'] || 'curator'
    else
      'curator'
    end
  end
end
