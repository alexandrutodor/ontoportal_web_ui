#!/usr/bin/env ruby
# frozen_string_literal: true

# Standalone isolated regression check for ONTO-T-B14:
# Frozen minimal disabled KGCL integration repair.
#
# Verifies:
# 1. OntologiesHelper#change_requests_enabled? availability condition:
#    - configured ontology + missing GitHub::Client returns false
#    - nil / empty / missing Rails change_request config returns false
#    - null / empty ontologies mapping returns false
#    - unknown acronym returns false
#    - nil / blank acronym returns false
#    - client present + configured ontology returns true (retained-enabled check)
# 2. ConceptsHelper synonym action buttons:
#    - add_synonym_button returns nil (action suppressed)
#    - remove_synonym_button returns nil (action suppressed)
#    - verified for both anonymous and logged-in sessions
# 3. ChangeRequestsController controller entrypoint gating:
#    - GET create_synonym returns controlled HTTP 503 with localized message
#      BEFORE session dereference (anonymous safe, no NoMethodError)
#    - POST create returns controlled HTTP 503 with localized message
#      BEFORE curie lookup, KGCL generation, and IssueCreatorService
#    - Spies verify exactly 0 API lookups, 0 KGCL calls, and 0 issue creations
#    - No flash notice or hidden-field author side effects
#    - Localized explanation verified in both English and French catalogs
# 4. Unchanged ontology editing surface outside disabled change requests
# 5. Zero network access (offline socket guard)

require 'socket'
require 'yaml'
require 'ostruct'

class DisallowedSocketError < StandardError; end

module SocketGuard
  def open(*)
    raise DisallowedSocketError, "TCPSocket.open called during offline check"
  end
  def initialize(*)
    raise DisallowedSocketError, "TCPSocket.new called during offline check"
  end
end
TCPSocket.singleton_class.prepend(SocketGuard)

failures = []

def assert(condition, message, failures)
  if condition
    puts "  [PASS] #{message}"
  else
    puts "  [FAIL] #{message}"
    failures << message
  end
end

repo_root = File.expand_path('../..', __dir__)
en_path = File.join(repo_root, 'config/locales/en.yml')
fr_path = File.join(repo_root, 'config/locales/fr.yml')

puts "=== Step 1: Locale catalogs contain localized unavailable scalar ==="
en_yaml = YAML.load_file(en_path)
fr_yaml = YAML.load_file(fr_path)

en_msg = en_yaml.dig('en', 'change_requests', 'unavailable')
fr_msg = fr_yaml.dig('fr', 'change_requests', 'unavailable')

assert(en_msg.is_a?(String) && !en_msg.strip.empty?, "en locale defines change_requests.unavailable: #{en_msg.inspect}", failures)
assert(fr_msg.is_a?(String) && !fr_msg.strip.empty?, "fr locale defines change_requests.unavailable: #{fr_msg.inspect}", failures)
assert(en_msg != fr_msg, "en and fr messages are distinct localized translations", failures)

require 'action_controller'
require 'action_dispatch'
require 'action_view'
require 'active_support/all'
require 'i18n'

I18n.backend.store_translations(:en, en_yaml['en'])
I18n.backend.store_translations(:fr, fr_yaml['fr'])
I18n.default_locale = :en

# Minimal Rails configuration mock
module Rails
  class Config
    attr_accessor :change_request
  end

  def self.configuration
    @config ||= Config.new
  end
end

puts "\n=== Step 2: OntologiesHelper#change_requests_enabled? availability matrix ==="
require_relative '../../app/helpers/ontologies_helper'

class TestHelperConsumer
  include OntologiesHelper
end

helper = TestHelperConsumer.new

# Scenario 2.1: Configured ontology + missing GitHub::Client
Rails.configuration.change_request = { ontologies: { STY: { repository: 'jvendetti/bioportal-nigms-u24' } } }
assert(!defined?(GitHub::Client), "GitHub::Client constant is not defined in standard runtime", failures)
assert(helper.change_requests_enabled?('STY') == false, "change_requests_enabled?('STY') is false when client is missing", failures)
assert(helper.change_requests_enabled?(:STY) == false, "change_requests_enabled?(:STY) is false when client is missing", failures)

