# frozen_string_literal: true

require 'json'
require 'time'
require 'stringio'
require 'digest'
require_relative 'lockfile_generator'

begin
  require 'zip'
rescue LoadError
  # Fallback for standalone/runner execution without full bundler environment
  gem_paths = Dir.glob('/home/ranma/ontoportal/**/rubyzip-*/lib') + Dir.glob('/home/ranma/**/rubyzip-*/lib')
  gem_paths.uniq.each { |p| $LOAD_PATH.unshift(p) }
  require 'zip' rescue nil
end

module Capsules
  class RoCrateExporter
    RO_CRATE_SPEC = 'https://w3id.org/ro/crate/1.1'
    RO_CRATE_CONTEXT = 'https://w3id.org/ro/crate/1.1/context'

    attr_reader :capsule, :lockfile_content

    def initialize(capsule_or_attrs)
      @capsule = if capsule_or_attrs.is_a?(SemanticCapsule)
                   capsule_or_attrs
                 else
                   SemanticCapsule.new(capsule_or_attrs)
                 end
      @generator = LockfileGenerator.new(@capsule)
      @lockfile_content = @generator.to_yaml
    end

    def export(output_path = nil)
      metadata_json = generate_metadata_json
      readme_text = generate_readme

      files_to_pack = {
        'ro-crate-metadata.json' => metadata_json,
        'semantic.lock' => @lockfile_content,
        'README.md' => readme_text
      }

      # Include any shapes that have file content
      (capsule.shapes || []).each do |shape|
        s = shape.is_a?(Hash) ? shape.transform_keys(&:to_s) : shape
        path = s['path'] || (s['name'] ? "shapes/#{s['name']}.ttl" : nil)
        files_to_pack[path] = s['content'] if path && s['content']
      end

      # Include any mapping sets that have file content
      (capsule.mapping_sets || []).each do |mapping|
        m = mapping.is_a?(Hash) ? mapping.transform_keys(&:to_s) : mapping
        path = m['path'] || (m['name'] ? "mappings/#{m['name']}.sssom.tsv" : nil)
        files_to_pack[path] = m['content'] if path && m['content']
      end

      zip_data = build_zip_archive(files_to_pack)

      if output_path
        File.binwrite(output_path, zip_data)
        output_path
      else
        zip_data
      end
    end

    alias_method :export_to_zip, :export

    def export_to_tempfile
      require 'tempfile'
      Tempfile.new(["capsule-#{capsule.name}-ro-crate-", '.zip']).tap do |tmp|
        tmp.binmode
        tmp.write(export)
        tmp.flush
        tmp.rewind
      end
    end

    def manifest_metadata
      JSON.parse(generate_metadata_json)
    end

    # Builds RO-Crate 1.1 JSON-LD Metadata graph
    def generate_metadata_json
      lock_sha256 = Digest::SHA256.hexdigest(@lockfile_content)

      graph = [
        # Metadata Descriptor
        {
          '@id' => 'ro-crate-metadata.json',
          '@type' => 'CreativeWork',
          'conformsTo' => { '@id' => RO_CRATE_SPEC },
          'about' => { '@id' => './' }
        },
        # Root Dataset Entity
        {
          '@id' => './',
          '@type' => ['Dataset', 'SemanticCapsule'],
          'name' => capsule.name,
          'description' => capsule.description,
          'version' => capsule.version,
          'datePublished' => capsule.created_at,
          'creator' => capsule.author,
          'author' => capsule.author,
          'conformsTo' => { '@id' => RO_CRATE_SPEC },
          'hasPart' => [
            { '@id' => 'semantic.lock' },
            { '@id' => 'README.md' }
          ]
        },
        # semantic.lock file entity
        {
          '@id' => 'semantic.lock',
          '@type' => 'File',
          'name' => 'OntoPortal Semantic Environment Lockfile',
          'description' => 'Deterministic lockfile specifying ontologies, SHACL shapes, SSSOM mappings, and vector models',
          'encodingFormat' => 'text/yaml',
          'sha256' => lock_sha256
        },
        # README.md file entity
        {
          '@id' => 'README.md',
          '@type' => 'File',
          'name' => 'Capsule Documentation',
          'description' => 'Human-readable summary and execution guidelines for this semantic capsule',
          'encodingFormat' => 'text/markdown'
        }
      ]

      # Add ontology parts to graph
      (capsule.locked_ontologies || []).each do |ont|
        ont = ont.transform_keys(&:to_s) if ont.respond_to?(:transform_keys)
        acronym = ont['acronym']
        next unless acronym

        ont_id = "ontologies/#{acronym}"
        graph[1]['hasPart'] << { '@id' => ont_id }
        graph << {
          '@id' => ont_id,
          '@type' => ['DefinedTermSet', 'Ontology'],
          'name' => acronym,
          'identifier' => ont['iri'] || acronym,
          'version' => ont['version_tag'] || 'latest',
          'sha256' => ont['sha256'],
          'triplesCount' => ont['triples_count']
        }.compact
      end

      # Add shape parts to graph
      (capsule.locked_shapes || []).each do |shape|
        shape = shape.transform_keys(&:to_s) if shape.respond_to?(:transform_keys)
        name = shape['name']
        next unless name

        shape_id = "shapes/#{name}"
        graph[1]['hasPart'] << { '@id' => shape_id }
        graph << {
          '@id' => shape_id,
          '@type' => ['CreativeWork', 'SHACLShapes'],
          'name' => name,
          'identifier' => shape['iri'] || name,
          'version' => shape['version'],
          'sha256' => shape['sha256']
        }.compact
      end

      # Add mapping parts to graph
      (capsule.locked_mappings || []).each do |mapping|
        mapping = mapping.transform_keys(&:to_s) if mapping.respond_to?(:transform_keys)
        m_id = mapping['id']
        next unless m_id

        part_id = "mappings/#{m_id}"
        graph[1]['hasPart'] << { '@id' => part_id }
        graph << {
          '@id' => part_id,
          '@type' => ['CreativeWork', 'SSSOMMappings'],
          'name' => m_id,
          'sourceOntology' => mapping['source_ontology'],
          'targetOntology' => mapping['target_ontology'],
          'sha256' => mapping['sha256'],
          'mappingCount' => mapping['mapping_count']
        }.compact
      end

      metadata = {
        '@context' => RO_CRATE_CONTEXT,
        '@graph' => graph
      }

      JSON.pretty_generate(metadata)
    end

    def generate_readme
      <<~MARKDOWN
        # Semantic Capsule: #{capsule.name} (v#{capsule.version})

        > **OntoPortal Deterministic Semantic Environment**

        - **Capsule ID**: `#{capsule.id}`
        - **Created At**: #{capsule.created_at}
        - **Author**: #{capsule.author}
        - **Manifest Digest**: `#{capsule.manifest_digest || 'See semantic.lock'}`

        ## Description
        #{capsule.description}

        ## Locked Ontologies
        #{(capsule.locked_ontologies || []).map { |o| "- **#{o['acronym']}** (version: `#{o['version_tag']}`, sha256: `#{o['sha256']}`)" }.join("\n")}

        ## Verification & Execution
        To verify this capsule with the OntoPortal CLI:
        ```bash
        rake capsule:validate[semantic.lock]
        ```
      MARKDOWN
    end

    private

    def build_zip_archive(files)
      if defined?(Zip::OutputStream)
        buffer = Zip::OutputStream.write_buffer do |zio|
          files.each do |filename, content|
            zio.put_next_entry(filename)
            zio.write(content)
          end
        end
        buffer.string
      else
        # Fallback using system zip if Zip gem is completely absent
        create_zip_via_tempdir(files)
      end
    end

    def create_zip_via_tempdir(files)
      require 'tmpdir'
      Dir.mktmpdir('ro_crate') do |dir|
        files.each do |filename, content|
          path = File.join(dir, filename)
          FileUtils.mkdir_p(File.dirname(path))
          File.write(path, content)
        end
        zip_path = File.join(dir, 'bundle.zip')
        system('zip', '-r', '-q', zip_path, '.', chdir: dir)
        File.binread(zip_path)
      end
    end
  end
end
