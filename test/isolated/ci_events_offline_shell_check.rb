#!/usr/bin/env ruby
# frozen_string_literal: true

# Standalone isolated regression check for ONTO-T-Q07 (First safe unit):
# - Validates fork PR synchronize events on .github/workflows/tests.yml and tests-system.yml
# - Validates new .github/workflows/offline-tests.yml offline-shell lane
# - Validates least privilege (contents: read, persist-credentials: false, no secrets, no services, no pull_request_target)
# - Validates fail-on-error and parses YAML handling Psych boolean coercion of 'on'
# - Extracts and executes the exact wired command (bash test/bin/run_api_test.sh)
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

puts '=== Step 1: Validate Workflow YAML Syntax & Event Triggers ==='

root_dir = File.expand_path('../..', __dir__)
before_harness_sha = Digest::SHA256.file(File.join(root_dir, 'test/bin/run_api_test.sh')).hexdigest
before_launcher_sha = Digest::SHA256.file(File.join(root_dir, 'bin/run_api')).hexdigest
workflows = {
  main_tests: File.join(root_dir, '.github/workflows/tests.yml'),
  system_tests: File.join(root_dir, '.github/workflows/tests-system.yml'),
  offline_tests: File.join(root_dir, '.github/workflows/offline-tests.yml')
}

parsed_workflows = {}

workflows.each do |key, path|
  assert(File.exist?(path), "Workflow file #{File.basename(path)} exists", failures) && (passed_count += 1)
  raw_yaml = File.read(path)
  data = Psych.safe_load(raw_yaml, permitted_classes: [], aliases: true)
  assert(data.is_a?(Hash), "Workflow #{File.basename(path)} parses into a Hash", failures) && (passed_count += 1)
  parsed_workflows[key] = { data: data, raw: raw_yaml }

  # In Psych, unquoted 'on:' is parsed as boolean key `true`
  on_config = data['on'] || data[true]
  assert(on_config.is_a?(Hash), "#{File.basename(path)} triggers config is a Hash", failures) && (passed_count += 1)

  # Check push preserved
  assert(on_config.key?('push'), "#{File.basename(path)} includes push trigger", failures) && (passed_count += 1)

  # Check pull_request types
  pr_config = on_config['pull_request']
  assert(pr_config.is_a?(Hash), "#{File.basename(path)} includes pull_request trigger", failures) && (passed_count += 1)
  pr_types = pr_config['types']
  assert(pr_types.is_a?(Array), "#{File.basename(path)} pull_request types is an Array", failures) && (passed_count += 1)
  assert(pr_types.include?('opened'), "#{File.basename(path)} pull_request includes 'opened'", failures) && (passed_count += 1)
  assert(pr_types.include?('reopened'), "#{File.basename(path)} pull_request includes 'reopened'", failures) && (passed_count += 1)
  assert(pr_types.include?('synchronize'), "#{File.basename(path)} pull_request includes 'synchronize' for fork PR updates", failures) && (passed_count += 1)

  # Check no pull_request_target
  assert(!on_config.key?('pull_request_target'), "#{File.basename(path)} omits pull_request_target (no privilege escalation)", failures) && (passed_count += 1)
end

puts "\n=== Step 2: Validate Offline Lane Least Privilege & Boundary ==="

offline_data = parsed_workflows[:offline_tests][:data]
offline_raw = parsed_workflows[:offline_tests][:raw]

# Check top-level or job-level permissions
perms = offline_data['permissions'] || offline_data.dig('jobs', 'offline-shell', 'permissions')
assert(perms == { 'contents' => 'read' }, "offline-tests.yml sets least-privilege permissions: contents: read", failures) && (passed_count += 1)

# Check job definition
jobs = offline_data['jobs'] || {}
assert(jobs.key?('offline-shell'), "offline-tests.yml defines 'offline-shell' job", failures) && (passed_count += 1)

job_def = jobs['offline-shell']
assert(job_def['runs-on'] == 'ubuntu-latest', "offline-shell job runs on ubuntu-latest", failures) && (passed_count += 1)
assert(job_def['services'].nil?, "offline-shell defines no service containers", failures) && (passed_count += 1)
assert(offline_data['env'].nil? && job_def['env'].nil?, "offline-shell defines no env / REMOTE_* inheritance", failures) && (passed_count += 1)
assert(!offline_raw.include?('secrets.'), "offline-shell references no secrets", failures) && (passed_count += 1)

