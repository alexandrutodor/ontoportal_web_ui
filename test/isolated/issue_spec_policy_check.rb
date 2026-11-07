#!/usr/bin/env ruby
# frozen_string_literal: true

# Standalone isolated regression check for ONTO-T-Q06 WebMock policy restoration:
# Verifies that spec/services/issue_creator_service_spec.rb preserves and restores
# incoming WebMock configuration across example execution and on example failures,
# without broadening to allow-all and while strictly denying remote network access.
#
# Every scenario explicitly selects ONLY spec/services/issue_creator_service_spec.rb
# without default directory discovery or copied hook logic.

EXPECTED_WEBMOCK_VERSION = '3.25.1'
EXPECTED_RSPEC_VERSION = '3.13.5'

begin
  gem 'webmock', "= #{EXPECTED_WEBMOCK_VERSION}"
  require 'webmock'
rescue Gem::LoadError, LoadError => e
  abort "FATAL: WebMock #{EXPECTED_WEBMOCK_VERSION} (from Gemfile.lock) could not be activated: #{e.message}"
end

begin
  gem 'rspec-core', "= #{EXPECTED_RSPEC_VERSION}"
  require 'rspec/core'
rescue Gem::LoadError, LoadError => e
  abort "FATAL: RSpec::Core #{EXPECTED_RSPEC_VERSION} (from Gemfile.lock) could not be activated: #{e.message}"
end

require 'open3'
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

assert(WebMock::VERSION == EXPECTED_WEBMOCK_VERSION, "WebMock version is locked #{EXPECTED_WEBMOCK_VERSION}", failures)
assert(RSpec::Core::Version::STRING == EXPECTED_RSPEC_VERSION, "RSpec::Core version is locked #{EXPECTED_RSPEC_VERSION}", failures)

repo_root = File.expand_path('../..', __dir__)
spec_path = File.join(repo_root, 'spec/services/issue_creator_service_spec.rb')

CHILD_RUNNER_SCRIPT = <<~'RUBY'
  require 'json'
  gem 'webmock', "= #{ENV.fetch('EXPECTED_WEBMOCK_VERSION')}"
  require 'webmock'
  gem 'rspec-core', "= #{ENV.fetch('EXPECTED_RSPEC_VERSION')}"
  require 'rspec/core'

  case ENV['SCENARIO_MODE']
  when 'allow_exact'
    WebMock.disable_net_connect!(allow: ['localhost:9393'])
  when 'allow_localhost'
    WebMock.disable_net_connect!(allow_localhost: true)
  when 'default_deny'
    WebMock.disable_net_connect!
  else
    abort "Unknown SCENARIO_MODE: #{ENV['SCENARIO_MODE']}"
  end

  before_allowed_9393 = !!WebMock.net_connect_allowed?('http://localhost:9393')
  before_allowed_8080 = !!WebMock.net_connect_allowed?('http://localhost:8080')
  before_remote = !!WebMock.net_connect_allowed?('https://api.github.com/graphql')

  if ENV['INJECT_FAILURE'] == '1'
    RSpec.configure do |c|
      c.before(:each) do
        raise 'intentional failure inside around hook'
      end
    end
  end

  rspec_args = [ENV.fetch('SPEC_PATH')]
  rspec_args.push('-e', ENV['SPEC_FILTER']) if ENV['SPEC_FILTER']

  exit_code = RSpec::Core::Runner.run(rspec_args)

  cfg = WebMock::Config.instance
  failed_ex = RSpec.world.all_examples.select { |ex| ex.execution_result.status == :failed }
  passed_ex = RSpec.world.all_examples.select { |ex| ex.execution_result.status == :passed }

  result = {
    exit_code: exit_code,
    before_allowed_9393: before_allowed_9393,
    before_allowed_8080: before_allowed_8080,
    before_remote: before_remote,
    after_allowed_9393: !!WebMock.net_connect_allowed?('http://localhost:9393'),
    after_allowed_8080: !!WebMock.net_connect_allowed?('http://localhost:8080'),
    after_remote: !!WebMock.net_connect_allowed?('https://api.github.com/graphql'),
    after_allow: cfg.allow,
    after_localhost: cfg.allow_localhost,
    after_net_connect: cfg.allow_net_connect,
    passed_count: passed_ex.size,
    failed_count: failed_ex.size,
    failure_message: failed_ex.first&.execution_result&.exception&.message
  }

  puts "---JSON_START---"
  puts JSON.generate(result)
RUBY

def run_scenario(mode:, spec_path:, filter: nil, inject_failure: false)
  env = ENV.to_h.merge(
    'EXPECTED_WEBMOCK_VERSION' => EXPECTED_WEBMOCK_VERSION,
    'EXPECTED_RSPEC_VERSION' => EXPECTED_RSPEC_VERSION,
    'SPEC_PATH' => spec_path,
    'SCENARIO_MODE' => mode.to_s,
    'SPEC_FILTER' => filter,
    'INJECT_FAILURE' => inject_failure ? '1' : '0'
  ).compact

  stdout, _stderr, status = Open3.capture3(env, 'ruby', '-e', CHILD_RUNNER_SCRIPT)
  json_str = stdout.split("---JSON_START---\n").last
  res = json_str ? JSON.parse(json_str) : {}
  [status.success?, res]
