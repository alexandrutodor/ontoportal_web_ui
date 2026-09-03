# frozen_string_literal: true

require_relative 'ontology_evaluation'

module Recommender
  class ParetoFrontier
    OBJECTIVES = %i[coverage specialization recency].freeze

    # Perform Fast Non-Dominated Sorting (Deb et al., NSGA-II)
    # Returns an Array of Fronts: [ [eval1, eval2], [eval3], ... ]
    def self.non_dominated_sort(evaluations)
      return [] if evaluations.nil? || evaluations.empty?

      sp = Hash.new { |h, k| h[k] = [] } # Entities dominated by p
      np = Hash.new(0)                   # Number of entities dominating p
      fronts = [[]]

      evaluations.each do |p|
        evaluations.each do |q|
          next if p == q

          if p.dominates?(q)
            sp[p] << q
          elsif q.dominates?(p)
            np[p] += 1
          end
        end

        if np[p].zero?
          p.pareto_rank = 1
          fronts[0] << p
        end
      end

      current_front_idx = 0
      while fronts[current_front_idx]&.any?
        next_front = []
        fronts[current_front_idx].each do |p|
          sp[p].each do |q|
            np[q] -= 1
            if np[q].zero?
              q.pareto_rank = current_front_idx + 2
              next_front << q
            end
          end
        end
        current_front_idx += 1
        fronts << next_front if next_front.any?
      end

      # Assign crowding distance within each front
      fronts.each do |front|
        assign_crowding_distance(front)
        front.sort_by! { |eval_item| [-eval_item.crowding_distance, -eval_item.coverage] }
      end

      fronts
    end

    # Crowding distance assignment to maintain solution diversity
    def self.assign_crowding_distance(front)
      return if front.nil? || front.empty?

      size = front.size
      if size <= 2
        front.each { |item| item.crowding_distance = Float::INFINITY }
        return
      end

      front.each { |item| item.crowding_distance = 0.0 }

      %i[coverage specialization recency redundancy].each do |objective|
        sorted = front.sort_by { |item| item.send(objective) }
        min_val = sorted.first.send(objective)
        max_val = sorted.last.send(objective)
        range = (max_val - min_val).to_f

        sorted.first.crowding_distance = Float::INFINITY
        sorted.last.crowding_distance = Float::INFINITY

        next if range <= 0.000001

        (1...(size - 1)).each do |i|
          next if sorted[i].crowding_distance == Float::INFINITY

          prev_val = sorted[i - 1].send(objective)
          next_val = sorted[i + 1].send(objective)
          sorted[i].crowding_distance += (next_val - prev_val).abs / range
        end
      end
    end

    # Combinatorial set covering: Evaluates combinations of ontologies of size 2..max_set_size
    # evaluating trade-offs between combined coverage and redundancy
    def self.pareto_set_covering(evaluations, max_set_size: 3, min_individual_coverage: 0.05)
      candidates = evaluations.select { |e| e.coverage >= min_individual_coverage }
      return [] if candidates.size < 2

      # Cap candidate pool to top 15 by coverage to prevent combinatorial explosion
      pool = candidates.sort_by { |e| -e.coverage }.first(15)

      set_candidates = []

      (2..[max_set_size, pool.size].min).each do |set_size|
        pool.combination(set_size).each do |combo|
          # Compute union of covered concepts
          covered_concepts = combo.map { |e| (e.coverage_details[:covered_terms] || []) }.flatten.uniq
          raw_union_coverage = combo.map(&:coverage).max # Lower bound is best single coverage
          if covered_concepts.any?
            # If explicit covered_terms available, calculate exact union ratio
            total_terms = combo.map { |e| (e.coverage_details[:total_terms] || 0) }.max
            union_ratio = total_terms.positive? ? (covered_concepts.size.to_f / total_terms) : raw_union_coverage
          else
            # Probabilistic independent union approximation: 1 - prod(1 - cov_i)
            union_ratio = 1.0 - combo.map { |e| 1.0 - [e.coverage, 0.99].min }.inject(:*)
          end

          # Redundancy metric: sum of pairwise overlaps or sum(coverage) - union_coverage
          sum_cov = combo.map(&:coverage).sum
          redundancy_ratio = [sum_cov - union_ratio, 0.0].max

          mean_specialization = combo.map(&:specialization).sum / set_size.to_f
          all_permissive = combo.all?(&:permissive_license?)

          set_candidates << {
            ontologies: combo.map(&:acronym),
            combined_coverage: union_ratio.round(4),
            redundancy: redundancy_ratio.round(4),
            mean_specialization: mean_specialization.round(4),
            set_size: set_size,
            license_permissive: all_permissive
          }
        end
      end

      # Filter non-dominated sets: maximize combined_coverage, minimize redundancy, minimize set_size
      non_dominated_sets(set_candidates)
    end

    def self.non_dominated_sets(sets)
      return [] if sets.empty?

      non_dom = sets.reject do |s1|
        sets.any? do |s2|
          next if s1 == s2

          better_or_equal = (s2[:combined_coverage] >= s1[:combined_coverage]) &&
                            (s2[:redundancy] <= s1[:redundancy]) &&
                            (s2[:set_size] <= s1[:set_size])

          strictly_better = (s2[:combined_coverage] > s1[:combined_coverage]) ||
                            (s2[:redundancy] < s1[:redundancy]) ||
                            (s2[:set_size] < s1[:set_size])

          better_or_equal && strictly_better
        end
      end

      non_dom.sort_by { |s| [-s[:combined_coverage], s[:set_size], s[:redundancy]] }
    end
  end
end
