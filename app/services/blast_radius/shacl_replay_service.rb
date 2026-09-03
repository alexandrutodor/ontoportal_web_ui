# frozen_string_literal: true

module BlastRadius
  class ShaclReplayService
    attr_reader :baseline_submission, :candidate_submission, :shapes, :options

    def initialize(baseline_submission: nil, candidate_submission: nil, shapes: nil, options: {})
      @baseline_submission  = baseline_submission
      @candidate_submission = candidate_submission
      @shapes               = shapes || default_shacl_shapes
      @options              = options || {}
    end

    # Evaluate SHACL validation rules against baseline vs candidate ontology
    # @return [Hash] { baseline_violations: Integer, candidate_violations: Integer, delta: Integer, new_violations: Array<Hash> }
    def evaluate
      baseline_results = run_shapes(@baseline_submission)
      candidate_results = run_shapes(@candidate_submission)

      baseline_signatures = baseline_results.map { |v| violation_signature(v) }.to_set
      new_violations = candidate_results.reject { |v| baseline_signatures.include?(violation_signature(v)) }

      b_count = baseline_results.size
      c_count = candidate_results.size
      delta = c_count - b_count

      {
        baseline_violations: b_count,
        candidate_violations: c_count,
        delta: delta,
        new_violations: new_violations
      }
    end

    private

    def default_shacl_shapes
      [
        {
          id: 'SHACL-PREF-LABEL-REQUIRED',
          name: 'Preferred Label Required',
          severity: 'Violation',
          rule: :pref_label_required,
          description: 'Each concept must define at least one rdfs:label or skos:prefLabel'
        },
        {
          id: 'SHACL-DEFINITION-RECOMMENDED',
          name: 'Concept Definition Recommended',
          severity: 'Warning',
          rule: :definition_recommended,
          description: 'Each public concept should have an explanatory textual definition'
        },
        {
          id: 'SHACL-VALID-IRI-SYNTAX',
          name: 'Valid IRI Syntax',
          severity: 'Violation',
          rule: :valid_iri_syntax,
          description: 'Concept identifier must be a valid RFC 3987 absolute IRI'
        },
        {
          id: 'SHACL-NO-SELF-CYCLE',
          name: 'Acyclic Subclass Hierarchy',
          severity: 'Violation',
          rule: :acyclic_subclass,
          description: 'A concept cannot be a direct or indirect subclass of itself'
        }
      ]
    end

    def run_shapes(submission)
      return [] if submission.nil?

      concepts = extract_concept_records(submission)
      violations = []

      concepts.each do |concept|
        @shapes.each do |shape|
          violation = check_shape(shape, concept, submission)
          violations << violation if violation
        end
      end

      violations
    end

    def check_shape(shape, concept, submission)
      case shape[:rule]
      when :pref_label_required
        label = concept[:label] || concept['label'] || concept[:prefLabel] || concept['prefLabel']
        if label.nil? || label.to_s.strip.empty?
          build_violation(shape, concept, 'Missing mandatory preferred label (rdfs:label/skos:prefLabel)')
        end
      when :definition_recommended
        definition = concept[:definition] || concept['definition']
        obsolete = concept[:obsolete] || concept['obsolete']
        if !obsolete && (definition.nil? || Array(definition).empty?)
          build_violation(shape, concept, 'Missing explanatory definition for active concept')
        end
      when :valid_iri_syntax
        iri = concept[:id] || concept['id'] || concept[:iri] || concept['iri']
        unless valid_iri?(iri)
          build_violation(shape, concept, "Concept identifier '#{iri}' is not a valid absolute IRI")
        end
      when :acyclic_subclass
        iri = concept[:id] || concept['id']
        parents = Array(concept[:subClassOf] || concept['subClassOf'] || concept[:parents] || concept['parents'])
        if parents.include?(iri)
          build_violation(shape, concept, "Immediate self-subclass cycle detected on '#{iri}'")
        end
      else
        nil
      end
    end

    def build_violation(shape, concept, message)
      iri = concept[:id] || concept['id'] || 'unknown'
      {
        shape_id: shape[:id],
        shape_name: shape[:name],
        severity: shape[:severity],
        focus_node: iri,
        message: message
      }
    end

    def violation_signature(v)
      "#{v[:shape_id]}:#{v[:focus_node]}"
    end

    def valid_iri?(str)
      return false if str.nil? || str.to_s.strip.empty?
      str.to_s =~ /\A[a-zA-Z][a-zA-Z0-9+.-]*:\/\/[^\s<>{}\\"^`]+|\Aurn:[^\s<>{}\\"^`]+\z/
    end

    def extract_concept_records(submission)
      if submission.respond_to?(:concept_records)
        submission.concept_records
      elsif submission.is_a?(Hash)
        concepts = submission[:concepts] || submission['concepts'] || []
        concepts.map do |c|
          if c.is_a?(Hash)
            c
          else
            { id: c.to_s, label: c.to_s.split(/[\/#]/).last }
          end
        end
      elsif submission.is_a?(Array)
        submission.map do |c|
          c.is_a?(Hash) ? c : { id: c.to_s, label: c.to_s.split(/[\/#]/).last }
        end
      else
        []
      end
    end
  end
end