end

puts "\n=== Step 1: Preseeded narrow endpoint allowlist (counterexample fix) ==="
ok1, res1 = run_scenario(mode: 'allow_exact', spec_path: spec_path, filter: 'strictly intercepts outbound')
assert(ok1, "Step 1 process exited with zero status", failures)
assert(res1['exit_code'] == 0, "Network guard example passed cleanly (exit 0)", failures)
assert(res1['before_allowed_9393'] == true, "Before example: localhost:9393 was permitted", failures)
assert(res1['before_remote'] == false, "Before example: remote was denied", failures)
assert(res1['after_allowed_9393'] == true, "After example: localhost:9393 allowance restored", failures)
assert(res1['after_remote'] == false, "After example: remote remains strictly denied", failures)
assert(res1['after_allow'] == ['localhost:9393'], "After example: exact allowlist ['localhost:9393'] retained", failures)
assert(res1['after_net_connect'] == false, "After example: allow-all net connect remains disabled", failures)

puts "\n=== Step 2: Full spec execution with preseeded narrow allowlist ==="
ok2, res2 = run_scenario(mode: 'allow_exact', spec_path: spec_path)
assert(ok2, "Step 2 process exited with zero status", failures)
assert(res2['exit_code'] == 0, "All 4 IssueCreatorService examples passed cleanly (exit 0)", failures)
assert(res2['passed_count'] == 4, "Passed count is exactly 4 real service examples", failures)
assert(res2['after_allowed_9393'] == true, "After full spec: localhost:9393 allowance restored", failures)
assert(res2['after_remote'] == false, "After full spec: remote remains denied", failures)
assert(res2['after_allow'] == ['localhost:9393'], "After full spec: exact allowlist preserved", failures)

puts "\n=== Step 3: Policy restored on actual example failure (injected into loaded hook) ==="
ok3, res3 = run_scenario(mode: 'allow_exact', spec_path: spec_path, filter: 'strictly intercepts outbound', inject_failure: true)
assert(ok3, "Step 3 runner completed execution", failures)
assert(res3['exit_code'] == 1, "Injected failing example produced expected exit 1", failures)
assert(res3['failed_count'] == 1, "Intentional failure produced exactly 1 failed example", failures)
assert(res3['failure_message'] == 'intentional failure inside around hook', "Failure was caused by injected callback inside actual around hook", failures)
assert(res3['after_allowed_9393'] == true, "After example failure: localhost:9393 allowance restored", failures)
assert(res3['after_remote'] == false, "After example failure: remote remains denied", failures)
assert(res3['after_allow'] == ['localhost:9393'], "After example failure: allowlist was not lost", failures)

puts "\n=== Step 4: Preseeded broad-localhost allowance restored ==="
ok4, res4 = run_scenario(mode: 'allow_localhost', spec_path: spec_path, filter: 'strictly intercepts outbound')
assert(ok4, "Step 4 process exited with zero status", failures)
assert(res4['exit_code'] == 0, "Network guard example passed cleanly (exit 0)", failures)
assert(res4['before_allowed_8080'] == true, "Before example: localhost was permitted", failures)
assert(res4['after_allowed_8080'] == true, "After example: broad localhost allowance restored", failures)
assert(res4['after_remote'] == false, "After example: remote remains denied", failures)
assert(res4['after_localhost'] == true, "After example: allow_localhost flag preserved", failures)
assert(res4['after_net_connect'] == false, "After example: allow-all net connect remains disabled", failures)

puts "\n=== Step 5: Default-deny (no preseeded allowances) never broadens ==="
ok5, res5 = run_scenario(mode: 'default_deny', spec_path: spec_path)
assert(ok5, "Step 5 process exited with zero status", failures)
assert(res5['exit_code'] == 0, "All 4 IssueCreatorService examples passed cleanly (exit 0)", failures)
assert(res5['passed_count'] == 4, "Default deny: all 4 real service examples passed", failures)
assert(res5['after_allowed_9393'] == false, "Default deny: local request remains denied", failures)
assert(res5['after_remote'] == false, "Default deny: remote request remains denied", failures)
assert(res5['after_allow'].nil?, "Default deny: allowlist remains nil", failures)
assert(res5['after_net_connect'] == false, "Default deny: never broadened to allow-all", failures)

puts "\n=== Summary ==="
if failures.empty?
  puts "ALL CHECKS PASSED: WebMock policy restoration verified across all scenarios."
  exit 0
else
  puts "#{failures.size} CHECK(S) FAILED:"
  failures.each { |f| puts " - #{f}" }
  exit 1
end
