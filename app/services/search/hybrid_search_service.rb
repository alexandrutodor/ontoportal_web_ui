# frozen_string_literal: true

require_relative '../../models/search/semantic_entity_document'

module Search
  class HybridSearchService
    DEFAULT_K = 60
    DEFAULT_WEIGHTS = {
      curie_exact: 1.2,
      bm25: 1.0,
      vector_similarity: 1.0,
      mapping_expansion: 0.8
    }.freeze
    OBSOLETE_DISCOUNT = 0.5

    attr_reader :query, :ontologies, :slice, :k, :weights, :options

    def initialize(query:, ontologies: nil, slice: nil, k: DEFAULT_K, weights: nil, options: {})
      @query = (query || '').to_s.strip
      @ontologies = normalize_ontologies(ontologies)
      @slice = slice
      @k = (k || DEFAULT_K).to_i
      @weights = DEFAULT_WEIGHTS.merge((weights || {}).transform_keys(&:to_sym))
      @options = options || {}
    end

    def self.call(query:, **kwargs)
      new(query: query, **kwargs).execute
    end

    def execute
      return empty_response if @query.empty?

      # Multi-channel candidate retrieval with error isolation
      channel_results = {
        curie_exact: retrieve_curie_exact,
        bm25: retrieve_bm25,
        vector_similarity: retrieve_vector_similarity,
        mapping_expansion: retrieve_mapping_expansion
      }

      fused_documents = fuse_ranks(channel_results)
      filtered_documents = apply_scope_filters(fused_documents)
      ranked_documents = sort_and_penalize(filtered_documents)

      {
        query: @query,
        k: @k,
        weights: @weights,
        total_results: ranked_documents.size,
        channel_counts: channel_results.transform_values(&:size),
        results: ranked_documents
      }
    end

    private

    def empty_response
      {
        query: @query,
        k: @k,
        weights: @weights,
        total_results: 0,
        channel_counts: { curie_exact: 0, bm25: 0, vector_similarity: 0, mapping_expansion: 0 },
        results: []
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

    # Channel 1: Exact CURIE / IRI match
    def retrieve_curie_exact
      results = []
      return results unless curie_or_iri?(@query)

      if @options[:curie_provider].respond_to?(:call)
        results = @options[:curie_provider].call(@query, ontologies: @ontologies)
      elsif defined?(LinkedData::Client::Models::Class) && LinkedData::Client::Models::Class.respond_to?(:find)
        begin
          acronym, class_id = split_curie(@query)
          if acronym && class_id && (@ontologies.nil? || @ontologies.include?(acronym))
            cls = LinkedData::Client::Models::Class.find(class_id, ontology: acronym)
            if cls && !cls.errors?
              results << doc_from_client_class(cls, acronym)
            end
          end
        rescue StandardError
          # Graceful degradation
        end
      end

      results
    rescue StandardError
      []
    end

    # Channel 2: BM25 / Solr lexical query
    def retrieve_bm25
      results = []
      if @options[:bm25_provider].respond_to?(:call)
        results = @options[:bm25_provider].call(@query, ontologies: @ontologies)
      elsif defined?(LinkedData::Client::Models::Class) && LinkedData::Client::Models::Class.respond_to?(:search)
        begin
          search_params = { q: @query }
          search_params[:ontologies] = @ontologies.join(',') if @ontologies&.any?
          search_page = LinkedData::Client::Models::Class.search(@query, search_params)
          if search_page&.collection
            results = search_page.collection.map do |item|
              doc_from_client_class(item, item.explore&.ontology&.acronym)
            end
          end
        rescue StandardError
          # Graceful degradation
        end
      end
      results
    rescue StandardError
      []
    end

    # Channel 3: Dense vector semantic similarity
    def retrieve_vector_similarity
      results = []
      if @options[:vector_provider].respond_to?(:call)
        results = @options[:vector_provider].call(@query, ontologies: @ontologies)
      elsif @options[:vector_index].respond_to?(:nearest)
        begin
          results = @options[:vector_index].nearest(@query, limit: 30, ontologies: @ontologies)
        rescue StandardError
          # Graceful degradation
        end
      else
        # Fallback pseudo-dense matching via character n-gram / jaccard similarity
        results = fallback_text_similarity
      end
      results
    rescue StandardError
      []
    end

    # Channel 4: SSSOM / certified mapping expansion
    def retrieve_mapping_expansion
      results = []
      if @options[:mapping_provider].respond_to?(:call)
        results = @options[:mapping_provider].call(@query, ontologies: @ontologies)
      elsif defined?(LinkedData::Client::Models::Mapping) && LinkedData::Client::Models::Mapping.respond_to?(:find)
        begin
          # Optional client mapping retrieval
        rescue StandardError
          # Graceful degradation
        end
      end
      results
    rescue StandardError
      []
    end

    # Fuse channel hits using Reciprocal Rank Fusion (RRF k=60)
    # RRF(d) = sum_{c in C} w_c / (k + rank_c(d))
    def fuse_ranks(channel_results)
      documents_by_key = {}

      channel_results.each do |channel, docs|
        weight = @weights[channel] || 1.0

        docs.each_with_index do |item, index|
          doc = item.is_a?(SemanticEntityDocument) ? item : SemanticEntityDocument.new(item)
          key = doc.document_key
          rank = index + 1

          existing_doc = documents_by_key[key]
          if existing_doc
            existing_doc.register_channel_hit(channel, rank: rank)
            channel_rrf = weight / (@k + rank)
            existing_doc.rrf_score += channel_rrf
            existing_doc.explanation[channel] = {
              rank: rank,
              weight: weight,
              rrf_component: channel_rrf.round(6)
            }
          else
            doc.register_channel_hit(channel, rank: rank)
            channel_rrf = weight / (@k + rank)
            doc.rrf_score = channel_rrf
            doc.explanation[channel] = {
              rank: rank,
              weight: weight,
              rrf_component: channel_rrf.round(6)
            }
            documents_by_key[key] = doc
          end
        end
      end

      documents_by_key.values
    end

    def apply_scope_filters(documents)
      documents.select do |doc|
        match_ontology = @ontologies.nil? || @ontologies.empty? || @ontologies.include?(doc.ontology_acronym)
        match_slice = @slice.nil? || doc.ontology_acronym.to_s.casecmp(@slice.to_s).zero?
        match_ontology && match_slice
      end
    end

    def sort_and_penalize(documents)
      documents.each do |doc|
        if doc.obsolete?
          doc.explanation[:obsolete_penalty] = OBSOLETE_DISCOUNT
          doc.rrf_score *= (1.0 - OBSOLETE_DISCOUNT)
        end
      end

      documents.sort_by { |d| [-d.rrf_score, d.pref_label.to_s.downcase] }
    end

    def curie_or_iri?(q)
      return true if q.start_with?('http://', 'https://', 'urn:')
      return true if q.match?(/\A[A-Za-z0-9_\-\.]+:[A-Za-z0-9_\-\.]+\z/)
      false
    end

    def split_curie(curie)
      parts = curie.split(':', 2)
      return [nil, nil] unless parts.size == 2
      [parts[0].upcase, parts[1]]
    end

    def doc_from_client_class(cls, acronym)
      curie_id = cls.id.to_s.split('/').last rescue cls.id.to_s
      SemanticEntityDocument.new(
        iri: cls.id,
        curie: "#{acronym}:#{curie_id}",
        pref_label: cls.prefLabel || cls.id,
        synonyms: cls.synonym || [],
        definition: cls.definition || [],
        ontology_acronym: acronym,
        obsolete: cls.respond_to?(:obsolete?) ? cls.obsolete? : false
      )
    end

    def fallback_text_similarity
      # When no explicit vector provider is supplied, return empty array (pure lexical fallback)
      []
    end
  end
end
