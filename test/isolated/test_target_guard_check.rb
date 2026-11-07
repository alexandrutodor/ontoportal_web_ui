#!/usr/bin/env ruby
# frozen_string_literal: true

# Standalone isolated regression check for ONTO-T-Q06 (unit 1):
# Proves fail-before-request test-target preflight, explicit test isolation marker,
# parsed endpoint validation, default-deny test networking via WebMock, and enforcement
# before any client/request/cleanup path without starting services or making remote network calls.

require 'uri'
require 'ipaddr'
require 'socket'
require 'open3'

failures = []

def assert(condition, message, failures)
  if condition
    puts "  [PASS] #{message}"
  else
    puts "  [FAIL] #{message}"
    failures << message
  end
end

puts "=== Step 1: Load TestTargetGuard in isolation ==="
require_relative '../helpers/test_target_guard'

assert(defined?(TestTargetGuard) == 'constant', "TestTargetGuard module is defined", failures)
assert(defined?(TestTargetGuard::TargetIsolationError) == 'constant', "TargetIsolationError is defined", failures)
assert(defined?(TestTargetGuard::MissingMarkerError) == 'constant', "MissingMarkerError is defined", failures)
assert(defined?(TestTargetGuard::DisallowedTargetError) == 'constant', "DisallowedTargetError is defined", failures)

puts "\n=== Step 2: Test endpoint parsing and approved host validation ==="
approved_hosts = %w[
  localhost
  127.0.0.1
  0.0.0.0
  ::1
  ontoportal_docker-api
  ontoportal_docker
  ontologies_api
]

approved_hosts.each do |host|
  assert(TestTargetGuard.approved_host?(host), "Approved host '#{host}' is accepted", failures)
end

# Check IPv4 loopback subnet
assert(TestTargetGuard.approved_host?('127.0.0.2'), "IPv4 loopback '127.0.0.2' is accepted", failures)
assert(TestTargetGuard.approved_host?('127.1.2.3'), "IPv4 loopback '127.1.2.3' is accepted", failures)

disallowed_hosts = %w[
  data.bioontology.org
  data.stageportal.lirmm.fr
  stage.matportal.org
  example.com
  192.168.1.10
  10.0.0.1
  172.16.0.1
]

disallowed_hosts.each do |host|
  assert(!TestTargetGuard.approved_host?(host), "Remote/disallowed host '#{host}' is rejected", failures)
end

puts "\n=== Step 3: Bad remote URLs fail before requests even with marker set ==="
orig_marker = ENV[TestTargetGuard::MARKER_ENV_VAR]
begin
  ENV[TestTargetGuard::MARKER_ENV_VAR] = '1'

  disallowed_targets = [
    'https://data.bioontology.org',
    'http://data.stageportal.lirmm.fr:9393',
    'http://192.168.1.50:9393',
    'http://10.0.0.2:9393',
    'https://production.matportal.org',
    'http://localhost:9393@data.bioontology.org',
    'http://evil.com/ontologies'
  ]

  disallowed_targets.each do |target|
    failed_properly = false
    begin
      TestTargetGuard.verify_isolated_test_target!(target)
    rescue TestTargetGuard::DisallowedTargetError
      failed_properly = true
    rescue StandardError => e
      puts "    Unexpected error for #{target}: #{e.class} - #{e.message}"
    end
    assert(failed_properly, "Remote destination #{target} fails with DisallowedTargetError even with marker set", failures)
  end

  # Test invalid schemes
  invalid_schemes = [
    'ftp://localhost:9393',
    'file:///etc/passwd',
    'javascript:alert(1)',
    ''
  ]

  invalid_schemes.each do |target|
    failed_properly = false
    begin
      TestTargetGuard.verify_isolated_test_target!(target)
    rescue TestTargetGuard::InvalidURLError
      failed_properly = true
    end
    assert(failed_properly, "Invalid target scheme/format #{target.inspect} fails with InvalidURLError", failures)
  end
ensure
  ENV[TestTargetGuard::MARKER_ENV_VAR] = orig_marker
end

puts "\n=== Step 4: Approved endpoints resolve ONLY with the explicit marker ==="
approved_endpoints = [
  'http://localhost:9393',
  'http://127.0.0.1:9393',
  'http://ontoportal_docker-api:9393',
  'http://ontoportal_docker:9393',
  'http://[::1]:9393'
]

