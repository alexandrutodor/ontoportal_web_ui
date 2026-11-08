# frozen_string_literal: true

class BulkMetadataPreviewComponent < ViewComponent::Base
  include ApplicationHelper
  include ActionView::Helpers::TagHelper
  include ActionView::Helpers::UrlHelper

  attr_reader :mode, :preview, :receipt, :all_metadata

  def initialize(preview: nil, receipt: nil, all_metadata: nil)
    @preview = preview
    @receipt = receipt
    @all_metadata = all_metadata
    @mode = receipt ? :receipt : :preview
  end

  def call
    if @mode == :receipt
      render_receipt
    else
      render_preview
    end
  end

  private

  def render_preview
    content_tag(:div, class: 'bulk-metadata-preview card p-3', id: 'bulk_metadata_preview_container') do
      safe_join([
        render_preview_header,
        render_stale_warning_note,
        content_tag(:form, action: '/ontologies_metadata_curator/confirm', method: 'post', data: { turbo: true }, id: 'bulk_preview_confirm_form') do
          safe_join([
            tag.input(type: 'hidden', name: '_method', value: 'put'),
            tag.input(type: 'hidden', name: 'preview_token', value: @preview[:preview_token]),
            tag.input(type: 'hidden', name: 'active_ontology', value: @preview[:active_ontology]),
            tag.input(type: 'hidden', name: 'all_metadata', value: @preview[:all_metadata]),
            render_preview_table,
            render_preview_actions
          ])
        end
      ])
    end
  end

  def render_preview_header
    content_tag(:div, class: 'd-flex justify-content-between align-items-center mb-3 pb-2 border-bottom') do
      safe_join([
        content_tag(:h4, t('ontologies_metadata_curator.preview_header', default: 'Bulk Metadata Changes Preview'), class: 'm-0'),
        content_tag(:span, t('ontologies_metadata_curator.preview_badge', default: 'Review before confirmation'), class: 'badge badge-info')
      ])
    end
  end

  def render_stale_warning_note
    content_tag(:div, class: 'alert alert-info py-2 px-3 mb-3 text-small', style: 'font-size: 0.85rem;') do
      t('ontologies_metadata_curator.preview_notice', default: 'Values are compared against current submission state. Unchecking a target excludes it from update. External changes before confirmation will require a fresh preview (best-effort recheck).')
    end
  end

  def render_preview_table
    content_tag(:div, class: 'table-responsive mb-3') do
      content_tag(:table, class: 'table table-bordered table-sm table-hover', id: 'bulk-preview-diff-table') do
        safe_join([
          content_tag(:thead, class: 'thead-light') do
            content_tag(:tr) do
              safe_join([
                content_tag(:th, t('ontologies_metadata_curator.include_target', default: 'Include'), style: 'width: 5%; text-align: center;'),
                content_tag(:th, t('ontologies_metadata_curator.target', default: 'Target'), style: 'width: 20%;'),
                content_tag(:th, t('ontologies_metadata_curator.property', default: 'Property'), style: 'width: 20%;'),
                content_tag(:th, t('ontologies_metadata_curator.current_value', default: 'Current Value'), style: 'width: 25%;'),
                content_tag(:th, t('ontologies_metadata_curator.proposed_value', default: 'Proposed Value'), style: 'width: 25%;'),
                content_tag(:th, t('ontologies_metadata_curator.status', default: 'Status'), style: 'width: 5%; text-align: center;')
              ])
            end
          end,
          content_tag(:tbody) do
            rows = []
            @preview[:targets].each do |target|
              props = target[:properties]
              first = true
              props.each do |attr, diff|
                rows << content_tag(:tr, class: "preview-row-#{diff[:status]}", data: { target_id: target[:target_id], property: attr, status: diff[:status] }) do
                  cols = []
                  if first
                    cols << content_tag(:td, rowspan: props.size, style: 'vertical-align: middle; text-align: center;') do
                      tag.input(type: 'checkbox', name: 'confirmed_targets[]', value: target[:target_id], checked: true, id: "include_#{target[:target_id]}", class: 'target-inclusion-checkbox', aria: { label: "Include #{target[:target_id]}" })
                    end
                    cols << content_tag(:td, rowspan: props.size, style: 'vertical-align: middle;') do
                      content_tag(:strong, "#{target[:ontology]} ##{target[:submission_id]}", class: 'target-identifier')
                    end
                    first = false
                  end
                  cols << content_tag(:td, content_tag(:code, attr.to_s))
                  cols << content_tag(:td, format_value(diff[:current]), class: 'current-value')
                  cols << content_tag(:td, format_value(diff[:proposed]), class: 'proposed-value')
                  cols << content_tag(:td, status_badge(diff[:status]), style: 'text-align: center;')
                  safe_join(cols)
                end
              end
            end
            safe_join(rows)
          end
        ])
      end
    end
  end

  def render_preview_actions
    content_tag(:div, class: 'd-flex justify-content-between align-items-center mt-3 pt-2 border-top') do
      safe_join([
        tag.button(t('ontologies_metadata_curator.cancel_preview', default: 'Cancel'), type: 'button', class: 'btn btn-secondary', data: { dismiss: 'modal' }),
        tag.button(t('ontologies_metadata_curator.confirm_updates', default: 'Confirm updates'), type: 'submit', class: 'btn btn-success', id: 'confirm_bulk_updates_btn', autofocus: true)
      ])
    end
  end

  def render_receipt
    content_tag(:div, class: 'bulk-metadata-receipt card p-3', id: 'bulk_metadata_receipt_container') do
      safe_join([
        render_receipt_header,
        render_receipt_table,
        render_receipt_actions
      ])
    end
  end

  def render_receipt_header
    content_tag(:div, class: 'd-flex justify-content-between align-items-center mb-3 pb-2 border-bottom') do
      safe_join([
        content_tag(:h4, t('ontologies_metadata_curator.review_receipt_title', default: 'Bulk Update Review Receipt'), class: 'm-0'),
        content_tag(:span, t('ontologies_metadata_curator.receipt_badge', default: 'Session Receipt'), class: 'badge badge-secondary')
      ])
    end
  end

  def render_receipt_table
    content_tag(:div, class: 'table-responsive mb-3') do
      content_tag(:table, class: 'table table-bordered table-sm table-hover', id: 'bulk-receipt-table') do
        safe_join([
          content_tag(:thead, class: 'thead-light') do
            content_tag(:tr) do
              safe_join([
                content_tag(:th, t('ontologies_metadata_curator.retry_col', default: 'Retry?'), style: 'width: 5%; text-align: center;'),
                content_tag(:th, t('ontologies_metadata_curator.target', default: 'Target'), style: 'width: 25%;'),
                content_tag(:th, t('ontologies_metadata_curator.properties', default: 'Properties'), style: 'width: 25%;'),
                content_tag(:th, t('ontologies_metadata_curator.status', default: 'Status'), style: 'width: 15%; text-align: center;'),
                content_tag(:th, t('ontologies_metadata_curator.details', default: 'Details'), style: 'width: 30%;')
              ])
            end
          end,
          content_tag(:tbody) do
            safe_join(@receipt.map do |row|
              st = row[:status]&.to_sym
              content_tag(:tr, class: "receipt-row-#{st}", data: { target: row[:target], status: st }) do
                safe_join([
                  content_tag(:td, style: 'text-align: center; vertical-align: middle;') do
                    if st == :rejected
                      tag.input(type: 'checkbox', name: 'retry_targets[]', value: row[:target], checked: true, id: "retry_#{row[:target]}", class: 'retry-target-checkbox', form: 'bulk_retry_preview_form')
                    elsif st == :unknown
                      content_tag(:span, '—', class: 'text-muted', title: t('ontologies_metadata_curator.receipt_unknown_reconcile', default: 'Unknown outcome requires re-read before retry'))
                    else
                      content_tag(:span, '✓', class: 'text-success', title: 'Confirmed')
                    end
                  end,
                  content_tag(:td, "#{row[:ontology]} ##{row[:submission_id]}", class: 'target-cell'),
                  content_tag(:td, Array(row[:fields]).join(', '), class: 'fields-cell'),
                  content_tag(:td, receipt_status_badge(st), style: 'text-align: center;'),
                  content_tag(:td, row[:message] || '', class: 'message-cell')
                ])
              end
            end)
          end
        ])
      end
    end
  end

  def render_receipt_actions
    rejected_rows = @receipt.select { |r| r[:status]&.to_sym == :rejected }
    content_tag(:div, class: 'd-flex justify-content-between align-items-center mt-3 pt-2 border-top') do
      elements = [
        tag.button(t('ontologies_metadata_curator.close', default: 'Close'), type: 'button', class: 'btn btn-secondary', data: { dismiss: 'modal' })
      ]
      if rejected_rows.any?
        elements << content_tag(:form, action: '/ontologies_metadata_curator/preview', method: 'post', data: { turbo: true }, id: 'bulk_retry_preview_form', class: 'd-inline') do
          tag.button(t('ontologies_metadata_curator.retry_preview', default: 'Fresh preview for failed targets'), type: 'submit', class: 'btn btn-warning', id: 'bulk_retry_preview_btn')
        end
      end
      safe_join(elements)
    end
  end

  def status_badge(status)
    case status
    when :unchanged
      content_tag(:span, t('ontologies_metadata_curator.status_unchanged', default: 'unchanged'), class: 'badge badge-secondary')
    when :added
      content_tag(:span, t('ontologies_metadata_curator.status_added', default: 'added'), class: 'badge badge-success')
    when :replaced
      content_tag(:span, t('ontologies_metadata_curator.status_replaced', default: 'replaced'), class: 'badge badge-warning')
    when :cleared
      content_tag(:span, t('ontologies_metadata_curator.status_cleared', default: 'cleared'), class: 'badge badge-danger')
    when :omitted
      content_tag(:span, t('ontologies_metadata_curator.status_omitted', default: 'omitted'), class: 'badge badge-light text-muted')
    else
      content_tag(:span, status.to_s, class: 'badge badge-secondary')
    end
  end

  def receipt_status_badge(status)
    case status
    when :success
      content_tag(:span, t('ontologies_metadata_curator.receipt_success', default: 'Success'), class: 'badge badge-success')
    when :rejected
      content_tag(:span, t('ontologies_metadata_curator.receipt_rejected', default: 'Rejected'), class: 'badge badge-danger')
    when :unknown
      content_tag(:span, t('ontologies_metadata_curator.receipt_unknown', default: 'Unknown'), class: 'badge badge-warning')
    else
      content_tag(:span, status.to_s, class: 'badge badge-secondary')
    end
  end

  def format_value(val)
    if BulkMetadataPreview.value_empty?(val)
      content_tag(:span, t('ontologies_metadata_curator.empty_value', default: '(empty)'), class: 'text-muted font-italic')
    elsif val == true
      content_tag(:span, 'true', class: 'badge badge-info')
    elsif val == false
      content_tag(:span, 'false', class: 'badge badge-secondary')
    elsif val.is_a?(Array)
      content_tag(:span, val.map { |v| format_value(v) }.join(', ').html_safe)
    elsif val.is_a?(Hash)
      content_tag(:span, val.map { |k, v| "#{k}: #{v}" }.join('; '))
    else
      content_tag(:span, ERB::Util.html_escape(val.to_s))
    end
  end
end
