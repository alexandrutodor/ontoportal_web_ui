#!/usr/bin/env ruby
# frozen_string_literal: true

# Standalone isolated regression check for ONTO-T-Q06 CLI validation (Unit 1):
# Proves CLI complete URL validation, rejection before child operations,
# loopback/container preservation, argument boundaries, consistent environment,
# and that shell metacharacters cannot execute in inner nested commands.

require 'open3'
require 'fileutils'
require 'tmpdir'
require 'json'

failures = []

def assert(condition, message, failures)
  if condition
    puts "  [PASS] #{message}"
  else
    puts "  [FAIL] #{message}"
    failures << message
  end
end

ontoportal_path = File.expand_path('../../bin/ontoportal', __dir__)
harness_dir = Dir.mktmpdir('ontoportal_cli_harness')
fake_bin_dir = File.join(harness_dir, 'bin')
FileUtils.mkdir_p(fake_bin_dir)

docker_log_file = File.join(harness_dir, 'docker_calls.jsonl')
run_api_log_file = File.join(harness_dir, 'run_api_calls.jsonl')
rails_log_file = File.join(harness_dir, 'rails_calls.jsonl')
bundle_log_file = File.join(harness_dir, 'bundle_calls.jsonl')
probe_marker_file = File.join(harness_dir, 'probe_marker.txt')

# Create fake docker executable
fake_docker_path = File.join(harness_dir, 'docker')
File.write(fake_docker_path, <<~SH)
  #!/usr/bin/env bash
  set -euo pipefail

  # Record invocation
  ruby -e '
    require "json"
    entry = {
      argv: ARGV,
      env: {
        API_URL: ENV["API_URL"],
        ONTOPORTAL_ISOLATED_TEST: ENV["ONTOPORTAL_ISOLATED_TEST"],
        RAILS_ENV: ENV["RAILS_ENV"]
      }
    }
    File.open("#{docker_log_file}", "a") { |f| f.puts(JSON.generate(entry)) }
  ' -- "$@"

  # If this is docker compose run ... test bash -c ..., execute inner bash in doubled harness
  if [ "$#" -ge 5 ] && [ "$1" = "compose" ] && [ "$2" = "run" ]; then
    # Find "bash" "-c"
    bash_c_found=false
    inner_script=""
    inner_args=()
    while [ "$#" -gt 0 ]; do
      if [ "$1" = "bash" ] && [ "${2:-}" = "-c" ]; then
        bash_c_found=true
        inner_script="$3"
        shift 3
        inner_args=("$@")
        break
      fi
      shift
    done

    if [ "$bash_c_found" = true ]; then
      ( cd "#{harness_dir}" && PATH="#{fake_bin_dir}:#{harness_dir}:$PATH" bash -c "$inner_script" "${inner_args[@]}" )
      exit $?
    fi
  fi
  exit 0
SH
FileUtils.chmod(0755, fake_docker_path)

# Create fake run_api executable
fake_run_api_path = File.join(harness_dir, 'run_api')
File.write(fake_run_api_path, <<~SH)
  #!/usr/bin/env bash
  ruby -e '
    require "json"
    entry = { argv: ARGV, env: { API_URL: ENV["API_URL"] } }
    File.open("#{run_api_log_file}", "a") { |f| f.puts(JSON.generate(entry)) }
  ' -- "$@"
  exit 0
SH
FileUtils.chmod(0755, fake_run_api_path)

# Create fake bin/rails executable in harness
fake_rails_path = File.join(fake_bin_dir, 'rails')
File.write(fake_rails_path, <<~SH)
  #!/usr/bin/env bash
  ruby -e '
    require "json"
    entry = {
      argv: ARGV,
      env: {
        API_URL: ENV["API_URL"],
        ONTOPORTAL_ISOLATED_TEST: ENV["ONTOPORTAL_ISOLATED_TEST"],
        RAILS_ENV: ENV["RAILS_ENV"]
      }
    }
    File.open("#{rails_log_file}", "a") { |f| f.puts(JSON.generate(entry)) }
  ' -- "$@"
  exit 0
SH
FileUtils.chmod(0755, fake_rails_path)

