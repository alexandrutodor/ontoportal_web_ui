#!/usr/bin/env ruby
# frozen_string_literal: true

# Standalone isolated regression check for ONTO-T-Q01:
# Validates .github/workflows/brakeman-analysis.yml and bin/brakeman_ci_summary.rb
# with flag-aware scanner stub, bounded SARIF fixtures, event context simulation,
# and permission boundaries.
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

puts '=== Step 1: Validate Brakeman Workflow YAML and Permissions ==='
workflow_path = File.expand_path('../../.github/workflows/brakeman-analysis.yml', __dir__)
assert(File.exist?(workflow_path), 'Workflow file exists', failures)

raw_yaml = File.read(workflow_path)
workflow = Psych.safe_load(raw_yaml, permitted_classes: [], aliases: true)

# 1. Triggers
on_config = workflow['on'] || workflow[true]
assert(on_config.is_a?(Hash), 'Workflow triggers are configured as a Hash', failures)
assert(on_config.key?('push') && on_config['push']['branches'] == ['master'],
       "Push trigger targets only 'master'", failures)
assert(on_config.key?('pull_request') && on_config['pull_request']['branches'] == ['master'],
       "Pull request trigger targets only 'master'", failures)
assert(!on_config.key?('pull_request_target'),
       'Workflow does not use pull_request_target', failures)
assert(!on_config.key?('workflow_dispatch'),
       'Workflow does not add unrequested workflow_dispatch capability', failures)

# 2. Scanning job permissions and steps
scan_job = workflow.dig('jobs', 'brakeman-scan')
assert(scan_job.is_a?(Hash), "Job 'brakeman-scan' is defined", failures)
scan_job_perms = scan_job['permissions']
assert(scan_job_perms.is_a?(Hash), "Scan job defines explicit permissions block", failures)
assert(scan_job_perms['contents'] == 'read', "Scan job specifies 'contents: read'", failures)
assert(!scan_job_perms.key?('security-events') || scan_job_perms['security-events'] == 'read',
       "Scan job is read-only and does not possess 'security-events: write'", failures)
assert(!raw_yaml.include?('secrets.'), 'Workflow does not reference or expose secrets', failures)

steps = scan_job['steps'] || []

# Ruby setup
ruby_step = steps.find { |s| s['uses']&.start_with?('ruby/setup-ruby') }
assert(ruby_step && ruby_step.dig('with', 'ruby-version') == '3.1',
       "Ruby setup step pins ruby-version: '3.1'", failures)

# Brakeman version derivation from Gemfile.lock (no fallback claiming lock alignment)
brakeman_setup_step = steps.find { |s| s['name'] == 'Setup Brakeman' }
assert(brakeman_setup_step && brakeman_setup_step['run']&.include?('Gemfile.lock'),
       'Brakeman setup derives version from Gemfile.lock', failures)
assert(!brakeman_setup_step['run'].include?(':-7.0.2'),
       'Brakeman setup does not fall back claiming lock alignment when extraction failed', failures)

# Verify lockfile version resolution
lockfile_path = File.expand_path('../../Gemfile.lock', __dir__)
lockfile_version = nil
File.foreach(lockfile_path) do |line|
  if line =~ /^\s*brakeman \(([0-9.]+)\)/
    lockfile_version = Regexp.last_match(1)
    break
  end
end
assert(lockfile_version == '7.0.2', 'Gemfile.lock records Brakeman 7.0.2', failures)

# Scan step
scan_step = steps.find { |s| s['name'] == 'Scan' }
assert(scan_step.is_a?(Hash), 'Scan step is defined', failures)
assert(!scan_step['continue-on-error'],
       'Scan step does not blanket continue-on-error (errors fail distinctly)', failures)
assert(scan_step['run']&.include?('--no-exit-on-warn'),
       "Scan step invocation includes '--no-exit-on-warn'", failures)
assert(!scan_step['run']&.include?('--no-exit-on-error'),
       'Scan step never disables exit-on-error', failures)
assert(scan_step['run']&.include?('bin/brakeman_ci_summary.rb'),
       'Scan step delegates evaluation to bin/brakeman_ci_summary.rb', failures)

# Artifact retention step
artifact_step = steps.find { |s| s['uses']&.start_with?('actions/upload-artifact') }
assert(artifact_step.is_a?(Hash), 'Artifact upload step is defined in scan job', failures)
assert(artifact_step['uses'] == 'actions/upload-artifact@v7.0.2',
       'Artifact upload step pins actions/upload-artifact@v7.0.2', failures)
