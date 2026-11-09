#!/usr/bin/env ruby
# frozen_string_literal: true

# Standalone isolated regression check for ONTO-T-Q07 (Supported RSpec Unit):
# - Validates new .github/workflows/offline-tests.yml offline-rspec-helper lane
# - Validates least privilege (contents: read, persist-credentials: false, no secrets, no services, no DB/Rails env)
# - Validates fail-on-error and setup-ruby / bundler-cache configuration
# - Extracts and executes the exact wired command offline in onto-q02-proof:af254f34 (--network none)
# - Executes a controlled assertion failure in an isolated temp copy to verify non-zero propagation
# - Confirms tracked source remains unchanged

require 'psych'
require 'open3'
require 'fileutils'
require 'tmpdir'
require 'digest'

failures = []
passed_count = 0

def assert(condition, message, failures)
  if condition
    puts "  [PASS] #{message}"
    true
  else
    puts "  [FAIL] #{message}"
    failures << message
    false
  end
end

puts '=== Step 1: Validate Workflow YAML & offline-rspec-helper Job ==='

root_dir = File.expand_path('../..', __dir__)
workflow_path = File.join(root_dir, '.github/workflows/offline-tests.yml')

assert(File.exist?(workflow_path), 'offline-tests.yml exists', failures) && (passed_count += 1)
raw_yaml = File.read(workflow_path)
data = Psych.safe_load(raw_yaml, permitted_classes: [], aliases: true)
assert(data.is_a?(Hash), 'offline-tests.yml parses into a Hash', failures) && (passed_count += 1)

jobs = data['jobs'] || {}
assert(jobs.key?('offline-rspec-helper'), "offline-tests.yml defines 'offline-rspec-helper' job", failures) && (passed_count += 1)

job_def = jobs['offline-rspec-helper']
assert(job_def['runs-on'] == 'ubuntu-latest', 'offline-rspec-helper job runs on ubuntu-latest', failures) && (passed_count += 1)
assert(job_def['services'].nil?, 'offline-rspec-helper defines no service containers', failures) && (passed_count += 1)
assert(data['env'].nil? && job_def['env'].nil?, 'offline-rspec-helper defines no env / REMOTE_* inheritance', failures) && (passed_count += 1)
assert(!job_def.to_s.include?('secrets.'), 'offline-rspec-helper references no secrets', failures) && (passed_count += 1)

steps = job_def['steps'] || []
checkout_step = steps.find { |s| s['uses']&.start_with?('actions/checkout') }
assert(checkout_step.is_a?(Hash), 'offline-rspec-helper includes actions/checkout step', failures) && (passed_count += 1)
assert(checkout_step['uses'] == 'actions/checkout@v3', 'offline-rspec-helper uses actions/checkout@v3', failures) && (passed_count += 1)
assert(checkout_step.dig('with', 'persist-credentials') == false, 'checkout specifies persist-credentials: false', failures) && (passed_count += 1)

ruby_step = steps.find { |s| s['uses']&.start_with?('ruby/setup-ruby') }
assert(ruby_step.is_a?(Hash), 'offline-rspec-helper includes ruby/setup-ruby step', failures) && (passed_count += 1)
assert(ruby_step['uses'] == 'ruby/setup-ruby@v1', 'offline-rspec-helper uses ruby/setup-ruby@v1', failures) && (passed_count += 1)
assert(ruby_step.dig('with', 'ruby-version') == '3.1.0', 'ruby/setup-ruby specifies ruby-version: 3.1.0', failures) && (passed_count += 1)
assert(ruby_step.dig('with', 'bundler-cache') == true, 'ruby/setup-ruby specifies bundler-cache: true', failures) && (passed_count += 1)

run_step = steps.find { |s| s['run'] }
assert(run_step.is_a?(Hash), 'offline-rspec-helper includes run step', failures) && (passed_count += 1)
assert(run_step['continue-on-error'] != true, 'run step enforces fail-on-error (no continue-on-error)', failures) && (passed_count += 1)