steps = job_def['steps'] || []
checkout_step = steps.find { |s| s['uses']&.start_with?('actions/checkout') }
assert(checkout_step.is_a?(Hash), "offline-shell includes actions/checkout step", failures) && (passed_count += 1)
assert(checkout_step['uses'] == 'actions/checkout@v3', "offline-shell uses actions/checkout@v3", failures) && (passed_count += 1)
assert(checkout_step.dig('with', 'persist-credentials') == false, "checkout specifies persist-credentials: false", failures) && (passed_count += 1)

run_step = steps.find { |s| s['run'] }
assert(run_step.is_a?(Hash), "offline-shell includes run step", failures) && (passed_count += 1)
assert(run_step['continue-on-error'] != true, "run step enforces fail-on-error (no continue-on-error)", failures) && (passed_count += 1)

extracted_command = run_step['run'].strip
assert(extracted_command == 'bash test/bin/run_api_test.sh', "extracted command matches expected harness: #{extracted_command}", failures) && (passed_count += 1)

puts "\n=== Step 3: Execute Extracted Wired Command (Unchanged Actual Harness) ==="

stdout, stderr, status = Open3.capture3(extracted_command, chdir: root_dir)
assert(status.success?, "Extracted command '#{extracted_command}' exited with status 0", failures) && (passed_count += 1)

pass_lines = stdout.lines.select { |l| l.start_with?('PASS:') }
assert(pass_lines.length == 16, "Extracted harness passed all 16 cases (found #{pass_lines.length})", failures) && (passed_count += 1)
assert(!stdout.include?('FAIL:'), "Extracted harness produced 0 failures", failures) && (passed_count += 1)

puts "\n=== Step 4: Controlled Assertion Failure in Temp Copy ==="

Dir.mktmpdir('q07-controlled-failure-') do |tmp_dir|
  temp_test_dir = File.join(tmp_dir, 'test/bin')
  temp_bin_dir = File.join(tmp_dir, 'bin')
  FileUtils.mkdir_p(temp_test_dir)
  FileUtils.mkdir_p(temp_bin_dir)

  temp_harness = File.join(temp_test_dir, 'run_api_test.sh')
  temp_run_api = File.join(temp_bin_dir, 'run_api')
  FileUtils.cp(File.join(root_dir, 'test/bin/run_api_test.sh'), temp_harness)
  FileUtils.cp(File.join(root_dir, 'bin/run_api'), temp_run_api)
  FileUtils.chmod(0755, temp_harness)
  FileUtils.chmod(0755, temp_run_api)

  # Inject a controlled failure into the temporary harness copy
  harness_content = File.read(temp_harness)
  # In run_case master 0 ..., change expected status to 99 to induce controlled failure
  tampered = harness_content.sub('run_case master 0 /ontologies_api/master/docker-compose.yml',
                                 'run_case master 99 /ontologies_api/master/docker-compose.yml')
  File.write(temp_harness, tampered)

  # Execute the tampered temporary harness
  fail_stdout, fail_stderr, fail_status = Open3.capture3("bash #{temp_harness}", chdir: root_dir)
  assert(!fail_status.success?, "Controlled assertion failure exited non-zero (exit code: #{fail_status.exitstatus})", failures) && (passed_count += 1)
  assert(fail_stderr.include?('FAIL: master returned 0, expected 99'), "Controlled failure was caught and reported expected FAIL message", failures) && (passed_count += 1)
end

puts "\n=== Step 5: Verify Tracked Files Integrity ==="

after_harness_sha = Digest::SHA256.file(File.join(root_dir, 'test/bin/run_api_test.sh')).hexdigest
after_launcher_sha = Digest::SHA256.file(File.join(root_dir, 'bin/run_api')).hexdigest

assert(before_harness_sha == after_harness_sha, "Tracked test/bin/run_api_test.sh SHA256 is unchanged", failures) && (passed_count += 1)
assert(before_launcher_sha == after_launcher_sha, "Tracked bin/run_api SHA256 is unchanged", failures) && (passed_count += 1)

# If git repository metadata is accessible (e.g. host execution), also verify git status
git_status, _, git_exit = Open3.capture3("git status --porcelain test/bin bin", chdir: root_dir)
if git_exit.success?
  assert(git_status.strip.empty?, "Git working tree for test/bin and bin is clean", failures) && (passed_count += 1)
end

puts "\n=== Summary ==="
puts "Total assertions: #{passed_count + failures.length}"
puts "Passed: #{passed_count}"
puts "Failed: #{failures.length}"

if failures.empty?
  puts "ALL CHECKS PASSED SUCCESSFULLY."
  exit 0
else
  puts "FAILED CHECKS:"
  failures.each { |f| puts " - #{f}" }
  exit 1
end
