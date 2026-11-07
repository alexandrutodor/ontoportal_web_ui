# frozen_string_literal: true

require 'minitest/autorun'
require 'logger'
require 'ostruct'
require 'pathname'
require 'socket'
require 'timeout'

# =============================================================================
# Standalone Offline Resource Serialization Status & Payload Check (ONTO-T-B17)
#
# Validates the frozen B17 resource serialization contract:
# 1. Result object / tuple contract (content, content_type, status, bytes, success?).
# 2. Upstream status preservation across all 3 callers and raw downloads:
#    - OntologiesRedirectionController#redirect (non-HTML content negotiation)
#    - ContentFinderController#index (HTML tool)
#    - OntologiesController#content_serializer (HTML modal)
#    - UriRedirection#fetch_and_forward_data (raw ontology downloads)
# 3. Upstream 200 preserves valid RDF MIME types (JSON-LD, RDF/XML, N-Triples, Turtle)
#    and exact byte-equivalence.
# 4. Upstream 403, 404, 502 stay non-success; error bodies are never labeled as valid
#    RDF and raw bodies/credentials are never leaked.
# 5. Controlled deadlines/timeouts produce generic appropriate 504 error.
# 6. Large-payload memory/size strategy: enforces transport chunk limit before
#    buffering full payload; returns 413 without partial 200 truncation.
# 7. Missing inputs on ContentFinder return empty form 200 without fake API errors;
#    controller cleans up instance state without stale result reuse.
# 8. HTML tool & modal failure branches bypass RDF highlighter & N-Triples parser,
#    display escaped controlled errors with actual HTTP status, and preserve UI widgets.
# =============================================================================

# Gem paths in native container environment
if Dir.exist?('/usr/local/bundle/ruby/3.1.0/gems') && (ENV['GEM_PATH'].nil? || !ENV['GEM_PATH'].include?('/usr/local/bundle/ruby/3.1.0'))
  Gem.use_paths(nil, Gem.path + ['/usr/local/bundle/ruby/3.1.0'])
end

sdk_lib = '/usr/local/bundle/ruby/3.1.0/bundler/gems/ontologies_api_ruby_client-6257685e5744/lib'
$LOAD_PATH.unshift(sdk_lib) if Dir.exist?(sdk_lib) && !$LOAD_PATH.include?(sdk_lib)

worktree_root = File.expand_path('../..', __dir__)
$LOAD_PATH.unshift(File.join(worktree_root, 'app/helpers'))
$LOAD_PATH.unshift(File.join(worktree_root, 'app/controllers/concerns'))
$LOAD_PATH.unshift(File.join(worktree_root, 'app/controllers'))

require 'rails'
require 'action_controller'
require 'action_view'
require 'active_record'
require 'haml'
require 'haml/plugin'

# Configure loggers and global app constants
ActionController::Base.logger = Logger.new(nil)
Rails.logger = Logger.new(nil)
Rails.application = OpenStruct.new(
  credentials: OpenStruct.new(analytics: {}),
  env_config: {},
  config: OpenStruct.new(root: Pathname.new(worktree_root))
)

$ENABLE_SLICES = false
$REST_URL = 'http://127.0.0.1:9' # Overridden per test with fixture server
$API_KEY = 'super-secret-api-token-xyz'

# Load actual localization dictionary
I18n.load_path = Dir[File.join(worktree_root, 'config/locales/*.yml')]
I18n.default_locale = :en
I18n.locale = :en

# Lightweight component doubles for rendering actual Haml templates offline
module ActionView
  class Base
    def inline_svg_tag(path, **_opts)
      "<svg data-src=\"#{path}\"></svg>".html_safe
    end
  end
end

module Input
  class UrlComponent
    def initialize(**opts); @opts = opts; end
    def render_in(_v); "<input name=\"#{@opts[:name]}\" value=\"#{@opts[:value]}\"/>".html_safe; end
  end

  class SelectComponent
    def initialize(**opts); @opts = opts; end
    def render_in(_v); "<select name=\"#{@opts[:name]}\"></select>".html_safe; end
  end
end

