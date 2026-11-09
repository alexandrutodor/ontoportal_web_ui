#!/usr/bin/env ruby
# frozen_string_literal: true

# Standalone isolated regression check for finite external portal WebMock stubs:
# Proves:
# 1. Finite exact HEAD URLs derived from configured external portals.
# 2. Excludes own API endpoint and local approved hosts.
# 3. Controlled status (200) returned for Faraday HEAD requests to external portals.
# 4. Default-deny strictly enforced: GET/POST to external portals denied by WebMock.
# 5. Default-deny strictly enforced: HEAD to unlisted portals denied by WebMock.
# 6. Real FederationHelper#federation_portal_status logic succeeds under test.
# 7. No wildcard any-host/any-method stubs or allow_net_connect blanket.
# 8. Zero actual remote network or service requests.

$LOAD_PATH.unshift(File.expand_path('../../lib', __dir__))
$LOAD_PATH.unshift(File.expand_path('..', __dir__))

require 'active_support/all'
require 'uri'
require 'faraday'
require 'webmock'
include WebMock::API

ENV['ONTOPORTAL_ISOLATED_TEST'] ||= '1'
ENV['API_URL'] ||= 'http://localhost:9393'

require_relative '../helpers/test_target_guard'
require_relative '../helpers/external_portal_stub_helper'

failures = []

def assert(condition, message, failures)
  if condition
    puts "  [PASS] #{message}"
  else
    puts "  [FAIL] #{message}"
    failures << message
  end
end

puts "=== Step 1: Initialize TestTargetGuard default-deny WebMock ==="
TestTargetGuard.enforce_isolated_test_target!
assert(WebMock.net_connect_allowed? == false, "WebMock default-deny is active", failures)

puts "\n=== Step 2: Load configured test portals ==="
require_relative '../../config/bioportal_config_test'
assert(defined?($PORTALS_INSTANCES) && $PORTALS_INSTANCES.is_a?(Array), "$PORTALS_INSTANCES is loaded", failures)

# Setup simulated LinkedData::Client settings as initialized by ontologies_api_client initializer
module LinkedData
  module Client
    Settings = Struct.new(:federated_portals, :rest_url)
    def self.settings
      @settings ||= Settings.new(
        $PORTALS_INSTANCES.map { |x| x[:api] && x[:apikey] ? [x[:name].downcase.to_sym, x.dup] : nil }.compact.to_h,
        ENV['API_URL'] || 'http://localhost:9393'
      )
    end
  end
end

puts "\n=== Step 3: Derive finite external portal URLs ==="
urls = ExternalPortalStubHelper.configured_external_portal_urls
puts "  Derived URLs count: #{urls.size}"
puts "  Derived URLs: #{urls.inspect}"

assert(urls.size.positive?, "Derived URLs list is non-empty", failures)
assert(urls.include?('https://data.agroportal.eu/'), "AgroPortal normalized URL is present", failures)
assert(urls.include?('https://data.agroportal.eu'), "AgroPortal chomp URL is present", failures)
assert(urls.include?('https://data.bioontology.org/'), "BioPortal normalized URL is present", failures)

# Ensure own API and approved hosts are NOT in external URLs
assert(!urls.any? { |u| u.include?('localhost:9393') }, "Own API localhost:9393 is excluded", failures)
assert(!urls.any? { |u| u.include?('ontologies_api') }, "Own API ontologies_api is excluded", failures)
assert(!urls.any? { |u| u.include?('127.0.0.1') }, "Loopback 127.0.0.1 is excluded", failures)
assert(!urls.any? { |u| u.include?('unlisted') }, "Arbitrary unlisted URL is excluded", failures)

puts "\n=== Step 4: Register finite HEAD stubs ==="
stubbed = ExternalPortalStubHelper.stub_configured_external_portal_health_checks(status: 200)
assert_equal_size = (stubbed.size == urls.size)
assert(assert_equal_size, "All derived URLs registered as stubs", failures)

puts "\n=== Step 5: Verify Faraday HEAD requests succeed with controlled status 200 ==="
urls.each do |target_url|
  res = Faraday.new(url: target_url).head
  assert(res.success? && res.status == 200, "HEAD #{target_url} returns controlled status 200", failures)
end

puts "\n=== Step 6: Verify default-deny rejects GET and POST to external portal URLs ==="
get_blocked = false
begin
  Faraday.new(url: 'https://data.agroportal.eu/').get
rescue WebMock::NetConnectNotAllowedError
  get_blocked = true
end
assert(get_blocked, "GET https://data.agroportal.eu/ is rejected by WebMock default-deny", failures)

post_blocked = false
begin
  Faraday.new(url: 'https://data.agroportal.eu/').post
rescue WebMock::NetConnectNotAllowedError
  post_blocked = true
end
assert(post_blocked, "POST https://data.agroportal.eu/ is rejected by WebMock default-deny", failures)

puts "\n=== Step 7: Verify default-deny rejects unlisted external host ==="
unlisted_blocked = false
begin
  Faraday.new(url: 'https://unlisted-portal.example.org/').head
rescue WebMock::NetConnectNotAllowedError
  unlisted_blocked = true
end
assert(unlisted_blocked, "HEAD https://unlisted-portal.example.org/ is rejected by WebMock default-deny", failures)

puts "\n=== Step 8: Verify real FederationHelper#federation_portal_status under test ==="
module Rails
  def self.cache
    @cache ||= ActiveSupport::Cache::MemoryStore.new
  end
  def self.logger
    @logger ||= Logger.new(nil)
  end
end

module ApplicationHelper; end
require_relative '../../app/helpers/federation_helper'

dummy_helper = Object.new
dummy_helper.extend(FederationHelper)

status_agro = dummy_helper.federation_portal_status(portal_name: :agroportal)
assert(status_agro == true, "Real federation_portal_status(:agroportal) evaluates to true", failures)

status_unlisted = dummy_helper.federation_portal_status(portal_name: :unlisted_portal)
assert(status_unlisted == false, "Real federation_portal_status(:unlisted_portal) safely returns false", failures)

puts "\n=== Summary ==="
if failures.empty?
  puts "ALL CHECKS PASSED: Finite external portal WebMock stubs verified."
  exit 0
else
  puts "FAILED with #{failures.size} issue(s):"
  failures.each { |f| puts "  - #{f}" }
  exit 1
end
