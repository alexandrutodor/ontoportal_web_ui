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

  def stub_configured_external_portal_health_checks(status: 200)
    ExternalPortalStubHelper.stub_configured_external_portal_health_checks(status: status)
  end
end
