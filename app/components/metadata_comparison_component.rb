# frozen_string_literal: true

class MetadataComparisonComponent < ViewComponent::Base
  include ApplicationHelper

  attr_reader :record

  def initialize(record:)
    super
    @record = record
  end

  def call
    content_tag(:div, id: 'metadata-comparison-root',
                      class: 'metadata-comparison-container my-3 p-3 bg-white border rounded shadow-sm',
                      data: {
                        controller: 'metadata-comparison-record',
                        'metadata-comparison-record-package-value': @record.to_json_package.to_json
                      }) do
      safe_join([
        header_section,
        toolbar_section,
        provenance_banner,
        error_container,
        table_container
      ])
    end
  end

  private

  def header_section
    content_tag(:div, class: 'd-flex justify-content-between align-items-center mb-3 pb-2 border-bottom') do
      content_tag(:h2, t('metadata_comparison.title', default: 'Metadata Comparison'), class: 'h4 mb-0')
    end
  end

  def toolbar_section
    query_params = {
      ontology: @record.ontology_acronym,
      submission_ids: @record.selection_criteria['submission_ids'],
      properties: @record.property_ids
    }.compact

    content_tag(:div, class: 'd-flex flex-wrap gap-2 align-items-center mb-3') do
      safe_join([
        # Hidden file input for reopening
        tag(:input, type: 'file', accept: '.json', class: 'd-none',
                    data: {
                      'metadata-comparison-record-target': 'fileInput',
                      action: 'change->metadata-comparison-record#onFileChange'
                    },
                    'aria-label': t('metadata_comparison.reopen_package', default: 'Reopen Saved Package')),

        # Reopen button
        content_tag(:button, type: 'button', class: 'btn btn-outline-secondary btn-sm',
                             data: { action: 'click->metadata-comparison-record#triggerFileInput' }) do
          t('metadata_comparison.reopen_package', default: 'Reopen Saved Package')
        end,

        # Download JSON Package
        content_tag(:a, href: comparison_url(query_params.merge(format: :json)),
                        class: 'btn btn-outline-primary btn-sm',
                        download: @record.json_filename) do
          t('metadata_comparison.download_json', default: 'Download JSON Package')
        end,

        # Download Companion CSV
        content_tag(:a, href: comparison_url(query_params.merge(format: :csv)),
                        class: 'btn btn-outline-primary btn-sm',
                        download: @record.csv_filename) do
          t('metadata_comparison.download_csv', default: 'Download Companion CSV')
        end,

        # Refresh Capture
        content_tag(:a, href: comparison_url(query_params),
                        class: 'btn btn-outline-success btn-sm') do
          t('metadata_comparison.refresh', default: 'Refresh Capture')
        end
      ])
    end
  end

  def comparison_url(params = {})
    if defined?(helpers) && helpers.respond_to?(:metadata_comparison_path)
      helpers.metadata_comparison_path(params)
    else
      query = params.map { |k, v| "#{k}=#{Array(v).join(',')}" }.join('&')
      "/metadata_comparison?#{query}"
    end
  rescue StandardError
    query = params.map { |k, v| "#{k}=#{Array(v).join(',')}" }.join('&')
    "/metadata_comparison?#{query}"
  end

  def provenance_banner
    content_tag(:div, class: 'alert alert-light border d-flex justify-content-between align-items-center py-2 px-3 mb-3') do
      safe_join([
        content_tag(:div, class: 'small') do
          safe_join([
            content_tag(:span, "Captured at #{@record.retrieval_timestamp.iso8601} (Read-only capture)",
                               class: 'fw-bold me-2',
                               data: { 'metadata-comparison-record-target': 'timestamp' }),
            content_tag(:span, "| #{@record.records.size} submission(s) captured",
                               class: 'text-muted',
                               data: { 'metadata-comparison-record-target': 'summary' })
          ])
        end
      ])
    end
  end

  def error_container
    content_tag(:div, '', class: 'alert alert-danger d-none my-2',
                          data: { 'metadata-comparison-record-target': 'error' },
                          role: 'alert')
  end

  def table_container
    content_tag(:div, class: 'table-responsive comparison-matrix-wrapper',
                      data: { 'metadata-comparison-record-target': 'container' }) do
      content_tag(:table, class: 'table table-bordered table-striped comparison-matrix mb-0',
                          role: 'table',
                          'aria-label': 'Metadata Comparison Matrix') do
        safe_join([table_header, table_body])
      end
    end
  end

  def table_header
    content_tag(:thead, class: 'table-light') do
      content_tag(:tr) do
        headers = [content_tag(:th, 'Submission / Version', scope: 'col', class: 'align-middle')]
        @record.properties_metadata.each do |prop|
          is_onto = prop['level'] == 'ontology'
          badge_class = is_onto ? 'badge bg-info text-dark' : 'badge bg-secondary'
          level_label = is_onto ? 'Ontology level (current at capture)' : 'Submission level'

          headers << content_tag(:th, scope: 'col', class: 'align-middle', data: { prop_id: prop['id'] }) do
            content_tag(:div, prop['label'], class: 'fw-bold') +
              content_tag(:small, level_label, class: badge_class)
          end
        end
        safe_join(headers)
      end
    end
  end

  def table_body
    content_tag(:tbody) do
      safe_join(@record.records.map { |rec| table_row(rec) })
    end
  end

  def table_row(rec)
    is_unavail = rec['status'] == 'unavailable'
    row_class = is_unavail ? 'table-warning unavailable-row' : ''

    content_tag(:tr, class: row_class, data: { row_key: rec['row_key'] }) do
      cells = [row_header_cell(rec, is_unavail)]

      @record.property_ids.each do |prop_id|
        cell = (rec['values'] && rec['values'][prop_id]) || { 'state' => 'empty', 'value' => nil }
        cells << render_value_cell(cell, prop_id)
      end

      safe_join(cells)
    end
  end

  def row_header_cell(rec, is_unavail)
    content_tag(:th, scope: 'row', class: 'align-middle') do
      parts = [content_tag(:div, rec['row_key'], class: 'fw-bold')]
      if rec['version_identifier'].present?
        parts << content_tag(:div, "v: #{rec['version_identifier']}", class: 'small text-muted')
      end

      if is_unavail
        parts << content_tag(:span, 'Unavailable', class: 'badge bg-danger')
        if rec['error'].present?
          parts << content_tag(:div, rec['error'], class: 'small text-danger')
        end
      else
        parts << content_tag(:span, 'Available', class: 'badge bg-success')
      end

      safe_join(parts)
    end
  end

  def render_value_cell(cell, prop_id = nil)
    state = cell['state']
    content_tag(:td, class: "align-middle state-#{state}", data: { prop_id: prop_id }.compact) do
      case state
      when 'unavailable'
        content_tag(:span, '[Unavailable]', class: 'badge bg-danger')
      when 'unknown'
        content_tag(:span, '[Unknown]', class: 'badge bg-warning text-dark')
      when 'empty'
        content_tag(:span, '[Empty]', class: 'text-muted fst-italic')
      else
        format_cell_value(cell['value'])
      end
    end
  end

  def format_cell_value(val)
    if val.nil?
      content_tag(:span, '[Empty]', class: 'text-muted fst-italic')
    elsif val.is_a?(Array)
      if val.empty?
        content_tag(:span, '[Empty]', class: 'text-muted fst-italic')
      else
        content_tag(:ul, class: 'list-unstyled mb-0') do
          safe_join(val.map { |item| content_tag(:li, format_cell_value(item)) })
        end
      end
    elsif val.is_a?(Hash) && val.key?('@value')
      lang_tag = val['@language'].present? ? content_tag(:small, " (#{val['@language']})", class: 'text-muted') : ''
      content_tag(:span, val['@value']) + lang_tag
    elsif val.is_a?(TrueClass) || val.is_a?(FalseClass)
      content_tag(:code, val.to_s)
    else
      ERB::Util.html_escape(val.to_s)
    end
  end
end