# Case 4a: Without marker, approved endpoints MUST FAIL preflight
[nil, '', '0', 'false', 'no'].each do |unset_val|
  ENV[TestTargetGuard::MARKER_ENV_VAR] = unset_val
  approved_endpoints.each do |endpoint|
    failed_missing_marker = false
    begin
      TestTargetGuard.verify_isolated_test_target!(endpoint)
    rescue TestTargetGuard::MissingMarkerError
      failed_missing_marker = true
    end
    assert(failed_missing_marker, "Endpoint #{endpoint} fails with MissingMarkerError when marker=#{unset_val.inspect}", failures)
  end
end

# Case 4b: With marker, approved endpoints resolve successfully
%w[1 true yes isolated].each do |set_val|
  ENV[TestTargetGuard::MARKER_ENV_VAR] = set_val
  approved_endpoints.each do |endpoint|
    uri = TestTargetGuard.verify_isolated_test_target!(endpoint)
    assert(uri.is_a?(URI::Generic), "Endpoint #{endpoint} resolves with marker=#{set_val.inspect}", failures)
  end
end

puts "\n=== Step 5: Real WebMock exact endpoint bounds and permission predicates ==="
# Activate and load locked WebMock gem (fail clearly if unavailable rather than silently load another)
EXPECTED_WEBMOCK_VERSION = '3.25.1'
begin
  gem 'webmock', "= #{EXPECTED_WEBMOCK_VERSION}"
  require 'webmock'
rescue Gem::LoadError, LoadError => e
  abort "FATAL: WebMock #{EXPECTED_WEBMOCK_VERSION} (from Gemfile.lock) could not be activated: #{e.message}"
end
require 'net/http'

assert(defined?(WebMock) == 'constant', "Actual WebMock gem is loaded", failures)
assert(WebMock::VERSION == EXPECTED_WEBMOCK_VERSION,
       "WebMock version matches locked version #{EXPECTED_WEBMOCK_VERSION} (actual: #{WebMock::VERSION})", failures)

# Configure Capybara mock object before WebMock policy
module Capybara
  class << self
    attr_accessor :server_host, :server_port, :app_host
  end
end
Capybara.server_host = '0.0.0.0'
Capybara.server_port = 31_337
Capybara.app_host = "http://#{Socket.gethostname}:#{Capybara.server_port}"

ENV[TestTargetGuard::MARKER_ENV_VAR] = '1'
TestTargetGuard.configure_webmock!('http://localhost:9393')

assert(!WebMock::Config.instance.allow_net_connect, "WebMock default-deny is active (allow_net_connect: false)", failures)
assert(WebMock::Config.instance.allow_localhost == false, "WebMock allow_localhost is false (no broad localhost access)", failures)

allowed_list = WebMock::Config.instance.allow
assert(allowed_list.include?('localhost:9393'), "Narrow allowlist includes validated local API host:port 'localhost:9393'", failures)
assert(allowed_list.include?('localhost:4444'), "Narrow allowlist includes local Selenium grid host:port 'localhost:4444'", failures)
assert(allowed_list.include?('127.0.0.1:4444'), "Narrow allowlist includes local Selenium grid host:port '127.0.0.1:4444'", failures)
assert(!allowed_list.include?('localhost'), "Narrow allowlist excludes bare hostname 'localhost'", failures)
assert(!allowed_list.include?('127.0.0.1'), "Narrow allowlist excludes bare hostname '127.0.0.1'", failures)
assert(!allowed_list.include?('0.0.0.0'), "Narrow allowlist excludes bare hostname '0.0.0.0'", failures)
assert(!allowed_list.include?('data.bioontology.org'), "Narrow allowlist excludes remote host 'data.bioontology.org'", failures)
assert(!allowed_list.include?('data.bioontology.org:443'), "Narrow allowlist excludes remote host:port 'data.bioontology.org:443'", failures)

# Capybara readiness endpoint check
assert(allowed_list.include?('0.0.0.0:31337'), "Allowlist includes Capybara bind/readiness host:port '0.0.0.0:31337'", failures)
assert(allowed_list.include?('127.0.0.1:31337'), "Allowlist includes Capybara loopback host:port '127.0.0.1:31337'", failures)
assert(allowed_list.include?('localhost:31337'), "Allowlist includes Capybara localhost host:port 'localhost:31337'", failures)
assert(allowed_list.include?("#{Socket.gethostname}:31337"), "Allowlist includes Capybara app host:port '#{Socket.gethostname}:31337'", failures)

