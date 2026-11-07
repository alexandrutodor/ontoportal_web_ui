#!/usr/bin/env ruby
# frozen_string_literal: true

# Standalone isolated regression check for ONTO-T-B13 (SPARQL Remote-Data Response Seam):
# Verifies replacement of runtime-data inline template evaluation with safe data rendering,
# preservation of harmless literal ERB arithmetic as data, preservation of JSON/XML payload and MIME,
# validation of unexpected/active MIME to non-active data fallback (text/plain),
# preservation of non-success HTTP status for local/upstream/timeout/authorization errors,
# and preservation of query rewrite and authorization policy.
#
# Supports both real Rails mode (inside onto-q02-proof container with Rails 7.0.8, Faraday, SPARQL)
# and host fallback mode.

$assertion_count = 0
$failures = []

def assert(condition, message)
  $assertion_count += 1
  if condition
    puts "  [PASS] #{message}"
  else
    puts "  [FAIL] #{message}"
    $failures << message
  end
end

begin
  require 'action_controller'
  require 'rack'
  require 'faraday'
  require 'sparql'
  REAL_RAILS_MODE = true
  RAILS_VERSION = ActionPack.version.to_s
rescue LoadError => e
  REAL_RAILS_MODE = false
  RAILS_VERSION = nil
end

puts "=== Step 1: Framework Environment Verification ==="
puts "Execution mode: #{REAL_RAILS_MODE ? "Real Rails #{RAILS_VERSION} (ActionPack #{ActionPack.version}, Faraday #{Faraday::VERSION}, SPARQL #{SPARQL::VERSION})" : 'Host fallback'}"

require 'ostruct'
require 'cgi'
require 'set'

# Mocks for LinkedData client models and environment
module LinkedData
  module Client
    def self.settings
      OpenStruct.new(rest_url: 'http://data.example.org')
    end

    module Models
      class User
        attr_accessor :admin

        def initialize(admin: false)
          @admin = admin
        end

        def admin?
          @admin
        end

        def self.find(name, opts = {})
          return nil if name == 'unknown_user'
          new(admin: (name == 'admin_user'))
        end
      end

      class Ontology
        attr_accessor :errors

        def initialize(errors: false)
          @errors = errors
        end

        def self.find_by_acronym(acronym, opts = {})
          return [] if acronym == 'missing_ont'
          [new(errors: (acronym == 'error_ont'))]
        end
      end
    end
  end
end

ADMIN_URL = 'http://data.example.org/admin/'

# Rails cache stub for controller before_action
module Rails
  def self.cache
    @cache ||= (defined?(ActiveSupport::Cache::MemoryStore) ? ActiveSupport::Cache::MemoryStore.new : Object.new)
  end
end

# Controller helper module stubs
module TurboHelper; end
module HomeHelper; end
module AdminHelper; end

unless defined?(Faraday)
  module Faraday
    class TimeoutError < StandardError; end
    class Response
      attr_accessor :status, :body, :headers
      def initialize(status: 200, body: '', response_headers: {})
        @status = status
        @body = body
        @headers = response_headers
      end
    end
    def self.new(*args, &block)
      conn = Object.new
      conn.define_singleton_method(:options) { OpenStruct.new }
      conn.define_singleton_method(:get) do |url|
        $faraday_call_count += 1
        raise 'No stubbed Faraday proc configured' unless $stubbed_faraday_proc
        $stubbed_faraday_proc.call(url)
      end
      conn
    end
  end
end

# Load the actual SparqlHelper and AdminController
repo_root = File.expand_path('../..', __dir__)
require File.join(repo_root, 'app/helpers/sparql_helper.rb')

if REAL_RAILS_MODE
  class ApplicationController < ActionController::Base
    helper SparqlHelper
    def determine_layout; nil; end
    def authorize_admin; true; end
    def t(key, **opts)
      case key
      when 'admin.query_not_permitted' then 'Query not permitted'
      else key.to_s
      end
    end
  end

  require File.join(repo_root, 'app/controllers/admin_controller.rb')