extracted_command = run_step['run'].strip
expected_command = 'bundle exec rspec spec/helpers/sparql_spec.rb spec/offline_network_boundary_spec.rb'
assert(extracted_command == expected_command, "extracted command matches expected: #{extracted_command}", failures) && (passed_count += 1)

assert(jobs.key?('legacy-rspec'), "offline-tests.yml defines 'legacy-rspec' job", failures) && (passed_count += 1)

legacy_job = jobs['legacy-rspec']
assert(legacy_job['runs-on'] == 'ubuntu-latest', 'legacy-rspec job runs on ubuntu-latest', failures) && (passed_count += 1)
assert(legacy_job.dig('services', 'mysql', 'image') == 'mysql:8.0', 'legacy-rspec defines mysql:8.0 service', failures) && (passed_count += 1)
assert(legacy_job.dig('services', 'mysql', 'env', 'MYSQL_ROOT_PASSWORD') == 'root', 'legacy-rspec configures root mysql password', failures) && (passed_count += 1)
assert(!legacy_job.to_s.include?('secrets.'), 'legacy-rspec references no secrets', failures) && (passed_count += 1)

legacy_steps = legacy_job['steps'] || []
legacy_checkout = legacy_steps.find { |s| s['uses']&.start_with?('actions/checkout') }
assert(legacy_checkout.is_a?(Hash), 'legacy-rspec includes actions/checkout step', failures) && (passed_count += 1)
assert(legacy_checkout['uses'] == 'actions/checkout@v3', 'legacy-rspec uses actions/checkout@v3', failures) && (passed_count += 1)
assert(legacy_checkout.dig('with', 'persist-credentials') == false, 'legacy-rspec specifies persist-credentials: false', failures) && (passed_count += 1)

legacy_ruby = legacy_steps.find { |s| s['uses']&.start_with?('ruby/setup-ruby') }
assert(legacy_ruby.is_a?(Hash), 'legacy-rspec includes ruby/setup-ruby step', failures) && (passed_count += 1)
assert(legacy_ruby['uses'] == 'ruby/setup-ruby@v1', 'legacy-rspec uses ruby/setup-ruby@v1', failures) && (passed_count += 1)
assert(legacy_ruby.dig('with', 'ruby-version') == '3.1.0', 'legacy-rspec ruby specifies ruby-version: 3.1.0', failures) && (passed_count += 1)
assert(legacy_ruby.dig('with', 'bundler-cache') == true, 'legacy-rspec ruby specifies bundler-cache: true', failures) && (passed_count += 1)

legacy_db_config = legacy_steps.find { |s| s['run']&.include?('config/database.yml') }
assert(legacy_db_config.is_a?(Hash), 'legacy-rspec includes database config setup', failures) && (passed_count += 1)

legacy_db_schema = legacy_steps.find { |s| s['run']&.include?('db:schema:load') }
assert(legacy_db_schema.is_a?(Hash), 'legacy-rspec includes database schema load', failures) && (passed_count += 1)

legacy_run = legacy_steps.find { |s| s['run']&.start_with?('bundle exec rspec') }
assert(legacy_run.is_a?(Hash), 'legacy-rspec includes run step', failures) && (passed_count += 1)
assert(legacy_steps.none? { |s| s['continue-on-error'] == true }, 'legacy-rspec enforces fail-on-error (no continue-on-error)', failures) && (passed_count += 1)

legacy_extracted = legacy_run['run'].strip
legacy_expected = 'bundle exec rspec spec/components spec/mailers spec/models spec/services'
assert(legacy_extracted == legacy_expected, "legacy-rspec extracted command matches expected: #{legacy_extracted}", failures) && (passed_count += 1)

puts "\n=== Step 2: Execute Extracted Wired Command in Isolated Container (--network none) ==="

