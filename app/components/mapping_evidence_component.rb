# frozen_string_literal: true

class MappingEvidenceComponent < ViewComponent::Base
  include ApplicationHelper
  include InternationalisationHelper
  include ActionView::Helpers::TagHelper

  def initialize(mapping:, class_1: nil, class_2: nil, direction: nil, provenance: nil, relation: nil)
    @mapping = mapping
    @class_1 = class_1 || extract_class_data(mapping&.classes&.[](0))
    @class_2 = class_2 || extract_class_data(mapping&.classes&.[](1))
    @direction = direction || extract_direction
    @provenance = provenance || extract_provenance
    @relation = relation || extract_relation
  end

  def call
    content_tag(:div, class: 'mapping-evidence-container card p-3', data: { mapping_id: @mapping&.id.to_s }) do
      safe_join([
        render_header,
        render_provenance_and_relation,
        render_classes_comparison
      ])
    end
  end

  private

  def render_header
    content_tag(:div, class: 'mapping-evidence-header border-bottom pb-2 mb-3 d-flex justify-content-between align-items-center') do
      content_tag(:h4, class: 'm-0') do
        safe_join([
          t('mappings.evidence.title', default: 'Mapping Evidence'),
          ' ',
          content_tag(:small, @mapping&.id.to_s, class: 'text-muted mapping-id', data: { mapping_id: @mapping&.id.to_s })
        ])
      end
    end
  end

  def render_provenance_and_relation
    content_tag(:div, class: 'mapping-evidence-provenance card bg-light p-3 mb-3') do
      safe_join([
        content_tag(:div, class: 'row') do
          safe_join([
            content_tag(:div, class: 'col-md-3') do
              safe_join([
                content_tag(:strong, "#{t('mappings.evidence.relation', default: 'Relation')}: "),
                content_tag(:span, @relation, class: 'mapping-relation-value', data: { relation: @relation })
              ])
            end,
            content_tag(:div, class: 'col-md-3') do
              safe_join([
                content_tag(:strong, "#{t('mappings.evidence.direction', default: 'Direction')}: "),
                render_direction_badge
              ])
            end,
            content_tag(:div, class: 'col-md-3') do
              safe_join([
                content_tag(:strong, "#{t('mappings.evidence.source', default: 'Source')}: "),
                content_tag(:span, @provenance[:source], class: 'mapping-source-value')
              ])
            end,
            content_tag(:div, class: 'col-md-3') do
              safe_join([
                content_tag(:strong, "#{t('mappings.evidence.source_name', default: 'Source name')}: "),
                content_tag(:span, @provenance[:source_name], class: 'mapping-source-name-value')
              ])
            end
          ])
        end,
        content_tag(:div, class: 'row mt-2') do
          content_tag(:div, class: 'col-12') do
            safe_join([
              content_tag(:strong, "#{t('mappings.evidence.comment', default: 'Comment')}: "),
              content_tag(:span, @provenance[:comment], class: 'mapping-comment-value')
            ])
          end
        end
      ])
    end
  end

  def render_direction_badge
    if @direction[:status] == :directed
      content_tag(:span, t('mappings.evidence.directed', default: 'Directed (Source → Target)'), class: 'badge badge-info mapping-direction-value', data: { direction: 'directed' })
    else
      content_tag(:span, unknown_direction_text, class: 'badge badge-secondary mapping-direction-value', data: { direction: 'unknown' })
    end
  end

  def render_classes_comparison
    left_class = @direction[:status] == :directed ? @direction[:source] : @class_1
    right_class = @direction[:status] == :directed ? @direction[:target] : @class_2
    left_title = @direction[:status] == :directed ? t('mappings.evidence.source', default: 'Source') : 'Class 1'
    right_title = @direction[:status] == :directed ? t('mappings.evidence.target', default: 'Target') : 'Class 2'

    content_tag(:div, class: 'mapping-evidence-classes row') do
      safe_join([
        content_tag(:div, class: 'col-md-6') do
          render_class_card(left_class, left_title, 'mapping-evidence-card-1')
        end,
        content_tag(:div, class: 'col-md-6') do
          render_class_card(right_class, right_title, 'mapping-evidence-card-2')
        end
      ])
    end
  end

  def render_class_card(class_data, title, css_class)
    class_data ||= {}
    content_tag(:div, class: "card mb-3 #{css_class}") do
      safe_join([
        content_tag(:div, class: 'card-header font-weight-bold d-flex justify-content-between align-items-center') do
          safe_join([
            content_tag(:span, title),
            content_tag(:span, class_data[:ontology_id] || unavailable_text, class: 'badge badge-dark ontology-id', data: { ontology_id: class_data[:ontology_id] })
          ])
        end,
        content_tag(:div, class: 'card-body') do
          safe_join([
            content_tag(:div, class: 'mb-2') do
              safe_join([
                content_tag(:small, "#{t('mappings.evidence.class_id', default: 'Class ID')}: ", class: 'text-muted font-weight-bold d-block'),
                content_tag(:span, class: 'class-id font-monospace text-break', data: { class_id: class_data[:id] }) do
                  if class_data[:link].present?
                    content_tag(:a, class_data[:id], href: class_data[:link], target: '_blank', rel: 'noopener noreferrer')
                  else
                    class_data[:id].to_s
                  end
                end
              ])
            end,
            content_tag(:div, class: 'mb-2') do
              safe_join([
                content_tag(:small, "#{t('mappings.evidence.ontology_id', default: 'Ontology ID')}: ", class: 'text-muted font-weight-bold d-block'),
                content_tag(:span, class_data[:ontology_id] || unavailable_text, class: 'ontology-id-text font-monospace')
              ])
            end,
            content_tag(:div, class: 'mb-2') do
              safe_join([
                content_tag(:strong, "#{t('mappings.evidence.label', default: 'Label')}: "),
                content_tag(:span, class_data[:remote_details_unavailable] ? remote_unavailable_text : (class_data[:label] || unavailable_text), class: 'class-label')
              ])
            end,
            content_tag(:div, class: 'mb-2') do
              safe_join([
                content_tag(:strong, "#{t('mappings.evidence.definition', default: 'Definition')}: "),
                content_tag(:p, class_data[:remote_details_unavailable] ? remote_unavailable_text : (class_data[:definition] || unavailable_text), class: 'class-definition mb-1')
              ])
            end,
            content_tag(:div, class: 'mb-2') do
              safe_join([
                content_tag(:strong, "#{t('mappings.evidence.synonyms', default: 'Synonyms')}: "),
                render_synonyms(class_data[:synonyms], class_data[:remote_details_unavailable])
              ])
            end
          ])
        end
      ])
    end
  end

  def render_synonyms(synonyms, remote_unavailable = false)
    if remote_unavailable
      content_tag(:span, remote_unavailable_text, class: 'text-muted')
    elsif synonyms.present? && Array(synonyms).any?
      content_tag(:ul, class: 'class-synonyms list-inline mb-0') do
        safe_join(Array(synonyms).map { |s| content_tag(:li, s, class: 'list-inline-item badge badge-light border mr-1') })
      end
    else
      content_tag(:span, unavailable_text, class: 'text-muted')
    end
  end

  def extract_class_data(cls)
    return { id: unavailable_text, ontology_id: unavailable_text, label: unavailable_text, definition: unavailable_text, synonyms: [], unavailable: true } if cls.nil?

    if same_portal_class?(cls)
      label = cls.respond_to?(:prefLabel) && cls.prefLabel.presence ||
              cls.respond_to?(:label) && cls.label.presence

      raw_def = cls.respond_to?(:definition) ? cls.definition : nil
      definition = if raw_def.is_a?(Array)
                     raw_def.reject(&:blank?).join('; ').presence
                   elsif raw_def.present?
                     raw_def.to_s
                   end

      raw_syn = cls.respond_to?(:synonym) ? cls.synonym : nil
      synonyms = Array(raw_syn).reject(&:blank?)

      ont_id = extract_ontology_id(cls)

      {
        id: cls.id,
        ontology_id: ont_id || unavailable_text,
        label: label,
        definition: definition,
        synonyms: synonyms,
        external: false,
        remote_details_unavailable: false,
        link: (cls.respond_to?(:links) && cls.links.is_a?(Hash) && cls.links['self']) || cls.id
      }
    else
      ont_id = extract_ontology_id(cls)
      {
        id: cls.id,
        ontology_id: ont_id || unavailable_text,
        label: nil,
        definition: nil,
        synonyms: [],
        external: true,
        remote_details_unavailable: true,
        link: (cls.respond_to?(:links) && cls.links.is_a?(Hash) && cls.links['self']) || cls.id
      }
    end
  end

  def same_portal_class?(cls)
    return false if cls.nil?
    if cls.respond_to?(:links) && cls.links.is_a?(Hash)
      return false if cls.links.key?('ui') && !internal_mapping_link?(cls.links['self'])
      return internal_mapping_link?(cls.links['self'])
    end
    false
  rescue StandardError
    false
  end

  def internal_mapping_link?(self_url)
    return false if self_url.blank?
    rest_url = LinkedData::Client.settings.rest_url.to_s rescue ''
    return true if rest_url.present? && self_url.start_with?(rest_url)
    return true if $LOCAL_IP.present? && self_url.include?($LOCAL_IP)
    false
  end

  def extract_ontology_id(cls)
    if cls.respond_to?(:links) && cls.links.is_a?(Hash) && cls.links['ontology'].present?
      cls.links['ontology'].to_s.split('/').last
    elsif cls.respond_to?(:ontology)
      cls.ontology.to_s.split('/').last
    end
  end

  def extract_direction
    return { status: :unknown, classes: [@class_1, @class_2] } if @mapping.nil? || @class_1.nil? || @class_2.nil?

    c1_id = @class_1[:id].to_s
    c2_id = @class_2[:id].to_s

    subject_id = nil
    object_id = nil

    if @mapping.respond_to?(:subject) && @mapping.respond_to?(:object) && @mapping.subject.present? && @mapping.object.present?
      subject_id = @mapping.subject.respond_to?(:id) ? @mapping.subject.id.to_s : @mapping.subject.to_s
      object_id = @mapping.object.respond_to?(:id) ? @mapping.object.id.to_s : @mapping.object.to_s
    elsif @mapping.respond_to?(:source_class) && @mapping.respond_to?(:target_class) && @mapping.source_class.present? && @mapping.target_class.present?
      subject_id = @mapping.source_class.respond_to?(:id) ? @mapping.source_class.id.to_s : @mapping.source_class.to_s
      object_id = @mapping.target_class.respond_to?(:id) ? @mapping.target_class.id.to_s : @mapping.target_class.to_s
    elsif @mapping.respond_to?(:target) && @mapping.target.present?
      target_val = @mapping.target.respond_to?(:id) ? @mapping.target.id.to_s : @mapping.target.to_s
      if target_val == c2_id
        return { status: :directed, source: @class_1, target: @class_2 }
      elsif target_val == c1_id
        return { status: :directed, source: @class_2, target: @class_1 }
      end
    elsif @mapping.respond_to?(:process) && @mapping.process
      proc = @mapping.process
      if proc.respond_to?(:subject) && proc.respond_to?(:object) && proc.subject.present? && proc.object.present?
        subject_id = proc.subject.respond_to?(:id) ? proc.subject.id.to_s : proc.subject.to_s
        object_id = proc.object.respond_to?(:id) ? proc.object.id.to_s : proc.object.to_s
      elsif proc.respond_to?(:source_class) && proc.respond_to?(:target_class) && proc.source_class.present? && proc.target_class.present?
        subject_id = proc.source_class.respond_to?(:id) ? proc.source_class.id.to_s : proc.source_class.to_s
        object_id = proc.target_class.respond_to?(:id) ? proc.target_class.id.to_s : proc.target_class.to_s
      end
    end

    if subject_id.present? && object_id.present?
      if subject_id == c1_id && object_id == c2_id
        return { status: :directed, source: @class_1, target: @class_2 }
      elsif subject_id == c2_id && object_id == c1_id
        return { status: :directed, source: @class_2, target: @class_1 }
      end
    end

    { status: :unknown, classes: [@class_1, @class_2] }
  end

  def extract_provenance
    source = @mapping.respond_to?(:source) && @mapping.source.presence ||
             (@mapping.respond_to?(:process) && @mapping.process&.respond_to?(:source) && @mapping.process.source.presence)
    source_name = @mapping.respond_to?(:process) && @mapping.process&.respond_to?(:source_name) && @mapping.process.source_name.presence
    comment = @mapping.respond_to?(:process) && @mapping.process&.respond_to?(:comment) && @mapping.process.comment.presence

    {
      source: source || unavailable_text,
      source_name: source_name || unavailable_text,
      comment: comment || unavailable_text
    }
  end

  def extract_relation
    rel = (@mapping.respond_to?(:process) && @mapping.process&.respond_to?(:relation) && @mapping.process.relation.presence) ||
          (@mapping.respond_to?(:relation) && @mapping.relation.presence)
    rel = Array(rel).reject(&:blank?)
    rel.empty? ? unavailable_text : rel.join(', ')
  end

  def unavailable_text
    t('mappings.evidence.unavailable', default: 'Unavailable')
  end

  def remote_unavailable_text
    t('mappings.evidence.remote_details_unavailable', default: 'Remote details unavailable')
  end

  def unknown_direction_text
    t('mappings.evidence.direction_unknown', default: 'Unknown')
  end
end
