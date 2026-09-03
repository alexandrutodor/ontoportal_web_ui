# frozen_string_literal: true

require 'ostruct'

module Mappings
  class SanityGuard
    # SI Base Dimensions: [Length (L), Mass (M), Time (T), Current (I), Temperature (theta), Amount (N), Luminosity (J)]
    DIMENSIONS = {
      length:       [1, 0, 0, 0, 0, 0, 0],
      mass:         [0, 1, 0, 0, 0, 0, 0],
      time:         [0, 0, 1, 0, 0, 0, 0],
      current:      [0, 0, 0, 1, 0, 0, 0],
      temperature:  [0, 0, 0, 0, 1, 0, 0],
      amount:       [0, 0, 0, 0, 0, 1, 0],
      luminosity:   [0, 0, 0, 0, 0, 0, 1],
      dimensionless:[0, 0, 0, 0, 0, 0, 0],
      velocity:     [1, 0, -1, 0, 0, 0, 0],
      acceleration: [1, 0, -2, 0, 0, 0, 0],
      force:        [1, 1, -2, 0, 0, 0, 0],
      energy:       [2, 1, -2, 0, 0, 0, 0],
      power:        [2, 1, -3, 0, 0, 0, 0],
      pressure:     [-1, 1, -2, 0, 0, 0, 0],
      stress:       [-1, 1, -2, 0, 0, 0, 0],
      frequency:    [0, 0, -1, 0, 0, 0, 0],
      electric_charge: [0, 0, 1, 1, 0, 0, 0],
      voltage:      [2, 1, -3, -1, 0, 0, 0],
      resistance:   [2, 1, -3, -2, 0, 0, 0]
    }.freeze

    # Known quantities map
    QUANTITY_PATTERNS = {
      /(^|[_\W])(length|distance|height|width|thickness|diameter|depth)($|[_\W])/i => { dim: :length, rank: 0 },
      /(^|[_\W])(mass|weight)($|[_\W])/i => { dim: :mass, rank: 0 },
      /(^|[_\W])(time|duration|period)($|[_\W])/i => { dim: :time, rank: 0 },
      /(^|[_\W])(temperature|temp)($|[_\W])/i => { dim: :temperature, rank: 0 },
      /(^|[_\W])(velocity|speed)($|[_\W])/i => { dim: :velocity, rank: 1 },
      /(^|[_\W])(force)($|[_\W])/i => { dim: :force, rank: 1 },
      /(^|[_\W])(energy|work|heat)($|[_\W])/i => { dim: :energy, rank: 0 },
      /(^|[_\W])(power)($|[_\W])/i => { dim: :power, rank: 0 },
      /(^|[_\W])(pressure)($|[_\W])/i => { dim: :pressure, rank: 0 },
      /(^|[_\W])(cauchy_stress|stress_tensor|stress)($|[_\W])/i => { dim: :stress, rank: 2 },
      /(^|[_\W])(elasticity_tensor|stiffness_tensor)($|[_\W])/i => { dim: :stress, rank: 4 },
      /(^|[_\W])(strain_tensor|shear_strain)($|[_\W])/i => { dim: :dimensionless, rank: 2 },
      /(^|[_\W])(frequency)($|[_\W])/i => { dim: :frequency, rank: 0 },
      /(^|[_\W])(voltage|electric_potential)($|[_\W])/i => { dim: :voltage, rank: 0 },
      /(^|[_\W])(current|electric_current)($|[_\W])/i => { dim: :current, rank: 0 }
    }.freeze

    CATEGORY_PATTERNS = {
      process: /(^|[_\W])(process|activity|event|procedure|measurement|experiment)($|[_\W])/i,
      material_entity: /(^|[_\W])(material|substance|object|specimen|sample|device|apparatus|crystal|alloy|polymer)($|[_\W])/i,
      quality: /(^|[_\W])(quality|property|characteristic|attribute)($|[_\W])/i,
      disposition: /(^|[_\W])(disposition|capability|function|role)($|[_\W])/i
    }.freeze

    DISJOINT_CATEGORIES = [
      %i[process material_entity],
      %i[process quality],
      %i[material_entity quality],
      %i[material_entity disposition]
    ].freeze

    def self.validate_mapping(subject, object, relation: 'skos:exactMatch')
      new.validate_single(subject, object, relation: relation)
    end

    def self.validate_batch(mappings)
      guard = new
      mappings.map do |mapping|
        guard.validate_mapping_record(mapping)
      end
    end

    def validate_single(subject, object, relation: 'skos:exactMatch')
      violations = []
      warnings = []

      subj_info = extract_entity_info(subject)
      obj_info = extract_entity_info(object)

      is_strict_relation = %w[
        skos:exactMatch
        http://www.w3.org/2004/02/skos/core#exactMatch
        owl:equivalentClass
        http://www.w3.org/2002/07/owl#equivalentClass
        owl:sameAs
        http://www.w3.org/2002/07/owl#sameAs
      ].include?(relation.to_s.strip)

      # 1. Check SI Physical Dimensions
      if subj_info[:dim] && obj_info[:dim]
        subj_vector = DIMENSIONS[subj_info[:dim]]
        obj_vector = DIMENSIONS[obj_info[:dim]]
        if subj_vector && obj_vector && subj_vector != obj_vector
          msg = "SI physical dimension mismatch: subject has #{subj_info[:dim]} #{subj_vector.inspect}, object has #{obj_info[:dim]} #{obj_vector.inspect}"
          if is_strict_relation
            violations << msg
          else
            warnings << msg
          end
        end
      end

      # 2. Check Tensor Rank
      if subj_info[:rank] && obj_info[:rank] && (subj_info[:rank] != obj_info[:rank])
        msg = "Tensor rank mismatch: subject is rank #{subj_info[:rank]} (#{rank_name(subj_info[:rank])}), object is rank #{obj_info[:rank]} (#{rank_name(obj_info[:rank])})"
        if is_strict_relation
          violations << msg
        else
          warnings << msg
        end
      end

      # 3. Check Disjoint Top-level Categories
      if subj_info[:category] && obj_info[:category] && subj_info[:category] != obj_info[:category]
        pair = [subj_info[:category], obj_info[:category]]
        if DISJOINT_CATEGORIES.any? { |c1, c2| (pair == [c1, c2]) || (pair == [c2, c1]) }
          msg = "Disjoint category violation: subject category '#{subj_info[:category]}' is disjoint with object category '#{obj_info[:category]}'"
          if is_strict_relation
            violations << msg
          else
            warnings << msg
          end
        end
      end

      OpenStruct.new(
        valid?: violations.empty?,
        violations: violations,
        warnings: warnings,
        subject: subj_info,
        object: obj_info,
        relation: relation
      )
    end

    def validate_mapping_record(mapping)
      if mapping.is_a?(Hash)
        subject = mapping[:subject_label] || mapping['subject_label'] || mapping[:subject_id] || mapping['subject_id']
        object = mapping[:object_label] || mapping['object_label'] || mapping[:object_id] || mapping['object_id']
        rel = mapping[:predicate_id] || mapping['predicate_id'] || 'skos:exactMatch'
      else
        subject = (mapping.respond_to?(:subject_label) && mapping.subject_label) || (mapping.respond_to?(:subject_id) && mapping.subject_id)
        object = (mapping.respond_to?(:object_label) && mapping.object_label) || (mapping.respond_to?(:target_id) && mapping.target_id) || (mapping.respond_to?(:object_id) && mapping.object_id)
        rel = mapping.respond_to?(:predicate_id) ? mapping.predicate_id : 'skos:exactMatch'
      end

      validate_single(subject, object, relation: rel)
    end

    def extract_entity_info(entity)
      text = if entity.respond_to?(:prefLabel) && entity.prefLabel
               "#{entity.prefLabel} #{entity.id}"
             elsif entity.is_a?(Hash)
               "#{entity[:label] || entity['label']} #{entity[:id] || entity['id']}"
             else
               entity.to_s
             end

      text = text.downcase

      dim = nil
      rank = nil
      category = nil

      QUANTITY_PATTERNS.each do |pattern, info|
        if text.match?(pattern)
          dim = info[:dim]
          rank = info[:rank]
          category = :quality
          break
        end
      end

      unless category
        CATEGORY_PATTERNS.each do |cat, pattern|
          if text.match?(pattern)
            category = cat
            break
          end
        end
      end

      {
        text: text,
        dim: dim,
        dim_vector: dim ? DIMENSIONS[dim] : nil,
        rank: rank,
        category: category
      }
    end

    private

    def rank_name(rank)
      case rank
      when 0 then 'Scalar'
      when 1 then 'Vector'
      when 2 then '2nd Order Tensor / Matrix'
      when 4 then '4th Order Tensor'
      else "Rank #{rank}"
      end
    end
  end
end
