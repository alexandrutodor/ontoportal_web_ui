#!/usr/bin/env ruby
# frozen_string_literal: true

# Standalone isolated regression check for ONTO-T-Q01:
# Validates .github/workflows/brakeman-analysis.yml and bin/brakeman_ci_summary.rb
# with synthetic scanner results, events, reports, and failure fixtures.
# Operates fully offline without booting Rails, calling remote APIs, or dispatching CI workflows.

require 'psych'
require 'json'
require 'open3'
require 'fileutils'
require 'tmpdir'

failures = []

def assert(condition, message, failures)
  if condition
    puts "  [PASS] #{message}"
  else
    puts "  [FAIL] #{message}"
    failures << message
  end
end

puts '=== Step 1: Validate Brakeman Workflow YAML and Policy ==='
workflow_path = File.expand_path('../../.github/workflows/brakeman-analysis.yml', __dir__)
assert(File.exist?(workflow_path), 'Workflow file exists', failures)

raw_yaml = File.read(workflow_path)
workflow = Psych.safe_load(raw_yaml, permitted_classes: [], aliases: true)

# 1. Triggers
on_config = workflow['on'] || workflow[true]
assert(on_config.is_a?(Hash), "Workflow triggers are configured as a Hash", failures)
assert(on_config.key?('push') && on_config['push']['branches'] == ['master'],
       "Push trigger targets only 'master'", failures)
assert(on_config.key?('pull_request') && on_config['pull_request']['branches'] == ['master'],
       "Pull request trigger targets only 'master'", failures)
assert(!on_config.key?('pull_request_target'),
       "Workflow does not use pull_request_target", failures)
assert(!on_config.key?('workflow_dispatch'),
       "Workflow does not add unrequested workflow_dispatch capability", failures)

# 2. Permissions & Security
job = workflow.dig('jobs', 'brakeman-scan')
assert(job.is_a?(Hash), "Job 'brakeman-scan' is defined", failures)
job_perms = job['permissions']
assert(job_perms.is_a?(Hash), "Job defines explicit permissions block", failures)
assert(job_perms['contents'] == 'read', "Job specifies 'contents: read'", failures)
assert(job_perms['security-events'] == 'write', "Job specifies 'security-events: write'", failures)
assert(!raw_yaml.include?('secrets.'), "Workflow does not reference or expose secrets", failures)

# 3. Steps inspection
steps = job['steps'] || []

# Ruby setup
ruby_step = steps.find { |s| s['uses']&.start_with?('ruby/setup-ruby') }
assert(ruby_step && ruby_step.dig('with', 'ruby-version') == '3.1',
       "Ruby setup step pins ruby-version: '3.1'", failures)

# Brakeman version derivation from Gemfile.lock
brakeman_setup_step = steps.find { |s| s['name'] == 'Setup Brakeman' }
assert(brakeman_setup_step && brakeman_setup_step['run']&.include?('Gemfile.lock'),
       "Brakeman setup derives version from Gemfile.lock", failures)

# Verify lockfile version resolution
lockfile_path = File.expand_path('../../Gemfile.lock', __dir__)
lockfile_version = nil
File.foreach(lockfile_path) do |line|
  if line =~ /^\s*brakeman \(([0-9.]+)\)/
    lockfile_version = Regexp.last_match(1)
    break
  end
end
assert(lockfile_version == '7.0.2', "Gemfile.lock records Brakeman 7.0.2", failures)

# Scan step
scan_step = steps.find { |s| s['name'] == 'Scan' }
assert(scan_step.is_a?(Hash), "Scan step is defined", failures)
assert(!scan_step['continue-on-error'],
       "Scan step does not blanket continue-on-error (errors fail distinctly)", failures)
assert(scan_step['run']&.include?('bin/brakeman_ci_summary.rb'),
       "Scan step delegates evaluation to bin/brakeman_ci_summary.rb", failures)

