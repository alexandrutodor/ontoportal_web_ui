# frozen_string_literal: true

require 'minitest/autorun'
require 'uri'
require 'cgi'

# Standalone offline regression suite for ONTO-T-B01 URL-policy boundary.
# Runs outside Rails *_test.rb discovery and uses synthetic keys only.
# No real network, no full Rails suite, no external services.

require_relative '../../app/services/safe_url_policy'
require_relative '../../app/helpers/urls_helper'

class UrlPolicyRegressionTest < Minitest::Test
  # Synthetic dummy tokens for offline testing
  MOCK_TOKEN = 'synthetic-sample-token-12345' # gitleaks:allow
  OLD_TOKEN = 'synthetic-sample-token-00000' # gitleaks:allow
  SYNTHETIC_REST_URL = 'http://data.matportal.org'
  SYNTHETIC_FAIRNESS_URL = 'https://fairness.stage.matportal.org'
  SERVICE_URLS = [SYNTHETIC_REST_URL, SYNTHETIC_FAIRNESS_URL].freeze
  UI_HOST = 'stage.matportal.org'

  # --- 1. Service Destination Allowlisting ---

  def test_permitted_service_url_for_exact_configured_destinations
    assert SafeUrlPolicy.permitted_service_url?(SYNTHETIC_REST_URL, service_urls: SERVICE_URLS)
    assert SafeUrlPolicy.permitted_service_url?("#{SYNTHETIC_REST_URL}/ontologies/RADX/download", service_urls: SERVICE_URLS)
    assert SafeUrlPolicy.permitted_service_url?("#{SYNTHETIC_REST_URL}/ontologies", service_urls: SERVICE_URLS)
    assert SafeUrlPolicy.permitted_service_url?(SYNTHETIC_FAIRNESS_URL, service_urls: SERVICE_URLS)
    assert SafeUrlPolicy.permitted_service_url?("#{SYNTHETIC_FAIRNESS_URL}/eval?ontologies=RADX", service_urls: SERVICE_URLS)
  end

  def test_permitted_service_url_with_base_subpath_and_port
    custom_services = ['http://localhost:8080/bioportal']

    assert SafeUrlPolicy.permitted_service_url?('http://localhost:8080/bioportal', service_urls: custom_services)
    assert SafeUrlPolicy.permitted_service_url?('http://localhost:8080/bioportal/ontologies', service_urls: custom_services)

    # Path prefix boundary: /bioportal-fake must not match /bioportal
    refute SafeUrlPolicy.permitted_service_url?('http://localhost:8080/bioportal-fake', service_urls: custom_services)
    refute SafeUrlPolicy.permitted_service_url?('http://localhost:8080/other', service_urls: custom_services)
    # Port mismatch
    refute SafeUrlPolicy.permitted_service_url?('http://localhost:9090/bioportal', service_urls: custom_services)
  end

  # --- 2. Rejection of Foreign, Lookalike, Malformed, and Exploit Vectors ---

  def test_rejects_foreign_urls_containing_rest_url_in_query
    foreign_query = "https://evil.com/?target=#{SYNTHETIC_REST_URL}&next=ok"
    refute SafeUrlPolicy.permitted_service_url?(foreign_query, service_urls: SERVICE_URLS)
    assert_equal '/', SafeUrlPolicy.resolve_login_redirect(foreign_query, user: MOCK_TOKEN, service_urls: SERVICE_URLS)
  end

  def test_rejects_foreign_urls_containing_rest_url_in_path
    foreign_path = "https://evil.com/#{SYNTHETIC_REST_URL}"
    refute SafeUrlPolicy.permitted_service_url?(foreign_path, service_urls: SERVICE_URLS)
    assert_equal '/', SafeUrlPolicy.resolve_login_redirect(foreign_path, user: MOCK_TOKEN, service_urls: SERVICE_URLS)
  end

  def test_rejects_lookalike_and_subdomain_hosts
    lookalikes = [
      'http://data.matportal.org.evil.com/ontologies',
      'http://evil-data.matportal.org/ontologies',
      'http://sub.data.matportal.org/ontologies',
      'http://notdata.matportal.org/ontologies'
    ]

    lookalikes.each do |url|
      refute SafeUrlPolicy.permitted_service_url?(url, service_urls: SERVICE_URLS), "Should reject lookalike: #{url}"
      assert_equal '/', SafeUrlPolicy.resolve_login_redirect(url, user: MOCK_TOKEN, service_urls: SERVICE_URLS)
    end
  end

  def test_rejects_differing_ports_and_schemes
    # Port mismatch
    port_mismatch = "#{SYNTHETIC_REST_URL}:8080/ontologies"
    refute SafeUrlPolicy.permitted_service_url?(port_mismatch, service_urls: SERVICE_URLS)

    # Scheme mismatch: https when configured is http
    scheme_mismatch = "https://data.matportal.org/ontologies"
    refute SafeUrlPolicy.permitted_service_url?(scheme_mismatch, service_urls: SERVICE_URLS)
  end

  def test_rejects_userinfo_in_service_and_redirect_urls
    userinfo_urls = [
      'http://admin:pass@data.matportal.org/ontologies',
      'http://attacker:data.matportal.org@evil.com/',
      'http://data.matportal.org@evil.com/ontologies'
    ]

    userinfo_urls.each do |url|
      refute SafeUrlPolicy.permitted_service_url?(url, service_urls: SERVICE_URLS), "Should reject userinfo: #{url}"
      assert_equal '/', SafeUrlPolicy.resolve_login_redirect(url, user: MOCK_TOKEN, service_urls: SERVICE_URLS)
    end
  end

  def test_rejects_protocol_relative_urls
    protocol_rel = [
      '//evil.com/test',
      '//data.matportal.org/ontologies',
      '//evil.com/?rest=http://data.matportal.org'
    ]

    protocol_rel.each do |url|
      refute SafeUrlPolicy.permitted_service_url?(url, service_urls: SERVICE_URLS)
      refute SafeUrlPolicy.safe_local_path?(url)
      assert_equal '/', SafeUrlPolicy.resolve_login_redirect(url, user: MOCK_TOKEN, service_urls: SERVICE_URLS)
    end
  end

  def test_rejects_backslash_and_control_char_manipulations
    dangerous = [
      '/\\evil.com',
      '/\\evil.com/test',
      "/\x00evil.com",
      "/ontologies\r\nSet-Cookie:bad=1",
      "http://data.matportal.org\\evil.com"
    ]

    dangerous.each do |url|
      refute SafeUrlPolicy.permitted_service_url?(url, service_urls: SERVICE_URLS)
      refute SafeUrlPolicy.safe_local_path?(url)
      assert_equal '/', SafeUrlPolicy.resolve_login_redirect(url, user: MOCK_TOKEN, service_urls: SERVICE_URLS)
    end
  end

  def test_rejects_unsupported_schemes
    unsupported = [
      'javascript:alert(1)',
      'data:text/html;base64,PHNjcmlwdD4=',
      'file:///etc/passwd',
      'ftp://data.matportal.org/dump'
    ]

    unsupported.each do |url|
      refute SafeUrlPolicy.permitted_service_url?(url, service_urls: SERVICE_URLS)
      refute SafeUrlPolicy.safe_local_path?(url)
      assert_equal '/', SafeUrlPolicy.resolve_login_redirect(url, user: MOCK_TOKEN, service_urls: SERVICE_URLS)
    end
  end

  # --- 3. Safe Local Return Paths ---

  def test_safe_local_paths_accepted
    paths = [
      '/',
      '/ontologies',
      '/ontologies/RADX',
      '/ontologies/new?ontology%5BviewOf%5D=http%3A%2F%2Fdata.matportal.org%2Fontologies%2FRADX',
      '/account#profile'
    ]

    paths.each do |p|
      assert SafeUrlPolicy.safe_local_path?(p)
      assert_equal p, SafeUrlPolicy.resolve_login_redirect(p, user: MOCK_TOKEN, service_urls: SERVICE_URLS)
    end
  end

  def test_same_origin_ui_urls_resolved_to_local_path
    allowed = [UI_HOST]
    same_origin_url = "https://#{UI_HOST}/ontologies/RADX?tab=views#summary"

    assert SafeUrlPolicy.safe_local_path?(same_origin_url, allowed_hosts: allowed)
    resolved = SafeUrlPolicy.resolve_login_redirect(same_origin_url, user: MOCK_TOKEN, service_urls: SERVICE_URLS, allowed_hosts: allowed)
    assert_equal '/ontologies/RADX?tab=views#summary', resolved
    refute_includes resolved, MOCK_TOKEN
  end

  # --- 4. Credential Attachment Policy ---

  def test_append_apikey_only_on_allowlisted_service_destination
    # Approved REST URL: receives key
    rest_url = "#{SYNTHETIC_REST_URL}/ontologies/RADX/download"
    result = SafeUrlPolicy.append_apikey_if_permitted(rest_url, MOCK_TOKEN, service_urls: SERVICE_URLS)
    assert_equal "#{SYNTHETIC_REST_URL}/ontologies/RADX/download?apikey=#{MOCK_TOKEN}", result

    # Foreign URL: receives NO key
    foreign = "https://evil.com/?rest=#{SYNTHETIC_REST_URL}"
    foreign_result = SafeUrlPolicy.append_apikey_if_permitted(foreign, MOCK_TOKEN, service_urls: SERVICE_URLS)
    assert_equal foreign, foreign_result
    refute_includes foreign_result, MOCK_TOKEN

    # Safe local path: receives NO key
    local = '/ontologies/RADX'
    local_result = SafeUrlPolicy.append_apikey_if_permitted(local, MOCK_TOKEN, service_urls: SERVICE_URLS)
    assert_equal local, local_result
  end

  def test_append_apikey_removes_duplicate_and_existing_keys
    url_with_keys = "#{SYNTHETIC_REST_URL}/ontologies/RADX?apikey=#{OLD_TOKEN}&apikey=EXTRA_OLD&format=csv"
    result = SafeUrlPolicy.append_apikey_if_permitted(url_with_keys, MOCK_TOKEN, service_urls: SERVICE_URLS)

    refute_includes result, OLD_TOKEN
    refute_includes result, 'EXTRA_OLD'
    assert_includes result, "apikey=#{MOCK_TOKEN}"
    assert_includes result, 'format=csv'
    # Exactly one apikey param in query
    parsed = URI.parse(result)
    params = URI.decode_www_form(parsed.query)
    assert_equal 1, params.count { |k, _| k == 'apikey' }
    assert_equal MOCK_TOKEN, params.assoc('apikey')[1]
  end

  def test_preserves_fragments_and_query_parameters
    url_with_frag = "#{SYNTHETIC_REST_URL}/ontologies/RADX?format=json#metadata"
    result = SafeUrlPolicy.append_apikey_if_permitted(url_with_frag, MOCK_TOKEN, service_urls: SERVICE_URLS)

    assert result.end_with?('#metadata')
    assert_includes result, "apikey=#{MOCK_TOKEN}"
    assert_includes result, 'format=json'
  end

  def test_preserves_unicode_and_percent_encoding
    url_with_unicode = "#{SYNTHETIC_REST_URL}/ontologies/M%C3%BCnchen?term=K%C3%B6ln%20City"
    result = SafeUrlPolicy.append_apikey_if_permitted(url_with_unicode, MOCK_TOKEN, service_urls: SERVICE_URLS)

    assert_includes result, '/ontologies/M%C3%BCnchen'
    assert_includes result, 'term=K%C3%B6ln+City'
    assert_includes result, "apikey=#{MOCK_TOKEN}"
  end

  def test_handles_malformed_queries_gracefully
    malformed_query = "#{SYNTHETIC_REST_URL}/ontologies?foo&=bar&&baz"
    result = SafeUrlPolicy.append_apikey_if_permitted(malformed_query, MOCK_TOKEN, service_urls: SERVICE_URLS)

    assert_includes result, "apikey=#{MOCK_TOKEN}"
  end

  # --- 5. Application and View Helper Integration Stubs ---

  def test_application_helper_append_apikey_stub
    # Simulate ApplicationHelper module with SafeUrlPolicy
    helper_mock = Class.new do
      def current_user
        nil
      end

      def get_apikey
        UrlPolicyRegressionTest::MOCK_TOKEN
      end

      def append_apikey_if_rest_url(link, user = current_user)
        return link if link.nil? || link.to_s.strip.empty?

        key = (user && user.respond_to?(:apikey) ? user.apikey : nil) || get_apikey
        SafeUrlPolicy.append_apikey_if_permitted(link, key)
      end
    end.new

    # Override service URLs via $REST_URL for test
    orig_rest = $REST_URL
    $REST_URL = SYNTHETIC_REST_URL

    begin
      # Approved REST endpoint receives key
      approved_link = "#{SYNTHETIC_REST_URL}/ontologies/RADX/download"
      res = helper_mock.append_apikey_if_rest_url(approved_link)
      assert_includes res, "apikey=#{MOCK_TOKEN}"

      # External metadata URL does not receive key
      external_meta = "https://github.com/my-project/ontology?rest_url=#{SYNTHETIC_REST_URL}"
      res2 = helper_mock.append_apikey_if_rest_url(external_meta)
      assert_equal external_meta, res2
      refute_includes res2, MOCK_TOKEN
    ensure
      $REST_URL = orig_rest
    end
  end

  def test_login_controller_redirect_resolution_with_user_stub
    user_stub = Struct.new(:apikey).new(MOCK_TOKEN)

    # Approved REST destination receives user's apikey
    rest_dest = "#{SYNTHETIC_REST_URL}/ontologies/RADX/download"
    res1 = SafeUrlPolicy.resolve_login_redirect(rest_dest, user: user_stub, service_urls: SERVICE_URLS)
    assert_equal "#{SYNTHETIC_REST_URL}/ontologies/RADX/download?apikey=#{MOCK_TOKEN}", res1

    # Local path does not receive apikey
    local_dest = '/ontologies/RADX'
    res2 = SafeUrlPolicy.resolve_login_redirect(local_dest, user: user_stub, service_urls: SERVICE_URLS)
    assert_equal '/ontologies/RADX', res2

    # Malicious external redirect is rejected to /
    evil_dest = 'https://evil.com/login?token=abc'
    res3 = SafeUrlPolicy.resolve_login_redirect(evil_dest, user: user_stub, service_urls: SERVICE_URLS)
    assert_equal '/', res3
  end

  def test_sanitize_redirect_param
    assert_equal '/ontologies/RADX', SafeUrlPolicy.sanitize_redirect_param('/ontologies/RADX')
    assert_nil SafeUrlPolicy.sanitize_redirect_param('https://evil.com/steal', fallback: nil)
    assert_nil SafeUrlPolicy.sanitize_redirect_param('//evil.com', fallback: nil)
    assert_nil SafeUrlPolicy.sanitize_redirect_param('/\\evil.com', fallback: nil)
    assert_equal "#{SYNTHETIC_REST_URL}/ontologies", SafeUrlPolicy.sanitize_redirect_param("#{SYNTHETIC_REST_URL}/ontologies", service_urls: SERVICE_URLS)
  end
end
