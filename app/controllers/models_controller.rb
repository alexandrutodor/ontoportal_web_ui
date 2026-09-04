class ModelsController < ApplicationController
  layout :determine_layout

  SECTIONS = %w[overview model_card datasets papers code inference].freeze

  DEFAULT_MODEL_CARD = {
    parameters: 'Unknown',
    size: 'Unknown',
    architecture: 'Unknown',
    framework: 'Unknown',
    precision: 'Unknown',
    inputs: 'Unknown',
    outputs: 'Unknown',
    version: 'Unknown',
    size_caveat: 'Published checkpoint and download sizes vary depending on model precision, compression, weights format, and checkpoint variant.'
  }.freeze

  SORT_OPTIONS = [
    ['Name ascending', 'name_asc'],
    ['Name descending', 'name_desc'],
    ['FAIR readiness', 'fair_desc']
  ].freeze

  FAIR_PROFILE = 'ontoportal-model-fair-metadata-readiness-v1'.freeze

  FAIR_DISCLAIMER = 'Model FAIR metadata readiness v1 is an automated heuristic reflecting public catalogue metadata completeness across Findability, Accessibility, Interoperability, and Reusability. It is a metadata-readiness indicator, not a formal certification, and is not directly comparable to ontology (O\'FAIRe) or dataset FAIR evaluations.'.freeze
  FAIR_METHODOLOGY = 'Methodology: 16 objective catalogue checks grouped across 4 principles (4 checks per principle, 25% each). Principle scores range from 0% to 100%. The overall score is the unweighted mean of F, A, I, and R principle scores, rounded to the nearest integer.'.freeze