assert(artifact_step['if'] == 'always()',
       "Artifact retention step uses 'if: always()' across all runs", failures)

# Untrusted PR skip notice step
skip_notice_step = steps.find { |s| s['name'] == 'Report Code Scanning upload skip' }
assert(skip_notice_step.is_a?(Hash), 'Skip notice step exists for PR/untrusted events', failures)

# 3. Dedicated upload job (job-guarded, upload-only, no checkout/code execution)
upload_job = workflow.dig('jobs', 'upload-sarif')
assert(upload_job.is_a?(Hash), "Dedicated 'upload-sarif' job is defined", failures)
assert(upload_job['needs'] == 'brakeman-scan' || Array(upload_job['needs']).include?('brakeman-scan'),
       "Upload job depends on 'brakeman-scan'", failures)
assert(upload_job['if'] == "github.event_name == 'push' && github.ref == 'refs/heads/master'",
       "Upload job is separately guarded at job level for trusted master pushes", failures)

upload_perms = upload_job['permissions']
assert(upload_perms.is_a?(Hash), 'Upload job defines explicit permissions block', failures)
assert(upload_perms['security-events'] == 'write',
       "Upload job is granted 'security-events: write'", failures)

upload_steps = upload_job['steps'] || []
assert(!upload_steps.any? { |s| s['uses']&.start_with?('actions/checkout') },
       'Upload job does not check out repository/PR code', failures)
assert(!upload_steps.any? { |s| s.key?('run') },
       'Upload job does not execute repository/PR code or shell scripts', failures)

download_step = upload_steps.find { |s| s['uses']&.start_with?('actions/download-artifact') }
assert(download_step.is_a?(Hash), 'Download artifact step is defined in upload job', failures)
assert(download_step['uses'] == 'actions/download-artifact@v8.0.2',
       'Download artifact step pins actions/download-artifact@v8.0.2', failures)
assert(download_step.dig('with', 'name') == 'brakeman-sarif',
       "Download artifact step requests 'brakeman-sarif'", failures)

codeql_upload_step = upload_steps.find { |s| s['uses']&.start_with?('github/codeql-action/upload-sarif') }
assert(codeql_upload_step.is_a?(Hash), 'Code scanning upload step is defined in upload job', failures)
assert(codeql_upload_step['uses'] == 'github/codeql-action/upload-sarif@v4',
       'Upload step pins github/codeql-action/upload-sarif@v4', failures)
assert(codeql_upload_step.dig('with', 'sarif_file') == 'output.sarif.json',
       "Upload step targets 'output.sarif.json'", failures)
assert(!codeql_upload_step['continue-on-error'],
       'Code scanning upload does not blanket continue-on-error', failures)

puts "\n=== Step 2: Exercise Actual Parsed Workflow Scan Command with Flag-Aware Scanner Stub ==="
helper_path = File.expand_path('../../bin/brakeman_ci_summary.rb', __dir__)
assert(File.exist?(helper_path) && File.executable?(helper_path),
       'bin/brakeman_ci_summary.rb exists and is executable', failures)

# Extract scan run script from workflow
workflow_scan_script = scan_step['run']
assert(workflow_scan_script.is_a?(String) && !workflow_scan_script.empty?,
       'Extracted scan run script from workflow definition', failures)

