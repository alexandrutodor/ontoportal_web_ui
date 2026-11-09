require 'faraday'

class ContentFinderController < ApplicationController
  include OntologyContentSerializer

  def index
    if params[:acronym].blank? || params[:uri].blank?
      @result = nil
      @error = nil
      render 'content_finder/index', layout: 'tool', status: 200
      return
    end

    result = serialize_content(ontology_acronym: params[:acronym],
                               concept_id: params[:uri],
                               format: params[:output_format])
    if result.success?
      @result = result.content
      @format = result.format
      @error = nil
      render 'content_finder/index', layout: 'tool', status: result.status
    else
      @result = nil
      @format = nil
      @error = result.error || "Upstream Service Error"
      render 'content_finder/index', layout: 'tool', status: result.status
    end
  end
end