# Scenario 2.2: Nil config
Rails.configuration.change_request = nil
assert(helper.change_requests_enabled?('STY') == false, "change_requests_enabled? is false when config is nil", failures)

# Scenario 2.3: Empty config
Rails.configuration.change_request = {}
assert(helper.change_requests_enabled?('STY') == false, "change_requests_enabled? is false when config is empty", failures)

# Scenario 2.4: Null ontologies in config (appliance environment profile)
Rails.configuration.change_request = { ontologies: nil }
assert(helper.change_requests_enabled?('STY') == false, "change_requests_enabled? is false when ontologies is nil", failures)

# Scenario 2.5: Empty ontologies hash
Rails.configuration.change_request = { ontologies: {} }
assert(helper.change_requests_enabled?('STY') == false, "change_requests_enabled? is false when ontologies is empty hash", failures)

# Scenario 2.6: Unknown acronym
Rails.configuration.change_request = { ontologies: { STY: { repository: 'repo' } } }
assert(helper.change_requests_enabled?('UNKNOWN') == false, "change_requests_enabled? is false for unconfigured acronym", failures)
assert(helper.change_requests_enabled?('') == false, "change_requests_enabled? is false for empty acronym", failures)
assert(helper.change_requests_enabled?(nil) == false, "change_requests_enabled? is false for nil acronym", failures)

puts "\n=== Step 3: ConceptsHelper suppresses synonym buttons when disabled ==="
module TermsReuses; end
module UrlsHelper; end
require_relative '../../app/helpers/concepts_helper'

class TestConceptsViewContext
  include ActionView::Helpers::TagHelper
  include ActionView::Helpers::UrlHelper
  include OntologiesHelper
  include ConceptsHelper

  attr_accessor :ontology, :concept, :session

  def initialize(user: nil)
    @ontology = OpenStruct.new(acronym: 'STY')
    @concept = OpenStruct.new(id: 'http://example.org/concept', prefLabel: 'Test Concept')
    @session = user ? { user: user } : {}
  end
end

anon_ctx = TestConceptsViewContext.new(user: nil)
assert(anon_ctx.add_synonym_button.nil?, "add_synonym_button returns nil for anonymous session with disabled integration", failures)
assert(anon_ctx.remove_synonym_button.nil?, "remove_synonym_button returns nil for anonymous session with disabled integration", failures)

user_mock = OpenStruct.new(username: 'tester')
logged_in_ctx = TestConceptsViewContext.new(user: user_mock)
assert(logged_in_ctx.add_synonym_button.nil?, "add_synonym_button returns nil for logged-in user with disabled integration", failures)
assert(logged_in_ctx.remove_synonym_button.nil?, "remove_synonym_button returns nil for logged-in user with disabled integration", failures)

puts "\n=== Step 4: ChangeRequestsController entrypoints controlled 503 gating ==="

# Define spies
$ontology_api_spy_calls = 0
module LinkedData
  module Client
    module Models
      class Ontology
        def self.find_by_acronym(*)
          $ontology_api_spy_calls += 1
          raise "SPY BREACH: Ontology.find_by_acronym should never be called when disabled"
        end
      end
    end
  end
end

$kgcl_spy_calls = 0
module KGCL
  module IssueContentGenerator
    def self.call(*)
      $kgcl_spy_calls += 1
      raise "SPY BREACH: KGCL::IssueContentGenerator.call should never be called when disabled"
    end
  end
end

$issue_creator_spy_calls = 0
class IssueCreatorService
  def self.call(*)
    $issue_creator_spy_calls += 1
    raise "SPY BREACH: IssueCreatorService.call should never be called when disabled"
  end
end

class ApplicationController < ActionController::Base
  def self.t(*args, **kwargs); I18n.t(*args, **kwargs); end
  def t(*args, **kwargs); I18n.t(*args, **kwargs); end
end

require_relative '../../app/controllers/change_requests_controller'

def dispatch_request(action, env)
  req = ActionDispatch::Request.new(env)
  res = ActionDispatch::Response.new
  ChangeRequestsController.dispatch(action, req, res)
