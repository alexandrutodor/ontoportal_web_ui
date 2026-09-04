# frozen_string_literal: true

require 'net/http'
require 'uri'
require 'json'

class DatasetsProvider
  MAX_QUERY_LENGTH = 120
  MAX_ID_LENGTH = 120
  MAX_RESPONSE_BYTES = 1_048_576
  PAGE_SIZE = 20
  ID_PATTERN = /\A[a-zA-Z0-9][a-zA-Z0-9._:-]{0,119}\z/

  CATALOGUE_PATH = File.expand_path('../../config/catalogues/dataset-catalogue.json', __dir__).freeze

  Record = Struct.new(:id, :title, :description, :publisher, :updated_at, :homepage, keyword_init: true)
  IndexResult = Struct.new(:records, :page, :total, keyword_init: true)

  class Error < StandardError
    attr_reader :status

    def initialize(message, status: :bad_gateway)
      @status = status
      super(message)
    end
  end

  def initialize(base_url: ENV['DATASETS_API_URL'])
    raw_url = base_url.to_s.strip
    if raw_url.present?
      @base_uri = URI.parse(raw_url)
      unless %w[http https].include?(@base_uri.scheme) && @base_uri.host.present? && @base_uri.userinfo.nil?
        raise Error.new('Dataset provider configuration is invalid.', status: :service_unavailable)
      end
      @mode = :remote
    else
      @mode = :native
    end
  rescue URI::InvalidURIError
    raise Error.new('Dataset provider configuration is invalid.', status: :service_unavailable)
  end

  def index(query:, page:)
    page = page.to_i.clamp(1, 1000)
    if @mode == :remote
      payload = get('/datasets', { q: bound(query, MAX_QUERY_LENGTH), page: page, per_page: PAGE_SIZE })
      rows = payload.is_a?(Hash) ? payload['datasets'] : nil
      raise Error, 'Dataset provider returned an invalid catalogue.' unless rows.is_a?(Array)

      records = rows.map { |row| normalize_record(row) }
      total = payload['total'].to_i if payload['total']
      IndexResult.new(records: records, page: page, total: total)
    else
      native_index(query: query, page: page)
    end
  end

  def detail(id)
    id = id.to_s
    raise Error.new('Dataset was not found.', status: :not_found) unless ID_PATTERN.match?(id)

    if @mode == :remote
      normalize_record(get("/datasets/#{URI.encode_www_form_component(id)}"))
    else
      native_detail(id)
    end
  end

  private

  def native_datasets
    @native_datasets ||= begin
      if File.exist?(CATALOGUE_PATH)
        doc = JSON.parse(File.binread(CATALOGUE_PATH))
        doc['datasets'] || []
      else
        []
      end
    rescue JSON::ParserError
      []
    end
  end

  def native_index(query:, page:)
    q = bound(query, MAX_QUERY_LENGTH).downcase
    matching = native_datasets.select do |row|
      next true if q.empty?

      id_match = row['id'].to_s.downcase.include?(q)
      title_match = row['title'].to_s.downcase.include?(q)
      desc_match = row['description'].to_s.downcase.include?(q)
      pub_match = row['publisher'].to_s.downcase.include?(q)
      tags_match = Array(row['tags']).any? { |tag| tag.to_s.downcase.include?(q) }
      id_match || title_match || desc_match || pub_match || tags_match
    end

    total = matching.length
    offset = (page - 1) * PAGE_SIZE
    page_rows = matching.slice(offset, PAGE_SIZE) || []
    records = page_rows.map { |row| normalize_record(row) }
    IndexResult.new(records: records, page: page, total: total)
  end

  def native_detail(id)
    row = native_datasets.find { |d| d['id'].to_s == id }
    raise Error.new('Dataset was not found.', status: :not_found) unless row

    normalize_record(row)
  end

  def get(path, params = {})
    uri = @base_uri.dup
    uri.path = [@base_uri.path.to_s.sub(%r{/$}, ''), path].join
    uri.query = URI.encode_www_form(params.reject { |_key, value| value.to_s.empty? })

    request = Net::HTTP::Get.new(uri.request_uri)
    request['Accept'] = 'application/json'
    response = nil
    body = +''
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = uri.scheme == 'https'
    http.open_timeout = 3
    http.read_timeout = 5
    http.write_timeout = 3 if http.respond_to?(:write_timeout=)

    http.start do |client|
      client.request(request) do |provider_response|
        response = provider_response
        next unless provider_response.is_a?(Net::HTTPSuccess)

        if provider_response.content_length && provider_response.content_length > MAX_RESPONSE_BYTES
          raise Error, 'Dataset provider response was too large.'
        end

        provider_response.read_body do |chunk|
          raise Error, 'Dataset provider response was too large.' if body.bytesize + chunk.bytesize > MAX_RESPONSE_BYTES

          body << chunk
        end
      end
    end

    raise Error.new('Dataset was not found.', status: :not_found) if response.is_a?(Net::HTTPNotFound)
    raise Error, 'Dataset provider returned an error.' unless response&.is_a?(Net::HTTPSuccess)

    JSON.parse(body)
  rescue JSON::ParserError
    raise Error, 'Dataset provider returned invalid JSON.'
  rescue Net::OpenTimeout, Net::ReadTimeout, Timeout::Error, SocketError,
         Errno::ECONNREFUSED, Errno::ECONNRESET, Errno::ECONNABORTED,
         Errno::EHOSTUNREACH, Errno::ENETUNREACH, Errno::ETIMEDOUT,
         EOFError, OpenSSL::SSL::SSLError, Net::ProtocolError,
         Net::HTTPBadResponse, Net::HTTPHeaderSyntaxError
    raise Error.new('Dataset provider is unavailable.', status: :service_unavailable)
  end

  def normalize_record(row)
    raise Error, 'Dataset provider returned an invalid dataset.' unless row.is_a?(Hash)

    values = row.transform_keys(&:to_s)
    id = bound(values['id'] || values['identifier'], MAX_ID_LENGTH)
    raise Error, 'Dataset provider returned a dataset without an identifier.' if id.empty?

    Record.new(
      id: id,
      title: bound(values['title'].presence || id, 240),
      description: bound(values['description'], 1000),
      publisher: bound(values['publisher'], 200),
      updated_at: bound(values['updated_at'], 80),
      homepage: safe_url(values['homepage'] || values['landing_page'])
    )
  end

  def bound(value, length)
    value.to_s.encode('UTF-8', invalid: :replace, undef: :replace).strip.first(length).to_s
  end

  def safe_url(value)
    uri = URI.parse(value.to_s)
    return unless %w[http https].include?(uri.scheme) && uri.host && uri.userinfo.nil?

    uri.to_s
  rescue URI::InvalidURIError
    nil
  end
end