# Verify actual WebMock permission predicate on API endpoints (Finding 2)
assert(WebMock.net_connect_allowed?('http://localhost:9393/ontologies'),
       "WebMock.net_connect_allowed? permits validated API port 9393", failures)
assert(!WebMock.net_connect_allowed?('http://localhost:8080/evil'),
       "WebMock.net_connect_allowed? denies unrelated port 8080 on localhost", failures)
assert(!WebMock.net_connect_allowed?('http://localhost:1234/test'),
       "WebMock.net_connect_allowed? denies unrelated port 1234 on localhost", failures)
assert(!WebMock.net_connect_allowed?('https://data.bioontology.org/ontologies'),
       "WebMock.net_connect_allowed? denies remote host data.bioontology.org", failures)

# Verify actual WebMock permission predicate on Capybara readiness endpoints (Finding 4)
assert(WebMock.net_connect_allowed?('http://0.0.0.0:31337/__identify__'),
       "WebMock.net_connect_allowed? permits Capybara readiness probe at 0.0.0.0:31337", failures)
assert(WebMock.net_connect_allowed?('http://127.0.0.1:31337/'),
       "WebMock.net_connect_allowed? permits Capybara 127.0.0.1:31337", failures)
assert(WebMock.net_connect_allowed?("http://#{Socket.gethostname}:31337/"),
       "WebMock.net_connect_allowed? permits Capybara app host #{Socket.gethostname}:31337", failures)
assert(!WebMock.net_connect_allowed?('http://0.0.0.0:31338/__identify__'),
       "WebMock.net_connect_allowed? denies neighboring port 0.0.0.0:31338", failures)
assert(!WebMock.net_connect_allowed?('http://127.0.0.1:31338/'),
       "WebMock.net_connect_allowed? denies neighboring port 127.0.0.1:31338", failures)
assert(!WebMock.net_connect_allowed?('http://localhost:31338/'),
       "WebMock.net_connect_allowed? denies neighboring port localhost:31338", failures)

puts "\n=== Step 5b: Transport double interception (zero sockets/services opened) ==="
# Transport double interceptor
class TransportAttemptedError < StandardError
  attr_reader :host, :port
  def initialize(host, port)
    @host = host
    @port = port
    super("Transport double intercepted connection to #{host}:#{port}")
  end
end

class TCPSocket
  def initialize(host, port, *rest, **kw)
    raise TransportAttemptedError.new(host, port)
  end
end

# Test 5b-1: Allowed API port 9393 reaches transport double
hit_transport_api = false
begin
  Net::HTTP.get(URI('http://localhost:9393/test'))
rescue TransportAttemptedError => e
  hit_transport_api = (e.host == 'localhost' && e.port == 9393)
rescue WebMock::NetConnectNotAllowedError
  hit_transport_api = false
end
assert(hit_transport_api, "Allowed API port 9393 passes WebMock and reaches transport double", failures)

# Test 5b-2: Forbidden API neighbor port 8080 blocked before transport double
blocked_before_transport = false
begin
  Net::HTTP.get(URI('http://localhost:8080/evil'))
rescue TransportAttemptedError
  blocked_before_transport = false
rescue WebMock::NetConnectNotAllowedError
  blocked_before_transport = true
end
assert(blocked_before_transport, "Forbidden API neighbor port 8080 blocked by WebMock before transport", failures)

# Test 5b-3: Allowed Capybara readiness probe 0.0.0.0:31337 reaches transport double
hit_transport_capybara = false
begin
  Net::HTTP.get(URI('http://0.0.0.0:31337/__identify__'))
rescue TransportAttemptedError => e
  hit_transport_capybara = (e.host == '0.0.0.0' && e.port == 31_337)
rescue WebMock::NetConnectNotAllowedError
  hit_transport_capybara = false
end
assert(hit_transport_capybara, "Allowed Capybara probe 0.0.0.0:31337 passes WebMock and reaches transport double", failures)

