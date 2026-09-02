class AssistantBackend
  MAX_RESPONSE_BYTES = 1_048_576

  class Error < StandardError
    attr_reader :status

    def initialize(message, status: :bad_gateway)
      @status = status
      super(message)
    end
  end

  def initialize(url: ENV['AI_ASSISTANT_BACKEND_URL'])
    @uri = self.class.validated_uri(url)
  end

  def self.validated_uri(url)
    raise Error.new('Assistant backend is not configured.', status: :service_unavailable) if url.to_s.strip.empty?

    uri = URI.parse(url.to_s)
    unless %w[http https].include?(uri.scheme) && uri.host.present? && uri.userinfo.nil?
      raise Error.new('Assistant backend configuration is invalid.', status: :service_unavailable)
    end
    uri
  rescue URI::InvalidURIError
    raise Error.new('Assistant backend configuration is invalid.', status: :service_unavailable)
  end

  def stream(payload)
    request = Net::HTTP::Post.new(@uri.request_uri)
    request['Accept'] = 'text/event-stream'
    request['Content-Type'] = 'application/json'
    request['User-Agent'] = 'OntoPortal Web UI'
    request.body = JSON.generate(payload)

    response = nil
    bytes = 0
    http = Net::HTTP.new(@uri.host, @uri.port)
    http.use_ssl = @uri.scheme == 'https'
    http.open_timeout = 3
    http.read_timeout = 30
    http.write_timeout = 3 if http.respond_to?(:write_timeout=)

    http.start do |client|
      client.request(request) do |backend_response|
        response = backend_response
        next unless backend_response.is_a?(Net::HTTPSuccess)
        next unless backend_response['content-type'].to_s.downcase.include?('text/event-stream')

        if backend_response.content_length && backend_response.content_length > MAX_RESPONSE_BYTES
          raise Error, 'Assistant backend response was too large.'
        end

        backend_response.read_body do |chunk|
          raise Error, 'Assistant backend response was too large.' if bytes + chunk.bytesize > MAX_RESPONSE_BYTES

          bytes += chunk.bytesize
          yield chunk
        end
      end
    end

    raise Error, 'Assistant backend returned an error.' unless response&.is_a?(Net::HTTPSuccess)
    unless response['content-type'].to_s.downcase.include?('text/event-stream')
      raise Error, 'Assistant backend returned an invalid response.'
    end
  rescue Error
    raise
  rescue Net::OpenTimeout, Net::ReadTimeout, Timeout::Error, SocketError,
         Errno::ECONNREFUSED, Errno::ECONNRESET, Errno::ECONNABORTED,
         Errno::EHOSTUNREACH, Errno::ENETUNREACH, Errno::ETIMEDOUT,
         EOFError, OpenSSL::SSL::SSLError, Net::ProtocolError,
         Net::HTTPBadResponse, Net::HTTPHeaderSyntaxError
    raise Error.new('Assistant backend is unavailable.', status: :service_unavailable)
  end
end
