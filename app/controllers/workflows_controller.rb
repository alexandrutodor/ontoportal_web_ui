# frozen_string_literal: true

require "json"

class WorkflowsController < ApplicationController
  layout :determine_layout
  before_action :require_workflows_catalogue if respond_to?(:before_action)

  CATALOGUE_PATH = File.expand_path("../../config/catalogues/workflow-catalogue.json", __dir__).freeze
  CATALOGUE_DOCUMENT = JSON.parse(File.binread(CATALOGUE_PATH), symbolize_names: true).freeze
  CATALOGUE = CATALOGUE_DOCUMENT.fetch(:records).freeze
  TAXONOMY_FAMILIES = CATALOGUE_DOCUMENT.fetch(:taxonomy_families).freeze
  SECTIONS = %w[overview steps software-environment related-resources papers-code reproducibility].freeze
  FACETS = %i[family task domain engine software language license environment access maintenance].freeze

  SORT_OPTIONS = [
    ['Name ascending', 'name_asc'],
    ['Name descending', 'name_desc'],
    ['FAIR readiness', 'fair_desc']
  ].freeze

  FAIR_PROFILE = 'ontoportal-workflow-fair-metadata-readiness-v1'.freeze
  FAIR_DISCLAIMER = 'Workflow FAIR metadata readiness v1 is an automated heuristic reflecting public catalogue metadata completeness across Findability, Accessibility, Interoperability, and Reusability. It is a catalogue metadata-readiness indicator, not a formal FAIR certification, scientific validation, code quality check, or execution guarantee.'.freeze
  FAIR_METHODOLOGY = 'Methodology: 16 objective catalogue checks grouped across 4 principles (4 checks per principle, 25% each). Principle scores range from 0% to 100%. The overall score is the unweighted mean of F, A, I, and R principle scores, rounded to the nearest integer.'.freeze

  helper_method :fair_score_for if respond_to?(:helper_method)

  def index
    catalogue = CATALOGUE
    requested_sort = params[:Sort_by].to_s
    @sort = %w[name_asc name_desc fair_desc].include?(requested_sort) ? requested_sort : 'name_asc'
    @sort_options = SORT_OPTIONS
    @workflows = catalogue.select { |workflow| matches_filters?(workflow, catalogue) }
    @workflows = case @sort
                 when 'name_desc' then @workflows.sort_by { |workflow| workflow[:name].to_s.downcase }.reverse
                 when 'fair_desc' then @workflows.sort_by { |workflow| [-self.class.fair_score_for(workflow)[:overall_score], workflow[:name].to_s.downcase] }
                 else @workflows.sort_by { |workflow| workflow[:name].to_s.downcase }
                 end
    @family_options = TAXONOMY_FAMILIES.sort_by(&:downcase)
    @task_options = facet_options(:task, catalogue)
    @domain_options = facet_options(:domain, catalogue)
    @engine_options = facet_options(:engine, catalogue)
    @software_options = facet_options(:software, catalogue)
    @language_options = facet_options(:language, catalogue)
    @license_options = facet_options(:license, catalogue)
    @environment_options = facet_options(:environment, catalogue)
    @access_options = facet_options(:access, catalogue)
    @maintenance_options = facet_options(:maintenance, catalogue)
    @selected_family = selected_values(:family, catalogue)
    @selected_task = selected_values(:task, catalogue)
    @selected_domain = selected_values(:domain, catalogue)
    @selected_engine = selected_values(:engine, catalogue)
    @selected_software = selected_values(:software, catalogue)
    @selected_language = selected_values(:language, catalogue)
    @selected_license = selected_values(:license, catalogue)
    @selected_environment = selected_values(:environment, catalogue)
    @selected_access = selected_values(:access, catalogue)
    @selected_maintenance = selected_values(:maintenance, catalogue)
    render :index
  end

  def show
    @workflow = CATALOGUE.find { |workflow| workflow[:catalogue_id].to_s == params[:id].to_s }
    return head :not_found unless @workflow

    @section = SECTIONS.include?(params[:section].to_s) ? params[:section].to_s : "overview"
    @fair_score = fair_score_for(@workflow)
    render :show
  end

  def fair_score_for(workflow)
    self.class.fair_score_for(workflow)
  end

  def self.fair_score_for(workflow)
    return { overall_score: 0, principles: { 'F' => 0, 'A' => 0, 'I' => 0, 'R' => 0 }, criteria: {}, profile: FAIR_PROFILE, disclaimer: FAIR_DISCLAIMER, methodology: FAIR_METHODOLOGY } unless workflow.is_a?(Hash)

    classification = workflow[:classification] || {}
    implementation = workflow[:implementation] || {}
    execution = workflow[:execution] || {}
    licensing = workflow[:licensing] || {}
    reproducibility = workflow[:reproducibility] || {}
    maintenance = workflow[:maintenance] || {}
    io = workflow[:io] || {}
    papers = Array(workflow[:papers])
    related = workflow[:related_resources] || {}

    # F: Findable (0-100)
    f_criteria = [
      { id: 'F1', label: 'Unique identifier & canonical title', pass: !workflow[:catalogue_id].to_s.strip.empty? && !workflow[:name].to_s.strip.empty? },
      { id: 'F2', label: 'Summary description of workflow scope', pass: !workflow[:summary].to_s.strip.empty? },
      { id: 'F3', label: 'Scientific taxonomy family & task keywords', pass: !classification[:family].to_s.strip.empty? && Array(classification[:scientific_tasks]).any? { |t| !t.to_s.strip.empty? } },
      { id: 'F4', label: 'Domain classification & materials context', pass: Array(classification[:domains]).any? { |d| !d.to_s.strip.empty? } || Array(classification[:material_classes]).any? { |m| !m.to_s.strip.empty? } }
    ]
    f_score = (f_criteria.count { |c| c[:pass] } / f_criteria.length.to_f * 100).round

    # A: Accessible (0-100)
    a_criteria = [
      { id: 'A1', label: 'Public definition or repository HTTPS link', pass: [implementation[:template_or_registry_url], implementation[:repository_url]].any? { |u| u.to_s.start_with?('https://') } },
      { id: 'A2', label: 'Documentation HTTPS link', pass: implementation[:documentation_url].to_s.start_with?('https://') },
      { id: 'A3', label: 'Declared access and proprietary status', pass: !workflow[:access_proprietary_status].to_s.strip.empty? && workflow[:access_proprietary_status] != 'Unknown' },
      { id: 'A4', label: 'Literature citation or preprint reference', pass: papers.any? { |p| p[:doi].to_s.start_with?('http') || p[:arxiv].to_s.start_with?('http') || (!p[:title].to_s.strip.empty? && p[:title] != 'Unknown') } }
    ]
    a_score = (a_criteria.count { |c| c[:pass] } / a_criteria.length.to_f * 100).round

    # I: Interoperable (0-100)
    i_criteria = [
      { id: 'I1', label: 'Documented input and output parameters', pass: Array(io[:inputs]).any? && Array(io[:outputs]).any? },
      { id: 'I2', label: 'Specified workflow engine or orchestrator', pass: Array(implementation[:workflow_engine_or_orchestrator]).any? { |e| !e.to_s.strip.empty? && e.to_s != 'Unknown' } },
      { id: 'I3', label: 'Primary software or programming language specification', pass: Array(implementation[:primary_software]).any? { |s| !s.to_s.strip.empty? && s.to_s != 'Unknown' } || Array(implementation[:programming_or_workflow_languages]).any? { |l| !l.to_s.strip.empty? && l.to_s != 'Unknown' } },
      { id: 'I4', label: 'Linked domain resources (datasets, models, or ontologies)', pass: [:datasets, :models, :ontologies].any? { |k| Array(related[k]).any? } }
    ]
    i_score = (i_criteria.count { |c| c[:pass] } / i_criteria.length.to_f * 100).round

    # R: Reusable (0-100)
    def_lic = licensing.dig(:workflow_definition, :license).to_s.strip
    ver = implementation[:version]
    ver_str = ver.is_a?(Hash) ? ver[:value].to_s.strip : ver.to_s.strip
    r_criteria = [
      { id: 'R1', label: 'Workflow definition license', pass: !def_lic.empty? && def_lic != 'Unknown' },
      { id: 'R2', label: 'Documented execution environments or container definitions', pass: Array(execution[:environments]).any? { |e| !e.to_s.strip.empty? && e.to_s != 'Unknown' } || Array(execution[:container_or_environment_definition]).any? { |c| !c.to_s.strip.empty? && c.to_s != 'Unknown' } },
      { id: 'R3', label: 'Explicit version or release specification', pass: !ver_str.empty? && ver_str != 'Unknown' },
      { id: 'R4', label: 'Verified maintenance status & timestamp', pass: !maintenance[:status].to_s.strip.empty? && maintenance[:status] != 'Unknown' && !maintenance[:last_verified].to_s.strip.empty? && maintenance[:last_verified] != 'Unknown' }
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

  def require_workflows_catalogue
    head :not_found unless Flipper.enabled?(:workflows_catalogue)
  end

  def facet_options(facet, collection = CATALOGUE)
    collection.flat_map { |workflow| facet_values(workflow, facet) }.compact.uniq.sort_by(&:downcase)
  end

  def selected_values(facet, collection = CATALOGUE)
    allowed = facet == :family ? TAXONOMY_FAMILIES : facet_options(facet, collection)
    allowed_by_case = allowed.each_with_object({}) { |value, result| result[value.downcase] = value }
    values_for(facet).filter_map { |value| allowed_by_case[value.downcase] }.uniq
  end

  def values_for(facet)
    value = params[facet]
    value = params[facet.to_s] if value.nil?
    Array(value).flat_map { |item| item.is_a?(Array) ? item : [item] }
      .map { |item| item.to_s.strip }.reject(&:empty?).first(20)
  end

  def query
    value = params[:q] || params["q"] || params[:search] || params["search"]
    value.to_s.strip.downcase
  end

  def matches_filters?(workflow, collection = CATALOGUE)
    filters_match = FACETS.all? do |facet|
      raw_values = values_for(facet)
      selected = selected_values(facet, collection)
      next false if raw_values.any? && selected.empty?

      selected.empty? || selected.any? { |value| facet_values(workflow, facet).any? { |candidate| candidate.to_s.casecmp?(value) } }
    end
    search = query
    haystack = [
      workflow[:catalogue_id], workflow[:name], workflow[:summary],
      workflow.dig(:classification, :family), workflow.dig(:classification, :scientific_tasks),
      workflow.dig(:classification, :domains), workflow.dig(:classification, :material_classes),
      workflow.dig(:implementation, :workflow_engine_or_orchestrator),
      workflow.dig(:implementation, :primary_software),
      workflow.dig(:implementation, :programming_or_workflow_languages)
    ].flatten.compact.join(" ").downcase

    filters_match && (search.empty? || haystack.include?(search))
  end

  def facet_values(workflow, facet)
    case facet
    when :family then Array(workflow.dig(:classification, :family))
    when :task then Array(workflow.dig(:classification, :scientific_tasks))
    when :domain then Array(workflow.dig(:classification, :domains))
    when :engine then Array(workflow.dig(:implementation, :workflow_engine_or_orchestrator))
    when :software then Array(workflow.dig(:implementation, :primary_software))
    when :language then Array(workflow.dig(:implementation, :programming_or_workflow_languages))
    when :license then Array(workflow.dig(:licensing, :workflow_definition, :license))
    when :environment then Array(workflow.dig(:execution, :environments))
    when :access then Array(workflow[:access_proprietary_status])
    when :maintenance then Array(workflow.dig(:maintenance, :status))
    else []
    end
  end
end
