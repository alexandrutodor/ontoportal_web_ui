# frozen_string_literal: true

require 'uri'
require 'cgi'

module SafeUrlPolicy
  extend self

  DEFAULT_FALLBACK = '/'
  HTTP_SCHEMES = %w[http https].freeze
  DANGEROUS_CHARS = /[\x00-\x1F\x7F\\]/

  # Check if a candidate destination matches an explicitly permitted service origin & base path
  def permitted_service_url?(url, service_urls: nil)
    return false if url.nil?

    parsed = parse_clean_uri(url)
    return false unless parsed && parsed.is_a?(URI::HTTP)
    return false if parsed.user || parsed.password
    return false if parsed.scheme.nil? || !HTTP_SCHEMES.include?(parsed.scheme.downcase)
    return false if parsed.host.nil? || parsed.host.empty?

    configured = service_urls || configured_service_urls
    return false if configured.empty?

    configured.any? do |base_str|
      next false if base_str.nil? || base_str.to_s.strip.empty?

      base_uri = parse_clean_uri(base_str)
      next false unless base_uri && base_uri.is_a?(URI::HTTP)
      next false if base_uri.scheme.nil? || base_uri.host.nil?

      match_service_origin_and_path?(parsed, base_uri)
    end
  end

  # Check if a path or URL is safe for local redirection
  def safe_local_path?(url, allowed_hosts: nil)
    return false if url.nil?

    str = url.to_s.strip
    return false if str.empty?
    return false if str.match?(DANGEROUS_CHARS)
    return false if str.start_with?('//') || str.start_with?('/\\')

    if str.start_with?('/')
      parsed = parse_clean_uri(str)
      return false unless parsed
      return false if parsed.scheme || parsed.host || parsed.user || parsed.password

      parsed.path.start_with?('/') && !parsed.path.start_with?('//')
    else
      parsed = parse_clean_uri(str)
      return false unless parsed && parsed.is_a?(URI::HTTP)
      return false if parsed.user || parsed.password
      return false unless HTTP_SCHEMES.include?(parsed.scheme.downcase)

      hosts = allowed_hosts || configured_local_hosts
      return false if hosts.empty?

      hosts.any? { |h| match_local_host?(parsed, h) }
    end
  end

  # Resolve candidate return URL to a safe destination.
  # Approved service URLs receive credentials (if user/key provided).
  # Safe local paths (or portal origins converted to local path) are preserved.
  # Any other candidate (foreign, malformed, lookalike, protocol-relative) falls back to safe local page.
  def resolve_login_redirect(url, user: nil, fallback: DEFAULT_FALLBACK, service_urls: nil, allowed_hosts: nil)
    return fallback if url.nil?

    candidate = url.to_s.strip
    return fallback if candidate.empty?

    unescaped = safe_unescape(candidate)

    # 1. Approved service destinations
    if permitted_service_url?(unescaped, service_urls: service_urls)
      return append_apikey_if_permitted(unescaped, user, service_urls: service_urls)
    elsif permitted_service_url?(candidate, service_urls: service_urls)
      return append_apikey_if_permitted(candidate, user, service_urls: service_urls)
    end

    # 2. Safe local paths
    if safe_local_path?(candidate, allowed_hosts: allowed_hosts)
      return to_local_path(candidate)
    elsif safe_local_path?(unescaped, allowed_hosts: allowed_hosts)
      return to_local_path(unescaped)
    end

    fallback
  end

  # Sanitize redirect parameter before rendering into hidden form fields or session.
  def sanitize_redirect_param(url, fallback: DEFAULT_FALLBACK, service_urls: nil, allowed_hosts: nil)
    return fallback if url.nil?

    candidate = url.to_s.strip
    return fallback if candidate.empty?

    unescaped = safe_unescape(candidate)

    if permitted_service_url?(candidate, service_urls: service_urls)
      candidate
    elsif permitted_service_url?(unescaped, service_urls: service_urls)
      unescaped
    elsif safe_local_path?(candidate, allowed_hosts: allowed_hosts)
      candidate
    elsif safe_local_path?(unescaped, allowed_hosts: allowed_hosts)
      unescaped
    else
      fallback
    end
  end

  # Append apikey only after allowlisting
  def append_apikey_if_permitted(url, user_or_key = nil, service_urls: nil)
    return url if url.nil? || url.to_s.strip.empty?
    return url unless permitted_service_url?(url, service_urls: service_urls)

    key = extract_apikey(user_or_key)
    return url if key.nil? || key.empty?

    parsed = parse_clean_uri(url)
    return url unless parsed

    params = begin
      URI.decode_www_form(parsed.query || '')
    rescue StandardError
      []
    end

    params.reject! { |k, _| k.to_s.downcase == 'apikey' }
    params << ['apikey', key]

    parsed.query = URI.encode_www_form(params)
    parsed.to_s
  rescue StandardError
    url
  end

  def append_apikey_if_rest_url(url, user_or_key = nil)
    append_apikey_if_permitted(url, user_or_key)
  end

  private

  def match_service_origin_and_path?(candidate, base)
    return false unless candidate.scheme && base.scheme
    return false unless candidate.scheme.downcase == base.scheme.downcase

    return false unless candidate.host && base.host
    return false unless candidate.host.downcase == base.host.downcase

    return false unless candidate.port == base.port

    base_path = base.path.to_s.chomp('/')
    cand_path = candidate.path.to_s

    if base_path.empty?
      true
    else
      cand_path == base_path || cand_path.start_with?("#{base_path}/")
    end
  end

  def match_local_host?(candidate, host_or_url)
    return false if host_or_url.nil? || host_or_url.to_s.strip.empty?

    target_host = nil
    target_port = nil

    if host_or_url.to_s.include?('://')
      parsed_host = parse_clean_uri(host_or_url)
      if parsed_host
        target_host = parsed_host.host&.downcase
        target_port = parsed_host.port
      end
    else
      parts = host_or_url.to_s.split(':', 2)
      target_host = parts[0]&.downcase
      target_port = parts[1]&.to_i if parts[1]
    end

    return false if target_host.nil? || target_host.empty?
    return false unless candidate.host.to_s.downcase == target_host
    return false if target_port && candidate.port != target_port

    true
  end

  def to_local_path(url)
    return url if url.start_with?('/') && !url.start_with?('//')

    parsed = parse_clean_uri(url)
    return DEFAULT_FALLBACK unless parsed

    path = parsed.path.to_s
    path = DEFAULT_FALLBACK if path.empty? || !path.start_with?('/')
    query = parsed.query ? "?#{parsed.query}" : ''
    fragment = parsed.fragment ? "##{parsed.fragment}" : ''
    "#{path}#{query}#{fragment}"
  end

  def parse_clean_uri(url)
    return nil if url.nil?

    str = url.to_s.strip
    return nil if str.empty?
    return nil if str.match?(DANGEROUS_CHARS)

    str = URI::DEFAULT_PARSER.escape(str) unless str.ascii_only?
    URI.parse(str)
  rescue URI::InvalidURIError, ArgumentError
    nil
  end

  def safe_unescape(str)
    return str if str.nil? || str.empty?

    CGI.unescape(str.to_s)
  rescue StandardError
    str
  end

  def extract_apikey(user_or_key)
    if user_or_key.nil?
      configured_fallback_apikey
    elsif user_or_key.respond_to?(:apikey)
      k = user_or_key.apikey.to_s
      !k.strip.empty? ? k : configured_fallback_apikey
    elsif user_or_key.is_a?(String)
      !user_or_key.strip.empty? ? user_or_key : configured_fallback_apikey
    else
      configured_fallback_apikey
    end
  end

  def configured_service_urls
    urls = []
    if defined?(LinkedData::Client) && LinkedData::Client.respond_to?(:settings) && LinkedData::Client.settings.respond_to?(:rest_url)
      urls << LinkedData::Client.settings.rest_url
    elsif defined?($REST_URL)
      urls << $REST_URL
    end

    urls << $FAIRNESS_URL if defined?($FAIRNESS_URL)
    urls.compact.map(&:to_s).map(&:strip).reject(&:empty?).uniq
  end

  def configured_local_hosts
    hosts = []
    if defined?($UI_URL) && $UI_URL && !$UI_URL.to_s.strip.empty?
      parsed = parse_clean_uri($UI_URL)
      hosts << parsed.host if parsed&.host
    end
    if defined?($HOSTNAME) && $HOSTNAME && !$HOSTNAME.to_s.strip.empty?
      hosts << $HOSTNAME
    end
    hosts.compact.map(&:to_s).map(&:downcase).uniq
  end

  def configured_fallback_apikey
    if defined?(LinkedData::Client) && LinkedData::Client.respond_to?(:settings) && LinkedData::Client.settings.respond_to?(:apikey)
      k = LinkedData::Client.settings.apikey.to_s
      !k.strip.empty? ? k : nil
    elsif defined?($API_KEY) && $API_KEY && !$API_KEY.to_s.strip.empty?
      $API_KEY.to_s
    end
  end
end
