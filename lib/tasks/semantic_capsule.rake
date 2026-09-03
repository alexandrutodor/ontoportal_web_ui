# frozen_string_literal: true

namespace :capsule do
  desc 'Validate a semantic.lock file for cryptographic integrity and schema compliance'
  task :validate, [:file_path] => :environment do |_t, args|
    file_path = args[:file_path] || 'semantic.lock'
    unless File.exist?(file_path)
      puts "[ERROR] File not found: #{file_path}"
      exit 1
    end

    require_relative '../../app/services/capsules/lockfile_validator'
    content = File.read(file_path)
    result = Capsules::LockfileValidator.validate(content)

    if result[:valid]
      puts "==> [VALID] Lockfile '#{file_path}' passed cryptographic integrity verification."
      puts "    Manifest Digest: #{result[:computed_digest]}"
      puts "    Status: #{result[:status]}"
    else
      puts "==> [INVALID] Lockfile '#{file_path}' failed verification!"
      puts "    Status: #{result[:status]}"
      puts "    Errors:"
      result[:errors].each { |err| puts "      - #{err}" }
      exit 1
    end
  end

  desc 'Export a Semantic Capsule as an RO-Crate 1.1 compliant ZIP package'
  task :export, %i[capsule_id output_path] => :environment do |_t, args|
    capsule_id = args[:capsule_id]
    output_path = args[:output_path] || "#{capsule_id || 'capsule'}-ro-crate.zip"

    require_relative '../../app/models/semantic_capsule'
    require_relative '../../app/services/capsules/ro_crate_exporter'

    capsule = capsule_id.present? ? SemanticCapsule.find(capsule_id) : SemanticCapsule.all.first
    unless capsule
      puts "[ERROR] Semantic Capsule not found: #{capsule_id}"
      exit 1
    end

    exporter = Capsules::RoCrateExporter.new(capsule)
    exporter.export(output_path)
    puts "==> [SUCCESS] RO-Crate exported for capsule '#{capsule.name}' to '#{output_path}'"
    puts "    File size: #{File.size(output_path)} bytes"
  end

  desc 'List all registered Semantic Capsules'
  task list: :environment do
    require_relative '../../app/models/semantic_capsule'
    capsules = SemanticCapsule.all
    puts "==> Registered Semantic Capsules (#{capsules.size}):"
    capsules.each do |c|
      puts "    - [#{c.status.upcase}] #{c.name} (v#{c.version}) ID: #{c.id}"
      puts "      Author: #{c.author} | Ontologies: #{(c.locked_ontologies || []).size}"
      puts "      Digest: #{c.manifest_digest}"
    end
  end
end
