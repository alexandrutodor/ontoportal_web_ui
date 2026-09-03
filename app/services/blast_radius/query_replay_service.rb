# frozen_string_literal: true

module BlastRadius
  class QueryReplayService
    attr_reader :baseline_submission, :candidate_submission, :options

    def initialize(baseline_submission: nil, candidate_submission: nil, options: {})
      @baseline_submission  = baseline_submission
      @candidate_submission = candidate_submission
      @options              = options || {}
    end

    # Replay benchmark query suite against baseline vs candidate ontology
    # @param queries [Array<Hash>] optional custom query definitions
    # @return [Hash] { total: Integer, passed: Integer, failed: Integer, regressions: Array<Hash> }
    def replay(queries = nil)
      queries_to_run = queries || default_benchmark_suite
      regressions = []
      passed = 0
      failed = 0

      queries_to_run.each do |query|
        eval_result = evaluate_query(query)
        if eval_result[:passed]
          passed += 1
        else
          failed += 1
          regressions << eval_result[:regression]
        end
      end

      {
        total: queries_to_run.size,
        passed: passed,
        failed: failed,
        regressions: regressions
      }
    end

    private

    def default_benchmark_suite
      @options[:queries] || [
        {
          id: 'Q-ROOT-LOOKUP',
          type: :concept_lookup,
          description: 'Lookup foundational root concepts',
          target_iris: extract_sample_iris(@baseline_submission, :root)
        },
        {
          id: 'Q-LEAF-LOOKUP',
          type: :concept_lookup,
          description: 'Lookup high-frequency leaf concepts',
          target_iris: extract_sample_iris(@baseline_submission, :leaf)
        },
        {
          id: 'Q-SUBCLASS-CLOSURE',
          type: :subclass_hierarchy,
          description: 'Verify transitive subclass hierarchy consistency',
          parent_iri: extract_sample_parent(@baseline_submission)
        },
        {
          id: 'Q-DATASET-BINDING',
          type: :dataset_annotation,
          description: 'Validate downstream dataset annotation bindings',
          annotation_iris: extract_sample_iris(@baseline_submission, :annotated)
        }
      ]
    end

    def evaluate_query(query)
      case query[:type]
      when :concept_lookup
        evaluate_concept_lookup(query)
      when :subclass_hierarchy
        evaluate_subclass_hierarchy(query)
      when :keyword_search
        evaluate_keyword_search(query)
      when :dataset_annotation
        evaluate_dataset_annotation(query)
      else
        evaluate_generic_query(query)
      end
    end

    def evaluate_concept_lookup(query)
      target_iris = Array(query[:target_iris])
      missing_iris = []

      target_iris.each do |iri|
        next if concept_exists?(@candidate_submission, iri)
        missing_iris << iri
      end

      if missing_iris.empty?
        { passed: true }
      else
        {
          passed: false,
          regression: {
            query_id: query[:id],
            query_type: 'concept_lookup',
            description: query[:description],
            reason: "Target concept IRI(s) no longer present in candidate: #{missing_iris.join(', ')}",
            missing_iris: missing_iris,
            baseline_count: target_iris.size,
            candidate_count: target_iris.size - missing_iris.size
          }
        }
      end
    end

    def evaluate_subclass_hierarchy(query)
      parent_iri = query[:parent_iri]
      return { passed: true } if parent_iri.nil?

      baseline_subclasses = subclasses_for(@baseline_submission, parent_iri)
      candidate_subclasses = subclasses_for(@candidate_submission, parent_iri)

      dropped_subclasses = baseline_subclasses - candidate_subclasses

      if dropped_subclasses.empty?
        { passed: true }
      else
        {
          passed: false,
          regression: {
            query_id: query[:id],
            query_type: 'subclass_hierarchy',
            description: query[:description],
            reason: "Subclasses severed from parent '#{parent_iri}': #{dropped_subclasses.join(', ')}",
            parent_iri: parent_iri,
            dropped_subclasses: dropped_subclasses,
            baseline_count: baseline_subclasses.size,
            candidate_count: candidate_subclasses.size
          }
        }
      end
    end

    def evaluate_keyword_search(query)
      term = query[:term].to_s.downcase
      baseline_matches = search_concepts(@baseline_submission, term)
      candidate_matches = search_concepts(@candidate_submission, term)

      if baseline_matches.any? && candidate_matches.empty?
        {
          passed: false,
          regression: {
            query_id: query[:id],
            query_type: 'keyword_search',
            description: query[:description],
            reason: "Search for '#{term}' returned 0 matches in candidate (was #{baseline_matches.size} in baseline)",
            term: term,
            baseline_count: baseline_matches.size,
            candidate_count: candidate_matches.size
          }
        }
      else
        { passed: true }
      end
    end

    def evaluate_dataset_annotation(query)
      annotation_iris = Array(query[:annotation_iris])
      orphaned_iris = []

      annotation_iris.each do |iri|
        next if concept_exists?(@candidate_submission, iri)
        orphaned_iris << iri
      end

      if orphaned_iris.empty?
        { passed: true }
      else
        {
          passed: false,
          regression: {
            query_id: query[:id],
            query_type: 'dataset_annotation',
            description: query[:description],
            reason: "Downstream dataset annotations reference #{orphaned_iris.size} missing concept(s)",
            orphaned_iris: orphaned_iris,
            baseline_count: annotation_iris.size,
            candidate_count: annotation_iris.size - orphaned_iris.size
          }
        }
      end
    end

    def evaluate_generic_query(query)
      baseline_count = (query[:baseline_count] || 1).to_i
      candidate_count = (query[:candidate_count] || baseline_count).to_i

      if candidate_count < baseline_count
        {
          passed: false,
          regression: {
            query_id: query[:id],
            query_type: 'generic',
            description: query[:description] || 'Generic query benchmark',
            reason: "Result count drop: expected #{baseline_count}, got #{candidate_count}",
            baseline_count: baseline_count,
            candidate_count: candidate_count
          }
        }
      else
        { passed: true }
      end
    end

    # Graph/Concept inspection helpers with fallback for mock / array structures
    def concept_exists?(submission, iri)
      return false if iri.nil?
      return true if submission.nil? # if not provided, pass

      if submission.respond_to?(:concepts)
        concepts = submission.concepts
        if concepts.is_a?(Hash)
          concepts.key?(iri) || concepts.values.any? { |c| c.respond_to?(:id) && c.id == iri }
        elsif concepts.is_a?(Array)
          concepts.any? { |c| c.is_a?(String) ? c == iri : (c.respond_to?(:id) && c.id == iri) }
        else
          true
        end
      elsif submission.is_a?(Hash)
        concepts = submission[:concepts] || submission['concepts'] || []
        concepts.include?(iri) || concepts.any? { |c| c.is_a?(Hash) && (c[:id] == iri || c['id'] == iri) }
      else
        true
      end
    end

    def subclasses_for(submission, parent_iri)
      return [] if submission.nil? || parent_iri.nil?

      if submission.respond_to?(:subclasses_for)
        submission.subclasses_for(parent_iri)
      elsif submission.is_a?(Hash)
        hierarchy = submission[:hierarchy] || submission['hierarchy'] || {}
        Array(hierarchy[parent_iri])
      else
        []
      end
    end

    def search_concepts(submission, term)
      return [] if submission.nil? || term.to_s.strip.empty?

      if submission.respond_to?(:search)
        submission.search(term)
      elsif submission.is_a?(Hash)
        concepts = submission[:concepts] || submission['concepts'] || []
        concepts.select { |c| c.to_s.downcase.include?(term) }
      else
        []
      end
    end

    def extract_sample_iris(submission, type)
      return [] if submission.nil?

      if submission.is_a?(Hash)
        all_concepts = submission[:concepts] || submission['concepts'] || []
        iris = all_concepts.map { |c| c.is_a?(Hash) ? (c[:id] || c['id']) : c.to_s }
        return iris.first(3) if type == :root
        return iris.last(3) if type == :leaf
        iris.sample(2)
      elsif submission.respond_to?(:sample_iris)
        submission.sample_iris(type)
      else
        []
      end
    end

    def extract_sample_parent(submission)
      return nil if submission.nil?

      if submission.is_a?(Hash)
        hierarchy = submission[:hierarchy] || submission['hierarchy'] || {}
        hierarchy.keys.first
      elsif submission.respond_to?(:sample_parent)
        submission.sample_parent
      else
        nil
      end
    end
  end
end
