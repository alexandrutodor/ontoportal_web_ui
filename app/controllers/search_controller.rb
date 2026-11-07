require 'uri'

class SearchController < ApplicationController
  include SearchAggregator, SearchContent, FederationHelper

  skip_before_action :verify_authenticity_token

  layout :determine_layout

  def index
    @search_query = params[:query] || params[:q] || ''
    params[:query] = nil
    @advanced_options_open = false
    @search_results = []
    @json_url = json_link("#{rest_url}/search", {})
    params[:portals] = params[:portals]&.join(',')

    return if @search_query.empty?

    params[:pagesize] = "150"

    set_federated_portals

    params[:ontologies] = nil if federated_request?

    @time = Benchmark.realtime do
      results = LinkedData::Client::Models::Class.search(@search_query, params)
      @federation_errors = federation_error(results) if federation_error?(results)
      results = results.collection


      @search_results = aggregate_results(@search_query, results)
      @federation_counts = federated_search_counts(@search_results)
    end
    @advanced_options_open = !search_params_empty?
    @json_url = json_link("#{rest_url}/search", params.permit!.to_h)
  end

  def json_search
    if params[:q].nil?
      render :plain => t('search.no_search_class_provided')
      return
    end

    if params[:callback].present?
      unless valid_callback_name?(params[:callback])
        render plain: "Invalid callback", status: :bad_request
        return
      end
    elsif params[:response].eql?("json")
      render plain: "Invalid callback", status: :bad_request
      return
    end

    query = params[:q].to_s.strip
    check_params_query(params)
    check_params_ontologies(params)  # Filter on ontology_id
    if params["id"]&.eql?('All')
      params.delete("id")
      params.delete("ontologies")
    end

    search_params = params[:response].eql?("rows") ? params.except(:response) : params
    search_page = LinkedData::Client::Models::Class.search(params[:q], search_params)

    @results = search_page.collection

    single_ontology = params[:id].present? && params[:id].to_s.split(",").length == 1

    if params[:response].eql?("rows")
      active_rows = []
      obsolete_rows = []

      for result in Array(@results)
        row = build_json_search_row(result, query, single_ontology)
        if result.obsolete?
          obsolete_rows << row
        else
          active_rows << row
        end
      end

      render json: (active_rows + obsolete_rows)
      return
    end

    response = ""
    obsolete_response = ""
    separator = (params[:separator].nil?) ? "~!~" : params[:separator]

    for result in Array(@results)
      row = build_json_search_row(result, query, single_ontology)
      entry = row.join("|") + separator
      if result.obsolete?
        obsolete_response << entry
      else
        response << entry
      end
    end

    # Obsolete results merge
    response << obsolete_response

    content_type = "text/html"
    if params[:response].eql?("json")
      response = "#{params[:callback]}({data:#{response.to_json}})"
      content_type = "application/javascript"
    end

    render plain: response, content_type: content_type
  end

  def json_ontology_classes_search
    acronym = params[:ontology_acronym]
    query = params[:search].to_s
    page_size = (params[:page_size] || 25).to_i

    if acronym.blank? || query.blank?
      render json: []
      return
    end

    query = "#{query.strip}*" unless query.end_with?('*')

    search_page = LinkedData::Client::Models::Class.search(query, {
      ontologies: acronym,
      pagesize: page_size,
      also_search_obsolete: false,
      also_search_views: false,
      include: 'prefLabel,synonym,definition'
    })

    results = Array(search_page&.collection).map do |cls|
      ontology_link = cls.links && cls.links['ontology']
      ontology_acronym = ontology_link ? ontology_link.split('/').last : acronym
      label = main_language_label(cls.prefLabel) || cls.id

      {
        id: cls.id,
        name: cls.id,
        label: label,
        acronym: ontology_acronym,
        type: 'Class'
      }
    end

    render json: results
  end

  def json_ontology_content_search
    query = params[:search].presence || '*'
    page = params[:page].to_i > 0 ? params[:page].to_i : 1
    acronyms = params[:ontologies]&.split(',') || []
    page_size = params[:page_size].to_i > 0 ? params[:page_size].to_i : 10
    type = params[:types]&.split(',') || []
    show_ontologies = !params[:show_ontologies].eql?('false')


    results, page, next_page, total_count = search_ontologies_content(query: query,
                                         page: page,
                                         page_size: page_size,
                                         filter_by_ontologies: acronyms,
                                        filter_by_types: type,
                                        show_ontologies: show_ontologies)

    render json: results
  end

  private

  def valid_callback_name?(callback)
    return false if callback.blank?
    /\A[a-zA-Z_$][a-zA-Z0-9_$]*(\.[a-zA-Z_$][a-zA-Z0-9_$]*)*\z/.match?(callback)
  end

  def build_json_search_row(result, query, single_ontology)
    record_type = ""
    label = search_concept_label(result.prefLabel, query).to_s
    target_value = label

    case params[:target]
    when "name"
      target_value = label
    when "shortid", "uri"
      target_value = result.id.to_s
    end

    first_col = target_value.dup
    first_col << " [obsolete]" if result.obsolete?

    ontology_link = result.links && result.links["ontology"]
    acronym = ontology_link ? ontology_link.to_s.split("/").last : ""
    synonyms = (result.synonym || []).join(";")
    definition = CGI.escape((result.definition || []).join(". "))

    if single_ontology
      [
        first_col,
        result.id.to_s,
        record_type,
        acronym,
        result.id.to_s,
        target_value,
        synonyms,
        definition
      ]
    else
      [
        first_col,
        result.id.to_s,
        record_type,
        acronym,
        result.id.to_s,
        target_value,
        synonyms,
        acronym,
        acronym,
        definition
      ]
    end
  end

  def check_params_query(params)
    params[:q] = params[:q].strip
    params[:q] = params[:q] + '*' unless params[:q].end_with?("*") # Add wildcard
  end

  def check_params_ontologies(params)
    params[:ontologies] ||= params[:id]
    if params[:ontologies]
      if params[:ontologies].include?(",")
        params[:ontologies] = params[:ontologies].split(",")
      else
        params[:ontologies] = [params[:ontologies]]
      end
      params[:ontologies] = params[:ontologies].join(",")
    end
  end

  def search_params
    [
      :ontologies, :categories,
      :also_search_properties, :also_search_obsolete, :also_search_views,
      :require_exact_match, :require_definition, :portals
    ]
  end

  def search_params_empty?
    (params[:lang].nil? || params[:lang].eql?('all')) &&
      search_params.all?{|key| params[key].nil? || params[key].empty?}
  end

end