end

# Scenario 4.1: Direct GET create_synonym - anonymous session (session[:user] == nil)
# Verifies 503 response BEFORE session[:user].username dereference (prevents NoMethodError)
Rails.configuration.change_request = { ontologies: { STY: { repository: 'repo' } } }
I18n.locale = :en
env_get_anon = Rack::MockRequest.env_for(
  "/change_requests/create_synonym?ont_acronym=STY&concept_id=test_c&concept_label=Test",
  method: "GET"
)
status, headers, body = dispatch_request(:create_synonym, env_get_anon)
assert(status == 503, "GET create_synonym anonymous returned HTTP 503 (was #{status})", failures)
assert(body.body == en_msg, "GET create_synonym anonymous body matches en explanation: #{body.body.inspect}", failures)

# Scenario 4.2: Direct GET create_synonym - logged in session
env_get_user = Rack::MockRequest.env_for(
  "/change_requests/create_synonym?ont_acronym=STY&concept_id=test_c&concept_label=Test",
  method: "GET",
  'rack.session' => { user: OpenStruct.new(username: 'legit_user') }
)
status, headers, body = dispatch_request(:create_synonym, env_get_user)
assert(status == 503, "GET create_synonym logged-in returned HTTP 503 (was #{status})", failures)
assert(body.body == en_msg, "GET create_synonym logged-in body matches en explanation", failures)

# Scenario 4.3: Direct GET create_synonym - unknown acronym
env_get_unknown = Rack::MockRequest.env_for(
  "/change_requests/create_synonym?ont_acronym=UNKNOWN&concept_id=test_c",
  method: "GET"
)
status, headers, body = dispatch_request(:create_synonym, env_get_unknown)
assert(status == 503, "GET create_synonym unknown acronym returned HTTP 503", failures)
assert(body.body == en_msg, "GET create_synonym unknown acronym returned explanation", failures)

# Scenario 4.4: Direct GET create_synonym - nil/empty config
Rails.configuration.change_request = nil
env_get_noconfig = Rack::MockRequest.env_for(
  "/change_requests/create_synonym?ont_acronym=STY&concept_id=test_c",
  method: "GET"
)
status, headers, body = dispatch_request(:create_synonym, env_get_noconfig)
assert(status == 503, "GET create_synonym with nil config returned HTTP 503", failures)
assert(body.body == en_msg, "GET create_synonym with nil config returned explanation", failures)

# Scenario 4.5: Direct GET create_synonym - French locale
Rails.configuration.change_request = { ontologies: { STY: { repository: 'repo' } } }
I18n.locale = :fr
env_get_fr = Rack::MockRequest.env_for(
  "/change_requests/create_synonym?ont_acronym=STY&concept_id=test_c",
  method: "GET"
)
status, headers, body = dispatch_request(:create_synonym, env_get_fr)
assert(status == 503, "GET create_synonym in French returned HTTP 503", failures)
assert(body.body == fr_msg, "GET create_synonym in French matches fr explanation: #{body.body.inspect}", failures)
I18n.locale = :en

# Scenario 4.6: Direct POST create - anonymous with form params
$ontology_api_spy_calls = 0
$kgcl_spy_calls = 0
$issue_creator_spy_calls = 0

env_post_anon = Rack::MockRequest.env_for(
  "/change_requests",
  method: "POST",
  params: {
    ont_acronym: "STY",
    concept_id: "http://example.org/c1",
    concept_label: "Label 1",
    create_synonym: { preferred_label: "Synonym 1", qualifier: "exact", comment: "Test" }
  }
)
status, headers, body = dispatch_request(:create, env_post_anon)
assert(status == 503, "POST create anonymous returned HTTP 503 (was #{status})", failures)
assert(body.body == en_msg, "POST create anonymous returned en explanation", failures)
assert($ontology_api_spy_calls == 0, "0 Ontology API lookup calls occurred (spy count: #{$ontology_api_spy_calls})", failures)
assert($kgcl_spy_calls == 0, "0 KGCL generator calls occurred (spy count: #{$kgcl_spy_calls})", failures)
assert($issue_creator_spy_calls == 0, "0 IssueCreatorService calls occurred (spy count: #{$issue_creator_spy_calls})", failures)

