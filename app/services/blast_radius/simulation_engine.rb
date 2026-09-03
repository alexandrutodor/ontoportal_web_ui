# frozen_string_literal: true

require 'fileutils'
require 'json'
require_relative 'query_replay_service'
require_relative 'shacl_replay_service'

module BlastRadius
  class SimulationEngine
    @memory_store = {}

    class << self
      attr_accessor :memory_store

      def simulate(ontology_acronym:, baseline_submission: nil, candidate_submission: nil, external_mappings: [], options: {})
        new(
          ontology_acronym: ontology_acronym,
          baseline_submission: baseline_submission,
          candidate_submission: candidate_submission,
          external_mappings: external_mappings,
          options: options
        ).execute
      end

      SAFE_ID_PATTERN = /\A[0-9a-zA-Z_-]{1,64}\z/.freeze

      def valid_report_id?(report_id)
        id_str = report_id.to_s
        !id_str.empty? && id_str.match?(SAFE_ID_PATTERN) && !id_str.include?('..')
      end

      def find_report(report_id)
        id_str = report_id.to_s.strip
        return nil unless valid_report_id?(id_str)

        report = @memory_store[id_str]
        return report if report

        # Fallback to disk store
        storage_file = storage_path_for(id_str)
        return nil unless storage_file && File.exist?(storage_file)

        raw = JSON.parse(File.read(storage_file))
        report = BlastRadiusReport.from_h(raw)
        @memory_store[id_str] = report
        report
      rescue StandardError
        nil
      end

      def latest_report(ontology_acronym)
        return nil if ontology_acronym.nil?
        reports = @memory_store.values.select { |r| r.ontology_acronym.to_s.downcase == ontology_acronym.to_s.downcase }
        reports.max_by { |r| r.created_at.to_s }
      end

      def store_report(report)
        @memory_store[report.id.to_s] = report
        save_to_disk(report)
        report
      end

      def clear_store!
        @memory_store.clear
      end

      private

      def storage_dir
        dir = defined?(Rails) && Rails.respond_to?(:root) ? Rails.root.join('tmp', 'blast_radius') : File.join(Dir.tmpdir, 'blast_radius')
        FileUtils.mkdir_p(dir) unless File.directory?(dir)
        dir
      end

      def storage_path_for(report_id)
        safe_id = File.basename(report_id.to_s)
        return nil unless valid_report_id?(safe_id)
        File.join(storage_dir, "#{safe_id}.json")
      end

      def save_to_disk(report)
        path = storage_path_for(report.id)
        return unless path
        File.write(path, report.to_json)
      rescue StandardError => e
        # Best effort persistence; memory store retains report
        warn "[BlastRadius::SimulationEngine] Disk write failed for #{report.id}: #{e.message}"
      end
    end

    attr_reader :ontology_acronym, :baseline_submission, :candidate_submission, :external_mappings, :options

    def initialize(ontology_acronym:, baseline_submission: nil, candidate_submission: nil, external_mappings: [], options: {})
      @ontology_acronym     = ontology_acronym
      @baseline_submission  = baseline_submission
      @candidate_submission = candidate_submission
      @external_mappings    = Array(external_mappings)
      @options              = options || {}
    end

    def execute
      concept_churn = compute_concept_churn
      orphaned_mappings = detect_orphaned_mappings(concept_churn[:removed], concept_churn[:obsoleted])
      query_results = replay_queries
      shacl_results = evaluate_shacl
      policy_violations = check_policy_rules
      logical_errors = check_logical_consistency

      report = BlastRadiusReport.new(
        ontology_acronym: @ontology_acronym,
        baseline_submission_id: extract_submission_id(@baseline_submission),
        candidate_submission_id: extract_submission_id(@candidate_submission),
        concept_churn: concept_churn,
        orphaned_mappings: orphaned_mappings,
        broken_queries: query_results[:regressions],
        shacl_violation_delta: shacl_results,
        policy_violations: policy_violations,
        logical_errors: logical_errors,
        metadata: {
          queries_total: query_results[:total],
          queries_passed: query_results[:passed],
          queries_failed: query_results[:failed],
          simulation_mode: @options[:simulation_mode] || 'digital_twin_shadow',
          curator: @options[:curator] || 'system'
        }
      )

      self.class.store_report(report)
      report
    end

    private

    def compute_concept_churn
      baseline_map = extract_concept_map(@baseline_submission)
      candidate_map = extract_concept_map(@candidate_submission)

      baseline_iris = baseline_map.keys.to_set
      candidate_iris = candidate_map.keys.to_set

      added_iris = (candidate_iris - baseline_iris).to_a
      removed_iris = (baseline_iris - candidate_iris).to_a

      obsoleted_iris = []
      modified_iris = []

      common_iris = baseline_iris & candidate_iris
      common_iris.each do |iri|
        base_item = baseline_map[iri]
        cand_item = candidate_map[iri]

        base_obs = item_obsolete?(base_item)
        cand_obs = item_obsolete?(cand_item)

        if !base_obs && cand_obs
          obsoleted_iris << iri
        elsif items_differ?(base_item, cand_item)
          modified_iris << iri
        end
      end

      {
        added: added_iris,
        removed: removed_iris,
        obsoleted: obsoleted_iris,
        modified: modified_iris
      }
    end

    def detect_orphaned_mappings(removed_iris, obsoleted_iris)
      removed_set = Array(removed_iris).to_set
      obsoleted_set = Array(obsoleted_iris).to_set
      orphaned = []

      @external_mappings.each do |mapping|
        from_concept = extract_mapping_concept(mapping, :from)
        to_concept = extract_mapping_concept(mapping, :to)
        relation = extract_mapping_relation(mapping)
        mapping_id = extract_mapping_id(mapping)

        if removed_set.include?(from_concept) || removed_set.include?(to_concept)
          orphaned << {
            mapping_id: mapping_id,
            from_concept: from_concept,
            to_concept: to_concept,
            relation: relation,
            reason: 'Concept removed in candidate ontology release'
          }
        elsif obsoleted_set.include?(from_concept) || obsoleted_set.include?(to_concept)
          orphaned << {
            mapping_id: mapping_id,
            from_concept: from_concept,
            to_concept: to_concept,
            relation: relation,
            reason: 'Concept obsoleted in candidate ontology release'
          }
        end
      end

      orphaned
    end

    def replay_queries
      service = BlastRadius::QueryReplayService.new(
        baseline_submission: @baseline_submission,
        candidate_submission: @candidate_submission,
        options: @options
      )
      service.replay(@options[:benchmark_queries])
    end

    def evaluate_shacl
      service = BlastRadius::ShaclReplayService.new(
        baseline_submission: @baseline_submission,
        candidate_submission: @candidate_submission,
        shapes: @options[:shacl_shapes],
        options: @options
      )
      service.evaluate
    end

    def check_policy_rules
      violations = []

      # 1. License Check
      if @options[:require_license] || @options[:enforce_spdx]
        cand_license = extract_license(@candidate_submission)
        if cand_license.nil? || cand_license.to_s.strip.empty?
          violations << 'Candidate ontology submission lacks a declared SPDX / open access license.'
        end
      end

      # 2. Base URI / Namespace drift check
      if @options[:expected_base_uri]
        cand_base = extract_base_uri(@candidate_submission)
        if cand_base && !cand_base.start_with?(@options[:expected_base_uri].to_s)
          violations << "Candidate base URI '#{cand_base}' diverges from approved namespace '#{@options[:expected_base_uri]}'."
        end
      end

      violations
    end

    def check_logical_consistency
      errors = []

      # Syntax or cycle flags passed in options or detected on submission
      if @options[:syntax_error]
        errors << "OWL/RDF syntax parse error: #{@options[:syntax_error]}"
      end

      if @options[:unsatisfiable_classes]&.any?
        errors << "OWL reasoner detected #{Array(@options[:unsatisfiable_classes]).size} unsatisfiable classes (inconsistent TBox)."
      end

      if @candidate_submission.respond_to?(:logical_errors) && @candidate_submission.logical_errors.any?
        errors.concat(@candidate_submission.logical_errors)
      end

      errors
    end

    def extract_concept_map(submission)
      return {} if submission.nil?

      if submission.respond_to?(:concept_map)
        submission.concept_map
      elsif submission.is_a?(Hash)
        concepts = submission[:concepts] || submission['concepts'] || []
        map = {}
        concepts.each do |c|
          if c.is_a?(Hash)
            id = c[:id] || c['id'] || c[:iri] || c['iri']
            map[id] = c if id
          else
            map[c.to_s] = { id: c.to_s, label: c.to_s.split(/[\/#]/).last }
          end
        end
        map
      elsif submission.is_a?(Array)
        map = {}
        submission.each do |c|
          if c.is_a?(Hash)
            id = c[:id] || c['id']
            map[id] = c if id
          else
            map[c.to_s] = { id: c.to_s, label: c.to_s.split(/[\/#]/).last }
          end
        end
        map
      else
        {}
      end
    end

    def item_obsolete?(item)
      return false if item.nil?
      item[:obsolete] || item['obsolete'] || item[:deprecated] || item['deprecated'] || false
    end

    def items_differ?(a, b)
      return false if a.nil? || b.nil?
      label_a = a[:label] || a['label'] || a[:prefLabel] || a['prefLabel']
      label_b = b[:label] || b['label'] || b[:prefLabel] || b['prefLabel']
      label_a != label_b
    end

    def extract_mapping_concept(mapping, direction)
      if mapping.is_a?(Hash)
        key = direction == :from ? [:from_concept, 'from_concept', :source, 'source'] : [:to_concept, 'to_concept', :target, 'target']
        key.each do |k|
          return mapping[k] if mapping.key?(k)
        end
        nil
      elsif mapping.respond_to?(direction == :from ? :from_concept : :to_concept)
        mapping.send(direction == :from ? :from_concept : :to_concept)
      else
        nil
      end
    end

    def extract_mapping_relation(mapping)
      if mapping.is_a?(Hash)
        mapping[:relation] || mapping['relation'] || 'skos:exactMatch'
      elsif mapping.respond_to?(:relation)
        mapping.relation
      else
        'skos:exactMatch'
      end
    end

    def extract_mapping_id(mapping)
      if mapping.is_a?(Hash)
        mapping[:id] || mapping['id'] || SecureRandom.hex(4)
      elsif mapping.respond_to?(:id)
        mapping.id
      else
        SecureRandom.hex(4)
      end
    end

    def extract_submission_id(sub)
      return nil if sub.nil?
      if sub.respond_to?(:submissionId)
        sub.submissionId
      elsif sub.respond_to?(:id)
        sub.id
      elsif sub.is_a?(Hash)
        sub[:submission_id] || sub['submission_id'] || sub[:id] || sub['id']
      else
        sub.to_s
      end
    end

    def extract_license(sub)
      return nil if sub.nil?
      if sub.respond_to?(:hasLicense)
        sub.hasLicense
      elsif sub.is_a?(Hash)
        sub[:hasLicense] || sub['hasLicense'] || sub[:license] || sub['license']
      else
        nil
      end
    end

    def extract_base_uri(sub)
      return nil if sub.nil?
      if sub.respond_to?(:URI)
        sub.URI
      elsif sub.is_a?(Hash)
        sub[:URI] || sub['URI'] || sub[:base_uri] || sub['base_uri']
      else
        nil
      end
    end
  end
end
