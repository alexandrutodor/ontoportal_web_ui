# frozen_string_literal: true

require 'uri'

module ExternalPortalStubHelper
  def self.configured_external_portal_urls
    candidates = []
    if defined?($PORTALS_INSTANCES) && $PORTALS_INSTANCES.is_a?(Array)
      candidates.concat($PORTALS_INSTANCES.map { |portal| portal[:api] || portal['api'] })
    end
    if defined?(LinkedData::Client) && LinkedData::Client.respond_to?(:settings) && LinkedData::Client.settings&.federated_portals
      candidates.concat(LinkedData::Client.settings.federated_portals.values.map { |portal| portal[:api] || portal['api'] })
    end

    own_api = (defined?(LinkedData::Client) && LinkedData::Client.respond_to?(:settings) && LinkedData::Client.settings&.rest_url) || $REST_URL || ENV['API_URL']
    own_uri = URI.parse(own_api) rescue nil
    own_host_port = own_uri ? "#{own_uri.host}:#{own_uri.port}" : nil

    external_urls = []
    candidates.compact.uniq.each do |api_url|
      url_str = api_url.to_s.strip
      next if url_str.empty?

      begin
        uri = URI.parse(url_str)
        next unless %w[http https].include?(uri.scheme)

        # Exclude own API endpoint and any local/isolated approved hosts
        next if own_host_port && "#{uri.host}:#{uri.port}" == own_host_port
        next if defined?(TestTargetGuard) && TestTargetGuard.respond_to?(:approved_host?) && TestTargetGuard.approved_host?(uri.host)

        normalized = url_str.end_with?('/') ? url_str : "#{url_str}/"
        external_urls << normalized
        external_urls << normalized.chomp('/')
      rescue URI::InvalidURIError
        next
      end
    end

    external_urls.uniq
  end

  def self.stub_configured_external_portal_health_checks(status: 200)
    urls = configured_external_portal_urls
    urls.each do |url|
      WebMock::API.stub_request(:head, url).to_return(status: status, body: '', headers: {})
    end
    urls
  end

  # Isolated runs have no outside network. Answer the app's background probes the way an
  # unreachable service would, so the app's own failure handling runs; WebMock's refusal is not a
  # StandardError and would otherwise escape it. A global stub survives WebMock.reset! (teardown can
  # race with late Turbo frame requests) and runs after local stubs, so portal health stubs win.
  def self.stub_isolated_external_services
    unless @isolated_services_stubbed
      WebMock.globally_stub_request(:after_local_stubs) do |request|
        next if WebMock.net_connect_allowed?(request.uri)

        if request.method == :head || external_portal_request?(request.uri)
          { exception: Errno::ECONNREFUSED }
        elsif request.method == :post && foops_request?(request.uri)
          { status: 503, body: '' }
        end
      end
      @isolated_services_stubbed = true
    end
    stub_configured_external_portal_health_checks
  end

  # Federated portals are unreachable in isolated runs, like a portal that is down.
  def self.external_portal_request?(uri)
    configured_external_portal_urls.any? { |url| (portal = URI.parse(url)).host == uri.host && portal.port == uri.port }
  end

  def self.foops_request?(uri)
    return false unless defined?($FOOPS_URL) && $FOOPS_URL.present?

    foops = URI.parse($FOOPS_URL)
    uri.host == foops.host && uri.path == foops.path
  end

  def stub_configured_external_portal_health_checks(status: 200)
    ExternalPortalStubHelper.stub_configured_external_portal_health_checks(status: status)
  end
end