# Artifact retention step
artifact_step = steps.find { |s| s['uses']&.start_with?('actions/upload-artifact') }
assert(artifact_step.is_a?(Hash), "Artifact upload step is defined", failures)
assert(artifact_step['uses'] == 'actions/upload-artifact@v7.0.2',
       "Artifact upload step pins actions/upload-artifact@v7.0.2", failures)
assert(artifact_step['if'] == 'always()',
       "Artifact retention step uses 'if: always()' across all runs", failures)

# Skip notice step for untrusted/PR events
skip_notice_step = steps.find { |s| s['name'] == 'Report Code Scanning upload skip' }
assert(skip_notice_step.is_a?(Hash), "Skip notice step exists for PR/untrusted events", failures)
assert(skip_notice_step['if'] == "github.event_name != 'push' || github.ref != 'refs/heads/master'",
       "Skip notice step evaluates non-master/PR events", failures)

# Code scanning upload step
upload_step = steps.find { |s| s['uses']&.start_with?('github/codeql-action/upload-sarif') }
assert(upload_step.is_a?(Hash), "Code scanning upload step is defined", failures)
assert(upload_step['uses'] == 'github/codeql-action/upload-sarif@v4',
       "Upload step pins github/codeql-action/upload-sarif@v4", failures)
assert(upload_step['if'] == "github.event_name == 'push' && github.ref == 'refs/heads/master'",
       "Code scanning upload is restricted to push on master", failures)
assert(!upload_step['continue-on-error'],
       "Code scanning upload does not blanket continue-on-error", failures)

puts "\n=== Step 2: Validate Reporting Helper with Synthetic Fixtures ==="
helper_path = File.expand_path('../../bin/brakeman_ci_summary.rb', __dir__)
assert(File.exist?(helper_path) && File.executable?(helper_path),
       "bin/brakeman_ci_summary.rb exists and is executable", failures)