else
  # Host fallback controller double
  class FallbackResponse
    attr_accessor :status, :body, :content_type, :headers

    def initialize
      @status = 200
      @body = ''
      @content_type = 'text/plain'
      @headers = {}
    end
  end

  class ApplicationController
    def self.layout(*); end
    def self.before_action(*); end

    attr_accessor :params, :response

    include SparqlHelper

    def initialize
      @response = FallbackResponse.new
      @params = {}
    end

    def helpers
      self
    end

    def render(options = {})
      if options[:plain]
        @response.body = options[:plain].to_s
        @response.content_type = options[:content_type] || 'text/plain; charset=utf-8'
        status = options[:status] || 200
        @response.status = status == :forbidden ? 403 : status
      elsif options[:inline]
        # In vulnerable version this evaluated inline ERB
        @response.body = options[:inline].to_s
        @response.content_type = 'text/html; charset=utf-8'
        @response.status = 200
      end
      true
    end

    def t(key, **opts)
      case key
      when 'admin.query_not_permitted' then 'Query not permitted'
      else key.to_s
      end
    end
  end

  require File.join(repo_root, 'app/controllers/admin_controller.rb')
end

# Faraday request interceptor
$stubbed_faraday_proc = nil
$faraday_call_count = 0

if defined?(Faraday)
  orig_faraday_new = Faraday.method(:new)
  Faraday.define_singleton_method(:new) do |*args, &block|
    conn = orig_faraday_new.call(*args, &block)
    conn.define_singleton_method(:get) do |url|
      $faraday_call_count += 1
      raise 'No stubbed Faraday proc configured' unless $stubbed_faraday_proc
      $stubbed_faraday_proc.call(url)
    end
    conn
  end
end

def with_stubbed_faraday(proc)
  $stubbed_faraday_proc = proc
  $faraday_call_count = 0
  yield
ensure
  $stubbed_faraday_proc = nil
end

def execute_sparql_endpoint(query_params)
  controller = AdminController.new
  if REAL_RAILS_MODE
    env_query = query_params.map { |k, v| "#{CGI.escape(k.to_s)}=#{CGI.escape(v.to_s)}" }.join('&')
    env = Rack::MockRequest.env_for("/sparql_proxy?#{env_query}")
    controller.set_request!(ActionDispatch::Request.new(env))
    controller.set_response!(ActionDispatch::Response.new)
    controller.process(:sparql_endpoint)
  else
    controller.params = query_params.transform_keys(&:to_s).merge(query_params.transform_keys(&:to_sym))
    controller.sparql_endpoint
  end
  controller.response
end

$SPARQL_URL = 'http://localhost:8890/sparql'
$REST_URL = 'http://data.example.org'
valid_graph = 'http://data.example.org/ontologies/TEST/submissions/1'
valid_query = 'SELECT * WHERE { ?s ?p ?o } LIMIT 10'

puts "\n=== Step 2: SPARQL ERB Data Preservation & No Template Evaluation ==="
with_stubbed_faraday(lambda do |url|
  Faraday::Response.new(
    status: 200,
    body: '{"results": {"literal_calc": "<%= 7 * 7 %>", "eval_check": "<%= 10 + 20 %>"}}',
    response_headers: { 'content-type' => 'application/sparql-results+json; charset=utf-8' }
  )
end) do
  resp = execute_sparql_endpoint(
    'named-graph-uri' => valid_graph,
    'query' => valid_query,
    'username' => 'admin_user',
    'apikey' => 'secret_token'
  )
  assert(resp.status == 200, "ERB data test returns status 200 (actual: #{resp.status})")
  assert(resp.content_type.to_s.start_with?('application/sparql-results+json'), "Content-Type is JSON (actual: #{resp.content_type})")
  assert(resp.body.include?('<%= 7 * 7 %>'), "Literal ERB arithmetic '<%= 7 * 7 %>' remains data in body")
  assert(resp.body.include?('<%= 10 + 20 %>'), "Literal ERB arithmetic '<%= 10 + 20 %>' remains data in body")
  assert(!resp.body.include?('49') && !resp.body.include?('30'), 'Harmless ERB delimiters are NOT evaluated by template compiler')
end

