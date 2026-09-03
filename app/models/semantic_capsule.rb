# frozen_string_literal: true

require 'securerandom'
require 'time'
require 'yaml'
require 'json'

class SemanticCapsule
  attr_accessor :id, :name, :version, :description, :author, :generator,
                :created_at, :status, :ontologies, :shapes, :mappings,
                :embeddings, :manifest_digest, :lockfile_data

  @registry = {}
  @semaphore = Mutex.new

  def initialize(attrs = {})
    attrs = attrs.transform_keys(&:to_s) if attrs.respond_to?(:transform_keys)

    @id = attrs['id'] || "capsule-#{SecureRandom.hex(6)}"
    @name = attrs['name'] || 'untitled-capsule'
    @version = attrs['version'] || '1.0.0'
    @description = attrs['description'] || ''
    @author = attrs['author'] || 'OntoPortal Curator'
    @generator = attrs['generator'] || 'OntoPortal Semantic Capsule Engine 1.0'
    @created_at = attrs['created_at'] || Time.now.utc.iso8601
    @status = attrs['status'] || 'locked'
    @ontologies = normalize_collection(attrs['ontologies'])
    @shapes = normalize_collection(attrs['shapes'])
    @mappings = normalize_collection(attrs['mapping_sets'] || attrs['mappings'])
    @embeddings = normalize_collection(attrs['embeddings'])
    @lockfile_data = attrs['lockfile_data']
    @manifest_digest = attrs['manifest_digest']
  end

  def persisted?
    !@id.nil? && !@id.empty?
  end

  def to_param
    @id
  end

  def locked_ontologies
    @ontologies
  end

  def locked_shapes
    @shapes
  end

  def locked_mappings
    @mappings
  end

  def mapping_sets
    @mappings
  end

  def mapping_sets=(val)
    @mappings = normalize_collection(val)
  end

  def locked_embeddings
    @embeddings
  end

  def verified?
    %w[verified valid].include?(@status.to_s.downcase)
  end

  def tampered?
    @status.to_s.downcase == 'tampered'
  end

  def to_lockfile(format: :yaml)
    require_relative '../services/capsules/lockfile_generator' unless defined?(Capsules::LockfileGenerator)
    generator = Capsules::LockfileGenerator.new(self)
    format == :json ? generator.to_json : generator.to_yaml
  end

  def validate_integrity
    require_relative '../services/capsules/lockfile_validator' unless defined?(Capsules::LockfileValidator)
    content = to_lockfile(format: :yaml)
    result = Capsules::LockfileValidator.validate(content)
    @status = result[:valid] ? 'verified' : (result[:status] == :tampered ? 'tampered' : 'invalid')
    @manifest_digest = result[:computed_digest]
    result
  end

  def export_ro_crate(output_path = nil)
    require_relative '../services/capsules/ro_crate_exporter' unless defined?(Capsules::RoCrateExporter)
    exporter = Capsules::RoCrateExporter.new(self)
    exporter.export(output_path)
  end

  def as_json(_options = {})
    {
      id: @id,
      name: @name,
      version: @version,
      description: @description,
      author: @author,
      generator: @generator,
      created_at: @created_at,
      status: @status,
      ontologies: @ontologies,
      shapes: @shapes,
      mappings: @mappings,
      embeddings: @embeddings,
      manifest_digest: @manifest_digest
    }
  end

  # Factory from semantic.lock file content (YAML or JSON)
  def self.from_lockfile(content)
    data = content.is_a?(Hash) ? content : (YAML.safe_load(content) || JSON.parse(content))
    data = data.transform_keys(&:to_s) if data.respond_to?(:transform_keys)

    capsule_meta = (data['capsule'] || {}).transform_keys(&:to_s)
    integrity = (data['integrity'] || {}).transform_keys(&:to_s)

    new(
      'id' => capsule_meta['id'] || "capsule-#{SecureRandom.hex(6)}",
      'name' => capsule_meta['name'] || 'imported-capsule',
      'version' => capsule_meta['version'] || '1.0.0',
      'description' => capsule_meta['description'] || '',
      'author' => capsule_meta['author'] || 'Unknown Author',
      'generator' => capsule_meta['generator'] || 'External Generator',
      'created_at' => capsule_meta['created_at'] || Time.now.utc.iso8601,
      'status' => 'locked',
      'ontologies' => data['ontologies'] || [],
      'shapes' => data['shapes'] || [],
      'mappings' => data['mappings'] || [],
      'embeddings' => data['embeddings'] || [],
      'manifest_digest' => integrity['manifest_digest'],
      'lockfile_data' => data
    )
  end

  # Registry store methods
  def self.all
    @semaphore.synchronize do
      seed_defaults! if @registry.empty?
      @registry.values
    end
  end

  def self.find(id)
    @semaphore.synchronize do
      seed_defaults! if @registry.empty?
      @registry[id.to_s]
    end
  end

  def self.save(capsule)
    @semaphore.synchronize do
      @registry[capsule.id.to_s] = capsule
    end
    capsule
  end

  def self.register(capsule)
    save(capsule)
  end

  def self.delete(id)
    @semaphore.synchronize do
      @registry.delete(id.to_s)
    end
  end

  def self.reset_registry!
    @semaphore.synchronize do
      @registry.clear
    end
  end

  def self.seed_defaults!
    default_capsule = new(
      'id' => 'urn:uuid:550e8400-e29b-41d4-a716-446655440000',
      'name' => 'battery-materials-kg',
      'version' => '1.0.0',
      'description' => 'Deterministic semantic environment for battery electrolyte extraction and autonomous analysis',
      'author' => 'Materials & Chemistry Consortium',
      'generator' => 'OntoPortal Semantic Capsule Engine 1.0',
      'created_at' => '2026-09-03T14:30:00Z',
      'status' => 'verified',
      'ontologies' => [
        {
          'acronym' => 'EMMO',
          'iri' => 'http://emmo.info/emmo',
          'submission_id' => 12,
          'version_tag' => '1.0.0-rc2',
          'sha256' => 'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855',
          'triples_count' => 84_321
        },
        {
          'acronym' => 'CHEMINF',
          'iri' => 'http://semanticchemistry.github.io/semanticchemistry/ontology/cheminf.owl',
          'submission_id' => 4,
          'version_tag' => '2.1.0',
          'sha256' => 'a1b2c3d4e5f60718293a4b5c6d7e8f90123456789abcdef0123456789abcdef0',
          'triples_count' => 32_100
        }
      ],
      'shapes' => [
        {
          'name' => 'BatteryDataShapes',
          'iri' => 'https://example.org/shapes/battery.shacl.ttl',
          'version' => '0.4.1',
          'sha256' => '5d41402abc4b2a76b9719d911017c592b21c43f80879654a9382103f5dbca4a8'
        }
      ],
      'mappings' => [
        {
          'id' => 'EMMO-CHEMINF-2026',
          'sssom_version' => '1.0',
          'source_ontology' => 'EMMO',
          'target_ontology' => 'CHEMINF',
          'sha256' => 'ca978112ca1bbdcafac231b39a23dc4da786eff8147c4e72b9807785afee48bb',
          'mapping_count' => 1420
        }
      ],
      'embeddings' => [
        {
          'model_id' => 'sentence-transformers/all-MiniLM-L6-v2',
          'dimension' => 384,
          'distance_metric' => 'cosine',
          'checksum' => '9f83c605d84386927a4d3b6fe8e36746816503c200c8f1e582888806282ff3e7'
        }
      ]
    )

    # Pre-generate manifest digest for default capsule
    require_relative '../services/capsules/lockfile_generator' unless defined?(Capsules::LockfileGenerator)
    gen = Capsules::LockfileGenerator.new(default_capsule)
    manifest = gen.generate
    default_capsule.manifest_digest = manifest['integrity']['manifest_digest']
    default_capsule.lockfile_data = manifest

    @registry[default_capsule.id] = default_capsule
  end

  private

  def normalize_collection(items)
    return [] unless items.is_a?(Array)

    items.map do |item|
      item.respond_to?(:transform_keys) ? item.transform_keys(&:to_s) : item
    end
  end
end
