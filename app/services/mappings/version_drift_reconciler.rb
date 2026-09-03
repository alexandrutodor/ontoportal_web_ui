# frozen_string_literal: true

require 'ostruct'

module Mappings
  class VersionDriftReconciler
    def self.reconcile(mappings, ontology_classes: {})
      new(mappings, ontology_classes: ontology_classes).reconcile
    end

    def initialize(mappings, ontology_classes: {})
      @mappings = mappings || []
      @classes = ontology_classes || {}
    end

    def reconcile
      stable = []
      repaired = []
      obsolete_orphans = []
      missing = []

      @mappings.each do |mapping|
        subj_id = extract_id(mapping, :subject)
        obj_id = extract_id(mapping, :object)

        subj_status = check_status(subj_id)
        obj_status = check_status(obj_id)

        # Check if subject or object has drifted
        if subj_status[:missing] || obj_status[:missing]
          missing << build_entry(mapping, subj_id, obj_id, :missing_entity, subj_status, obj_status)
        elsif subj_status[:replaced_by] || obj_status[:replaced_by]
          repaired << build_entry(
            mapping,
            subj_status[:replaced_by] || subj_id,
            obj_status[:replaced_by] || obj_id,
            :repairable,
            subj_status,
            obj_status,
            repaired: true,
            original_subject: subj_id,
            original_object: obj_id
          )
        elsif subj_status[:obsolete] || obj_status[:obsolete]
          obsolete_orphans << build_entry(mapping, subj_id, obj_id, :obsolete_orphan, subj_status, obj_status)
        else
          stable << build_entry(mapping, subj_id, obj_id, :stable, subj_status, obj_status)
        end
      end

      total = @mappings.size
      summary = {
        total_mappings: total,
        stable_count: stable.size,
        repairable_count: repaired.size,
        obsolete_orphan_count: obsolete_orphans.size,
        missing_count: missing.size,
        drift_rate: total.positive? ? ((repaired.size + obsolete_orphans.size + missing.size).to_f / total).round(4) : 0.0
      }

      OpenStruct.new(
        summary: summary,
        stable_mappings: stable,
        repaired_mappings: repaired,
        obsolete_orphans: obsolete_orphans,
        missing_mappings: missing,
        notifications: generate_notifications(summary, repaired, obsolete_orphans)
      )
    end

    private

    def extract_id(mapping, role)
      if mapping.is_a?(Hash)
        mapping["#{role}_id"] || mapping["#{role}_id".to_sym]
      elsif mapping.respond_to?(:classes) && mapping.classes.is_a?(Array)
        cls = role == :subject ? mapping.classes[0] : mapping.classes[1]
        cls ? (cls.respond_to?(:id) ? cls.id : cls.to_s) : nil
      elsif role == :subject && mapping.respond_to?(:subject_id)
        mapping.subject_id
      elsif role == :object
        if mapping.is_a?(OpenStruct) || mapping.is_a?(Struct)
          mapping[:object_id] rescue mapping.object_id
        elsif mapping.respond_to?(:target_id)
          mapping.target_id
        elsif mapping.respond_to?(:object_target)
          mapping.object_target
        elsif mapping.class.instance_methods(false).include?(:object_id)
          mapping.object_id
        else
          mapping.instance_variable_get(:@object_id)
        end
      else
        nil
      end
    end

    def check_status(uri)
      return { active: true } if uri.nil? || @classes.empty?

      cls = @classes[uri] || @classes[uri.to_s]
      return { missing: true } if cls.nil?

      is_obsolete = cls.respond_to?(:obsolete?) ? cls.obsolete? : (cls[:obsolete] || cls['obsolete'] || cls[:deprecated] || cls['deprecated'])
      replacement = if cls.respond_to?(:replaced_by)
                      cls.replaced_by
                    elsif cls.is_a?(Hash)
                      cls[:replaced_by] || cls['replaced_by'] || cls[:term_replaced_by] || cls['term_replaced_by']
                    end

      {
        active: !is_obsolete,
        obsolete: !!is_obsolete,
        replaced_by: replacement,
        label: cls.respond_to?(:prefLabel) ? cls.prefLabel : (cls[:label] || cls['label'])
      }
    end

    def build_entry(mapping, subj, obj, status, subj_status, obj_status, options = {})
      OpenStruct.new({
        mapping: mapping,
        subject_id: subj,
        object_id: obj,
        status: status,
        subject_status: subj_status,
        object_status: obj_status
      }.merge(options))
    end

    def generate_notifications(summary, repaired, obsolete)
      notes = []
      if repaired.any?
        notes << "#{repaired.size} mapping(s) can be automatically re-anchored to replacement concepts."
      end
      if obsolete.any?
        notes << "#{obsolete.size} mapping(s) reference obsoleted concepts with no designated replacement."
      end
      notes
    end
  end
end