puts "\n=== Step 3: Standard JSON and XML Payload & MIME Preservation ==="
# JSON preservation
with_stubbed_faraday(lambda do |url|
  Faraday::Response.new(
    status: 200,
    body: '{"head": {"vars": ["s"]}, "results": {"bindings": [{"s": {"type": "uri", "value": "http://ex.org/1"}}]}}',
    response_headers: { 'content-type' => 'application/sparql-results+json' }
  )
end) do
  resp = execute_sparql_endpoint('named-graph-uri' => valid_graph, 'query' => valid_query)
  assert(resp.status == 200, "JSON result status 200 preserved")
  assert(resp.content_type.to_s.include?('application/sparql-results+json'), "JSON MIME preserved (actual: #{resp.content_type})")
  assert(resp.body.include?('http://ex.org/1'), "JSON payload body preserved intact")
end

# XML preservation
xml_payload = '<sparql xmlns="http://www.w3.org/2005/sparql-results#"><head><variable name="x"/></head><results><result><binding name="x"><literal><%= 1 + 1 %></literal></binding></result></results></sparql>'
with_stubbed_faraday(lambda do |url|
  Faraday::Response.new(
    status: 200,
    body: xml_payload,
    response_headers: { 'content-type' => 'application/sparql-results+xml; charset=utf-8' }
  )
end) do
  resp = execute_sparql_endpoint('named-graph-uri' => valid_graph, 'query' => valid_query)
  assert(resp.status == 200, "XML result status 200 preserved")
  assert(resp.content_type.to_s.include?('application/sparql-results+xml'), "XML MIME preserved (actual: #{resp.content_type})")
  assert(resp.body.include?('<literal><%= 1 + 1 %></literal>'), "XML payload preserved with unevaluated ERB")
end

puts "\n=== Step 4: Upstream Error Status Preservation ==="
with_stubbed_faraday(lambda do |url|
  Faraday::Response.new(
    status: 500,
    body: 'Virtuoso 37000 Error: execution failed',
    response_headers: { 'content-type' => 'text/plain' }
  )
end) do
  resp = execute_sparql_endpoint('named-graph-uri' => valid_graph, 'query' => valid_query)
  assert(resp.status == 500, "Upstream HTTP 500 error preserved, not falsely 200 (actual: #{resp.status})")
  assert(resp.body.include?('Virtuoso 37000 Error'), "Upstream error text preserved in response body")
end

puts "\n=== Step 5: Unexpected Active MIME Fallback to Safe Data Type ==="
# Active HTML fallback
with_stubbed_faraday(lambda do |url|
  Faraday::Response.new(
    status: 200,
    body: '<html><body><script>alert("xss")</script><div>results</div></body></html>',
    response_headers: { 'content-type' => 'text/html; charset=utf-8' }
  )
end) do
  resp = execute_sparql_endpoint('named-graph-uri' => valid_graph, 'query' => valid_query)
  assert(resp.status == 200, "Response status 200 preserved on valid response")
  assert(resp.content_type.to_s.include?('text/plain'), "Active text/html MIME sanitized to text/plain fallback (actual: #{resp.content_type})")
  assert(!resp.content_type.to_s.include?('text/html'), "Response does NOT deliver active text/html")
end

# Active Javascript fallback
with_stubbed_faraday(lambda do |url|
  Faraday::Response.new(
    status: 200,
    body: 'alert("evil")',
    response_headers: { 'content-type' => 'application/javascript' }
  )
end) do
  resp = execute_sparql_endpoint('named-graph-uri' => valid_graph, 'query' => valid_query)
  assert(resp.content_type.to_s.include?('text/plain'), "application/javascript sanitized to text/plain fallback (actual: #{resp.content_type})")
end

puts "\n=== Step 6: Local Parse / Disallowed / Unconfigured / Timeout Errors ==="
# Unconfigured endpoint
old_sparql_url = $SPARQL_URL
$SPARQL_URL = nil
resp = execute_sparql_endpoint('named-graph-uri' => valid_graph, 'query' => valid_query)
assert(resp.status == 503, "Unconfigured endpoint returns 503 Service Unavailable (actual: #{resp.status})")
assert(resp.body.include?('No SPARQL endpoint configured'), "Unconfigured endpoint body matches expected message")
$SPARQL_URL = old_sparql_url

