#!/usr/bin/env ruby
# frozen_string_literal: true

# Standalone isolated regression check for ONTO-T-Q06 WebMock policy restoration:
# Verifies that IssueCreatorService spec preserves and restores incoming WebMock
# configuration (including preseeded narrow allowances and broad-localhost settings)
# across example execution and on example failures, without broadening to allow-all
# and while strictly denying remote network access.

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
subproc_env = ENV.to_h

puts "\n=== Step 1: Preseeded narrow endpoint allowlist (counterexample fix) ==="
step1_code = <<-RUBY
gem 'webmock', '= #{EXPECTED_WEBMOCK_VERSION}'
require 'webmock'
gem 'rspec-core', '= #{EXPECTED_RSPEC_VERSION}'
require 'rspec/core'

WebMock.disable_net_connect!(allow: ['localhost:9393'])
before_allowed = !!WebMock.net_connect_allowed?('http://localhost:9393')
before_remote = !!WebMock.net_connect_allowed?('https://api.github.com/graphql')

exit_code = RSpec::Core::Runner.run(['#{spec_path}', '-e', 'strictly intercepts outbound'])

after_allowed = !!WebMock.net_connect_allowed?('http://localhost:9393')
after_remote = !!WebMock.net_connect_allowed?('https://api.github.com/graphql')
after_allow = WebMock::Config.instance.allow
after_net_connect = WebMock::Config.instance.allow_net_connect

result = {
  before_allowed: before_allowed,
  before_remote: before_remote,
  exit_code: exit_code,
  after_allowed: after_allowed,
  after_remote: after_remote,
  after_allow: after_allow,
  after_net_connect: after_net_connect
}
puts "---JSON_START---"
puts JSON.generate(result)
RUBY

stdout, stderr, status = Open3.capture3(subproc_env, 'ruby', '-e', step1_code)
json_str = stdout.split("---JSON_START---\n").last
res1 = json_str ? JSON.parse(json_str) : {}

assert(status.success?, "Step 1 process exited with zero status", failures)
assert(res1['exit_code'] == 0, "Network guard example passed cleanly (exit 0)", failures)
assert(res1['before_allowed'] == true, "Before example: localhost:9393 was permitted", failures)
assert(res1['before_remote'] == false, "Before example: remote was denied", failures)
assert(res1['after_allowed'] == true, "After example: localhost:9393 allowance restored", failures)
assert(res1['after_remote'] == false, "After example: remote remains strictly denied", failures)
assert(res1['after_allow'] == ['localhost:9393'], "After example: exact allowlist ['localhost:9393'] retained", failures)
assert(res1['after_net_connect'] == false, "After example: allow-all net connect remains disabled", failures)

puts "\n=== Step 2: Full spec execution with preseeded narrow allowlist ==="
step2_code = <<-RUBY
gem 'webmock', '= #{EXPECTED_WEBMOCK_VERSION}'
require 'webmock'
gem 'rspec-core', '= #{EXPECTED_RSPEC_VERSION}'
require 'rspec/core'

WebMock.disable_net_connect!(allow: ['localhost:9393'])

exit_code = RSpec::Core::Runner.run(['#{spec_path}'])

after_allowed = !!WebMock.net_connect_allowed?('http://localhost:9393')
after_remote = !!WebMock.net_connect_allowed?('https://api.github.com/graphql')
after_allow = WebMock::Config.instance.allow

result = {
  exit_code: exit_code,
  after_allowed: after_allowed,
  after_remote: after_remote,
  after_allow: after_allow
}
puts "---JSON_START---"
puts JSON.generate(result)
RUBY

stdout, stderr, status = Open3.capture3(subproc_env, 'ruby', '-e', step2_code)
json_str = stdout.split("---JSON_START---\n").last
res2 = json_str ? JSON.parse(json_str) : {}

assert(status.success?, "Step 2 process exited with zero status", failures)
assert(res2['exit_code'] == 0, "All 4 IssueCreatorService examples passed cleanly (exit 0)", failures)
assert(res2['after_allowed'] == true, "After full spec: localhost:9393 allowance restored", failures)
assert(res2['after_remote'] == false, "After full spec: remote remains denied", failures)
assert(res2['after_allow'] == ['localhost:9393'], "After full spec: exact allowlist preserved", failures)

puts "\n=== Step 3: Policy restored even on example failure ==="
step3_code = <<-RUBY
gem 'webmock', '= #{EXPECTED_WEBMOCK_VERSION}'
require 'webmock'
gem 'rspec-core', '= #{EXPECTED_RSPEC_VERSION}'
require 'rspec/core'

WebMock.disable_net_connect!(allow: ['localhost:9393'])