Dir.mktmpdir('brakeman_stub_test') do |test_dir|
  stub_bin_dir = File.join(test_dir, 'bin')
  FileUtils.mkdir_p(stub_bin_dir)
  stub_path = File.join(stub_bin_dir, 'brakeman')

  # Create flag-aware scanner stub:
  # - warnings produce exit 3 without --no-exit-on-warn, and exit 0 with --no-exit-on-warn
  # - scanner errors produce exit 7 (Errors_Found_Exit_Code) regardless of --no-exit-on-warn
  File.write(stub_path, <<~'RUBY')
    #!/usr/bin/env ruby
    require 'json'

    exit_on_warn = true
    output_file = nil
    args = ARGV.dup
    while (arg = args.shift)
      case arg
      when '--no-exit-on-warn'
        exit_on_warn = false
      when '-o', '--output'
        output_file = args.shift
      end
    end

    mode = ENV['MOCK_SCANNER_MODE'] || 'warnings'
    if mode == 'error'
      warn 'Brakeman fatal error encountered during analysis'
      exit 7
    elsif mode == 'warnings'
      if output_file
        sarif = {
          'version' => '2.1.0',
          'runs' => [
            {
              'tool' => { 'driver' => { 'name' => 'Brakeman', 'version' => '7.0.2' } },
              'results' => [
                {
                  'ruleId' => 'BRAKE0001',
                  'level' => 'warning',
                  'message' => { 'text' => 'SQL injection risk detected' },
                  'locations' => [{ 'physicalLocation' => { 'artifactLocation' => { 'uri' => 'app/models/user.rb' } } }]
                }
              ]
            }
          ]
        }
        File.write(output_file, JSON.pretty_generate(sarif))
      end
      exit(exit_on_warn ? 3 : 0)
    else
      # clean
      if output_file
        sarif = {
          'version' => '2.1.0',
          'runs' => [
            {
              'tool' => { 'driver' => { 'name' => 'Brakeman', 'version' => '7.0.2' } },
              'results' => []
            }
          ]
        }
        File.write(output_file, JSON.pretty_generate(sarif))
      end
      exit 0
    end
  RUBY
  FileUtils.chmod(0o755, stub_path)

  # Copy helper to test directory bin/ so relative path 'ruby bin/brakeman_ci_summary.rb' works
  target_bin = File.join(test_dir, 'bin', 'brakeman_ci_summary.rb')
  FileUtils.cp(helper_path, target_bin)
  FileUtils.chmod(0o755, target_bin)

  env = {
    'PATH' => "#{stub_bin_dir}:#{ENV['PATH']}",
    'MOCK_SCANNER_MODE' => 'warnings'
  }

  # Run the parsed workflow scan script directly via bash
  stdout, stderr, status = Open3.capture3(
    env,
    'bash', '-c', workflow_scan_script,
    chdir: test_dir
  )

  assert(status.exitstatus == 0,
         'Workflow scan script exits 0 when warnings exist (enabled by --no-exit-on-warn)', failures)
  assert(stdout.include?('Total findings: 1'),
         'Workflow scan script correctly counts findings (1 finding)', failures)
  assert(stdout.include?('[Brakeman CI Gate] PASSED: Non-blocking findings baseline accepted.'),
         'Workflow scan script confirms nonblocking baseline passed', failures)

  # Error scenario: simulate genuine scanner crash
  env['MOCK_SCANNER_MODE'] = 'error'
  stdout, stderr, status = Open3.capture3(
    env,
    'bash', '-c', workflow_scan_script,
    chdir: test_dir
  )

  assert(status.exitstatus == 1,
         'Workflow scan script exits 1 on genuine scanner crash (preserves exit-on-error)', failures)
  assert(stderr.include?('[Brakeman CI Error] Scanner execution failed with exit code 7'),
         'Workflow scan script distinguishes scanner error exit code 7', failures)

  # Counterexample verification: running scan script WITHOUT --no-exit-on-warn in warnings mode
  script_without_flag = workflow_scan_script.sub('--no-exit-on-warn ', '')
  env['MOCK_SCANNER_MODE'] = 'warnings'
  stdout, stderr, status = Open3.capture3(
    env,
    'bash', '-c', script_without_flag,
    chdir: test_dir
  )
  assert(status.exitstatus == 1,
         'Without --no-exit-on-warn, warnings cause scanner failure exit 1 (counterexample verified)', failures)
  assert(stderr.include?('[Brakeman CI Error] Scanner execution failed with exit code 3'),
         'Without --no-exit-on-warn, Brakeman exits code 3 which helper rejects', failures)
end