# Test 5b-4: Forbidden Capybara neighbor 0.0.0.0:31338 blocked before transport double
blocked_capybara_neighbor = false
begin
  Net::HTTP.get(URI('http://0.0.0.0:31338/__identify__'))
rescue TransportAttemptedError
  blocked_capybara_neighbor = false
rescue WebMock::NetConnectNotAllowedError
  blocked_capybara_neighbor = true
end
assert(blocked_capybara_neighbor, "Forbidden Capybara neighbor 0.0.0.0:31338 blocked by WebMock before transport", failures)

# Test 5b-5: SELENIUM_REMOTE_URL regression check (Finding 1)
# With marked localhost:9393 target and SELENIUM_REMOTE_URL set to a remote destination,
# actual WebMock predicate must deny remote, and request must be blocked before transport double.
orig_selenium_url = ENV['SELENIUM_REMOTE_URL']
begin
  ENV['SELENIUM_REMOTE_URL'] = 'https://data.bioontology.org'
  TestTargetGuard.configure_webmock!('http://localhost:9393')

  assert(!WebMock::Config.instance.allow.include?('data.bioontology.org:443'),
         "Allowlist excludes remote SELENIUM_REMOTE_URL host:port 'data.bioontology.org:443'", failures)
  assert(!WebMock.net_connect_allowed?('https://data.bioontology.org/ontologies'),
         "WebMock.net_connect_allowed? denies remote SELENIUM_REMOTE_URL destination", failures)

  blocked_selenium_remote = false
  begin
    Net::HTTP.get(URI('https://data.bioontology.org/ontologies'))
  rescue TransportAttemptedError
    blocked_selenium_remote = false
  rescue WebMock::NetConnectNotAllowedError
    blocked_selenium_remote = true
  end
  assert(blocked_selenium_remote,
         "Request to remote SELENIUM_REMOTE_URL blocked by WebMock before transport double", failures)
ensure
  ENV['SELENIUM_REMOTE_URL'] = orig_selenium_url
  TestTargetGuard.configure_webmock!('http://localhost:9393')
end

puts "\n=== Step 5c: Setup recovery and adapter persistence (Finding 3) ==="
# Simulate prior WebMock.disable! from rogue setup
WebMock.disable!

# Representative setup execution restores WebMock adapters and enforces default-deny policy
TestTargetGuard.configure_webmock!('http://localhost:9393')

blocked_after_setup = false
begin
  Net::HTTP.get(URI('https://data.bioontology.org/ontologies'))
rescue TransportAttemptedError
  blocked_after_setup = false
rescue WebMock::NetConnectNotAllowedError
  blocked_after_setup = true
end
assert(blocked_after_setup, "WebMock default-deny is restored and active after setup recovery", failures)

puts "\n=== Step 6: ApplicationTestHelpers preflight runs BEFORE requests/cleanup ==="
# Load ApplicationTestHelpers
require_relative '../helpers/application_test_helpers'

# Create spies to track whether any client or Faraday request is triggered
$spy_client_calls = []

module MockLinkedData
  module Client
    class Base; end
    class Settings
      attr_accessor :rest_url
    end

    class << self
      def settings
        @settings ||= Settings.new
      end
    end

    module Models
      class Category
        def self.all
          $spy_client_calls << :category_all
          []
        end
      end

      class Group
        def self.all
          $spy_client_calls << :group_all
          []
        end
      end

      class Agent
        def self.all
          $spy_client_calls << :agent_all
          []
        end
      end

      class User
        def self.all
          $spy_client_calls << :user_all
          []
        end
      end

      class Ontology
        def self.find_by_acronym(acronym)
          $spy_client_calls << [:ontology_find, acronym]
          []
        end
      end
    end
  end
end

Object.const_set(:LinkedData, MockLinkedData) unless defined?(LinkedData)

# Harness including helper modules
class HelperHarness
  include ApplicationTestHelpers::Categories
  include ApplicationTestHelpers::Groups
  include ApplicationTestHelpers::Agents
  include ApplicationTestHelpers::Users
  include ApplicationTestHelpers::Ontologies
end

harness = HelperHarness.new

# Test 6a: Remote destination fails before any cleanup or request
$spy_client_calls.clear
ENV[TestTargetGuard::MARKER_ENV_VAR] = '1'
LinkedData::Client.settings.rest_url = 'https://data.bioontology.org'

remote_blocked = false
begin
  harness.delete_categories
