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

  # Synthetic .invalid test origins
  SYNTHETIC_API_URL = 'https://api.example.invalid/api'
  PORTAL_HOST_INVALID = 'portal.example.invalid'
  PORTAL_URL_INVALID = 'https://portal.example.invalid'
  INVALID_SERVICE_URLS = [SYNTHETIC_API_URL].freeze

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

  # --- 6. Focused Regressions: Finding 1, 2, and 3 Corrections ---

  def test_finding_1_candidate_first_service_resolution_prevents_double_decoding
    # 1. Query delimiter preservation: q=A%26B%3DC must not be split into q=A&B=C
    url_q = "#{SYNTHETIC_API_URL}/download?q=A%26B%3DC"
    resolved_q = SafeUrlPolicy.resolve_login_redirect(url_q, user: MOCK_TOKEN, service_urls: INVALID_SERVICE_URLS)
    assert_equal "#{SYNTHETIC_API_URL}/download?q=A%26B%3DC&apikey=#{MOCK_TOKEN}", resolved_q

    parsed_q = URI.parse(resolved_q)
    params_q = URI.decode_www_form(parsed_q.query)
    assert_equal 2, params_q.length
    assert_equal ['q', 'A&B=C'], params_q.assoc('q')
    assert_nil params_q.assoc('B')

    # 2. Encoded # in IRI without separate outer fragment: must not split into URL fragment
    url_iri = "#{SYNTHETIC_API_URL}/download?iri=http%3A%2F%2Fexample.org%2FC%23Term&label=A%2BB%26C%3DD"
    resolved_iri = SafeUrlPolicy.resolve_login_redirect(url_iri, user: MOCK_TOKEN, service_urls: INVALID_SERVICE_URLS)
    assert_equal "#{SYNTHETIC_API_URL}/download?iri=http%3A%2F%2Fexample.org%2FC%23Term&label=A%2BB%26C%3DD&apikey=#{MOCK_TOKEN}", resolved_iri

    parsed_iri = URI.parse(resolved_iri)
    assert_nil parsed_iri.fragment
    params_iri = URI.decode_www_form(parsed_iri.query)
    assert_equal 'http://example.org/C#Term', params_iri.assoc('iri')[1]
    assert_equal 'A+B&C=D', params_iri.assoc('label')[1]
    assert_equal MOCK_TOKEN, params_iri.assoc('apikey')[1]

    # 3. Encoded # in IRI WITH separate outer fragment: outer fragment preserved
    url_iri_frag = "#{SYNTHETIC_API_URL}/download?iri=http%3A%2F%2Fexample.org%2FC%23Term&label=A%2BB%26C%3DD#view"
    resolved_iri_frag = SafeUrlPolicy.resolve_login_redirect(url_iri_frag, user: MOCK_TOKEN, service_urls: INVALID_SERVICE_URLS)
    assert_equal "#{SYNTHETIC_API_URL}/download?iri=http%3A%2F%2Fexample.org%2FC%23Term&label=A%2BB%26C%3DD&apikey=#{MOCK_TOKEN}#view", resolved_iri_frag
    assert_equal 'view', URI.parse(resolved_iri_frag).fragment

    # 4. Encoded concept-path identity preserved
    concept_path = "#{SYNTHETIC_API_URL}/ontologies/TEST/classes/http%3A%2F%2Fexample.org%2Fconcept%231"
    resolved_concept = SafeUrlPolicy.resolve_login_redirect(concept_path, user: MOCK_TOKEN, service_urls: INVALID_SERVICE_URLS)
    assert_equal "#{SYNTHETIC_API_URL}/ontologies/TEST/classes/http%3A%2F%2Fexample.org%2Fconcept%231?apikey=#{MOCK_TOKEN}", resolved_concept

    # 5. Unicode values and literal plus preserved
    unicode_url = "#{SYNTHETIC_API_URL}/ontologies/M%C3%BCnchen?term=K%C3%B6ln%20City&formula=A%2BB"
    resolved_unicode = SafeUrlPolicy.resolve_login_redirect(unicode_url, user: MOCK_TOKEN, service_urls: INVALID_SERVICE_URLS)
    assert_includes resolved_unicode, '/ontologies/M%C3%BCnchen'
    assert_includes resolved_unicode, 'term=K%C3%B6ln+City'
    assert_includes resolved_unicode, 'formula=A%2BB'
    assert_includes resolved_unicode, "apikey=#{MOCK_TOKEN}"

    # 6. Mixed fixture: existing percent-escapes + raw Unicode in query must not double-encode existing escapes
    mixed_url = "#{SYNTHETIC_API_URL}/download?q=A%26B%3DC&label=Größe"
    resolved_mixed = SafeUrlPolicy.resolve_login_redirect(mixed_url, user: MOCK_TOKEN, service_urls: INVALID_SERVICE_URLS)
    assert_includes resolved_mixed, 'q=A%26B%3DC'
    refute_includes resolved_mixed, 'q=A%2526B%253DC'
    assert_includes resolved_mixed, 'label=Gr%C3%B6%C3%9Fe'
    assert_includes resolved_mixed, "apikey=#{MOCK_TOKEN}"

    parsed_mixed = URI.parse(resolved_mixed)
    params_mixed = URI.decode_www_form(parsed_mixed.query)
    assert_equal 'A&B=C', params_mixed.assoc('q')[1]
    assert_equal 'Größe', params_mixed.assoc('label')[1]

    # 7. Unwrapping outer redirect encoding only when necessary
    wrapped = CGI.escape(url_iri)
    resolved_wrapped = SafeUrlPolicy.resolve_login_redirect(wrapped, user: MOCK_TOKEN, service_urls: INVALID_SERVICE_URLS)
    assert_equal "#{SYNTHETIC_API_URL}/download?iri=http%3A%2F%2Fexample.org%2FC%23Term&label=A%2BB%26C%3DD&apikey=#{MOCK_TOKEN}", resolved_wrapped
  end

  def test_finding_1_login_lifecycle_roundtrips
    dest = "#{SYNTHETIC_API_URL}/download?iri=http%3A%2F%2Fexample.org%2FC%23Term&label=A%2BB%26C%3DD"
    outer_param = CGI.escape(dest)

    # 1. LoginController#index sanitizes incoming redirect parameter
    sanitized = SafeUrlPolicy.sanitize_redirect_param(outer_param, service_urls: INVALID_SERVICE_URLS)
    assert_equal dest, sanitized

    # 2a. Password login form lifecycle:
    # Sanitized value is placed into hidden field in HTML form.
    # Form submission sends application/x-www-form-urlencoded POST body.
    # Rack decodes the POST parameter once, yielding form_param.
    form_post_body = "redirect=#{CGI.escape(sanitized)}&user%5Busername%5D=tester"
    rack_decoded_redirect = CGI.unescape(form_post_body.split('&').find { |p| p.start_with?('redirect=') }.split('=', 2)[1])
    assert_equal dest, rack_decoded_redirect

    # LoginController#create resolves rack_decoded_redirect:
    resolved_from_form = SafeUrlPolicy.resolve_login_redirect(rack_decoded_redirect, user: MOCK_TOKEN, service_urls: INVALID_SERVICE_URLS)
    assert_equal "#{SYNTHETIC_API_URL}/download?iri=http%3A%2F%2Fexample.org%2FC%23Term&label=A%2BB%26C%3DD&apikey=#{MOCK_TOKEN}", resolved_from_form

    # 2b. OmniAuth session lifecycle:
    # Sanitized value stored into session[:redirect] and retrieved during callback.
    session_redirect = sanitized
    assert_equal dest, session_redirect

    # LoginController#create_omniauth resolves session_redirect:
    resolved_from_session = SafeUrlPolicy.resolve_login_redirect(session_redirect, user: MOCK_TOKEN, service_urls: INVALID_SERVICE_URLS)
    assert_equal "#{SYNTHETIC_API_URL}/download?iri=http%3A%2F%2Fexample.org%2FC%23Term&label=A%2BB%26C%3DD&apikey=#{MOCK_TOKEN}", resolved_from_session
  end

  def test_finding_2_base_path_canonical_hierarchy_enforcement
    parent_segments = [
      '..',
      '%2e%2e',
      '%2E%2E',
      '%2e%2E',
      '%2E%2e',
      '.%2e',
      '.%2E',
      '%2e.',
      '%2E.'
    ]

    # Rejection of parent dot segments escaping /api
    parent_segments.each do |seg|
      url = "#{SYNTHETIC_API_URL}/#{seg}/outside"
      refute SafeUrlPolicy.permitted_service_url?(url, service_urls: INVALID_SERVICE_URLS), "Should reject dot segment: #{seg}"
      assert_equal '/', SafeUrlPolicy.sanitize_redirect_param(url, service_urls: INVALID_SERVICE_URLS)
      assert_equal '/', SafeUrlPolicy.resolve_login_redirect(url, user: MOCK_TOKEN, service_urls: INVALID_SERVICE_URLS)

      unmodified = SafeUrlPolicy.append_apikey_if_permitted(url, MOCK_TOKEN, service_urls: INVALID_SERVICE_URLS)
      assert_equal url, unmodified
      refute_includes unmodified, MOCK_TOKEN
    end

    # Suffix dot segments and encoded separator variants
    escaped_variants = [
      "#{SYNTHETIC_API_URL}/..",
      "#{SYNTHETIC_API_URL}/../",
      "#{SYNTHETIC_API_URL}/%2e%2e",
      "#{SYNTHETIC_API_URL}/%2e%2e%2foutside",
      "#{SYNTHETIC_API_URL}/%2E%2E%2Foutside"
    ]

    escaped_variants.each do |url|
      refute SafeUrlPolicy.permitted_service_url?(url, service_urls: INVALID_SERVICE_URLS), "Should reject escaped variant: #{url}"
      assert_equal '/', SafeUrlPolicy.sanitize_redirect_param(url, service_urls: INVALID_SERVICE_URLS)
      assert_equal '/', SafeUrlPolicy.resolve_login_redirect(url, user: MOCK_TOKEN, service_urls: INVALID_SERVICE_URLS)

      unmodified = SafeUrlPolicy.append_apikey_if_permitted(url, MOCK_TOKEN, service_urls: INVALID_SERVICE_URLS)
      assert_equal url, unmodified
      refute_includes unmodified, MOCK_TOKEN
    end

    # Verify metadata attachment entry point (append_apikey_if_rest_url)
    orig_rest = $REST_URL
    $REST_URL = SYNTHETIC_API_URL
    begin
      traversal_url = "#{SYNTHETIC_API_URL}/../outside"
      result = SafeUrlPolicy.append_apikey_if_rest_url(traversal_url, MOCK_TOKEN)
      assert_equal traversal_url, result
      refute_includes result, MOCK_TOKEN
    ensure
      $REST_URL = orig_rest
    end

    # Retain acceptance of valid base path, subpaths, and normal dotted filenames
    accepted_paths = [
      SYNTHETIC_API_URL,
      "#{SYNTHETIC_API_URL}/",
      "#{SYNTHETIC_API_URL}/download",
      "#{SYNTHETIC_API_URL}/download.csv",
      "#{SYNTHETIC_API_URL}/v1/schema.v1.0.owl",
      "#{SYNTHETIC_API_URL}/ontologies/RADX",
      "#{SYNTHETIC_API_URL}/data.2026.11.07.json"
    ]

    accepted_paths.each do |url|
      assert SafeUrlPolicy.permitted_service_url?(url, service_urls: INVALID_SERVICE_URLS), "Should accept: #{url}"
      resolved = SafeUrlPolicy.resolve_login_redirect(url, user: MOCK_TOKEN, service_urls: INVALID_SERVICE_URLS)
      assert_includes resolved, "apikey=#{MOCK_TOKEN}", "Should append key to: #{url}"
    end
  end

  def test_finding_3_rejects_leading_double_slash_path_on_allowed_host
    allowed_hosts = [PORTAL_HOST_INVALID]
    double_slash_url = "#{PORTAL_URL_INVALID}//outside.example.invalid/x"

    # Predicate rejection
    refute SafeUrlPolicy.safe_local_path?(double_slash_url, allowed_hosts: allowed_hosts)

    # Direct resolution falls back to safe local path '/' instead of protocol-relative '//outside...'
    resolved = SafeUrlPolicy.resolve_login_redirect(double_slash_url, user: MOCK_TOKEN, allowed_hosts: allowed_hosts)
    assert_equal '/', resolved
    refute resolved.start_with?('//')

    # Sanitizer falls back safely
    sanitized = SafeUrlPolicy.sanitize_redirect_param(double_slash_url, allowed_hosts: allowed_hosts)
    assert_equal '/', sanitized

    # Outer redirect encoded representation also safely falls back
    encoded_double_slash = CGI.escape(double_slash_url)
    assert_equal '/', SafeUrlPolicy.resolve_login_redirect(encoded_double_slash, user: MOCK_TOKEN, allowed_hosts: allowed_hosts)
    assert_equal '/', SafeUrlPolicy.sanitize_redirect_param(encoded_double_slash, allowed_hosts: allowed_hosts)

    # Backslash variant rejection
    backslash_url = "#{PORTAL_URL_INVALID}/\\outside.example.invalid/x"
    refute SafeUrlPolicy.safe_local_path?(backslash_url, allowed_hosts: allowed_hosts)
    assert_equal '/', SafeUrlPolicy.resolve_login_redirect(backslash_url, user: MOCK_TOKEN, allowed_hosts: allowed_hosts)
    assert_equal '/', SafeUrlPolicy.sanitize_redirect_param(backslash_url, allowed_hosts: allowed_hosts)

    # to_local_path safe fallback
    assert_equal '/', SafeUrlPolicy.send(:to_local_path, double_slash_url)
    assert_equal '/', SafeUrlPolicy.send(:to_local_path, backslash_url)
    assert_equal '/', SafeUrlPolicy.send(:to_local_path, '//outside.example.invalid/x')
    assert_equal '/', SafeUrlPolicy.send(:to_local_path, '/\\outside.example.invalid/x')

    # Retain normal permitted local navigation on allowed host
    normal_url = "#{PORTAL_URL_INVALID}/ontologies/RADX?tab=views#summary"
    assert SafeUrlPolicy.safe_local_path?(normal_url, allowed_hosts: allowed_hosts)
    assert_equal '/ontologies/RADX?tab=views#summary', SafeUrlPolicy.resolve_login_redirect(normal_url, user: MOCK_TOKEN, allowed_hosts: allowed_hosts)
  end
end