module Buttons
  class RegularButtonComponent
    def initialize(**opts); @opts = opts; end
    def render_in(_v); "<button id=\"#{@opts[:id]}\">#{@opts[:value]}</button>".html_safe; end
  end
end

module Display
  class EmptyStateComponent
    def initialize(**opts); @opts = opts; end
    def render_in(_v); "<div class=\"empty-state\">#{@opts[:text]}</div>".html_safe; end
  end

  class RdfHighlighterComponent
    def initialize(**opts); @opts = opts; end
    def render_in(_v); "<div class=\"rdf-highlighter\" data-format=\"#{@opts[:format]}\">#{@opts[:text]}</div>".html_safe; end
  end
end

class PopupLinkTextComponent
  def initialize(text:); @text = text; end
  def call; @text; end
end

class TurboModalComponent
  def initialize(**opts); end
  def render_in(_v); ''.html_safe; end
end

class TurboFrameComponent
  def initialize(**opts); end
  def render_in(v, &block); block ? v.capture(&block) : ''.html_safe; end
end

class TableComponent
  def initialize(**opts); end
  def add_row(*args); end
  def row
    row_obj = Object.new
    def row_obj.td; yield if block_given?; end
    yield row_obj if block_given?
  end
  def render_in(_v); '<table class="table"></table>'.html_safe; end
end

# Require actual production helpers, concerns, and controllers
require 'urls_helper'
require 'terms_reuses'
require 'components_helper'
require 'ontologies_helper'
require 'internationalisation_helper'
require 'multi_languages_helper'
require 'application_controller'
require 'mappings_helper'
require 'concepts_helper'
require 'turbo_helper'
require 'concepts_controller'
require 'search_content'
require 'properties_helper'
require 'properties_controller'
require 'mapping_statistics'
require 'mappings_controller'
require 'modal_helper'
require 'application_helper'
require 'fair_score_helper'
require 'instances_helper'
require 'schemes_helper'
require 'collections_helper'
require 'submission_updater'
require 'ontology_updater'
require 'sparql_helper'
require 'federation_helper'
require 'submission_filter'
require 'ontology_content_serializer'
require 'uri_redirection'
require 'ontologies_controller'
require 'content_finder_controller'
require 'ontologies_redirection_controller'

ActionView::Base.include MultiLanguagesHelper
ActionView::Base.include ApplicationHelper
ActionView::Base.include ComponentsHelper
ActionView::Base.include OntologiesHelper
ActionView::Base.include ModalHelper

module ApplicationHelper
  def onts_for_select
    [['Test Ontology', 'TEST']]
  end
end

[ApplicationController, ContentFinderController, OntologiesController, OntologiesRedirectionController].each do |ctrl|
  ctrl.prepend_view_path(File.join(worktree_root, 'app/views'))
  ctrl.skip_before_action :set_locale, :domain_ontology_set, :init_trial_license, :authorize_and_redirect,
                          :submission_metadata, :set_federated_portals, :authorize_read_only,
                          :authorize_ontology_admin, raise: false
  ctrl.layout false
end

# Task-owned loopback server running inside --network none container
class LoopbackFixtureServer
  attr_reader :port

  def initialize
    @server = TCPServer.new('127.0.0.1', 0)
    @port = @server.addr[1]
    @routes = {}
    @running = true
    @thread = Thread.new { run_loop }
  end

  def route(path, &handler)
    @routes[path] = handler
  end

  def shutdown
    @running = false
    @server.close rescue nil
    @thread.join rescue nil
  end

  private

  def run_loop
    while @running
      begin
        socket = @server.accept
      rescue IOError, Errno::EBADF
        break
      end
      Thread.new(socket) do |s|
        handle_connection(s)
      end
    end
  end

  def handle_connection(s)
    req_line = s.gets
    return s.close unless req_line

    method, full_path, _ = req_line.split(' ')
    path = full_path ? full_path.split('?').first : '/'

    headers = {}
    while (line = s.gets) && (line.strip != '')
      k, v = line.split(':', 2)
      headers[k.strip.downcase] = v.strip if k && v
    end

    handler = @routes[path] || @routes['*']
    if handler
      handler.call(method, full_path, headers, s)
    else
      s.print "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
    end
    s.close rescue nil
  end
end

