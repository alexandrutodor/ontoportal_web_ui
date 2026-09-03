# frozen_string_literal: true

module Recommender
  class OntologyEvaluation
    PERMISSIVE_LICENSES = %w[
      CC0-1.0 CC-BY-4.0 CC-BY-3.0 MIT Apache-2.0 BSD-2-Clause BSD-3-Clause ISC
      ODC-By ODbL CC-BY-SA-4.0
    ].freeze

    attr_accessor :acronym, :name, :coverage, :specialization, :recency,
                  :redundancy, :license_spdx, :license_permissive,
                  :pareto_rank, :crowding_distance, :coverage_details,
                  :raw_metrics, :composite_score

    def initialize(attributes = {})
      @acronym = (attributes[:acronym] || attributes['acronym']).to_s
      @name = (attributes[:name] || attributes['name'] || @acronym).to_s
      @coverage = (attributes[:coverage] || attributes['coverage'] || 0.0).to_f
      @specialization = (attributes[:specialization] || attributes['specialization'] || 0.0).to_f
      @recency = (attributes[:recency] || attributes['recency'] || 0.0).to_f
      @redundancy = (attributes[:redundancy] || attributes['redundancy'] || 0.0).to_f
      @license_spdx = (attributes[:license_spdx] || attributes['license_spdx'] || attributes[:license] || attributes['license'] || 'UNKNOWN').to_s.strip
      @license_permissive = determine_license_permissive(attributes[:license_permissive] || attributes['license_permissive'])
      @pareto_rank = (attributes[:pareto_rank] || attributes['pareto_rank'] || nil)&.to_i
      @crowding_distance = (attributes[:crowding_distance] || attributes['crowding_distance'] || 0.0).to_f
      @coverage_details = attributes[:coverage_details] || attributes['coverage_details'] || {}
      @raw_metrics = attributes[:raw_metrics] || attributes['raw_metrics'] || {}
      @composite_score = (attributes[:composite_score] || attributes['composite_score'] || 0.0).to_f
    end

    def permissive_license?
      @license_permissive == true
    end

    # Dominance test against another evaluation:
    # returns true if self dominates other in objectives:
    # coverage (max), specialization (max), recency (max), redundancy (min)
    def dominates?(other)
      return false if other.nil?

      ge_coverage = @coverage >= other.coverage
      ge_specialization = @specialization >= other.specialization
      ge_recency = @recency >= other.recency
      le_redundancy = @redundancy <= other.redundancy

      all_at_least_as_good = ge_coverage && ge_specialization && ge_recency && le_redundancy
      at_least_one_strictly_better = (@coverage > other.coverage) ||
                                     (@specialization > other.specialization) ||
                                     (@recency > other.recency) ||
                                     (@redundancy < other.redundancy)

      all_at_least_as_good && at_least_one_strictly_better
    end

    def to_h
      {
        acronym: @acronym,
        name: @name,
        coverage: @coverage.round(4),
        specialization: @specialization.round(4),
        recency: @recency.round(4),
        redundancy: @redundancy.round(4),
        license_spdx: @license_spdx,
        license_permissive: permissive_license?,
        pareto_rank: @pareto_rank,
        crowding_distance: @crowding_distance.round(6),
        composite_score: @composite_score.round(4),
        coverage_details: @coverage_details
      }
    end

    def as_json(options = nil)
      to_h.as_json(options)
    rescue NoMethodError
      to_h
    end

    private

    def determine_license_permissive(explicit_flag)
      return explicit_flag == true if explicit_flag == true || explicit_flag == false
      PERMISSIVE_LICENSES.include?(@license_spdx.upcase) || PERMISSIVE_LICENSES.include?(@license_spdx)
    end
  end
end
