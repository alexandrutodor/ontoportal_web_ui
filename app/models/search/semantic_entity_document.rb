# frozen_string_literal: true

module Search
  class SemanticEntityDocument
    attr_accessor :iri, :curie, :pref_label, :synonyms, :definition,
                  :ontology_acronym, :ontology_name, :obsolete,
                  :channel_scores, :channel_ranks, :rrf_score,
                  :matched_channels, :explanation

    def initialize(attributes = {})
      @iri = attributes[:iri] || attributes['iri']
      @curie = attributes[:curie] || attributes['curie']
      @pref_label = attributes[:pref_label] || attributes['pref_label'] || attributes[:prefLabel] || attributes['prefLabel'] || ''
      @synonyms = Array(attributes[:synonyms] || attributes['synonyms'] || attributes[:synonym] || attributes['synonym']).compact
      @definition = format_definition(attributes[:definition] || attributes['definition'])
      @ontology_acronym = attributes[:ontology_acronym] || attributes['ontology_acronym'] || attributes[:acronym] || attributes['acronym']
      @ontology_name = attributes[:ontology_name] || attributes['ontology_name']
      @obsolete = parse_boolean(attributes[:obsolete] || attributes['obsolete'])
      @channel_scores = (attributes[:channel_scores] || attributes['channel_scores'] || {}).transform_keys(&:to_sym)
      @channel_ranks = (attributes[:channel_ranks] || attributes['channel_ranks'] || {}).transform_keys(&:to_sym)
      @rrf_score = (attributes[:rrf_score] || attributes['rrf_score'] || 0.0).to_f
      @matched_channels = Array(attributes[:matched_channels] || attributes['matched_channels']).map(&:to_sym)
      @explanation = attributes[:explanation] || attributes['explanation'] || {}
    end

    def document_key
      "#{ontology_acronym}:#{iri}"
    end

    def obsolete?
      @obsolete == true
    end

    def register_channel_hit(channel, rank:, raw_score: 1.0)
      sym_channel = channel.to_sym
      @channel_ranks[sym_channel] = rank
      @channel_scores[sym_channel] = raw_score
      @matched_channels << sym_channel unless @matched_channels.include?(sym_channel)
    end

    def to_h
      {
        iri: @iri,
        curie: @curie,
        pref_label: @pref_label,
        synonyms: @synonyms,
        definition: @definition,
        ontology_acronym: @ontology_acronym,
        ontology_name: @ontology_name,
        obsolete: obsolete?,
        channel_scores: @channel_scores,
        channel_ranks: @channel_ranks,
        rrf_score: @rrf_score.round(6),
        matched_channels: @matched_channels,
        explanation: @explanation
      }
    end

    def as_json(options = nil)
      to_h.as_json(options)
    rescue NoMethodError
      to_h
    end

    private

    def format_definition(raw_def)
      case raw_def
      when Array
        raw_def.join(' ')
      when String
        raw_def
      else
        ''
      end
    end

    def parse_boolean(val)
      return false if val.nil?
      return true if val == true || val == 'true' || val == 1 || val == '1'
      false
    end
  end
end
