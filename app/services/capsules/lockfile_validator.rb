# frozen_string_literal: true

require 'yaml'
require 'json'
require 'digest'
require_relative 'lockfile_generator'

module Capsules
  class LockfileValidator
    SUPPORTED_SCHEMA_VERSIONS = ['semantic.lock/v1'].freeze

    attr_reader :content, :options, :errors, :warnings

    def initialize(content, options = {})
      @content = content
      @options = options
      @errors = []
      @warnings = []
    end

    def self.validate(content, options = {})
      new(content, options).validate
    end

    def validate
      manifest = parse_content
      return failure_result(:invalid) unless manifest

      return failure_result(:invalid) unless validate_structure(manifest)

      validate_cryptographic_integrity(manifest)
    end

    private

    def parse_content
      if content.is_a?(Hash)
        content
      elsif content.is_a?(String)
        parse_string_payload(content)
      else
        @errors << "Expected content to be a YAML/JSON string or Hash, got #{content.class}"
        nil
      end
    end

    def parse_string_payload(str)
      return nil if str.strip.empty?

      # Attempt YAML first (YAML is a superset of JSON)
      YAML.safe_load(str, permitted_classes: [Date, Time])
    rescue Psych::Exception => e
      # Fallback to JSON parser
      begin
        JSON.parse(str)
      rescue JSON::ParserError => json_err
        @errors << "Failed to parse lockfile content as YAML parse error (#{e.message}) or JSON (#{json_err.message})"
        nil
      end
    end

    def validate_structure(manifest)
      unless manifest.is_a?(Hash)
        @errors << 'Root of lockfile must be a key-value mapping (Hash)'
        return false
      end

      schema_ver = manifest['schema_version']
      unless SUPPORTED_SCHEMA_VERSIONS.include?(schema_ver)
        @errors << "Unsupported or missing schema_version: '#{schema_ver}'. Supported versions: #{SUPPORTED_SCHEMA_VERSIONS.join(', ')}"
        return false
      end

      capsule = manifest['capsule']
      if !capsule.is_a?(Hash)
        @errors << "Missing or invalid 'capsule' section"
      else
        @errors << "Capsule section missing 'id'" if capsule['id'].to_s.strip.empty?
        @errors << "Missing capsule.name" if capsule['name'].to_s.strip.empty?
        @errors << "Capsule section missing 'version'" if capsule['version'].to_s.strip.empty?
      end

      ontologies = manifest['ontologies']
      if !ontologies.is_a?(Array)
        @errors << "Missing or invalid 'ontologies' list"
      else
        ontologies.each_with_index do |ont, idx|
          unless ont.is_a?(Hash)
            @errors << "Ontology at index #{idx} must be a mapping"
            next
          end
          @errors << "Ontology at index #{idx} missing acronym: 'acronym' is required" if ont['acronym'].to_s.strip.empty?
          @errors << "Ontology at index #{idx} (#{ont['acronym']}) missing 'sha256'" if ont['sha256'].to_s.strip.empty?
        end
      end

      integrity = manifest['integrity']
      if !integrity.is_a?(Hash)
        @errors << "Missing or invalid 'integrity' section"
      elsif integrity['manifest_digest'].to_s.strip.empty?
        @errors << "Integrity section missing 'manifest_digest'"
      end

      @errors.empty?
    end

    def validate_cryptographic_integrity(manifest)
      expected_digest = manifest.dig('integrity', 'manifest_digest')
      computed_digest = LockfileGenerator.compute_digest(manifest)

      if expected_digest != computed_digest
        @errors << "Integrity verification failed: manifest digest mismatch! Expected #{expected_digest}, but recomputed #{computed_digest}. Lockfile has been tampered with or corrupted."
        return {
          valid: false,
          status: :tampered,
          errors: @errors,
          warnings: @warnings,
          expected_digest: expected_digest,
          computed_digest: computed_digest,
          manifest: manifest
        }
      end

      # Optional artifact payload verification if provided in options
      if options[:artifact_contents].is_a?(Hash)
        artifact_errors = verify_artifact_contents(manifest, options[:artifact_contents])
        if artifact_errors.any?
          @errors.concat(artifact_errors)
          return {
            valid: false,
            status: :artifact_mismatch,
            errors: @errors,
            warnings: @warnings,
            expected_digest: expected_digest,
            computed_digest: computed_digest,
            manifest: manifest
          }
        end
      end

      {
        valid: true,
        status: :valid,
        errors: [],
        warnings: @warnings,
        expected_digest: expected_digest,
        computed_digest: computed_digest,
        manifest: manifest
      }
    end

    def verify_artifact_contents(manifest, artifact_contents)
      errors = []
      (manifest['ontologies'] || []).each do |ont|
        acronym = ont['acronym']
        raw = artifact_contents[acronym] || artifact_contents[acronym.to_sym]
        next unless raw

        actual_sha = Digest::SHA256.hexdigest(raw.to_s)
        expected_sha = ont['sha256'].to_s.sub(/^sha256:/i, '')

        if actual_sha != expected_sha
          errors << "SHA-256 mismatch for ontology #{acronym}: expected #{expected_sha}, computed #{actual_sha}"
        end
      end
      errors
    end

    def failure_result(status)
      {
        valid: false,
        status: status,
        errors: @errors,
        warnings: @warnings,
        expected_digest: nil,
        computed_digest: nil,
        manifest: nil
      }
    end
  end
end