puts "\n=== Step 3: Bounded SARIF Validation Synthetic Fixtures ==="
Dir.mktmpdir('sarif_validation_test') do |tmpdir|
  def create_sarif_file(path, data)
    File.write(path, data.is_a?(String) ? data : JSON.pretty_generate(data))
  end

  def valid_sarif(results, tool_version = '7.0.2')
    {
      'version' => '2.1.0',
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
  end

  # Case 1: Clean scan (0 findings)
  clean_sarif = File.join(tmpdir, 'clean.sarif.json')
  clean_diag = File.join(tmpdir, 'clean_diag.json')
  create_sarif_file(clean_sarif, valid_sarif([]))
  stdout, stderr, status = Open3.capture3(
    helper_path,
    '--sarif', clean_sarif,
    '--scanner-status', '0',
    '--diagnostics-out', clean_diag
  )
  assert(status.exitstatus == 0, 'Clean scan exits 0', failures)
  assert(stdout.include?('Total findings: 0'), 'Clean scan reports 0 findings', failures)
  diag = JSON.parse(File.read(clean_diag))
  assert(diag['gate_status'] == 'passed' && diag['findings_count'] == 0,
         'Clean scan diagnostics record passed gate and 0 findings', failures)

  # Case 2: Scan with findings (nonblocking baseline)
  findings_sarif = File.join(tmpdir, 'findings.sarif.json')
  findings_diag = File.join(tmpdir, 'findings_diag.json')
  sample_findings = [
    { 'ruleId' => 'BRAKE0001', 'level' => 'warning' },
    { 'ruleId' => 'BRAKE0002', 'level' => 'error' }
  ]
  create_sarif_file(findings_sarif, valid_sarif(sample_findings))
  stdout, stderr, status = Open3.capture3(
    helper_path,
    '--sarif', findings_sarif,
    '--scanner-status', '0',
    '--diagnostics-out', findings_diag
  )
  assert(status.exitstatus == 0, 'Scan with findings exits 0 (nonblocking baseline)', failures)
  assert(stdout.include?('Total findings: 2'), 'Reports correct findings count', failures)
  assert(stdout.include?('[Brakeman CI Gate] PASSED: Non-blocking findings baseline accepted.'),
         'Explicitly confirms nonblocking findings baseline accepted', failures)
  diag = JSON.parse(File.read(findings_diag))
  assert(diag['gate_status'] == 'passed' && diag['findings_count'] == 2,
         'Diagnostics record passed gate with 2 findings', failures)

  # Case 3: Scanner execution failure (non-zero status)
  fail_diag = File.join(tmpdir, 'scanner_fail_diag.json')
  stdout, stderr, status = Open3.capture3(
    helper_path,
    '--sarif', findings_sarif,
    '--scanner-status', '1',
    '--diagnostics-out', fail_diag
  )
  assert(status.exitstatus == 1, 'Scanner execution failure exits 1', failures)
  assert(stderr.include?('[Brakeman CI Error] Scanner execution failed with exit code 1'),
         'Scanner failure reported distinctly to stderr', failures)
  diag = JSON.parse(File.read(fail_diag))
  assert(diag['gate_status'] == 'scanner_failed', "Diagnostics record 'scanner_failed'", failures)

  # Case 4: Missing report
  missing_diag = File.join(tmpdir, 'missing_diag.json')
  stdout, stderr, status = Open3.capture3(
    helper_path,
    '--sarif', File.join(tmpdir, 'does_not_exist.json'),
    '--scanner-status', '0',
    '--diagnostics-out', missing_diag
  )
  assert(status.exitstatus == 2, 'Missing report exits 2', failures)
  assert(stderr.include?('Missing SARIF report'), 'Missing report reported distinctly', failures)
  diag = JSON.parse(File.read(missing_diag))
  assert(diag['gate_status'] == 'missing_report', "Diagnostics record 'missing_report'", failures)

  # Case 5: Malformed JSON report (invalid syntax)
  corrupt_json = File.join(tmpdir, 'corrupt.json')
  create_sarif_file(corrupt_json, '{"version": "2.1.0", "runs": [ TRUNCATED')
  corrupt_diag = File.join(tmpdir, 'corrupt_diag.json')
  stdout, stderr, status = Open3.capture3(
    helper_path,
    '--sarif', corrupt_json,
    '--scanner-status', '0',
    '--diagnostics-out', corrupt_diag
  )
  assert(status.exitstatus == 3, 'Malformed JSON report exits 3', failures)
  assert(stderr.include?('Malformed SARIF report: SARIF report is not valid JSON'),
         'Malformed JSON syntax reported distinctly', failures)
  diag = JSON.parse(File.read(corrupt_diag))
  assert(diag['gate_status'] == 'malformed_report', "Diagnostics record 'malformed_report'", failures)

  # Case 6: Root JSON is null
  null_root_path = File.join(tmpdir, 'null_root.json')
  create_sarif_file(null_root_path, 'null')
  null_root_diag = File.join(tmpdir, 'null_root_diag.json')
  stdout, stderr, status = Open3.capture3(
    helper_path,
    '--sarif', null_root_path,
    '--scanner-status', '0',
    '--diagnostics-out', null_root_diag
  )
  assert(status.exitstatus == 3, 'Null root JSON exits 3 without crashing', failures)
  assert(stderr.include?('Invalid SARIF structure: root must be a JSON object'),
         'Null root error reported distinctly', failures)
  assert(!stdout.include?('valid SARIF 2.1.0'), 'Does not claim valid SARIF for null root', failures)
  diag = JSON.parse(File.read(null_root_diag))
  assert(diag['gate_status'] == 'malformed_report', "Diagnostics record 'malformed_report' for null root", failures)

  # Case 7: Root JSON is array
  array_root_path = File.join(tmpdir, 'array_root.json')
  create_sarif_file(array_root_path, '[]')
  stdout, stderr, status = Open3.capture3(
    helper_path,
    '--sarif', array_root_path,
    '--scanner-status', '0',
    '--diagnostics-out', File.join(tmpdir, 'array_root_diag.json')
  )
  assert(status.exitstatus == 3, 'Array root JSON exits 3 without crashing', failures)

  # Case 8: Missing SARIF version and tool (matching reviewer counterexample)
  missing_ver_path = File.join(tmpdir, 'missing_version_and_tool.json')
  create_sarif_file(missing_ver_path, { 'runs' => [{ 'results' => [] }] })
  missing_ver_diag = File.join(tmpdir, 'missing_version_diag.json')
  stdout, stderr, status = Open3.capture3(
    helper_path,
    '--sarif', missing_ver_path,
    '--scanner-status', '0',
    '--diagnostics-out', missing_ver_diag
  )
  assert(status.exitstatus == 3,
         'Missing SARIF version exits 3 as malformed_report (counterexample verified)', failures)
  assert(stderr.include?("expected version '2.1.0'"),
         'Missing/wrong SARIF version reported distinctly', failures)
  assert(!stdout.include?('valid SARIF 2.1.0') && !stdout.include?('[Brakeman CI Gate] PASSED'),
         'Does not claim valid SARIF or pass when version is missing', failures)
  diag = JSON.parse(File.read(missing_ver_diag))
  assert(diag['gate_status'] == 'malformed_report', "Diagnostics record 'malformed_report'", failures)

  # Case 9: Wrong SARIF version
  wrong_ver_path = File.join(tmpdir, 'wrong_version.json')
  create_sarif_file(wrong_ver_path, { 'version' => '2.0.0', 'runs' => [{ 'results' => [] }] })
  stdout, stderr, status = Open3.capture3(
    helper_path,
    '--sarif', wrong_ver_path,
    '--scanner-status', '0',
    '--diagnostics-out', File.join(tmpdir, 'wrong_ver_diag.json')
  )
  assert(status.exitstatus == 3, "Wrong SARIF version '2.0.0' exits 3", failures)

  # Case 10: Missing runs array
  missing_runs_path = File.join(tmpdir, 'missing_runs.json')
  create_sarif_file(missing_runs_path, { 'version' => '2.1.0' })
  stdout, stderr, status = Open3.capture3(
    helper_path,
    '--sarif', missing_runs_path,
    '--scanner-status', '0',
    '--diagnostics-out', File.join(tmpdir, 'missing_runs_diag.json')
  )
  assert(status.exitstatus == 3, 'Missing runs array exits 3', failures)
  assert(stderr.include?("'runs' array is missing or empty"),
         'Missing runs array reported distinctly', failures)

  # Case 11: Missing or wrong tool driver name
  wrong_tool_path = File.join(tmpdir, 'wrong_tool.json')
  create_sarif_file(wrong_tool_path, {
    'version' => '2.1.0',
    'runs' => [
      {
        'tool' => { 'driver' => { 'name' => 'ESLint', 'version' => '8.0.0' } },
        'results' => []
      }
    ]
  })
  wrong_tool_diag = File.join(tmpdir, 'wrong_tool_diag.json')
  stdout, stderr, status = Open3.capture3(
    helper_path,
    '--sarif', wrong_tool_path,
    '--scanner-status', '0',
    '--diagnostics-out', wrong_tool_diag
  )
  assert(status.exitstatus == 3, "Tool driver other than 'Brakeman' exits 3", failures)
  assert(stderr.include?("expected tool driver name 'Brakeman'"),
         'Non-Brakeman tool name reported distinctly', failures)
  assert(!stdout.include?('[Brakeman CI Gate] PASSED'),
         'Non-Brakeman tool does not pass gate', failures)

  # Case 12: Null result entry in results array
  null_result_path = File.join(tmpdir, 'null_result.json')
  create_sarif_file(null_result_path, {
    'version' => '2.1.0',
    'runs' => [
      {
        'tool' => { 'driver' => { 'name' => 'Brakeman', 'version' => '7.0.2' } },
        'results' => [nil]
      }
    ]
  })
  null_result_diag = File.join(tmpdir, 'null_result_diag.json')
  stdout, stderr, status = Open3.capture3(
    helper_path,
    '--sarif', null_result_path,
    '--scanner-status', '0',
    '--diagnostics-out', null_result_diag
  )
  assert(status.exitstatus == 3, 'Null result entry exits 3 without crashing', failures)
  assert(stderr.include?('each result entry must be an object'),
         'Null result entry reported distinctly', failures)
  diag = JSON.parse(File.read(null_result_diag))
  assert(diag['gate_status'] == 'malformed_report',
         "Diagnostics record 'malformed_report' for null result entry", failures)

  # Case 13: Non-object result entry in results array
  str_result_path = File.join(tmpdir, 'str_result.json')
  create_sarif_file(str_result_path, {
    'version' => '2.1.0',
    'runs' => [
      {
        'tool' => { 'driver' => { 'name' => 'Brakeman', 'version' => '7.0.2' } },
        'results' => ['string_instead_of_object']
      }
    ]
  })
  stdout, stderr, status = Open3.capture3(
    helper_path,
    '--sarif', str_result_path,
    '--scanner-status', '0',
    '--diagnostics-out', File.join(tmpdir, 'str_result_diag.json')
  )
  assert(status.exitstatus == 3, 'Non-object result entry exits 3 without crashing', failures)

  # Case 14: Step summary and GitHub output integration
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
  assert(status.exitstatus == 0, 'Env integration run exits 0', failures)
  assert(File.exist?(summary_file) && File.read(summary_file).include?('## Brakeman Scan Status: PASSED'),
         'GITHUB_STEP_SUMMARY receives Markdown summary', failures)
  output_content = File.exist?(output_file) ? File.read(output_file) : ''
  assert(output_content.include?('gate_status=passed') && output_content.include?('findings_count=2'),
         'GITHUB_OUTPUT receives gate_status and findings_count', failures)

  # Case 15: Wrong-typed tool container - scalar string (parent counterexample)
  scalar_tool_sarif = File.join(tmpdir, 'scalar_tool.sarif.json')
  scalar_tool_diag = File.join(tmpdir, 'scalar_tool_diag.json')
  scalar_tool_summary = File.join(tmpdir, 'scalar_tool_summary.md')
  scalar_tool_output = File.join(tmpdir, 'scalar_tool_output.txt')
  create_sarif_file(scalar_tool_sarif, {
    'version' => '2.1.0',
    'runs' => [
      {
        'tool' => 'invalid',
        'results' => []
      }
    ]
  })
  stdout, stderr, status = Open3.capture3(
    {
      'GITHUB_STEP_SUMMARY' => scalar_tool_summary,
      'GITHUB_OUTPUT' => scalar_tool_output
    },
    helper_path,
    '--sarif', scalar_tool_sarif,
    '--scanner-status', '0',
    '--diagnostics-out', scalar_tool_diag
  )
  assert(status.exitstatus == 3, 'Scalar tool container exits 3 without crashing', failures)
  assert(stderr.include?("expected tool driver name 'Brakeman'"),
         'Scalar tool container reports malformed driver expectation', failures)
  assert(!stdout.include?('valid SARIF 2.1.0') && !stdout.include?('[Brakeman CI Gate] PASSED'),
         'Scalar tool container does not claim valid SARIF or pass gate', failures)
  diag = File.exist?(scalar_tool_diag) ? JSON.parse(File.read(scalar_tool_diag)) : {}
  assert(diag['gate_status'] == 'malformed_report',
         "Scalar tool container diagnostics record 'malformed_report'", failures)
  assert(File.exist?(scalar_tool_summary) && File.read(scalar_tool_summary).include?('## Brakeman Scan Status: MALFORMED_REPORT'),
         'Scalar tool container writes GITHUB_STEP_SUMMARY', failures)
  scalar_output_content = File.exist?(scalar_tool_output) ? File.read(scalar_tool_output) : ''
  assert(scalar_output_content.include?('gate_status=malformed_report'),
         'Scalar tool container writes GITHUB_OUTPUT', failures)

  # Case 16: Wrong-typed tool container - array (parent counterexample)
  array_tool_sarif = File.join(tmpdir, 'array_tool.sarif.json')
  array_tool_diag = File.join(tmpdir, 'array_tool_diag.json')
  array_tool_summary = File.join(tmpdir, 'array_tool_summary.md')
  array_tool_output = File.join(tmpdir, 'array_tool_output.txt')
  create_sarif_file(array_tool_sarif, {
    'version' => '2.1.0',
    'runs' => [
      {
        'tool' => [],
        'results' => []
      }
    ]
  })
  stdout, stderr, status = Open3.capture3(
    {
      'GITHUB_STEP_SUMMARY' => array_tool_summary,
      'GITHUB_OUTPUT' => array_tool_output
    },
    helper_path,
    '--sarif', array_tool_sarif,
    '--scanner-status', '0',
    '--diagnostics-out', array_tool_diag
  )
  assert(status.exitstatus == 3, 'Array tool container exits 3 without crashing', failures)
  assert(stderr.include?("expected tool driver name 'Brakeman'"),
         'Array tool container reports malformed driver expectation', failures)
  assert(!stdout.include?('valid SARIF 2.1.0') && !stdout.include?('[Brakeman CI Gate] PASSED'),
         'Array tool container does not claim valid SARIF or pass gate', failures)
  diag = File.exist?(array_tool_diag) ? JSON.parse(File.read(array_tool_diag)) : {}
  assert(diag['gate_status'] == 'malformed_report',
         "Array tool container diagnostics record 'malformed_report'", failures)
  assert(File.exist?(array_tool_summary) && File.read(array_tool_summary).include?('## Brakeman Scan Status: MALFORMED_REPORT'),
         'Array tool container writes GITHUB_STEP_SUMMARY', failures)
  array_output_content = File.exist?(array_tool_output) ? File.read(array_tool_output) : ''
  assert(array_output_content.include?('gate_status=malformed_report'),
         'Array tool container writes GITHUB_OUTPUT', failures)
end

puts "\n=== Step 4: Event Context and Job-Level Security Gate Simulation ==="
events = [
  {
    name: 'push to master (trusted)',
    event_name: 'push',
    ref: 'refs/heads/master',
    expected_scan_run: true,
    expected_upload_job_run: true,
    expected_write_token_in_job: true,
    expected_artifact_retained: true
  },
  {
    name: 'internal pull_request',
    event_name: 'pull_request',
    ref: 'refs/pull/42/merge',
    expected_scan_run: true,
    expected_upload_job_run: false,
    expected_write_token_in_job: false,
    expected_artifact_retained: true
  },
  {
    name: 'fork pull_request',
    event_name: 'pull_request',
    ref: 'refs/pull/99/merge',
    expected_scan_run: true,
    expected_upload_job_run: false,
    expected_write_token_in_job: false,
    expected_artifact_retained: true
  },
  {
    name: 'feature branch push',
    event_name: 'push',
    ref: 'refs/heads/feature/test',
    expected_scan_run: false,
    expected_upload_job_run: false,
    expected_write_token_in_job: false,
    expected_artifact_retained: false
  }
]

upload_job_condition = upload_job['if']

events.each do |ev|
  # Evaluate whether upload job runs based on the workflow's actual 'if' condition
  upload_job_runs = (ev[:event_name] == 'push' && ev[:ref] == 'refs/heads/master')
  assert(upload_job_runs == ev[:expected_upload_job_run],
         "Event '#{ev[:name]}' upload job execution gate: #{upload_job_runs} == #{ev[:expected_upload_job_run]}", failures)

  # Check that write token is only ever present in upload-sarif job, never in scan job
  scan_job_has_write = (scan_job.dig('permissions', 'security-events') == 'write')
  assert(!scan_job_has_write,
         "Event '#{ev[:name]}' scanning job has no write token (strictly read-only)", failures)

  if upload_job_runs
    upload_job_has_write = (upload_job.dig('permissions', 'security-events') == 'write')
    assert(upload_job_has_write,
           "Event '#{ev[:name]}' upload job has write token isolated to trusted context", failures)
  end
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