# Disallowed mutation query (INSERT DATA)
resp = execute_sparql_endpoint(
  'named-graph-uri' => valid_graph,
  'query' => 'INSERT DATA { <http://example.org/s> <http://example.org/p> <http://example.org/o> }'
)
assert(resp.status == 403, "Disallowed INSERT query returns 403 Forbidden (actual: #{resp.status})")
assert(resp.body.include?('INSERT Queries not permitted'), "Disallowed query body matches expected message")

# Local query syntax parse error
resp = execute_sparql_endpoint(
  'named-graph-uri' => valid_graph,
  'query' => 'SELECT ?x WHERE { ?x ?y'
)
assert(resp.status == 400, "Syntax parse error returns 400 Bad Request (actual: #{resp.status})")
assert(resp.body.include?('Failed to parse query'), "Parse error body matches expected message")

# Query timeout
with_stubbed_faraday(lambda do |url|
  raise Faraday::TimeoutError, 'execution expired'
end) do
  resp = execute_sparql_endpoint('named-graph-uri' => valid_graph, 'query' => valid_query)
  assert(resp.status == 504, "Connection timeout returns 504 Gateway Timeout (actual: #{resp.status})")
  assert(resp.body.include?('Query timeout'), "Timeout body matches expected message")
end

puts "\n=== Step 7: Authorization Short-Circuit Preservation ==="
# Missing user
$faraday_call_count = 0
resp = execute_sparql_endpoint(
  'named-graph-uri' => valid_graph,
  'query' => valid_query,
  'username' => 'unknown_user',
  'apikey' => 'bad_key'
)
assert(resp.status == 403, "Missing user short-circuits with 403 Forbidden (actual: #{resp.status})")
assert(resp.body == 'Query not permitted', "Missing user message is 'Query not permitted'")
assert($faraday_call_count == 0, 'No Faraday call made on missing user authorization failure')

# Blank graph without admin user
$faraday_call_count = 0
resp = execute_sparql_endpoint(
  'named-graph-uri' => '',
  'query' => valid_query,
  'username' => 'normal_user',
  'apikey' => 'token'
)
assert(resp.status == 403, "Blank graph without admin user short-circuits with 403 Forbidden (actual: #{resp.status})")
assert($faraday_call_count == 0, 'No Faraday call made on blank graph non-admin failure')

# Missing ontology
$faraday_call_count = 0
resp = execute_sparql_endpoint(
  'named-graph-uri' => 'http://data.example.org/ontologies/missing_ont/submissions/1',
  'query' => valid_query
)
assert(resp.status == 403, "Missing ontology short-circuits with 403 Forbidden (actual: #{resp.status})")
assert($faraday_call_count == 0, 'No Faraday call made on missing ontology failure')

# Ontology with errors
$faraday_call_count = 0
resp = execute_sparql_endpoint(
  'named-graph-uri' => 'http://data.example.org/ontologies/error_ont/submissions/1',
  'query' => valid_query
)
assert(resp.status == 403, "Ontology with errors short-circuits with 403 Forbidden (actual: #{resp.status})")
assert($faraday_call_count == 0, 'No Faraday call made on ontology error failure')

puts "\n=== Step 8: Scoped Query Rewrite & Encoding Normalization ==="
class HelperHost
  include SparqlHelper
end
helper = HelperHost.new

# Query rewrite
rewritten = helper.change_from_clause(valid_query, valid_graph)
expected_graph = valid_graph.gsub($REST_URL, 'http://data.bioontology.org')
assert(rewritten.include?("FROM <#{expected_graph}> WHERE"), "change_from_clause properly inserts graph into query")

# Encoding normalization: UTF-8 preserved
utf8_in = "test åäö 漢字"
assert(helper.normalize_body_encoding(utf8_in) == utf8_in, "normalize_body_encoding preserves valid UTF-8 string")

# Encoding normalization: ISO-8859-1 conversion
iso_bytes = "caf\xE9".b
assert(helper.normalize_body_encoding(iso_bytes) == "café", "normalize_body_encoding cleanly converts legacy ISO-8859-1 bytes to UTF-8")

puts "\n=== Regression Check Summary ==="
if $failures.empty?
  puts "ALL #{$assertion_count} ACCEPTANCE ASSERTIONS PASSED."
  exit 0
else
  puts "#{$failures.size} OF #{$assertion_count} ASSERTION(S) FAILED:"
  $failures.each { |f| puts "  - #{f}" }
  exit 1
end
