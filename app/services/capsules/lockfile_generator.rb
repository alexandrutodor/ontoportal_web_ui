# frozen_string_literal: true

require 'digest'
require 'json'
require 'yaml'
require 'time'

module Capsules
  class LockfileGenerator
    SCHEMA_VERSION = 'semantic.lock/v1'

    attr_reader :capsule

    def initialize(capsule_or_attrs)
      @capsule = if capsule_or_attrs.is_a?(SemanticCapsule)
                   capsule_or_attrs
                 else
                   SemanticCapsule.new(capsule_or_attrs)
                 end
    end

    def add_ontology(attrs = {})
      ont = attrs.is_a?(Hash) ? attrs.transform_keys(&:to_s) : attrs
      ont['sha256'] ||= 'sha256:' + Digest::SHA256.hexdigest(ont['content'] || ont['acronym'].to_s)
      capsule.ontologies << ont
      self
    end

    def add_shape(attrs = {})
      shp = attrs.is_a?(Hash) ? attrs.transform_keys(&:to_s) : attrs
      shp['sha256'] ||= 'sha256:' + Digest::SHA256.hexdigest(shp['content'] || shp['name'].to_s)
      capsule.shapes << shp
      self
    end

    def add_mapping(attrs = {})
      map = attrs.is_a?(Hash) ? attrs.transform_keys(&:to_s) : attrs
      capsule.mappings << map
      self
    end

    def add_embedding(attrs = {})
      emb = attrs.is_a?(Hash) ? attrs.transform_keys(&:to_s) : attrs
      capsule.embeddings << emb
      self
    end

    def generate
      manifest = {
        'schema_version' => SCHEMA_VERSION,
        'capsule' => build_capsule_section,
        'ontologies' => build_ontologies_section,
        'shapes' => build_shapes_section,
        'mappings' => build_mappings_section,
        'embeddings' => build_embeddings_section
      }

      digest = self.class.compute_digest(manifest)

      manifest['integrity'] = {
        'manifest_digest' => digest,
        'algorithm' => 'sha256',
        'generated_at' => Time.now.utc.iso8601
      }

      manifest
    end

    def to_yaml
      YAML.dump(generate)
    end

    def to_json(opts = { indent: '  ' })
      JSON.pretty_generate(generate, opts)
    end

    # Deterministic canonicalization for cryptographic reproducibility
    def self.canonicalize(obj)
      case obj
      when Hash
        sorted_hash = {}
        obj.keys.map(&:to_s).sort.each do |key|
          value = obj.key?(key) ? obj[key] : obj[key.to_sym]
          sorted_hash[key] = canonicalize(value)
        end
        sorted_hash
      when Array
        obj.map { |item| canonicalize(item) }
      else
        obj
      end
    end

    # Compute canonical SHA-256 digest of payload excluding integrity section
    def self.compute_digest(manifest)
      data_to_hash = manifest.reject { |k, _| k.to_s == 'integrity' }
      canonical_data = canonicalize(data_to_hash)
      json_canonical = JSON.generate(canonical_data)
      "sha256:#{Digest::SHA256.hexdigest(json_canonical)}"
    end

    # Utility method to compute SHA-256 checksum of raw content or files
    def self.digest_content(content)
      "sha256:#{Digest::SHA256.hexdigest(content.to_s)}"
    end

    def self.digest_file(filepath)
      return nil unless File.exist?(filepath)

      sha = Digest::SHA256.file(filepath).hexdigest
      "sha256:#{sha}"
    end

    private

    def build_capsule_section
      {
        'id' => capsule.id,
        'name' => capsule.name,
        'version' => capsule.version,
        'description' => capsule.description,
        'author' => capsule.author,
        'created_at' => capsule.created_at,
        'generator' => capsule.generator
      }
    end

    def build_ontologies_section
      (capsule.locked_ontologies || []).map do |ont|
        ont = ont.transform_keys(&:to_s) if ont.respond_to?(:transform_keys)
        raw_sha = ont['sha256']
        raw_sha ||= Digest::SHA256.hexdigest(ont['content'] || ont['iri'] || ont['uri'] || ont['acronym'].to_s)
        {
          'acronym' => ont['acronym'],
          'iri' => ont['iri'] || ont['uri'],
          'submission_id' => ont['submission_id']&.to_i,
          'version_tag' => ont['version_tag'] || ont['version'] || 'latest',
          'sha256' => normalize_sha256(raw_sha),
          'triples_count' => ont['triples_count']&.to_i
        }.compact
      end
    end

    def build_shapes_section
      (capsule.locked_shapes || []).map do |shape|
        shape = shape.transform_keys(&:to_s) if shape.respond_to?(:transform_keys)
        raw_sha = shape['sha256']
        raw_sha ||= Digest::SHA256.hexdigest(shape['content'] || shape['iri'] || shape['path'] || shape['name'].to_s)
        {
          'name' => shape['name'],
          'iri' => shape['iri'] || shape['path'],
          'version' => shape['version'] || '1.0',
          'sha256' => normalize_sha256(raw_sha)
        }.compact
      end
    end

    def build_mappings_section
      (capsule.locked_mappings || []).map do |mapping|
        mapping = mapping.transform_keys(&:to_s) if mapping.respond_to?(:transform_keys)
        {
          'id' => mapping['id'],
          'sssom_version' => mapping['sssom_version'] || '1.0',
          'source_ontology' => mapping['source_ontology'],
          'target_ontology' => mapping['target_ontology'],
          'sha256' => normalize_sha256(mapping['sha256']),
          'mapping_count' => mapping['mapping_count']&.to_i
        }.compact
      end
    end

    def build_embeddings_section
      (capsule.locked_embeddings || []).map do |emb|
        emb = emb.transform_keys(&:to_s) if emb.respond_to?(:transform_keys)
        {
          'model_id' => emb['model_id'],
          'dimension' => emb['dimension']&.to_i,
          'distance_metric' => emb['distance_metric'] || 'cosine',
          'checksum' => emb['checksum']
        }.compact
      end
    end

    def normalize_sha256(hash_str)
      return nil if hash_str.nil? || hash_str.to_s.strip.empty?

      clean = hash_str.to_s.sub(/^sha256:/i, '')
      clean
    end
  end
end