rescue TestTargetGuard::DisallowedTargetError
  remote_blocked = true
end
assert(remote_blocked, "delete_categories against remote target raises DisallowedTargetError", failures)
assert($spy_client_calls.empty?, "delete_categories against remote target dispatched 0 client calls", failures)

# Test 6b: Missing marker fails before any cleanup or request
$spy_client_calls.clear
ENV[TestTargetGuard::MARKER_ENV_VAR] = nil
LinkedData::Client.settings.rest_url = 'http://localhost:9393'

marker_blocked = false
begin
  harness.delete_groups
rescue TestTargetGuard::MissingMarkerError
  marker_blocked = true
end
assert(marker_blocked, "delete_groups with missing marker raises MissingMarkerError", failures)
assert($spy_client_calls.empty?, "delete_groups with missing marker dispatched 0 client calls", failures)

# Test 6c: Valid target with marker passes preflight and proceeds to client calls
$spy_client_calls.clear
ENV[TestTargetGuard::MARKER_ENV_VAR] = '1'
LinkedData::Client.settings.rest_url = 'http://localhost:9393'

harness.delete_categories
assert($spy_client_calls.include?(:category_all), "delete_categories with valid target proceeds after preflight", failures)

puts "\n=== Step 7: bin/ontoportal test CLI preflight ==="
ontoportal_path = File.expand_path('../../bin/ontoportal', __dir__)

# Test 7a: CLI rejects remote URL with exit status 1 before starting services
stdout_err, status = Open3.capture2e(ontoportal_path, 'test', '--api-url', 'https://data.bioontology.org')
assert(!status.success?, "bin/ontoportal test --api-url https://data.bioontology.org exits with non-zero status", failures)
assert(stdout_err.include?('Refusing to run tests against remote or non-isolated API target'),
       "bin/ontoportal test reports refusal message for remote target", failures)
assert(!stdout_err.include?('Running API...'), "bin/ontoportal test did NOT start local API", failures)

# Test 7b: CLI rejects arbitrary external IP
stdout_err, status = Open3.capture2e(ontoportal_path, 'test', '--api-url', 'http://192.168.1.100:9393')
assert(!status.success?, "bin/ontoportal test --api-url http://192.168.1.100:9393 exits with non-zero status", failures)

# Test 7c: Inspect bin/ontoportal passes ONTOPORTAL_ISOLATED_TEST=1 to container test command
bin_content = File.read(ontoportal_path)
has_isolated_flag = bin_content.include?('ONTOPORTAL_ISOLATED_TEST=1')
assert(has_isolated_flag, "bin/ontoportal sets ONTOPORTAL_ISOLATED_TEST=1 in docker compose run", failures)

puts "\n=== Step 8: Verify test/test_helper.rb and system setups network policy ==="
test_helper_path = File.expand_path('../test_helper.rb', __dir__)
test_helper_content = File.read(test_helper_path)

assert(!test_helper_content.include?('WebMock.allow_net_connect!'),
       "test/test_helper.rb must NOT contain WebMock.allow_net_connect!", failures)
assert(test_helper_content.include?('TestTargetGuard.enforce_isolated_test_target!'),
       "test/test_helper.rb enforces TestTargetGuard preflight at boot", failures)
assert(test_helper_content.include?('TestTargetGuard.configure_webmock!'),
       "test/test_helper.rb configures default-deny WebMock", failures)
assert(test_helper_content.include?('Capybara.server_port'),
       "test/test_helper.rb configures explicit Capybara.server_port before policy", failures)

# Verify no system test setup contains unrestricted WebMock.disable!
system_test_files = Dir.glob(File.expand_path('../system/*_test.rb', __dir__))
system_test_files.each do |st_file|
  file_content = File.read(st_file)
  rel_path = st_file.sub(%r{^.*/test/}, 'test/')
  assert(!file_content.include?('WebMock.disable!'),
         "#{rel_path} must NOT contain WebMock.disable!", failures)
end

puts "\n" + ("=" * 60)
if failures.empty?
  puts "ALL CHECKS PASSED: ONTO-T-Q06 test-target preflight & network isolation verified offline."
  exit 0
else
  puts "FAILED CHECKS (#{failures.size}):"
  failures.each { |f| puts "  - #{f}" }
  exit 1
end