# Create fake bundle executable in harness
fake_bundle_path = File.join(harness_dir, 'bundle')
File.write(fake_bundle_path, <<~SH)
  #!/usr/bin/env bash
  ruby -e '
    require "json"
    entry = {
      argv: ARGV,
      env: {
        API_URL: ENV["API_URL"],
        ONTOPORTAL_ISOLATED_TEST: ENV["ONTOPORTAL_ISOLATED_TEST"],
        RAILS_ENV: ENV["RAILS_ENV"]
      }
    }
    File.open("#{bundle_log_file}", "a") { |f| f.puts(JSON.generate(entry)) }
  ' -- "$@"
  exit 0
SH
FileUtils.chmod(0755, fake_bundle_path)

# Helper to read log records
def read_log(path)
  return [] unless File.exist?(path)
  File.readlines(path).map { |line| JSON.parse(line.strip) rescue nil }.compact
end

def clear_logs(*paths)
  paths.each { |p| FileUtils.rm_f(p) }
end

harness_env = {
  'PATH' => "#{fake_bin_dir}:#{harness_dir}:#{ENV['PATH']}",
  'RUN_API_CMD' => fake_run_api_path
}

begin
  puts "=== Step 1: Demonstrate before-fix vulnerability vs after-fix protection ==="
  # The before-fix vulnerability in base commit 1bb0bfdd:
  # 1. Authority extraction accepted 127.* domain lookalikes like 127.fake.com.
  # 2. Inner bash string interpolation bash -c "... API_URL=$api_url ..." executed
  #    command substitutions before Rails or TestTargetGuard ran.
  #
  # We demonstrate the flaw of unquoted inner shell interpolation:
  probe_vuln_marker = File.join(harness_dir, 'before_fix_vuln_probe.txt')
  FileUtils.rm_f(probe_vuln_marker)

  vuln_api_url = "http://localhost:9393/$(touch #{probe_vuln_marker})"
  # Simulate how the legacy launcher interpolated into double quotes:
  Open3.capture2e('bash', '-c', "echo API_URL=#{vuln_api_url}")
  assert(File.exist?(probe_vuln_marker),
         "Before-fix pattern: unquoted inner shell interpolation executes command substitutions", failures)
  FileUtils.rm_f(probe_vuln_marker)

  # Now verify the after-fix bin/ontoportal rejects the exact same payload before any child execution:
  clear_logs(docker_log_file, run_api_log_file, rails_log_file, bundle_log_file)
  stdout_err, status = Open3.capture2e(harness_env, ontoportal_path, 'test', '--api-url', vuln_api_url)
  assert(!status.success?, "After-fix bin/ontoportal rejects payload with command substitution with non-zero exit status", failures)
  assert(!File.exist?(probe_vuln_marker), "After-fix bin/ontoportal did NOT execute command substitution", failures)
  assert(read_log(docker_log_file).empty?, "After-fix: Docker was NOT invoked for command-substitution payload", failures)
  assert(read_log(run_api_log_file).empty?, "After-fix: run_api was NOT invoked for command-substitution payload", failures)
  assert(stdout_err.include?('Error:'), "After-fix: error message is output on stderr", failures)

  puts "\n=== Step 2: Reject remote, lookalike, and malformed endpoints before child operations ==="
  invalid_targets = [
    # Remote host lookalikes that bypassed legacy 127.* prefix check
    'http://127.fake.com:9393',
    'http://127.0.0.1.nip.io:9393',
    'http://127.1.1.1.evil.org',
    'http://127.300.0.1:9393',
    'http://127.0.0.01:9393',

    # Remote destinations and non-isolated IPs
    'https://data.bioontology.org',
    'http://data.stageportal.lirmm.fr:9393',
    'https://stage.matportal.org',
    'http://example.com',
    'http://192.168.1.1:9393',
    'http://10.0.0.1:9393',
    'http://172.16.0.1:9393',

    # Userinfo, query, fragment, and percent-encoding
    'http://user:pass@localhost:9393',
    'http://localhost:9393@data.bioontology.org',
    'http://localhost:9393?query=val',
    'http://localhost:9393#fragment',
    'http://localhost:9393/%20',

    # Shell metacharacters and operators
    "http://localhost:9393/`touch #{probe_marker_file}`",
    "http://localhost:9393;touch #{probe_marker_file}",
    "http://localhost:9393|cat",
    "http://localhost:9393&cat",
    "http://localhost:9393/foo<bar",
    "http://localhost:9393/foo>bar",

    # Path traversal and invalid base path
    'http://localhost:9393/../secret',
    'http://localhost:9393//double-slash',
    'http://[localhost]:9393',
    'http://localhost:9393/[path]',

    # Malformed ports and schemes
    'http://localhost:0',
    'http://localhost:65536',
    'http://localhost:99999',
    'http://localhost:notaport',
    'ftp://localhost:9393',
    'javascript:alert(1)'
  ]

  invalid_targets.each do |target|
    clear_logs(docker_log_file, run_api_log_file)
    stdout_err, status = Open3.capture2e(harness_env, ontoportal_path, 'test', '--api-url', target)

    assert(!status.success?, "Target #{target.inspect} exits with non-zero status", failures)
    assert(read_log(docker_log_file).empty?, "Target #{target.inspect} dispatched 0 docker calls", failures)
    assert(read_log(run_api_log_file).empty?, "Target #{target.inspect} dispatched 0 run_api calls", failures)
  end

  assert(!File.exist?(probe_marker_file), "Metacharacter probe marker file was NEVER created on disk", failures)

  puts "\n=== Step 3: Reject remote endpoint configured via API_URL environment variable ==="
  clear_logs(docker_log_file, run_api_log_file)
  env_override = harness_env.merge('API_URL' => 'http://127.fake.com:9393')
  stdout_err, status = Open3.capture2e(env_override, ontoportal_path, 'test')
  assert(!status.success?, "API_URL=http://127.fake.com exits with non-zero status", failures)
  assert(read_log(docker_log_file).empty?, "API_URL=http://127.fake.com dispatched 0 docker calls", failures)
  assert(read_log(run_api_log_file).empty?, "API_URL=http://127.fake.com dispatched 0 run_api calls", failures)

  puts "\n=== Step 4: Approved local targets pass preflight and invoke container ==="
  approved_targets = [
    'http://localhost:9393',
    'http://localhost:9393/',
    'http://localhost:9393/api',
    'http://localhost:9393/api/v1',
    'http://127.0.0.1:9393',
    'http://127.0.0.2:8080',
    'http://127.1.2.3:9393',
    'http://0.0.0.0:9393',
    'http://[::1]:9393',
    'https://[::1]:443/api',
    'http://ontoportal_docker-api:9393',
    'http://ontoportal_docker:9393',
    'http://ontologies_api:9393'
  ]

  approved_targets.each do |target|
    clear_logs(docker_log_file, run_api_log_file)
    stdout_err, status = Open3.capture2e(harness_env, ontoportal_path, 'test', '--api-url', target)

    assert(status.success?, "Approved target #{target.inspect} exits with success", failures)

    docker_calls = read_log(docker_log_file)
    assert(docker_calls.size >= 1, "Approved target #{target.inspect} invoked docker compose run", failures)

    if docker_calls.any?
      call = docker_calls.first
      argv = call['argv']
      # Must pass -e ONTOPORTAL_ISOLATED_TEST=1 -e API_URL=target -e RAILS_ENV=test
      assert(argv.include?('ONTOPORTAL_ISOLATED_TEST=1'), "Passes ONTOPORTAL_ISOLATED_TEST=1 in docker argv", failures)
      assert(argv.include?("API_URL=#{target}"), "Passes API_URL=#{target} in docker argv", failures)
      assert(argv.include?('RAILS_ENV=test'), "Passes RAILS_ENV=test in docker argv", failures)

      # Target must be passed as positional argv parameter to inner script, NOT interpolated
      c_idx = argv.index('-c')
      assert(!c_idx.nil?, "Invokes inner bash with -c", failures)
      if c_idx
        inner_script = argv[c_idx + 1]
        assert(!inner_script.include?(target), "Inner bash script does NOT interpolate API URL into script source", failures)
        # Positional parameter $1 must be target
        assert_equal = argv[c_idx + 3] == target
        assert(assert_equal, "Positional parameter following _ is target API URL", failures)
      end
    end

    # Explicit --api-url must NOT trigger local API bootstrap
    assert(read_log(run_api_log_file).empty?, "Approved target #{target.inspect} did NOT run bin/run_api", failures)
  end

  puts "\n=== Step 5: Default target starts local API bootstrap and invokes container ==="
  clear_logs(docker_log_file, run_api_log_file)
  env_clean = harness_env.dup
  env_clean.delete('API_URL')
  stdout_err, status = Open3.capture2e(env_clean, ontoportal_path, 'test')

  assert(status.success?, "Default test invocation exits with success", failures)
  run_api_calls = read_log(run_api_log_file)
  assert(run_api_calls.size == 1, "Default test invocation runs bin/run_api exactly once", failures)

  docker_calls = read_log(docker_log_file)
  assert(docker_calls.size >= 1, "Default test invocation invoked docker", failures)
  if docker_calls.any?
    call = docker_calls.first
    assert(call['argv'].include?('API_URL=http://localhost:9393'), "Default test invocation sets API_URL=http://localhost:9393", failures)
  end

  puts "\n=== Step 6: Preserve argument boundaries and prevent inner shell execution ==="
  test_arg_probe = File.join(harness_dir, 'test_arg_probe.txt')
  FileUtils.rm_f(test_arg_probe)
  clear_logs(docker_log_file, run_api_log_file, bundle_log_file, rails_log_file)

  # Pass test arguments with spaces, options, and shell metacharacters
  user_test_args = [
    'test/models/user_test.rb:25',
    '-n',
    'test query with spaces',
    "test/$(touch #{test_arg_probe})"
  ]

  stdout_err, status = Open3.capture2e(harness_env, ontoportal_path, 'test', '--api-url', 'http://localhost:9393', *user_test_args)
  assert(status.success?, "Execution with user test arguments exits with success", failures)

  # Metacharacter inside user test argument must NOT have executed
  assert(!File.exist?(test_arg_probe), "Shell metacharacters in user test arguments were NOT executed", failures)

  # Check that bundle exec rails test received all 4 arguments with exact boundaries intact
  bundle_calls = read_log(bundle_log_file)
  test_exec_call = bundle_calls.find { |c| c['argv'] && c['argv'].include?('test') }
  assert(!test_exec_call.nil?, "Fake bundle received exec rails test call", failures)

  if test_exec_call
    argv = test_exec_call['argv']
    assert(argv.include?('test/models/user_test.rb:25'), "Preserved exact argument 1", failures)
    assert(argv.include?('-n'), "Preserved option flag -n", failures)
    assert(argv.include?('test query with spaces'), "Preserved argument with spaces intact (no word splitting)", failures)
    assert(argv.include?("test/$(touch #{test_arg_probe})"), "Preserved argument with shell syntax intact without evaluation", failures)
  end

  puts "\n=== Step 7: Consistent environment applied to both preparation and execution ==="
  rails_calls = read_log(rails_log_file)
  db_prepare_call = rails_calls.find { |c| c['argv'] && c['argv'].include?('db:prepare') }
  assert(!db_prepare_call.nil?, "Fake rails received db:prepare call", failures)

  if db_prepare_call
    env = db_prepare_call['env']
    assert(env['RAILS_ENV'] == 'test', "db:prepare has RAILS_ENV=test", failures)
    assert(env['ONTOPORTAL_ISOLATED_TEST'] == '1', "db:prepare has ONTOPORTAL_ISOLATED_TEST=1", failures)
    assert(env['API_URL'] == 'http://localhost:9393', "db:prepare has API_URL=http://localhost:9393", failures)
  end

  if test_exec_call
    env = test_exec_call['env']
    assert(env['RAILS_ENV'] == 'test', "rails test has RAILS_ENV=test", failures)
    assert(env['ONTOPORTAL_ISOLATED_TEST'] == '1', "rails test has ONTOPORTAL_ISOLATED_TEST=1", failures)
    assert(env['API_URL'] == 'http://localhost:9393', "rails test has API_URL=http://localhost:9393", failures)
  end

ensure
  FileUtils.rm_rf(harness_dir)
end

puts "\n" + ('=' * 60)
if failures.empty?
  puts "ALL CHECKS PASSED: ONTO-T-Q06 CLI validation and launcher harness verified offline."
  exit 0
else
  puts "FAILED CHECKS (#{failures.size}):"
  failures.each { |f| puts "  - #{f}" }
  exit 1
end