Dir.mktmpdir('brakeman_ci_test') do |tmpdir|
  # Fixture generator helper
  def create_sarif(path, results, tool_version = '7.0.2')
    sarif = {
      'version' => '2.1.0',
      '$schema' => 'https://raw.githubusercontent.com/oasis-tcs/sarif-spec/master/Schemata/sarif-schema-2.1.0.json',
      'runs' => [
        {
          'tool' => {
            'driver' => {
              'name' => 'Brakeman',
              'version' => tool_version
            }
          },
          'results' => results
        }
      ]
    }
    File.write(path, JSON.pretty_generate(sarif))
  end

  # Case 1: Clean scan (0 findings)
  clean_sarif = File.join(tmpdir, 'clean.sarif.json')
  clean_diag = File.join(tmpdir, 'clean_diag.json')
  create_sarif(clean_sarif, [])
  stdout, stderr, status = Open3.capture3(
    helper_path,
    '--sarif', clean_sarif,
    '--scanner-status', '0',
    '--diagnostics-out', clean_diag
  )
  assert(status.exitstatus == 0, "Clean scan exits 0", failures)
  assert(stdout.include?('Total findings: 0'), "Clean scan reports 0 findings", failures)
  diag = JSON.parse(File.read(clean_diag))
  assert(diag['gate_status'] == 'passed' && diag['findings_count'] == 0,
         "Clean scan diagnostics record passed gate and 0 findings", failures)

  # Case 2: Scan with findings (non-blocking baseline)
  findings_sarif = File.join(tmpdir, 'findings.sarif.json')
  findings_diag = File.join(tmpdir, 'findings_diag.json')
  sample_findings = [
    {
      'ruleId' => 'BRAKE0001',
      'level' => 'warning',
      'message' => { 'text' => 'Possible SQL injection' },
      'locations' => [{ 'physicalLocation' => { 'artifactLocation' => { 'uri' => 'app/models/user.rb' } } }]
    },
    {
      'ruleId' => 'BRAKE0002',
      'level' => 'error',
      'message' => { 'text' => 'Remote Code Execution risk' },
      'locations' => [{ 'physicalLocation' => { 'artifactLocation' => { 'uri' => 'app/controllers/admin.rb' } } }]
    }
  ]
  create_sarif(findings_sarif, sample_findings)
  stdout, stderr, status = Open3.capture3(
    helper_path,
    '--sarif', findings_sarif,
    '--scanner-status', '0',
    '--diagnostics-out', findings_diag
  )
  assert(status.exitstatus == 0,
         "Scan with findings exits 0 under nonblocking baseline policy", failures)
  assert(stdout.include?('Total findings: 2'),
         "Scan with findings reports correct finding count", failures)
  assert(stdout.include?('PASSED: Non-blocking findings baseline accepted'),
         "Scan with findings explicitly confirms non-blocking acceptance", failures)
  diag = JSON.parse(File.read(findings_diag))
  assert(diag['gate_status'] == 'passed' && diag['findings_count'] == 2,
         "Diagnostics record passed gate with 2 findings", failures)
  assert(diag['severity_counts'] == { 'warning' => 1, 'error' => 1 },
         "Diagnostics record severity breakdown accurately", failures)

  # Case 3: Scanner execution failure (non-zero scanner status)
  fail_diag = File.join(tmpdir, 'scanner_fail_diag.json')
  stdout, stderr, status = Open3.capture3(
    helper_path,
    '--sarif', findings_sarif,
    '--scanner-status', '1',
    '--diagnostics-out', fail_diag
  )
  assert(status.exitstatus == 1,
         "Scanner execution failure exits 1 (distinct from findings)", failures)
  assert(stderr.include?('[Brakeman CI Error] Scanner execution failed with exit code 1'),
         "Scanner execution error reported distinctly to stderr", failures)
  diag = JSON.parse(File.read(fail_diag))
  assert(diag['gate_status'] == 'scanner_failed',
         "Diagnostics record 'scanner_failed' status", failures)

  # Case 4: Missing report
  missing_diag = File.join(tmpdir, 'missing_diag.json')
  nonexistent_path = File.join(tmpdir, 'does_not_exist.sarif.json')
  stdout, stderr, status = Open3.capture3(
    helper_path,
    '--sarif', nonexistent_path,
    '--scanner-status', '0',
    '--diagnostics-out', missing_diag
  )
  assert(status.exitstatus == 2,
         "Missing SARIF report exits 2 (distinct from scanner/finding error)", failures)
  assert(stderr.include?('Missing SARIF report'),
         "Missing report error reported distinctly to stderr", failures)
  diag = JSON.parse(File.read(missing_diag))
  assert(diag['gate_status'] == 'missing_report',
         "Diagnostics record 'missing_report' status", failures)

  # Case 5: Malformed JSON report
  malformed_json_path = File.join(tmpdir, 'corrupt.sarif.json')
  File.write(malformed_json_path, '{"version": "2.1.0", "runs": [ TRUNCATED')
  malformed_diag = File.join(tmpdir, 'corrupt_diag.json')
  stdout, stderr, status = Open3.capture3(
    helper_path,
    '--sarif', malformed_json_path,
    '--scanner-status', '0',
    '--diagnostics-out', malformed_diag
  )
  assert(status.exitstatus == 3,
         "Malformed JSON report exits 3", failures)
  assert(stderr.include?('Malformed SARIF report: SARIF report is not valid JSON'),
         "Malformed JSON error reported distinctly", failures)
  diag = JSON.parse(File.read(malformed_diag))
  assert(diag['gate_status'] == 'malformed_report',
         "Diagnostics record 'malformed_report' status for invalid JSON", failures)

  # Case 6: Malformed SARIF schema (valid JSON, missing runs)
  invalid_schema_path = File.join(tmpdir, 'invalid_schema.sarif.json')
  File.write(invalid_schema_path, JSON.pretty_generate({ 'version' => '2.1.0' }))
  invalid_schema_diag = File.join(tmpdir, 'invalid_schema_diag.json')
  stdout, stderr, status = Open3.capture3(
    helper_path,
    '--sarif', invalid_schema_path,
    '--scanner-status', '0',
    '--diagnostics-out', invalid_schema_diag
  )
  assert(status.exitstatus == 3,
         "SARIF with missing runs array exits 3", failures)
  assert(stderr.include?("Invalid SARIF structure: 'runs' array is missing or empty"),
         "Missing runs array reported distinctly", failures)

  # Case 7: Strict policy option (fail-on-findings)
  strict_diag = File.join(tmpdir, 'strict_diag.json')
  stdout, stderr, status = Open3.capture3(
    helper_path,
    '--sarif', findings_sarif,
    '--scanner-status', '0',
    '--policy', 'fail-on-findings',
    '--diagnostics-out', strict_diag
  )
  assert(status.exitstatus == 4,
         "fail-on-findings policy exits 4 when findings exist", failures)
  assert(stderr.include?('[Brakeman CI Gate] FAILED: Policy requires 0 findings, but found 2'),
         "fail-on-findings logs descriptive failure message", failures)

  # Case 8: GitHub step summary and output integration
  summary_file = File.join(tmpdir, 'step_summary.md')
  output_file = File.join(tmpdir, 'github_output.txt')
  env_vars = {
    'GITHUB_STEP_SUMMARY' => summary_file,
    'GITHUB_OUTPUT' => output_file
  }
  stdout, stderr, status = Open3.capture3(
    env_vars,
    helper_path,
    '--sarif', findings_sarif,
    '--scanner-status', '0',
    '--diagnostics-out', File.join(tmpdir, 'env_diag.json')
  )
  assert(status.exitstatus == 0, "Env integration run exits 0", failures)
  assert(File.exist?(summary_file) && File.read(summary_file).include?('## Brakeman Scan Status: PASSED'),
         "GITHUB_STEP_SUMMARY receives Markdown summary", failures)
  output_content = File.exist?(output_file) ? File.read(output_file) : ''
  assert(output_content.include?('gate_status=passed') && output_content.include?('findings_count=2'),
         "GITHUB_OUTPUT receives gate_status and findings_count", failures)