helper_method :model_card_for, :fair_score_for if respond_to?(:helper_method)

  CATALOGUE_PATH = File.expand_path("../../config/catalogues/model-catalogue.json", __dir__).freeze
  CATALOGUE_DOCUMENT = JSON.parse(File.binread(CATALOGUE_PATH), symbolize_names: true).freeze
  CATALOGUE = CATALOGUE_DOCUMENT.fetch(:records).freeze

  DEFAULT_GROUPS = [].freeze
  DEFAULT_PROJECTS = [].freeze


  def index
    catalogue = scoped_catalogue
    requested_sort = params[:Sort_by].to_s
    @sort = %w[name_asc name_desc fair_desc].include?(requested_sort) ? requested_sort : 'name_asc'
    @sort_options = SORT_OPTIONS
    @models = catalogue.select { |model| matches_filters?(model) }
    @models = case @sort
              when 'name_desc' then @models.sort_by { |model| model[:name].to_s.downcase }.reverse
              when 'fair_desc' then @models.sort_by { |model| [-self.class.fair_score_for(model)[:overall_score], model[:name].to_s.downcase] }
              else @models.sort_by { |model| model[:name].to_s.downcase }
              end
    @sections = SECTIONS
    @organization_options = catalogue.map { |model| model[:organization] }.reject { |o| o.to_s.strip.empty? }.uniq.sort_by(&:downcase)
    @task_options = catalogue.flat_map { |model| model[:tasks] }.reject { |t| t.to_s.strip.empty? }.uniq.sort_by(&:downcase)
    @domain_options = catalogue.flat_map { |model| model[:domains] }.reject { |d| d.to_s.strip.empty? }.uniq.sort_by(&:downcase)
    @hub_options = catalogue.flat_map { |model| model[:hubs] }.reject { |h| h.to_s.strip.empty? }.uniq.sort_by(&:downcase)
    @license_options = catalogue.map { |model| model[:license] }.reject { |l| l.to_s.strip.empty? }.uniq.sort_by(&:downcase)
    @group_options = (DEFAULT_GROUPS + catalogue.flat_map { |model| Array(model[:groups]) + Array(model[:slices]) }).reject { |g| g.to_s.strip.empty? }.uniq.sort_by(&:downcase)
    @project_options = (DEFAULT_PROJECTS + catalogue.flat_map { |model| Array(model[:projects]) }).reject { |p| p.to_s.strip.empty? }.uniq.sort_by(&:downcase)
    @selected_organization = params[:organization].to_s.strip
    @selected_task = params[:task].to_s.strip
    @selected_domain = params[:domain].to_s.strip
    @selected_hub = params[:hub].to_s.strip
    @selected_license = params[:license].to_s.strip
    @selected_group = (params[:group] || params[:groups]).to_s.strip
    @selected_project = (params[:project] || params[:projects]).to_s.strip
    if params[:format].to_s == 'json' || (defined?(request) && request&.format&.json?)
      render json: api_models_payload(@models)
    else
      render :index
    end
  end

  def show
    @model = scoped_catalogue.find { |model| model[:id] == params[:id].to_s }
    return head :not_found unless @model

    @sections = SECTIONS
    requested_section = params[:section].to_s
    @section = SECTIONS.include?(requested_section) ? requested_section : 'overview'
    @model_card = model_card_for(@model)
    @fair_score = fair_score_for(@model)
    if params[:format].to_s == 'json' || (defined?(request) && request&.format&.json?)
      render json: api_model_payload(@model, @model_card, @fair_score)
    else
      render :show
    end
  end

  def api_index
    catalogue = scoped_catalogue
    models = catalogue.select { |model| matches_filters?(model) }
    render json: api_models_payload(models)
  end

  def api_show
    model = scoped_catalogue.find { |m| m[:id] == params[:id].to_s }
    return render json: { error: 'Model not found', id: params[:id] }, status: :not_found unless model

    card = model_card_for(model)
    fair = fair_score_for(model)
    render json: api_model_payload(model, card, fair)
  end

  def api_catalogues_summary
    render json: {
      catalogues: [
        { id: 'ontologies', name: 'Ontologies & Vocabularies', path: '/ontologies', api_path: '/ontologies' },
        { id: 'datasets', name: 'Materials Datasets', path: '/datasets', api_path: '/datasets' },
        { id: 'models', name: 'Machine Learning Models', path: '/models', api_path: '/api/v1/models', count: CATALOGUE.length },
        { id: 'workflows', name: 'Computational Workflows', path: '/workflows', api_path: '/api/v1/workflows', count: WorkflowsController::CATALOGUE.length },
        { id: 'repositories', name: 'Software Repositories', path: '/repositories', api_path: '/api/v1/repositories', count: RepositoriesController::CATALOGUE.length }
      ]
    }
  end

  private

  def api_models_payload(models)
    {
      total: models.length,
      page: 1,
      page_count: 1,
      collection: models.map do |m|
        card = model_card_for(m)
        fair = fair_score_for(m)
        api_model_payload(m, card, fair)
      end
    }
  end

  def api_model_payload(model, card, fair)
    model.merge(
      model_card: card,
      fair_readiness: {
        overall_score: fair[:overall_score],
        principles: fair[:principles]
      },
      links: {
        ui: "/models/#{model[:id]}",
        api: "/api/v1/models/#{model[:id]}"
      }
    )
  end

  def model_card_for(model)
    self.class.model_card_for(model)
  end

  def fair_score_for(model)
    self.class.fair_score_for(model)
  end

  def self.model_card_for(model)
    return {} unless model.is_a?(Hash)

    card = DEFAULT_MODEL_CARD.merge(model[:model_card] || {})
    org = model[:organization].to_s.strip
    card[:organization] = org.empty? ? 'Unknown' : model[:organization]
    lic = model[:license].to_s.strip
    card[:license] = lic.empty? ? 'Unknown' : model[:license]
    src = card[:source_url].to_s.strip
    card[:source_url] = if !src.empty?
                          card[:source_url]
                        elsif (code_url = model.dig(:resources, :code)&.first&.dig(:url)) && !code_url.to_s.strip.empty?
                          code_url
                        elsif (paper_url = model.dig(:resources, :papers)&.first&.dig(:url)) && !paper_url.to_s.strip.empty?
                          paper_url
                        else
                          'Not publicly documented'
                        end
    card
  end

  def self.fair_score_for(model)
    return { overall_score: 0, principles: { 'F' => 0, 'A' => 0, 'I' => 0, 'R' => 0 }, criteria: {}, profile: FAIR_PROFILE, disclaimer: FAIR_DISCLAIMER, methodology: FAIR_METHODOLOGY } unless model.is_a?(Hash)

    card = model_card_for(model)
    resources = model[:resources] || {}
    hubs = Array(model[:hubs]).reject { |h| h.to_s.strip.empty? }
    domains = Array(model[:domains]).reject { |d| d.to_s.strip.empty? }
    tasks = Array(model[:tasks]).reject { |t| t.to_s.strip.empty? }
    tags = Array(model[:tags]).reject { |tg| tg.to_s.strip.empty? }
    code_links = Array(resources[:code])
    paper_links = Array(resources[:papers])
    dataset_links = Array(resources[:datasets])
    all_resource_links = code_links + paper_links + dataset_links + Array(resources[:inference])

    # F: Findable (0-100)
    f_criteria = [
      { id: 'F1', label: 'Unique identifier & canonical title', pass: !model[:id].to_s.strip.empty? && !model[:name].to_s.strip.empty? },
      { id: 'F2', label: 'Summary description of scope and capabilities', pass: !model[:summary].to_s.strip.empty? },
      { id: 'F3', label: 'Discoverability task keywords or domain tags', pass: tasks.any? || tags.any? },
      { id: 'F4', label: 'Attributed creator organization or institution', pass: !model[:organization].to_s.strip.empty? && model[:organization] != 'Unknown' }
    ]
    f_score = (f_criteria.count { |c| c[:pass] } / f_criteria.length.to_f * 100).round

    # A: Accessible (0-100)
    a_criteria = [
      { id: 'A1', label: 'Primary code repository or model card HTTPS link', pass: code_links.any? { |c| c[:url].to_s.start_with?('https://') } },
      { id: 'A2', label: 'Public HTTPS resource link (code, paper, dataset, or inference)', pass: all_resource_links.any? { |r| r[:url].to_s.start_with?('https://') } },
      { id: 'A3', label: 'Peer-reviewed publication or preprint reference', pass: paper_links.any? { |p| p[:url].to_s.start_with?('https://') } },
      { id: 'A4', label: 'Identified hub distribution platform', pass: hubs.any? }
    ]
    a_score = (a_criteria.count { |c| c[:pass] } / a_criteria.length.to_f * 100).round

    # I: Interoperable (0-100)
    i_criteria = [
      { id: 'I1', label: 'Catalogued materials or molecular domain labels', pass: domains.any? },
      { id: 'I2', label: 'Linked training or evaluation reference datasets', pass: dataset_links.any? },
      { id: 'I3', label: 'Documented architecture or framework metadata', pass: card[:architecture] != 'Unknown' || card[:framework] != 'Unknown' },
      { id: 'I4', label: 'Documented input or output modalities', pass: card[:inputs] != 'Unknown' || card[:outputs] != 'Unknown' }
    ]
    i_score = (i_criteria.count { |c| c[:pass] } / i_criteria.length.to_f * 100).round

    # R: Reusable (0-100)
    r_criteria = [
      { id: 'R1', label: 'Declared licence or access-terms field', pass: !model[:license].to_s.strip.empty? && model[:license] != 'Unknown' },
      { id: 'R2', label: 'Verified curation timestamp currency', pass: !model[:verified_on].to_s.strip.empty? },
      { id: 'R3', label: 'Documented version or checkpoint release', pass: card[:version] != 'Unknown' && !card[:version].to_s.strip.empty? },
      { id: 'R4', label: 'Linked implementation or publication resource', pass: code_links.any? { |c| c[:url].to_s.start_with?('https://') } || paper_links.any? { |p| p[:url].to_s.start_with?('https://') } }
    ]
    r_score = (r_criteria.count { |c| c[:pass] } / r_criteria.length.to_f * 100).round

    overall = ((f_score + a_score + i_score + r_score) / 4.0).round

    {
      overall_score: overall,
      principles: {
        'F' => f_score,
        'A' => a_score,
        'I' => i_score,
        'R' => r_score
      },
      criteria: {
        'Findable' => f_criteria,
        'Accessible' => a_criteria,
        'Interoperable' => i_criteria,
        'Reusable' => r_criteria
      },
      profile: FAIR_PROFILE,
      disclaimer: FAIR_DISCLAIMER,
      methodology: FAIR_METHODOLOGY
    }
  end

  private

  def require_models_catalogue
    head :not_found unless Flipper.enabled?(:models_catalogue)
  end

  def current_slice_acronym
    filter = @subdomain_filter || (Thread.current[:slice] if Thread.current[:slice].is_a?(Hash))
    return nil unless filter.is_a?(Hash) && (filter[:active] == true || filter["active"] == true)

    acronym = (filter[:acronym] || filter["acronym"]).to_s.strip.downcase
    acronym.empty? ? nil : acronym
  end

  def scoped_catalogue
    slice = current_slice_acronym
    return CATALOGUE unless slice

    CATALOGUE.select do |model|
      Array(model[:slices]).map { |s| s.to_s.strip.downcase }.reject(&:empty?).include?(slice)
    end
  end

  def matches_filters?(model)
    search = params[:search].to_s.strip.downcase
    organization = params[:organization].to_s.strip.downcase
    task = params[:task].to_s.strip.downcase
    domain = params[:domain].to_s.strip.downcase
    hub = params[:hub].to_s.strip.downcase
    license = params[:license].to_s.strip.downcase
    group = (params[:group] || params[:groups]).to_s.strip.downcase
    project = (params[:project] || params[:projects]).to_s.strip.downcase
    haystack = [
      model[:id],
      model[:name],
      model[:organization],
      model[:summary],
      model[:tasks],
      model[:domains],
      model[:tags],
      model[:hubs],
      model[:license],
      model[:groups],
      model[:slices],
      model[:projects]
    ].flatten.compact.join(' ').downcase

    (search.empty? || haystack.include?(search)) &&
      (organization.empty? || model[:organization].to_s.downcase == organization) &&
      (task.empty? || Array(model[:tasks]).any? { |value| value.to_s.downcase == task }) &&
      (domain.empty? || Array(model[:domains]).any? { |value| value.to_s.downcase == domain }) &&
      (hub.empty? || Array(model[:hubs]).any? { |value| value.to_s.downcase == hub }) &&
      (license.empty? || model[:license].to_s.downcase == license) &&
      (group.empty? || (Array(model[:groups]) + Array(model[:slices])).any? { |value| value.to_s.downcase == group }) &&
      (project.empty? || Array(model[:projects]).any? { |value| value.to_s.downcase == project })
  end
end
