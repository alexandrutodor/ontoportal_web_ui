# frozen_string_literal: true

require "json"

class RepositoriesController < ApplicationController
  layout :determine_layout
  before_action :require_repositories_catalogue if respond_to?(:before_action)

  CATALOGUE_PATH = File.expand_path("../../config/catalogues/repository-catalogue.json", __dir__).freeze
  CATALOGUE_DOCUMENT = JSON.parse(File.binread(CATALOGUE_PATH), symbolize_names: true).freeze
  CATALOGUE = CATALOGUE_DOCUMENT.fetch(:repositories).freeze
  SECTIONS = %w[overview languages releases workflows models datasets ontologies papers archive].freeze
  FACETS = %i[host organization type domain task language license package maintenance archive access related].freeze
  RESOURCE_TYPES = %w[workflows models datasets ontologies].freeze

  SORT_OPTIONS = [
    ['Name ascending', 'name_asc'],
    ['Name descending', 'name_desc'],
    ['FAIR readiness', 'fair_desc']
  ].freeze

  FAIR_PROFILE = 'ontoportal-repository-fair-metadata-readiness-v1'.freeze
  FAIR_DISCLAIMER = 'Repository FAIR metadata readiness v1 is an automated heuristic reflecting public catalogue metadata completeness across Findability, Accessibility, Interoperability, and Reusability. It is a catalogue metadata-readiness indicator, not a formal FAIR certification, code quality audit, security assessment, sustainability evaluation, or scientific endorsement.'.freeze
  FAIR_METHODOLOGY = 'Methodology: 16 objective catalogue checks grouped across 4 principles (4 checks per principle, 25% each). Principle scores range from 0% to 100%. The overall score is the unweighted mean of F, A, I, and R principle scores, rounded to the nearest integer.'.freeze

  helper_method :fair_score_for if respond_to?(:helper_method)

  def index
    catalogue = CATALOGUE
    requested_sort = params[:Sort_by].to_s
    @sort = %w[name_asc name_desc fair_desc].include?(requested_sort) ? requested_sort : 'name_asc'
    @sort_options = SORT_OPTIONS
    @repositories = catalogue.select { |repository| matches_filters?(repository, catalogue) }
    @repositories = case @sort
                    when 'name_desc' then @repositories.sort_by { |repository| repository[:project_name].to_s.downcase }.reverse
                    when 'fair_desc' then @repositories.sort_by { |repository| [-self.class.fair_score_for(repository)[:overall_score], repository[:project_name].to_s.downcase] }
                    else @repositories.sort_by { |repository| repository[:project_name].to_s.downcase }
                    end
    @host_options = facet_options(:host, catalogue)
    @organization_options = facet_options(:organization, catalogue)
    @language_options = facet_options(:language, catalogue)
    @license_options = facet_options(:license, catalogue)
    @task_options = facet_options(:task, catalogue)
    @domain_options = facet_options(:domain, catalogue)
    @ecosystem_options = facet_options(:package, catalogue)
    @type_options = facet_options(:type, catalogue)
    @maintenance_options = facet_options(:maintenance, catalogue)
    @archive_options = facet_options(:archive, catalogue)
    @access_options = facet_options(:access, catalogue)
    @selected_host = selected_values(:host, catalogue)
    @selected_organization = selected_values(:organization, catalogue)
    @selected_language = selected_values(:language, catalogue)
    @selected_license = selected_values(:license, catalogue)
    @selected_task = selected_values(:task, catalogue)
    @selected_domain = selected_values(:domain, catalogue)
    @selected_type = selected_values(:type, catalogue)
    @selected_ecosystem = selected_values(:package, catalogue)
    @selected_maintenance = selected_values(:maintenance, catalogue)
    @selected_archive = selected_values(:archive, catalogue)
    @selected_access = selected_values(:access, catalogue)
    render :index
  end

  def show
    @repository = CATALOGUE.find { |repository| repository[:id].to_s == params[:id].to_s }
    return head :not_found unless @repository

    @section = SECTIONS.include?(params[:section].to_s) ? params[:section].to_s : "overview"
    @fair_score = fair_score_for(@repository)
    render :show
  end

  def fair_score_for(repository)
    self.class.fair_score_for(repository)
  end

  def self.fair_score_for(repository)
    return { overall_score: 0, principles: { 'F' => 0, 'A' => 0, 'I' => 0, 'R' => 0 }, criteria: {}, profile: FAIR_PROFILE, disclaimer: FAIR_DISCLAIMER, methodology: FAIR_METHODOLOGY } unless repository.is_a?(Hash)

    canonical = repository[:canonical_repository] || {}
    languages = repository[:languages] || {}
    licenses = repository[:licenses] || {}
    environment = repository[:environment] || {}
    release = repository[:release]
    release_hash = release.is_a?(Hash) ? release : {}
    packages = Array(repository[:packages])
    papers = Array(repository[:papers])
    archives = Array(repository[:archives])
    citation = repository[:citation_metadata] || {}
    status = repository[:status] || {}
    related = repository[:related_resources] || {}

    # F: Findable (0-100)
    org = repository[:owner_organization].to_s.strip
    f_criteria = [
      { id: 'F1', label: 'Unique identifier & canonical project name', pass: !repository[:id].to_s.strip.empty? && !repository[:project_name].to_s.strip.empty? },
      { id: 'F2', label: 'Summary description of repository purpose', pass: !repository[:summary].to_s.strip.empty? },
      { id: 'F3', label: 'Attributed owner organization or maintainer', pass: !org.empty? && org != 'Unknown' },
      { id: 'F4', label: 'Classified domain topics or computational tasks', pass: Array(repository[:broad_domains]).any? { |d| !d.to_s.strip.empty? && d.to_s != 'Unknown' } || Array(repository[:tasks]).any? { |t| !t.to_s.strip.empty? && t.to_s != 'Unknown' } }
    ]
    f_score = (f_criteria.count { |c| c[:pass] } / f_criteria.length.to_f * 100).round

    # A: Accessible (0-100)
    host = canonical[:host].to_s.strip
    access = status[:access].to_s.strip
    a_criteria = [
      { id: 'A1', label: 'Canonical repository HTTPS link', pass: canonical[:url].to_s.start_with?('https://') },
      { id: 'A2', label: 'Declared host platform and access status', pass: !host.empty? && host != 'Unknown' && !access.empty? && access != 'Unknown' },
      { id: 'A3', label: 'Documented package manager distribution or release download', pass: packages.any? { |p| p.is_a?(Hash) && p[:url].to_s.start_with?('https://') } || release_hash[:url].to_s.start_with?('https://') },
      { id: 'A4', label: 'Persistent archive PID (Software Heritage, Zenodo, or DOI)', pass: archives.any? { |a| a.is_a?(Hash) && a[:url].to_s.start_with?('https://') } }
    ]
    a_score = (a_criteria.count { |c| c[:pass] } / a_criteria.length.to_f * 100).round

    # I: Interoperable (0-100)
    primary_lang = languages[:primary].to_s.strip
    cff = citation[:citation_cff].to_s.strip
    codemeta = citation[:codemeta].to_s.strip
    i_criteria = [
      { id: 'I1', label: 'Specified primary programming language', pass: !primary_lang.empty? && primary_lang != 'Unknown' },
      { id: 'I2', label: 'Documented installation surfaces or container environment', pass: Array(environment[:install_surfaces]).any? { |s| !s.to_s.strip.empty? && s.to_s != 'Unknown' } || (!environment[:containers].to_s.strip.empty? && environment[:containers] != 'Unknown') },
      { id: 'I3', label: 'Standard citation metadata (CITATION.cff or CodeMeta)', pass: (!cff.empty? && cff != 'Unknown') || (!codemeta.empty? && codemeta != 'Unknown') },
      { id: 'I4', label: 'Linked materials-science resources (workflows, models, datasets, ontologies)', pass: [:workflows, :models, :datasets, :ontologies].any? { |k| terms = Array(related.dig(k, :search_terms)); terms.any? && terms.none? { |t| t.to_s == 'Unknown' } } }
    ]
    i_score = (i_criteria.count { |c| c[:pass] } / i_criteria.length.to_f * 100).round

    # R: Reusable (0-100)
    spdx = licenses[:repository_spdx].to_s.strip
    ver = release.is_a?(Hash) ? release[:version].to_s.strip : release.to_s.strip
    maint = status[:maintenance].to_s.strip
    verif = status[:last_verified].to_s.strip
    r_criteria = [
      { id: 'R1', label: 'Declared repository SPDX code license', pass: !spdx.empty? && spdx != 'Unknown' },
      { id: 'R2', label: 'Documented release version or tag', pass: !ver.empty? && ver != 'Unknown' },
      { id: 'R3', label: 'Verified maintenance status & currency timestamp', pass: !maint.empty? && maint != 'Unknown' && !verif.empty? && verif != 'Unknown' },
      { id: 'R4', label: 'Associated publication or citation reference', pass: papers.any? { |p| p.is_a?(Hash) && (!p[:identifier].to_s.strip.empty? || !p[:title].to_s.strip.empty?) } }
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

  def require_repositories_catalogue
    head :not_found unless Flipper.enabled?(:repositories_catalogue)
  end

  def facet_options(facet, collection = CATALOGUE)
    collection.flat_map { |repository| facet_values(repository, facet) }.compact.uniq.sort_by(&:downcase)
  end

  def selected_values(facet, collection = CATALOGUE)
    allowed = facet_options(facet, collection)
    allowed_by_case = allowed.each_with_object({}) { |value, result| result[value.downcase] = value }
    values_for(facet).filter_map { |value| allowed_by_case[value.downcase] }.uniq
  end

  def values_for(facet)
    keys = {
      host: :host, organization: :organization, type: :type, domain: :domain,
      task: :task, language: :language, license: :license, package: :package,
      maintenance: :maintenance, archive: :archive, access: :access, related: :related,
      repository_type: :type, ecosystem: :package
    }
    key = keys.fetch(facet, facet)
    value = params[key] || params[key.to_s]
    value ||= params[:repository_type] || params["repository_type"] if facet == :type
    value ||= params[:ecosystem] || params["ecosystem"] if facet == :package
    Array(value).flat_map { |item| item.is_a?(Array) ? item : [item] }
      .map { |item| item.to_s.strip }.reject(&:empty?).first(20)
  end

  def query
    value = params[:q] || params["q"] || params[:search] || params["search"]
    value.to_s.strip.downcase
  end

  def matches_filters?(repository, collection = CATALOGUE)
    FACETS.all? do |facet|
      selected = selected_values(facet, collection)
      selected.empty? || selected.any? { |value| facet_values(repository, facet).any? { |candidate| candidate.to_s.casecmp?(value) } }
    end && boolean_filters_match?(repository) && (query.empty? || searchable_text(repository).include?(query))
  end

  def boolean_filters_match?(repository)
    %i[has_paper has_archive_pid has_environment].all? do |key|
      value = params[key] || params[key.to_s]
      value.nil? || value.to_s.empty? || !value.to_s.casecmp?("true") || boolean_value(repository, key)
    end
  end

  def boolean_value(repository, key)
    case key
    when :has_paper then repository[:papers].is_a?(Array) && !repository[:papers].empty?
    when :has_archive_pid
      Array(repository[:archives]).any? { |archive| archive.is_a?(Hash) && archive[:persistent_id].to_s != "Unknown" }
    when :has_environment then repository[:environment].is_a?(Hash) && repository[:environment].values.any? { |value| value.to_s != "Unknown" && Array(value).any? { |item| item.to_s != "Unknown" } }
    end
  end

  def searchable_text(repository)
    [
      repository[:id], repository[:project_name], repository[:owner_organization], repository[:summary],
      repository.dig(:canonical_repository, :url), repository.dig(:canonical_repository, :host),
      repository[:repository_types], repository[:broad_domains], repository[:tasks],
      repository.dig(:languages, :primary), repository.dig(:languages, :secondary),
      Array(repository[:packages]).flat_map { |package| package.is_a?(Hash) ? package.values_at(:ecosystem, :name) : package },
      Array(repository[:papers]).flat_map { |paper| paper.is_a?(Hash) ? paper.values_at(:title, :identifier) : paper },
      RESOURCE_TYPES.flat_map { |type| repository.dig(:related_resources, type.to_sym, :search_terms) }
    ].flatten.compact.join(" ").downcase
  end

  def facet_values(repository, facet)
    case facet
    when :host then Array(repository.dig(:canonical_repository, :host))
    when :organization then Array(repository[:owner_organization])
    when :type then Array(repository[:repository_types])
    when :domain then Array(repository[:broad_domains])
    when :task then Array(repository[:tasks])
    when :language then Array(repository.dig(:languages, :primary))
    when :license then Array(repository.dig(:licenses, :repository_spdx))
    when :package
      packages = Array(repository[:packages])
      packages.flat_map { |package| package.is_a?(Hash) ? [package[:ecosystem], package[:name]] : package }
    when :maintenance then Array(repository.dig(:status, :maintenance))
    when :archive then Array(repository.dig(:status, :archive))
    when :access then Array(repository.dig(:status, :access))
    when :related
      RESOURCE_TYPES.select do |type|
        group = repository.dig(:related_resources, type.to_sym)
        group && (Array(group[:stable_ids]).any? { |id| id.to_s != "Unknown" } || Array(group[:search_terms]).any? { |term| term.to_s != "Unknown" })
      end
    else []
    end
  end
end
