# frozen_string_literal: true

class MetadataComparisonController < ApplicationController
  layout false
  before_action :check_metadata_comparison_enabled

  def show
    @record = MetadataComparisonRecord.build(params, user: session[:user])

    respond_to do |format|
      format.html do
        component = MetadataComparisonComponent.new(record: @record)
        rendered_html = (component.render_in(view_context) rescue component.call)
        render html: rendered_html.html_safe, layout: false
      end
      format.json do
        render json: @record.to_json_package
      end
      format.csv do
        send_data @record.to_csv, type: 'text/csv; charset=utf-8', filename: @record.csv_filename, disposition: 'attachment'
      end
    end
  end

  private

  def check_metadata_comparison_enabled
    not_found unless helpers.metadata_comparison_enabled?
  end
end