# Test suite executing full B17 serialization contract
class ResourceSerializationStatusContractCheck < Minitest::Test
  def setup
    @server = LoopbackFixtureServer.new
    @original_rest_url = $REST_URL
    $REST_URL = "http://127.0.0.1:#{@server.port}"
  end

  def teardown
    @server.shutdown
    $REST_URL = @original_rest_url
  end

  # Helper to execute controller actions offline
  def dispatch(ctrl_class, action, params: {}, headers: {})
    req = ActionDispatch::TestRequest.create
    req.flash = ActionDispatch::Flash::FlashHash.new
    headers.each { |k, v| req.headers[k] = v }
    params.each { |k, v| req.params[k] = v }

    res = ActionDispatch::TestResponse.create
    ctrl = ctrl_class.new
    ctrl.set_request!(req)
    ctrl.set_response!(res)
    ctrl.process(action)
    res
  end

  # ---------------------------------------------------------------------------
  # 1. Result Object & Destructuring Tuple Contract
  # ---------------------------------------------------------------------------
  def test_result_object_and_tuple_destructuring
    res_success = OntologyContentSerializer::Result.new(
      content: 'triple-content',
      content_type: 'text/turtle',
      status: 200,
      error: nil
    )
    assert res_success.success?
    assert_equal 200, res_success.status
    assert_equal 'text/turtle', res_success.content_type
    assert_equal 'triple-content', res_success.content
    assert_equal 14, res_success.bytes
    assert_nil res_success.error

    # Parallel assignment / destructuring into [content, content_type, status]
    content, content_type, status = res_success
    assert_equal 'triple-content', content
    assert_equal 'text/turtle', content_type
    assert_equal 200, status

    res_failure = OntologyContentSerializer::Result.new(
      content: nil,
      content_type: 'text/plain',
      status: 404,
      error: 'Not Found'
    )
    refute res_failure.success?
    assert_equal 404, res_failure.status
    assert_equal 0, res_failure.bytes
    assert_equal 'Not Found', res_failure.error
  end

  # ---------------------------------------------------------------------------
  # 2. Upstream 200 Success Across Formats & Byte-Equivalence
  # ---------------------------------------------------------------------------
  def test_upstream_200_formats_and_byte_equivalence
    formats = {
      'turtle' => {
        accept: 'text/turtle',
        body: "@prefix ex: <http://example.org/> .\nex:Resource a ex:Class ;\n  ex:label \"Success\" .",
        mime: 'text/turtle'
      },
      'json' => {
        accept: 'application/ld+json',
        body: '{"@context":"http://example.org/","@id":"ex:Resource","label":"Success"}',
        mime: 'application/ld+json'
      },
      'xml' => {
        accept: 'application/rdf+xml',
        body: '<?xml version="1.0"?><rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#"></rdf:RDF>',
        mime: 'application/rdf+xml'
      },
      'ntriples' => {
        accept: 'application/n-triples',
        body: "<http://example.org/res> <http://example.org/prop> \"value\" .\n",
        mime: 'application/n-triples'
      }
    }

    formats.each do |fmt_name, spec|
      @server.route("/ontologies/TEST/resolve/#{CGI.escape('http://example.org/res')}") do |_method, _path, headers, s|
        assert_equal spec[:accept], headers['accept']
        assert_includes headers['authorization'], 'apikey token='
        s.print "HTTP/1.1 200 OK\r\nContent-Type: #{spec[:mime]}\r\nContent-Length: #{spec[:body].bytesize}\r\nConnection: close\r\n\r\n#{spec[:body]}"
      end

      ctrl = ContentFinderController.new
      result = ctrl.serialize_content(
        ontology_acronym: 'TEST',
        concept_id: 'http://example.org/res',
        format: fmt_name
      )

      assert result.success?, "Expected success for #{fmt_name}"
      assert_equal 200, result.status
      assert_equal spec[:mime], result.content_type
      assert_equal spec[:body], result.content
      assert_equal spec[:body].bytesize, result.bytes
    end
  end

  # ---------------------------------------------------------------------------
  # 3. Upstream Failures: 403, 404, 502 Never Label as Valid RDF & Never Leak
  # ---------------------------------------------------------------------------
  def test_upstream_failures_preserve_status_and_never_label_rdf
    [403, 404, 502].each do |status_code|
      raw_upstream_leak = "ERROR_LEAK_SECRET_KEY=#{ENV['API_KEY'] || 'secret'} <p>Stack trace</p>"

      @server.route("/ontologies/TEST/resolve/#{CGI.escape('http://example.org/res')}") do |_method, _path, _headers, s|
        s.print "HTTP/1.1 #{status_code} Error\r\nContent-Type: text/html\r\nContent-Length: #{raw_upstream_leak.bytesize}\r\nConnection: close\r\n\r\n#{raw_upstream_leak}"
      end

      # Direct serializer test
      ctrl = ContentFinderController.new
      result = ctrl.serialize_content(
        ontology_acronym: 'TEST',
        concept_id: 'http://example.org/res',
        format: 'turtle'
      )

      refute result.success?
      assert_equal status_code, result.status
      assert_equal 'text/plain', result.content_type
      assert_nil result.content
      refute_includes result.error, 'ERROR_LEAK_SECRET_KEY'
      refute_includes result.error, $API_KEY
    end
  end

  # ---------------------------------------------------------------------------
  # 4. Caller 1: OntologiesRedirectionController#redirect (non-HTML)
  # ---------------------------------------------------------------------------
  def test_ontologies_redirection_caller_matrix
    # Stub find_type_by_id so it resolves without needing search API
    OntologiesRedirectionController.class_eval do
      def find_type_by_id(_id, _acronym)
        ['class', 'http://example.org/res']
      end
    end

    # Success 200 case
    rdf_body = "@prefix : <http://example.org/> .\n:res a :Class ."
    @server.route("/ontologies/TEST/resolve/#{CGI.escape('http://example.org/res')}") do |_method, _path, headers, s|
      assert_equal 'text/turtle', headers['accept']
      s.print "HTTP/1.1 200 OK\r\nContent-Type: text/turtle\r\nContent-Length: #{rdf_body.bytesize}\r\nConnection: close\r\n\r\n#{rdf_body}"
    end

    res_200 = dispatch(OntologiesRedirectionController, :redirect,
                       params: { acronym: 'TEST', id: 'res' },
                       headers: { 'HTTP_ACCEPT' => 'text/turtle' })
    assert_equal 200, res_200.status
    assert_includes res_200.headers['Content-Type'], 'text/turtle'
    assert_equal rdf_body, res_200.body

    # Failure 404 case
    @server.route("/ontologies/TEST/resolve/#{CGI.escape('http://example.org/res')}") do |_m, _p, _h, s|
      s.print "HTTP/1.1 404 Not Found\r\nContent-Type: text/html\r\nContent-Length: 9\r\nConnection: close\r\n\r\nNot Found"
    end
    res_404 = dispatch(OntologiesRedirectionController, :redirect,
                       params: { acronym: 'TEST', id: 'res' },
                       headers: { 'HTTP_ACCEPT' => 'text/turtle' })
    assert_equal 404, res_404.status
    assert_includes res_404.headers['Content-Type'], 'text/plain'
    assert_equal 'Not Found', res_404.body

    # Failure 403 case
    @server.route("/ontologies/TEST/resolve/#{CGI.escape('http://example.org/res')}") do |_m, _p, _h, s|
      s.print "HTTP/1.1 403 Forbidden\r\nContent-Type: text/html\r\nContent-Length: 9\r\nConnection: close\r\n\r\nForbidden"
    end
    res_403 = dispatch(OntologiesRedirectionController, :redirect,
                       params: { acronym: 'TEST', id: 'res' },
                       headers: { 'HTTP_ACCEPT' => 'text/turtle' })
    assert_equal 403, res_403.status
    assert_includes res_403.headers['Content-Type'], 'text/plain'
    assert_equal 'Forbidden', res_403.body

    # Failure 502 case
    @server.route("/ontologies/TEST/resolve/#{CGI.escape('http://example.org/res')}") do |_m, _p, _h, s|
      s.print "HTTP/1.1 502 Bad Gateway\r\nContent-Type: text/html\r\nContent-Length: 11\r\nConnection: close\r\n\r\nBad Gateway"
    end
    res_502 = dispatch(OntologiesRedirectionController, :redirect,
                       params: { acronym: 'TEST', id: 'res' },
                       headers: { 'HTTP_ACCEPT' => 'text/turtle' })
    assert_equal 502, res_502.status
    assert_includes res_502.headers['Content-Type'], 'text/plain'
    assert_equal 'Bad Gateway', res_502.body
  end

  # ---------------------------------------------------------------------------
  # 5. Caller 2: ContentFinderController#index (HTML Tool)
  # ---------------------------------------------------------------------------
  def test_content_finder_missing_inputs_empty_form_200
    res = dispatch(ContentFinderController, :index, params: {})
    assert_equal 200, res.status
    assert_includes res.body, 'content-finder-container'
    refute_includes res.body, 'alert-danger'
    refute_includes res.body, 'Content not found'
  end

  def test_content_finder_success_renders_widget
    rdf_body = "@prefix : <http://example.org/> .\n:res a :Class ."
    @server.route("/ontologies/TEST/resolve/#{CGI.escape('http://example.org/res')}") do |_m, _p, _h, s|
      s.print "HTTP/1.1 200 OK\r\nContent-Type: text/turtle\r\nContent-Length: #{rdf_body.bytesize}\r\nConnection: close\r\n\r\n#{rdf_body}"
    end

    res = dispatch(ContentFinderController, :index,
                   params: { acronym: 'TEST', uri: 'http://example.org/res', output_format: 'turtle' })
    assert_equal 200, res.status
    assert_includes res.body, 'rdf-highlighter'
    refute_includes res.body, 'alert-danger'
  end

  def test_content_finder_html_output_parses_n_triples_table
    nt_body = "<http://example.org/res> <http://example.org/prop> \"value\" .\n"
    @server.route("/ontologies/TEST/resolve/#{CGI.escape('http://example.org/res')}") do |_m, _p, _h, s|
      s.print "HTTP/1.1 200 OK\r\nContent-Type: application/n-triples\r\nContent-Length: #{nt_body.bytesize}\r\nConnection: close\r\n\r\n#{nt_body}"
    end

    res = dispatch(ContentFinderController, :index,
                   params: { acronym: 'TEST', uri: 'http://example.org/res', output_format: 'html' })
    assert_equal 200, res.status
    refute_includes res.body, 'alert-danger'
    assert_includes res.body, 'content-finder-result'
  end

  def test_content_finder_failure_bypasses_parser_and_shows_escaped_error
    [404, 403, 502].each do |code|
      @server.route("/ontologies/TEST/resolve/#{CGI.escape('http://example.org/res')}") do |_m, _p, _h, s|
        s.print "HTTP/1.1 #{code} Error\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
      end

      res = dispatch(ContentFinderController, :index,
                     params: { acronym: 'TEST', uri: 'http://example.org/res', output_format: 'html' })
      assert_equal code, res.status
      assert_includes res.body, 'alert alert-danger'
      # Crucial: N-Triples parser / highlighter is bypassed
      refute_includes res.body, 'rdf-highlighter'
      refute_includes res.body, 'content-finder-result'
      # UI input form is preserved
      assert_includes res.body, 'content-finder-container'
    end
  end

  # ---------------------------------------------------------------------------
  # 6. Caller 3: OntologiesController#content_serializer (HTML Modal)
  # ---------------------------------------------------------------------------
  def test_ontologies_content_serializer_modal_matrix
    # Success 200 modal
    rdf_body = "@prefix : <http://example.org/> .\n:res a :Class ."
    @server.route("/ontologies/TEST/resolve/#{CGI.escape('res')}") do |_m, _p, _h, s|
      s.print "HTTP/1.1 200 OK\r\nContent-Type: text/turtle\r\nContent-Length: #{rdf_body.bytesize}\r\nConnection: close\r\n\r\n#{rdf_body}"
    end

    res_200 = dispatch(OntologiesController, :content_serializer,
                       params: { acronym: 'TEST', id: 'res', output_format: 'turtle' })
    assert_equal 200, res_200.status
    assert_includes res_200.body, 'resource_content_modal'
    assert_includes res_200.body, 'rdf-highlighter'
    refute_includes res_200.body, 'alert-danger'

    # Failure 404 modal
    @server.route("/ontologies/TEST/resolve/#{CGI.escape('res')}") do |_m, _p, _h, s|
      s.print "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
    end

    res_404 = dispatch(OntologiesController, :content_serializer,
                       params: { acronym: 'TEST', id: 'res', output_format: 'turtle' })
    assert_equal 404, res_404.status
    assert_includes res_404.body, 'resource_content_modal'
    assert_includes res_404.body, 'alert alert-danger'
    assert_includes res_404.body, 'Not Found'
    refute_includes res_404.body, 'rdf-highlighter'

    # Failure 502 modal
    @server.route("/ontologies/TEST/resolve/#{CGI.escape('res')}") do |_m, _p, _h, s|
      s.print "HTTP/1.1 502 Bad Gateway\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
    end

    res_502 = dispatch(OntologiesController, :content_serializer,
                       params: { acronym: 'TEST', id: 'res', output_format: 'turtle' })
    assert_equal 502, res_502.status
    assert_includes res_502.body, 'resource_content_modal'
    assert_includes res_502.body, 'alert alert-danger'
    assert_includes res_502.body, 'Bad Gateway'
    refute_includes res_502.body, 'rdf-highlighter'
  end

  # ---------------------------------------------------------------------------
  # 7. Controlled Timeouts (Explicit Connect & Read Deadlines)
  # ---------------------------------------------------------------------------
  def test_controlled_timeout_produces_504_gateway_timeout
    # Sleep to trigger Faraday timeout (configured to READ_TIMEOUT = 15s in production,
    # temporarily tested via isolated short timeout or socket stall)
    @server.route("/ontologies/TEST/resolve/#{CGI.escape('http://example.org/res')}") do |_m, _p, _h, s|
      # Stall connection until timeout
      sleep 0.8
      s.print "HTTP/1.1 200 OK\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
    end

    # Test serializer with a 0.2s deadline override to verify timeout rescue
    original_timeout = OntologyContentSerializer::READ_TIMEOUT
    OntologyContentSerializer.send(:remove_const, :READ_TIMEOUT)
    OntologyContentSerializer.const_set(:READ_TIMEOUT, 0.2)

    begin
      ctrl = ContentFinderController.new
      result = ctrl.serialize_content(
        ontology_acronym: 'TEST',
        concept_id: 'http://example.org/res',
        format: 'turtle'
      )
      refute result.success?
      assert_equal 504, result.status
      assert_equal 'text/plain', result.content_type
      assert_equal 'Gateway Timeout', result.error
    ensure
      OntologyContentSerializer.send(:remove_const, :READ_TIMEOUT)
      OntologyContentSerializer.const_set(:READ_TIMEOUT, original_timeout)
    end
  end

  # ---------------------------------------------------------------------------
  # 8. Large-Payload Memory/Size Strategy & Transport Chunk Enforcement
  # ---------------------------------------------------------------------------
  def test_large_payload_chunk_enforcement_and_413_rejection
    # Enforce a small max payload size in test to prove chunk enforcement aborts
    # transport BEFORE buffering the full payload
    original_max = OntologyContentSerializer::MAX_PAYLOAD_SIZE
    OntologyContentSerializer.send(:remove_const, :MAX_PAYLOAD_SIZE)
    OntologyContentSerializer.const_set(:MAX_PAYLOAD_SIZE, 64) # 64 bytes max

    server_pipe_broken = false

    @server.route("/ontologies/TEST/resolve/#{CGI.escape('http://example.org/res')}") do |_m, _p, _h, s|
      s.print "HTTP/1.1 200 OK\r\nContent-Type: text/turtle\r\nTransfer-Encoding: chunked\r\n\r\n"
      begin
        50.times do
          # 64 bytes per chunk
          chunk = 'A' * 64
          s.print "#{chunk.bytesize.to_s(16)}\r\n#{chunk}\r\n"
          s.flush
          sleep 0.005
        end
        s.print "0\r\n\r\n"
      rescue Errno::EPIPE, Errno::ECONNRESET
        server_pipe_broken = true
      end
    end

    begin
      ctrl = ContentFinderController.new
      result = ctrl.serialize_content(
        ontology_acronym: 'TEST',
        concept_id: 'http://example.org/res',
        format: 'turtle'
      )

      refute result.success?
      assert_equal 413, result.status
      assert_equal 'text/plain', result.content_type
      assert_equal 'Payload Too Large', result.error
      assert_nil result.content
      # Verify that client disconnected and broke pipe, proving bounded transport
      # chunk enforcement rather than post-buffering whole body
      10.times do
        break if server_pipe_broken
        sleep 0.02
      end
      assert server_pipe_broken, 'Expected client to abort connection chunk read before completing stream'
    ensure
      OntologyContentSerializer.send(:remove_const, :MAX_PAYLOAD_SIZE)
      OntologyContentSerializer.const_set(:MAX_PAYLOAD_SIZE, original_max)
    end
  end

  # ---------------------------------------------------------------------------
  # 9. Raw Download Transport (UriRedirection#fetch_and_forward_data)
  # ---------------------------------------------------------------------------
  def test_raw_download_transport_success_and_errors
    dummy_class = Class.new do
      include UriRedirection

      attr_reader :sent_data, :rendered

      def send_data(data, options = {})
        @sent_data = { data: data, options: options }
      end

      def render(options = {})
        @rendered = options
      end

      def rest_url
        $REST_URL
      end

      def get_apikey
        $API_KEY
      end
    end

    # 1. Raw download 200 byte-equivalence
    raw_ontology_payload = "<?xml version=\"1.0\"?>\n<rdf:RDF>Ontology Data</rdf:RDF>"
    @server.route('/ontologies/TEST/download') do |_m, full_path, _h, s|
      assert_includes full_path, "apikey=#{$API_KEY}"
      s.print "HTTP/1.1 200 OK\r\nContent-Type: application/rdf+xml\r\nContent-Length: #{raw_ontology_payload.bytesize}\r\nConnection: close\r\n\r\n#{raw_ontology_payload}"
    end

    obj = dummy_class.new
    obj.download_ontology({ acronym: 'TEST' })

    assert obj.sent_data, 'Expected send_data to be called for 200 download'
    assert_equal 200, obj.sent_data[:options][:status]
    assert_equal 'application/rdf+xml', obj.sent_data[:options][:type]
    assert_equal raw_ontology_payload, obj.sent_data[:data]

    # 2. Raw download 404 does not leak apikey or send raw error
    @server.route('/ontologies/TEST/download') do |_m, _p, _h, s|
      s.print "HTTP/1.1 404 Not Found\r\nContent-Type: text/html\r\nContent-Length: 9\r\nConnection: close\r\n\r\nNot Found"
    end

    obj404 = dummy_class.new
    obj404.download_ontology({ acronym: 'TEST' })

    assert obj404.rendered, 'Expected render to be called for 404 download'
    assert_equal 404, obj404.rendered[:status]
    assert_equal 'text/plain', obj404.rendered[:content_type]
    assert_equal 'Not Found', obj404.rendered[:plain]
    refute_includes obj404.rendered[:plain], $API_KEY

    # 3. Raw download large payload abort
    original_download_max = UriRedirection::MAX_DOWNLOAD_SIZE
    UriRedirection.send(:remove_const, :MAX_DOWNLOAD_SIZE)
    UriRedirection.const_set(:MAX_DOWNLOAD_SIZE, 32) # 32 bytes max

    @server.route('/ontologies/TEST/download') do |_m, _p, _h, s|
      s.print "HTTP/1.1 200 OK\r\nContent-Type: application/rdf+xml\r\nConnection: close\r\n\r\n#{'Z' * 128}"
    end

    begin
      obj_large = dummy_class.new
      obj_large.download_ontology({ acronym: 'TEST' })
      assert obj_large.rendered
      assert_equal 413, obj_large.rendered[:status]
      assert_equal 'Payload Too Large', obj_large.rendered[:plain]
    ensure
      UriRedirection.send(:remove_const, :MAX_DOWNLOAD_SIZE)
      UriRedirection.const_set(:MAX_DOWNLOAD_SIZE, original_download_max)
    end
  end
end
