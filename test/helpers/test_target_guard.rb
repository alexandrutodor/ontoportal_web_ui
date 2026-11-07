# frozen_string_literal: true

require 'uri'
require 'ipaddr'
require 'socket'

module TestTargetGuard
  class TargetIsolationError < StandardError; end
  class MissingMarkerError < TargetIsolationError; end
  class DisallowedTargetError < TargetIsolationError; end
  class InvalidURLError < TargetIsolationError; end

  MARKER_ENV_VAR = 'ONTOPORTAL_ISOLATED_TEST'
  DEFAULT_CAPYBARA_PORT = 31_337

  # Actual local bootstrap and container hostnames from ontoportal_docker compose setup
  APPROVED_HOSTS = %w[
    localhost
    127.0.0.1
    0.0.0.0
    ::1
    ontoportal_docker-api
    ontoportal_docker
    ontologies_api
  ].map(&:freeze).freeze

  APPROVED_SCHEMES = %w[http https].map(&:freeze).freeze

  class << self
    def isolated_marker?
      val = ENV[MARKER_ENV_VAR].to_s.strip.downcase
      %w[1 true yes isolated].include?(val)
    end

    def current_target_url
      if defined?(LinkedData::Client) && LinkedData::Client.respond_to?(:settings) && LinkedData::Client.settings&.rest_url.to_s.strip != ''
        LinkedData::Client.settings.rest_url.strip
      elsif ENV['API_URL'].to_s.strip != ''
        ENV['API_URL'].strip
      elsif defined?($REST_URL) && $REST_URL.to_s.strip != ''
        $REST_URL.strip
      else
        'http://localhost:9393'
      end
    end

    def parse_endpoint(url)
      url_str = url.to_s.strip
      raise InvalidURLError, "Test target URL cannot be blank" if url_str.empty?

      uri = URI.parse(url_str)
      unless uri.is_a?(URI::HTTP) || uri.is_a?(URI::HTTPS)
        raise InvalidURLError, "Test target URL must use http or https scheme (got #{url.inspect})"
      end

      host = uri.host
      if host.nil? || host.strip.empty?
        raise InvalidURLError, "Test target URL host cannot be blank (got #{url.inspect})"
      end

      uri
    rescue URI::InvalidURIError => e
      raise InvalidURLError, "Invalid test target URL #{url.inspect}: #{e.message}"
    end

    def approved_host?(host)
      return false if host.nil? || host.strip.empty?

      cleaned = host.strip.downcase.sub(/\A\[/, '').sub(/\]\z/, '')
      return true if APPROVED_HOSTS.include?(cleaned)

      begin
        ip = IPAddr.new(cleaned)
        return true if ip.loopback?
      rescue IPAddr::InvalidAddressError
        # host is not an IP literal
      end

      false
    end

    def approved_endpoint?(url)
      uri = parse_endpoint(url)
      approved_host?(uri.host)
    rescue TargetIsolationError
      false
    end

    # Preflight verification: fails before any network request or cleanup
    def verify_isolated_test_target!(url = nil)
      target_url = url || current_target_url
      parsed_uri = parse_endpoint(target_url)

      # 1. Reject arbitrary remote/shared destinations first, even if marker is set
      unless approved_host?(parsed_uri.host)
        raise DisallowedTargetError,
              "Target #{target_url.inspect} is not an approved isolated test target. " \
              "Only local/isolated container targets (#{APPROVED_HOSTS.join(', ')}) are allowed."
      end

      # 2. Approved endpoints resolve ONLY with the explicit marker
      unless isolated_marker?
        raise MissingMarkerError,
              "Target #{target_url.inspect} is an approved local endpoint, but explicit marker " \
              "#{MARKER_ENV_VAR}=1 is not set. Refusing to run tests against unmarked target."
      end

      parsed_uri
    end

    # Configures WebMock to default-deny all network access, narrowly permitting only the validated target
    def configure_webmock!(url = nil)
      return unless defined?(WebMock)

      uri = verify_isolated_test_target!(url)

      # Ensure HTTP library adapters are enabled (WebMock.disable! turns off adapters;
      # WebMock.enable! restores them so default-deny interception is active)
      WebMock.enable! if WebMock.respond_to?(:enable!)

      # Bounded endpoint allowances: explicit host:port only, never bare host
      allowed_hosts = [
        "#{uri.host}:#{uri.port}",
        '127.0.0.1:4444',
        'localhost:4444'
      ]

      if defined?(Capybara)
        if Capybara.respond_to?(:server_port)
          Capybara.server_port ||= (ENV['CAPYBARA_SERVER_PORT'] || DEFAULT_CAPYBARA_PORT).to_i
        end
        if Capybara.respond_to?(:server_host) && (Capybara.server_host.nil? || Capybara.server_host.empty?)
          Capybara.server_host = ENV['CAPYBARA_SERVER_HOST'] || '0.0.0.0'
        end

        port = Capybara.respond_to?(:server_port) ? Capybara.server_port : nil
        if port
          server_host = Capybara.respond_to?(:server_host) && Capybara.server_host ? Capybara.server_host : '0.0.0.0'
          allowed_hosts << "#{server_host}:#{port}"
          allowed_hosts << "0.0.0.0:#{port}"
          allowed_hosts << "127.0.0.1:#{port}"
          allowed_hosts << "localhost:#{port}"
          allowed_hosts << "#{Socket.gethostname}:#{port}"

          if Capybara.respond_to?(:app_host) && Capybara.app_host
            begin
              app_uri = URI.parse(Capybara.app_host)
              app_port = app_uri.port || port
              allowed_hosts << "#{app_uri.host}:#{app_port}" if app_uri.host
            rescue URI::InvalidURIError
            end
          end
        end
      end

      WebMock.disable_net_connect!(
        allow_localhost: false,
        allow: allowed_hosts.compact.uniq
      )
    end

    def enforce_isolated_test_target!(url = nil)
      uri = verify_isolated_test_target!(url)
      configure_webmock!(url) if defined?(WebMock)
      uri
    end
  end
end