# Scenario 4.7: Direct POST create - logged-in user with spoofed author hidden fields
env_post_spoofed = Rack::MockRequest.env_for(
  "/change_requests",
  method: "POST",
  params: {
    ont_acronym: "STY",
    concept_id: "http://example.org/c1",
    concept_label: "Label 1",
    username: "attacker_spoofed_user",
    operation: "NEW_SYNONYM",
    create_synonym: { preferred_label: "Evil Synonym", qualifier: "exact", comment: "Injected" }
  },
  'rack.session' => { user: OpenStruct.new(username: 'victim_user') }
)
status, headers, body = dispatch_request(:create, env_post_spoofed)
assert(status == 503, "POST create with spoofed author fields returned HTTP 503", failures)
assert(body.body == en_msg, "POST create with spoofed author fields returned en explanation", failures)
assert($ontology_api_spy_calls == 0, "0 Ontology API calls on spoofed POST attempt", failures)
assert($kgcl_spy_calls == 0, "0 KGCL generator calls on spoofed POST attempt", failures)
assert($issue_creator_spy_calls == 0, "0 IssueCreatorService calls on spoofed POST attempt", failures)

# Scenario 4.8: Direct POST create - nil config & unknown acronym
Rails.configuration.change_request = nil
env_post_unknown = Rack::MockRequest.env_for(
  "/change_requests",
  method: "POST",
  params: { ont_acronym: "UNKNOWN", concept_id: "http://example.org/c1" }
)
status, headers, body = dispatch_request(:create, env_post_unknown)
assert(status == 503, "POST create with unknown acronym and nil config returned HTTP 503", failures)
assert($ontology_api_spy_calls == 0 && $kgcl_spy_calls == 0 && $issue_creator_spy_calls == 0, "Spies confirm 0 calls for unknown acronym POST", failures)

puts "\n=== Step 5: Retained-enabled matrix contract check ==="
# Verify that IF GitHub::Client were present and ontology configured, helper reflects availability
module GitHub
  Client = Object.new
end
Rails.configuration.change_request = { ontologies: { STY: { repository: 'jvendetti/bioportal-nigms-u24' } } }

assert(helper.change_requests_enabled?('STY') == true, "change_requests_enabled?('STY') is true when client is present and ontology configured", failures)
assert(helper.change_requests_enabled?(:STY) == true, "change_requests_enabled?(:STY) is true when client is present and ontology configured", failures)
assert(helper.change_requests_enabled?('UNKNOWN') == false, "change_requests_enabled?('UNKNOWN') is false even when client is present", failures)
assert(helper.change_requests_enabled?('') == false, "change_requests_enabled?('') is false when acronym is empty", failures)
assert(helper.change_requests_enabled?(nil) == false, "change_requests_enabled?(nil) is false when acronym is nil", failures)

# Cleanup injected constant to preserve clean environment
GitHub.send(:remove_const, :Client)
Object.send(:remove_const, :GitHub)
assert(!defined?(GitHub::Client), "GitHub::Client constant cleaned up after retained-enabled check", failures)

puts "\n=== Step 6: Unchanged ontology editing surface ==="
# Verify unrelated helper methods operate as normal
sub_retired = { status: 'retired' }
sub_active = { status: 'production' }
assert(helper.ontology_retired?(sub_retired) == true, "ontology_retired? operates normally for retired status", failures)
assert(helper.ontology_retired?(sub_active) == false, "ontology_retired? operates normally for active status", failures)
assert(helper.ontology_data_sections.include?('classes'), "ontology_data_sections retains classes section", failures)
assert(helper.acronyms([OpenStruct.new(acronym: 'TEST')]) == ['TEST'], "acronyms helper operates normally", failures)

puts "\n=== Summary ==="
if failures.empty?
  puts "ALL CHECKS PASSED: ONTO-T-B14 disabled KGCL integration repair verified."
  exit 0
else
  puts "FAILED with #{failures.size} failure(s):"
  failures.each { |f| puts " - #{f}" }
  exit 1
end