# Simulate the same around(:each) hook on a failing example
RSpec.describe 'SimulatedFailingExample' do
  around(:each) do |example|
    config = WebMock::Config.instance
    original_allow_net_connect = config.allow_net_connect
    original_allow_localhost = config.allow_localhost
    original_allow = config.allow.is_a?(Array) ? config.allow.dup : config.allow
    original_net_http_connect_on_start = config.net_http_connect_on_start

    WebMock.disable_net_connect!
    begin
      example.run
    ensure
      WebMock.reset!
      if original_allow_net_connect
        WebMock.allow_net_connect!(net_http_connect_on_start: original_net_http_connect_on_start)
        config.allow_localhost = original_allow_localhost
        config.allow = original_allow
      else
        WebMock.disable_net_connect!(
          allow_localhost: original_allow_localhost,
          allow: original_allow,
          net_http_connect_on_start: original_net_http_connect_on_start
        )
      end
    end
  end

  it 'fails intentionally' do
    expect(1).to eq(2)
  end
end

exit_code = RSpec::Core::Runner.run([])

after_allowed = !!WebMock.net_connect_allowed?('http://localhost:9393')
after_remote = !!WebMock.net_connect_allowed?('https://api.github.com/graphql')
after_allow = WebMock::Config.instance.allow

result = {
  exit_code: exit_code,
  after_allowed: after_allowed,
  after_remote: after_remote,
  after_allow: after_allow
}
puts "---JSON_START---"
puts JSON.generate(result)
RUBY

stdout, stderr, status = Open3.capture3(subproc_env, 'ruby', '-e', step3_code)
json_str = stdout.split("---JSON_START---\n").last
res3 = json_str ? JSON.parse(json_str) : {}

assert(status.success?, "Step 3 runner completed execution", failures)
assert(res3['exit_code'] == 1, "Simulated failing example produced expected exit 1", failures)
assert(res3['after_allowed'] == true, "After example failure: localhost:9393 allowance restored", failures)
assert(res3['after_remote'] == false, "After example failure: remote remains denied", failures)
assert(res3['after_allow'] == ['localhost:9393'], "After example failure: allowlist was not lost", failures)

puts "\n=== Step 4: Preseeded broad-localhost allowance restored ==="
step4_code = <<-RUBY
gem 'webmock', '= #{EXPECTED_WEBMOCK_VERSION}'
require 'webmock'
gem 'rspec-core', '= #{EXPECTED_RSPEC_VERSION}'
require 'rspec/core'

WebMock.disable_net_connect!(allow_localhost: true)
before_allowed = !!WebMock.net_connect_allowed?('http://localhost:8080')

exit_code = RSpec::Core::Runner.run(['#{spec_path}', '-e', 'strictly intercepts outbound'])

after_allowed = !!WebMock.net_connect_allowed?('http://localhost:8080')
after_remote = !!WebMock.net_connect_allowed?('https://api.github.com/graphql')
after_localhost = WebMock::Config.instance.allow_localhost
after_net_connect = WebMock::Config.instance.allow_net_connect

result = {
  before_allowed: before_allowed,
  exit_code: exit_code,
  after_allowed: after_allowed,
  after_remote: after_remote,
  after_localhost: after_localhost,
  after_net_connect: after_net_connect
}
puts "---JSON_START---"
puts JSON.generate(result)
RUBY

stdout, stderr, status = Open3.capture3(subproc_env, 'ruby', '-e', step4_code)
json_str = stdout.split("---JSON_START---\n").last
res4 = json_str ? JSON.parse(json_str) : {}

assert(status.success?, "Step 4 process exited with zero status", failures)
assert(res4['exit_code'] == 0, "Network guard example passed cleanly (exit 0)", failures)
assert(res4['before_allowed'] == true, "Before example: localhost was permitted", failures)
assert(res4['after_allowed'] == true, "After example: broad localhost allowance restored", failures)
assert(res4['after_remote'] == false, "After example: remote remains denied", failures)
assert(res4['after_localhost'] == true, "After example: allow_localhost flag preserved", failures)
assert(res4['after_net_connect'] == false, "After example: allow-all net connect remains disabled", failures)

puts "\n=== Step 5: Default-deny (no preseeded allowances) never broadens ==="
step5_code = <<-RUBY
gem 'webmock', '= #{EXPECTED_WEBMOCK_VERSION}'
require 'webmock'
gem 'rspec-core', '= #{EXPECTED_RSPEC_VERSION}'
require 'rspec/core'

WebMock.disable_net_connect!

exit_code = RSpec::Core::Runner.run(['#{spec_path}'])

after_local = !!WebMock.net_connect_allowed?('http://localhost:9393')
after_remote = !!WebMock.net_connect_allowed?('https://api.github.com/graphql')
after_allow = WebMock::Config.instance.allow
after_net_connect = WebMock::Config.instance.allow_net_connect

result = {
  exit_code: exit_code,
  after_local: after_local,
  after_remote: after_remote,
  after_allow: after_allow,
  after_net_connect: after_net_connect
}
puts "---JSON_START---"
puts JSON.generate(result)
RUBY

stdout, stderr, status = Open3.capture3(subproc_env, 'ruby', '-e', step5_code)
json_str = stdout.split("---JSON_START---\n").last
res5 = json_str ? JSON.parse(json_str) : {}

assert(status.success?, "Step 5 process exited with zero status", failures)
assert(res5['exit_code'] == 0, "All 4 IssueCreatorService examples passed cleanly (exit 0)", failures)
assert(res5['after_local'] == false, "Default deny: local request remains denied", failures)
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
