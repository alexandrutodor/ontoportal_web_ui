# frozen_string_literal: true

require_relative '../models/semantic_capsule'
require_relative '../services/capsules/lockfile_generator'
require_relative '../services/capsules/lockfile_validator'
require_relative '../services/capsules/ro_crate_exporter'

class SemanticCapsulesController < ApplicationController
  before_action :set_capsule, only: %i[show edit update destroy download_lock download_bundle verify]

  def index
    @capsules = SemanticCapsule.all
    respond_to do |format|
      format.html
      format.json { render json: @capsules.map(&:as_json) }
    end
  end

  def show
    respond_to do |format|
      format.html
      format.json { render json: @capsule.as_json }
      format.yaml { render plain: @capsule.to_lockfile(format: :yaml), content_type: 'text/yaml' }
    end
  end

  def new
    @capsule = SemanticCapsule.new(
      'name' => 'new-capsule',
      'version' => '1.0.0',
      'author' => session[:user]&.username || 'Curator'
    )
  end

  def create
    if params[:lockfile_upload].present?
      file_content = params[:lockfile_upload].read
      @capsule = SemanticCapsule.from_lockfile(file_content)
    else
      ontologies_data = parse_collection_param(params[:ontologies_json])
      shapes_data = parse_collection_param(params[:shapes_json])
      mappings_data = parse_collection_param(params[:mappings_json])
      embeddings_data = parse_collection_param(params[:embeddings_json])

      @capsule = SemanticCapsule.new(
        'name' => params[:name].presence || 'custom-capsule',
        'version' => params[:version].presence || '1.0.0',
        'description' => params[:description],
        'author' => params[:author].presence || session[:user]&.username || 'Curator',
        'ontologies' => ontologies_data,
        'shapes' => shapes_data,
        'mappings' => mappings_data,
        'embeddings' => embeddings_data
      )

      # Generate canonical lockfile & digest
      generator = Capsules::LockfileGenerator.new(@capsule)
      manifest = generator.generate
      @capsule.lockfile_data = manifest
      @capsule.manifest_digest = manifest.dig('integrity', 'manifest_digest')
      @capsule.status = 'locked'
    end

    SemanticCapsule.save(@capsule)

    respond_to do |format|
      format.html { redirect_to semantic_capsule_path(@capsule.id), notice: 'Semantic Capsule successfully created and locked.' }
      format.json { render json: @capsule.as_json, status: :created }
    end
  rescue StandardError => e
    flash.now[:alert] = "Failed to create capsule: #{e.message}"
    @capsule ||= SemanticCapsule.new
    render :new, status: :unprocessable_entity
  end

  def download_lock
    send_data @capsule.to_lockfile(format: :yaml),
              filename: "#{@capsule.name}-semantic.lock",
              type: 'text/yaml',
              disposition: 'attachment'
  end

  def download_bundle
    zip_bytes = @capsule.export_ro_crate
    send_data zip_bytes,
              filename: "#{@capsule.name}-v#{@capsule.version}-ro-crate.zip",
              type: 'application/zip',
              disposition: 'attachment'
  end

  def verify
    result = @capsule.validate_integrity
    if result[:valid]
      flash[:notice] = "Capsule verified! Cryptographic digest #{result[:computed_digest]} matches manifest."
    else
      flash[:alert] = "Capsule integrity check failed (#{result[:status]}): #{result[:errors].join('; ')}"
    end
    redirect_to semantic_capsule_path(@capsule.id)
  end

  def validate
    content = if params[:lockfile_file].present?
                params[:lockfile_file].read
              else
                params[:content]
              end

    result = Capsules::LockfileValidator.validate(content)

    respond_to do |format|
      format.json { render json: result }
      format.html do
        if result[:valid]
          flash[:notice] = "Lockfile is valid! Integrity digest: #{result[:computed_digest]}"
        else
          flash[:alert] = "Lockfile validation failed (#{result[:status]}): #{result[:errors].join(', ')}"
        end
        redirect_to semantic_capsules_path
      end
    end
  end

  def destroy
    SemanticCapsule.delete(params[:id])
    respond_to do |format|
      format.html { redirect_to semantic_capsules_path, notice: 'Semantic Capsule deleted.' }
      format.json { head :no_content }
    end
  end

  private

  def set_capsule
    @capsule = SemanticCapsule.find(params[:id])
    return if @capsule

    respond_to do |format|
      format.html { redirect_to semantic_capsules_path, alert: "Capsule '#{params[:id]}' not found." }
      format.json { render json: { error: 'Not found' }, status: :not_found }
    end
  end

  def parse_collection_param(param_str)
    return [] if param_str.blank?

    JSON.parse(param_str)
  rescue JSON::ParserError
    []
  end
end
