# frozen_string_literal: true

require 'faraday'

module OntologyContentSerializer
  extend ActiveSupport::Concern

  CONNECT_TIMEOUT = 5
  READ_TIMEOUT = 15
  MAX_PAYLOAD_SIZE = 10 * 1024 * 1024 # 10 MiB

  class PayloadTooLargeError < StandardError; end

  Result = Struct.new(:content, :content_type, :status, :error, :bytes, :format, keyword_init: true) do
    def to_ary
      [content, content_type, status]
    end

    def success?
      status.to_i >= 200 && status.to_i < 300 && error.nil?
    end

    def bytes
      self[:bytes] || (content ? content.bytesize : 0)
    end
  end

  def serialize_content(ontology_acronym:, concept_id:, format:)
    @format = nil
    @result = nil
    @acronym = nil
    @serialization_status = 200
    @serialization_error = nil

    if ontology_acronym.blank? || concept_id.blank?
      return Result.new(content: nil, content_type: nil, status: 200, error: nil, format: nil)
    end

    @acronym = ontology_acronym.to_s
    @format = format.to_s
    @format = 'ntriples' if @format.eql?('html')

    url = content_finder_url(ontology_acronym, concept_id)
    accept_header = content_finder_accept_header(@format)

    token = get_apikey
    conn = Faraday.new(url: url) do |faraday|
      faraday.options.open_timeout = CONNECT_TIMEOUT
      faraday.options.timeout = READ_TIMEOUT
      faraday.headers['Accept'] = accept_header
      faraday.headers['Authorization'] = "apikey token=#{token}"
      faraday.adapter Faraday.default_adapter
    end

    buffer = String.new(encoding: Encoding::BINARY)
    response = conn.get do |req|
      req.options.on_data = Proc.new do |chunk, _total_bytes|
        if buffer.bytesize + chunk.bytesize > MAX_PAYLOAD_SIZE
          raise PayloadTooLargeError, "Payload exceeds limit of #{MAX_PAYLOAD_SIZE} bytes"
        end
        buffer << chunk
      end
    end

    if buffer.empty? && response.body.present?
      if response.body.bytesize > MAX_PAYLOAD_SIZE
        raise PayloadTooLargeError, "Payload exceeds limit of #{MAX_PAYLOAD_SIZE} bytes"
      end
      buffer = response.body.b
    end

    status = response.status.to_i
    actual_content_type = response.headers['content-type'].presence || accept_header
    actual_format = format_for_content_type(actual_content_type)

    if status >= 200 && status < 300
      if actual_format.nil?
        @serialization_status = 502
        error_msg = controlled_error_message(502)
        @serialization_error = error_msg
        Result.new(content: nil, content_type: 'text/plain', status: 502, error: error_msg, format: nil)
      else
        @result = buffer
        @format = actual_format
        @serialization_status = status
        Result.new(content: buffer, content_type: actual_content_type, status: status, error: nil, format: actual_format)
      end
    else
      @serialization_status = status
      error_msg = controlled_error_message(status)
      @serialization_error = error_msg
      Result.new(content: nil, content_type: 'text/plain', status: status, error: error_msg, format: nil)
    end
  rescue PayloadTooLargeError
    @serialization_status = 413
    error_msg = controlled_error_message(413)
    @serialization_error = error_msg
    Result.new(content: nil, content_type: 'text/plain', status: 413, error: error_msg)
  rescue Faraday::TimeoutError
    @serialization_status = 504
    error_msg = controlled_error_message(504)
    @serialization_error = error_msg
    Result.new(content: nil, content_type: 'text/plain', status: 504, error: error_msg)
  rescue Faraday::ConnectionFailed, StandardError
    @serialization_status = 502
    error_msg = controlled_error_message(502)
    @serialization_error = error_msg
    Result.new(content: nil, content_type: 'text/plain', status: 502, error: error_msg)
  end

  SUPPORTED_MIME_FORMATS = {
    'application/ld+json'   => 'json',
    'application/json'      => 'json',
    'application/rdf+xml'   => 'xml',
    'text/xml'              => 'xml',
    'application/xml'       => 'xml',
    'application/n-triples' => 'ntriples',
    'text/n3'               => 'ntriples',
    'text/turtle'           => 'turtle',
    'application/x-turtle'  => 'turtle'
  }.freeze

  def format_for_content_type(content_type)
    return nil if content_type.blank?
    media_type = content_type.to_s.split(';').first.to_s.strip.downcase
    SUPPORTED_MIME_FORMATS[media_type]
  end

  def content_finder_url(acronym, uri)
    esc_uri = defined?(helpers) && helpers.respond_to?(:escape) ? helpers.escape(uri.to_s.strip) : CGI.escape(uri.to_s.strip)
    URI.parse("#{rest_url}/ontologies/#{acronym.to_s.strip}/resolve/#{esc_uri}")
  end

  def content_finder_accept_header(output_format)
    case output_format
    when 'json', 'application/json', 'application/ld+json', 'application/*'
      'application/ld+json'
    when 'xml', 'text/xml', 'text/rdf+xml',  'application/rdf+xml', 'application/xml'
      'application/rdf+xml'
    when 'ntriples', 'application/n-triples', '*/*', 'text/*', 'text/n3'
      'application/n-triples'
    when 'turtle', 'text/turtle'
      'text/turtle'
    else
      output_format
    end
  end

  private

  def controlled_error_message(status)
    case status.to_i
    when 403
      I18n.t('ontology_content_serializer.forbidden', default: 'Forbidden')
    when 404
      I18n.t('ontology_content_serializer.not_found', default: 'Not Found')
    when 413
      I18n.t('ontology_content_serializer.payload_too_large', default: 'Payload Too Large')
    when 502
      I18n.t('ontology_content_serializer.bad_gateway', default: 'Bad Gateway')
    when 504
      I18n.t('ontology_content_serializer.gateway_timeout', default: 'Gateway Timeout')
    else
      I18n.t('ontology_content_serializer.generic_error', default: 'Upstream Service Error')
    end
  end

end
