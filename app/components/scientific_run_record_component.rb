# frozen_string_literal: true

class ScientificRunRecordComponent < ViewComponent::Base
  include ApplicationHelper
  include ActionView::Helpers::TagHelper

  def initialize(tool:, run_record: nil, mode: :actions, form_selector: 'form')
    @tool = tool.to_s
    @run_record = run_record
    @mode = mode.to_sym
    @form_selector = form_selector
  end

  def render?
    run_records_enabled?
  end

  def call
    content_tag(:div,
                class: 'scientific-run-record-container d-inline-block',
                data: {
                  controller: 'scientific-run-record',
                  scientific_run_record_tool_value: @tool,
                  scientific_run_record_form_selector_value: @form_selector
                }) do
      elements = []

      # Status alert container
      elements << content_tag(:div, nil,
                              class: 'scientific-run-record-status d-none mb-2',
                              data: { scientific_run_record_target: 'status' },
                              role: 'status',
                              aria: { live: 'polite' })

      # Hidden file input for import
      elements << content_tag(:input, nil,
                              type: 'file',
                              class: 'd-none',
                              accept: '.json,application/json',
                              data: {
                                scientific_run_record_target: 'fileInput',
                                action: 'change->scientific-run-record#importFile'
                              })

      # Download controls (when run_record is present and mode is :actions)
      if @mode == :actions && @run_record.present?
        elements << render_download_controls
      end

      # Import button
      elements << render_import_button

      safe_join(elements)
    end
  end

  private

  def render_download_controls
    content_tag(:div, class: 'scientific-run-record-export d-inline-block mr-2') do
      parts = []

      # Download button
      parts << content_tag(:button,
                           type: 'button',
                           id: "#{@tool}_run_record_download",
                           class: 'secondary-button regular-button slim scientific-run-record-download-btn',
                           data: {
                             action: 'click->scientific-run-record#downloadRecord',
                             scientific_run_record_target: 'downloadBtn'
                           }) do
        safe_join([
          content_tag(:span, (inline_svg_tag('icons/download.svg') rescue inline_svg_tag('upload.svg') rescue ''.html_safe), class: 'mr-1'),
          content_tag(:span, t('scientific_run_record.download', default: 'Download Run Record'))
        ])
      end

      # Options checkboxes
      parts << content_tag(:div, class: 'scientific-run-record-options mt-1 small text-muted') do
        safe_join([
          content_tag(:label, class: 'mr-3 mb-0 d-inline-flex align-items-center') do
            safe_join([
              content_tag(:input, nil,
                          type: 'checkbox',
                          class: 'mr-1',
                          data: { scientific_run_record_target: 'includeInputText' }),
              content_tag(:span, t('scientific_run_record.include_input_text', default: 'Include input text'))
            ])
          end,
          content_tag(:label, class: 'mr-3 mb-0 d-inline-flex align-items-center') do
            safe_join([
              content_tag(:input, nil,
                          type: 'checkbox',
                          class: 'mr-1',
                          checked: true,
                          data: { scientific_run_record_target: 'includeResults' }),
              content_tag(:span, t('scientific_run_record.include_results', default: 'Include captured results'))
            ])
          end,
          content_tag(:div,
                      t('scientific_run_record.settings_only_note', default: 'Settings-only record requires the original input to rerun.'),
                      class: 'settings-only-note text-muted font-italic mt-1',
                      data: { scientific_run_record_target: 'settingsNote' })
        ])
      end

      # Embedded JSON payload
      json_payload = @run_record.respond_to?(:to_json) ? @run_record.to_json : @run_record.to_s
      parts << content_tag(:script,
                           json_payload.html_safe,
                           type: 'application/json',
                           data: { scientific_run_record_target: 'recordPayload' })

      safe_join(parts)
    end
  end

  def render_import_button
    content_tag(:div, class: 'scientific-run-record-import d-inline-block') do
      content_tag(:button,
                  type: 'button',
                  id: "#{@tool}_run_record_import",
                  class: 'secondary-button regular-button slim scientific-run-record-import-btn',
                  data: {
                    action: 'click->scientific-run-record#triggerImport',
                    scientific_run_record_target: 'importBtn'
                  }) do
        safe_join([
          content_tag(:span, (inline_svg_tag('upload.svg') rescue ''.html_safe), class: 'mr-1'),
          content_tag(:span, t('scientific_run_record.import', default: 'Import Run Record'))
        ])
      end
    end
  end
end
