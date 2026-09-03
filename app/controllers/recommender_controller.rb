class RecommenderController < ApplicationController
  layout :determine_layout

  # REST_URI is defined in application_controller.rb
  RECOMMENDER_URI = "/recommender"

  def index
  end

  # def create
  #   # Parse params (default values are set at the service level)
  #   input = params[:input].strip.gsub("\r\n", " ").gsub("\n", " ")
  #   start = Time.now
  #   query = RECOMMENDER_URI
  #   query += "?input=" + CGI.escape(input)
  #   query += "&ontologies=" + CGI.escape(params[:ontologies].join(',')) unless params[:ontologies].nil?
  #   query += "&input_type=" + params[:input_type] unless params[:input_type].nil?
  #   query += "&output_type=" + params[:output_type] unless params[:output_type].nil?
  #   query += "&max_elements_set=" + params[:max_elements_set] unless params[:output_type].nil?
  #   query += "&wc=" + params[:wc].to_s unless params[:wc].nil?
  #   query += "&ws=" + params[:ws].to_s unless params[:ws].nil?
  #   query += "&wa=" + params[:wa].to_s unless params[:wa].nil?
  #   query += "&wd=" + params[:wd].to_s unless params[:wd].nil?
  #   recommendations = parse_json(query) # See application_controller.rb
  #   LOG.add :debug, "Retrieved #{recommendations.length} recommendations: #{Time.now - start}s"
  #   render :json => recommendations
  # end

  # NOTE: this call (POST) works at a local environment but not in staging
  def create
    if params[:algorithm] == 'pareto' || params[:pareto].to_s == 'true' || params[:license_filter].present?
      return pareto
    end

    start = Time.now
    input = params[:input].strip.gsub("\r\n", " ").gsub("\n", " ")
    # Default values are set at the service level)
    form_data = Hash.new
    form_data['input'] = input
    form_data['ontologies'] = params[:ontologies].join(',') unless params[:ontologies].nil?
    form_data['input_type'] = params[:input_type] unless params[:input_type].nil?
    form_data['output_type'] = params[:output_type] unless params[:output_type].nil?
    form_data['max_elements_set'] = params[:max_elements_set] unless params[:output_type].nil?
    form_data['wc'] = params[:wc].to_s unless params[:wc].nil?
    form_data['ws'] = params[:ws].to_s unless params[:ws].nil?
    form_data['wa'] = params[:wa].to_s unless params[:wa].nil?
    form_data['wd'] = params[:wd].to_s unless params[:wd].nil?
    recommendations = LinkedData::Client::HTTP.post(RECOMMENDER_URI, form_data, raw: true)
    Log.add :debug, "Retrieved #{recommendations.length} recommendations: #{Time.now - start}s"
    render json: recommendations
  end

  def pareto
    input = (params[:input] || '').to_s.strip.gsub("\r\n", " ").gsub("\n", " ")
    ontologies = params[:ontologies]
    license_filter = params[:license_filter]

    @pareto_data = Recommender::ParetoRecommenderService.call(
      input: input,
      ontologies: ontologies,
      license_filter: license_filter,
      options: {
        output_type: params[:output_type] || 'individual',
        max_elements_set: params[:max_elements_set] || 3,
        require_permissive_license: params[:require_permissive].to_s == 'true'
      }
    )

    respond_to do |format|
      format.html do
        if request.xhr?
          render partial: 'recommender/pareto_results', locals: { pareto_data: @pareto_data }, layout: false
        else
          render :index
        end
      end
      format.json do
        render json: @pareto_data
      end
    end
  end

end