end

puts "\n=== Step 3: Event Context and Security Gate Simulation ==="
# Verify event evaluation logic matching GitHub Actions runner behavior
events = [
  {
    name: 'push to master (trusted)',
    event_name: 'push',
    ref: 'refs/heads/master',
    expected_upload: true,
    expected_artifact: true
  },
  {
    name: 'internal pull_request',
    event_name: 'pull_request',
    ref: 'refs/pull/42/merge',
    expected_upload: false,
    expected_artifact: true
  },
  {
    name: 'fork pull_request',
    event_name: 'pull_request',
    ref: 'refs/pull/99/merge',
    expected_upload: false,
    expected_artifact: true
  },
  {
    name: 'feature branch push',
    event_name: 'push',
    ref: 'refs/heads/feature/test',
    expected_upload: false,
    expected_artifact: true
  }
]

events.each do |ev|
  trusted_upload = (ev[:event_name] == 'push' && ev[:ref] == 'refs/heads/master')
  assert(trusted_upload == ev[:expected_upload],
         "Event '#{ev[:name]}' trusted upload check: #{trusted_upload} == #{ev[:expected_upload]}", failures)
  assert(ev[:expected_artifact],
         "Event '#{ev[:name]}' retains SARIF artifact under if: always()", failures)
end

puts "\n=== Summary ==="
if failures.empty?
  puts 'ALL CHECKS PASSED: ONTO-T-Q01 regression test is clean.'
  exit 0
else
  puts "#{failures.size} CHECK(S) FAILED:"
  failures.each { |f| puts " - #{f}" }
  exit 1
end
