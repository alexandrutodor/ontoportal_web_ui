class DatasetsController < ApplicationController
  layout :determine_layout
  before_action :require_datasets

  def index
    @query = params[:q].to_s.encode('UTF-8', invalid: :replace, undef: :replace).strip.first(DatasetsProvider::MAX_QUERY_LENGTH).to_s
    @page = params[:page].to_i.clamp(1, 1000)
    @result = DatasetsProvider.new.index(query: @query, page: @page)
    @datasets = @result.records
  rescue DatasetsProvider::Error => error
    render_provider_error(error)
  end

  def show
    id = params[:id].to_s
    return head :not_found unless DatasetsProvider::ID_PATTERN.match?(id)

    @dataset = DatasetsProvider.new.detail(id)
  rescue DatasetsProvider::Error => error
    render_provider_error(error)
  end

  private

  def require_datasets
    head :not_found unless Flipper.enabled?(:datasets)
  end

  def render_provider_error(error)
    @datasets = []
    @result = nil
    @dataset = nil
    @datasets_error = error.message
    render action_name, status: error.status
  end
end
