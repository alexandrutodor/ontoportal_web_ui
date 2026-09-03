# frozen_string_literal: true

require_relative '../../models/recommender/ontology_evaluation'
require_relative '../../models/recommender/pareto_frontier'

module Recommender
  class ParetoRecommenderService
    attr_reader :input, :ontologies, :options, :license_filter

    def initialize(input:, ontologies: nil, license_filter: nil, options: {})
      @input = (input || '').to_s.strip
      @ontologies = normalize_ontologies(ontologies)
      @license_filter = license_filter&.to_s&.strip&.downcase
      @options = options || {}
    end

    def self.call(input:, **kwargs)
      new(input: input, **kwargs).execute
    end

    def execute
      return empty_result if @input.empty?

      # 1. Obtain candidate evaluations from provider or API client
      raw_evaluations = retrieve_evaluations

      # 2. Filter by ontology scope if specified
      if @ontologies&.any?
        raw_evaluations.select! { |e| @ontologies.include?(e.acronym) }
      end

      total_candidates = raw_evaluations.size

      # 3. Apply SPDX / license hard-gate if requested
      gated_evaluations = apply_license_gate(raw_evaluations)
      license_gated_count = total_candidates - gated_evaluations.size

      # 4. Perform Pareto Non-Dominated Sorting
      fronts = ParetoFrontier.non_dominated_sort(gated_evaluations)
      frontier = fronts.first || []

      # 5. Calculate multi-ontology Pareto set cover if requested
      sets = []
      if @options[:output_type] == 'set' || @options[:include_sets] == true
        max_set = (@options[:max_elements_set] || 3).to_i
        sets = ParetoFrontier.pareto_set_covering(gated_evaluations, max_set_size: max_set)
      end

      {
        input: @input,
        license_filter: @license_filter,
        total_evaluated: total_candidates,
        license_gated_count: license_gated_count,
        frontier: frontier,
        fronts: fronts,
        sets: sets,
        all_evaluations: fronts.flatten
      }
    end

    private

    def empty_result
      {
        input: @input,
        license_filter: @license_filter,
        total_evaluated: 0,
        license_gated_count: 0,
        frontier: [],
        fronts: [],
        sets: [],
        all_evaluations: []
      }
    end

    def normalize_ontologies(onts)
      return nil if onts.nil?
      case onts
      when Array
        onts.map(&:to_s).reject(&:empty?)
      when String
        onts.split(',').map(&:strip).reject(&:empty?)
      else
        nil
      end
    end

    def apply_license_gate(evaluations)
      return evaluations unless @license_filter == 'permissive' || @options[:require_permissive_license] == true

      evaluations.select(&:permissive_license?)
    end

    def retrieve_evaluations
      if @options[:evaluations_provider].respond_to?(:call)
        return @options[:evaluations_provider].call(@input, ontologies: @ontologies)
      end

      # Integration with LinkedData::Client recommender endpoint when in Rails runtime
      if defined?(LinkedData::Client::HTTP)
        begin
          form_data = {
            'input' => @input,
            'input_type' => @options[:input_type] || 'text',
            'output_type' => 'individual'
          }
          form_data['ontologies'] = @ontologies.join(',') if @ontologies&.any?

          response = LinkedData::Client::HTTP.post('/recommender', form_data, raw: false)
          return transform_api_response(response) if response.is_a?(Array)
        rescue StandardError
          # Fallback to local heuristic estimation
        end
      end

      # Heuristic keyword-matching evaluation fallback for offline/isolated execution
      heuristic_evaluations
    end

    def transform_api_response(api_items)
      api_items.map do |item|
        acronym = item.ontologies&.first&.acronym rescue nil
        name = item.ontologies&.first&.name rescue acronym
        coverage = (item.coverageResult&.normalizedScore || item.coverageScore || 0.0).to_f
        specialization = (item.specializationResult&.normalizedScore || item.specializationScore || 0.0).to_f
        recency = (item.acceptanceResult&.normalizedScore || item.acceptanceScore || 0.5).to_f
        redundancy = (item.detailResult&.normalizedScore || 0.0).to_f

        OntologyEvaluation.new(
          acronym: acronym,
          name: name,
          coverage: coverage,
          specialization: specialization,
          recency: recency,
          redundancy: redundancy,
          license_spdx: extract_license_from_item(item)
        )
      end.compact
    end

    def extract_license_from_item(item)
      # Check metadata or fallback to CC-BY-4.0 / UNKNOWN
      (item.ontologies&.first&.license rescue nil) || 'CC-BY-4.0'
    end

    def heuristic_evaluations
      # Mock/heuristic generator for test and offline environments
      words = @input.downcase.scan(/\b[a-z]{3,}\b/).uniq
      sample_onts = [
        { acronym: 'CHEBI', name: 'Chemical Entities of Biological Interest', license: 'CC-BY-4.0' },
        { acronym: 'GO', name: 'Gene Ontology', license: 'CC-BY-4.0' },
        { acronym: 'PROV', name: 'PROV Ontology', license: 'CC0-1.0' },
        { acronym: 'BFO', name: 'Basic Formal Ontology', license: 'CC0-1.0' },
        { acronym: 'MATP', name: 'Materials Science Core', license: 'MIT' },
        { acronym: 'PROPR', name: 'Proprietary Industry Ontology', license: 'Proprietary' }
      ]

      sample_onts.map do |ont|
        seed = ont[:acronym].bytes.sum
        # Deterministic scores based on words and seed
        coverage = [((words.size * 0.15) + ((seed % 10) * 0.05)), 0.95].min
        specialization = [(((seed % 7) + 3) * 0.1), 0.98].min
        recency = [(((seed % 5) + 5) * 0.1), 0.99].min
        redundancy = [(((seed % 4) + 1) * 0.08), 0.5].min

        OntologyEvaluation.new(
          acronym: ont[:acronym],
          name: ont[:name],
          coverage: coverage.round(4),
          specialization: specialization.round(4),
          recency: recency.round(4),
          redundancy: redundancy.round(4),
          license_spdx: ont[:license]
        )
      end
    end
  end
end