docker_cmd = [
  'docker', 'run', '--rm', '--network', 'none',
  '-v', "#{root_dir}:/app:ro",
  '-v', '/home/ranma/ontoportal/worktrees/ui-remediation-test-bundle/.remediation/runtime-test-bundle:/runtime-test-bundle:ro',
  '-w', '/app',
  '-e', 'PATH=/runtime-test-bundle/overlay/gems/bin:/usr/local/bundle/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin',
  '-e', 'BUNDLE_APP_CONFIG=/runtime-test-bundle/bundle_app_config',
  '-e', 'BUNDLE_PATH=/runtime-test-bundle/bundle',
  '-e', 'BUNDLE_WITHOUT=development:deployment',
  '-e', 'BUNDLE_FROZEN=true',
  'onto-q02-proof:af254f34',
  'sh', '-c', extracted_command
]

stdout, stderr, status = Open3.capture3(*docker_cmd)
assert(status.success?, "Extracted command '#{extracted_command}' exited with status 0 in container", failures) && (passed_count += 1)
assert(stdout.include?('21 examples, 0 failures'), "All 21 examples passed (found '21 examples, 0 failures')", failures) && (passed_count += 1)
assert(!stdout.include?('failed'), 'Output contains 0 failures', failures) && (passed_count += 1)

puts "\n=== Step 3: Controlled Assertion Failure in Temp Copy ==="

Dir.mktmpdir('q07-rspec-failure-') do |tmp_dir|
  temp_spec = File.join(tmp_dir, 'controlled_failure_spec.rb')
  File.write(temp_spec, <<~RUBY)
    require_relative '/app/spec/offline_helper'
    RSpec.describe 'Controlled Failure' do
      it 'deliberately fails' do
        expect(1).to eq(2)
      end
    end
  RUBY

  fail_docker_cmd = [
    'docker', 'run', '--rm', '--network', 'none',
    '-v', "#{root_dir}:/app:ro",
    '-v', '/home/ranma/ontoportal/worktrees/ui-remediation-test-bundle/.remediation/runtime-test-bundle:/runtime-test-bundle:ro',
    '-v', "#{tmp_dir}:#{tmp_dir}:ro",
    '-w', '/app',
    '-e', 'PATH=/runtime-test-bundle/overlay/gems/bin:/usr/local/bundle/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin',
    '-e', 'BUNDLE_APP_CONFIG=/runtime-test-bundle/bundle_app_config',
    '-e', 'BUNDLE_PATH=/runtime-test-bundle/bundle',
    '-e', 'BUNDLE_WITHOUT=development:deployment',
    '-e', 'BUNDLE_FROZEN=true',
    'onto-q02-proof:af254f34',
    'bundle', 'exec', 'rspec', temp_spec
  ]

  fail_stdout, fail_stderr, fail_status = Open3.capture3(*fail_docker_cmd)
  assert(!fail_status.success?, "Controlled failure exited non-zero (exit code: #{fail_status.exitstatus})", failures) && (passed_count += 1)
  assert(fail_stdout.include?('1 failure') && fail_stdout.include?('expected: 2'), 'Controlled failure reported expected failure details', failures) && (passed_count += 1)
end

puts "\n=== Step 4: Verify Tracked Files Integrity ==="

assert(File.exist?(File.join(root_dir, 'spec/helpers/sparql_spec.rb')), 'spec/helpers/sparql_spec.rb exists', failures) && (passed_count += 1)
assert(File.exist?(File.join(root_dir, 'spec/offline_helper.rb')), 'spec/offline_helper.rb exists', failures) && (passed_count += 1)
assert(File.exist?(File.join(root_dir, 'spec/offline_network_boundary_spec.rb')), 'spec/offline_network_boundary_spec.rb exists', failures) && (passed_count += 1)

puts "\n=== Summary ==="
puts "Total assertions: #{passed_count + failures.length}"
puts "Passed: #{passed_count}"
puts "Failed: #{failures.length}"

if failures.empty?
  puts "ALL CHECKS PASSED SUCCESSFULLY."
  exit 0
else
  puts "FAILURES DETECTED:"
  failures.each { |f| puts " - #{f}" }
  exit 1
end
