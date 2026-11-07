begin
  require 'sparql/grammar'
rescue LoadError
  # SPARQL grammar loaded when gem available
end

begin
  require 'faraday'
rescue LoadError
  # Faraday loaded when gem available
end

require 'cgi'
require 'set'

begin
  require 'active_support/core_ext/object/blank'
rescue LoadError
  class Object
    def blank?
      respond_to?(:empty?) ? !!empty? : !self
    end
  end
end

module SparqlHelper
  ALLOWED_SPARQL_MIME_TYPES = Set.new([
    'application/sparql-results+json',
    'application/sparql-results+xml',
    'application/sparql-results+thrift',
    'application/json',
    'application/ld+json',
    'application/xml',
    'text/xml',
    'application/rdf+xml',
    'text/turtle',
    'application/x-turtle',
    'text/n3',
    'application/n-triples',
    'text/plain',
    'text/csv',
    'text/tab-separated-values',
    'text/tsv',
    'text/boolean',
    'application/trig',
    'application/n-quads'
  ]).freeze

  def validate_sparql_content_type(raw_content_type)
    return 'text/plain; charset=utf-8' if raw_content_type.blank?

    media_type = raw_content_type.to_s.split(';').first.to_s.strip.downcase
    if ALLOWED_SPARQL_MIME_TYPES.include?(media_type)
      raw_content_type
    else
      'text/plain; charset=utf-8'
    end
  end

  def normalize_body_encoding(body)
    return '' if body.nil?

    str = body.to_s
    if str.encoding == Encoding::UTF_8 && str.valid_encoding?
      str
    else
      utf8_str = str.dup.force_encoding(Encoding::UTF_8)
      if utf8_str.valid_encoding?
        utf8_str
      else
        str.dup.force_encoding('ISO-8859-1').encode(Encoding::UTF_8, invalid: :replace, undef: :replace)
      end
    end
  end

  def encode_param(string)
    CGI.escape(string.to_s) if string
  end
  def change_from_clause(query, graph)
    validate_sparql_query(query)
    query = remove_sparql_comments(query)
    # Clean up any blank lines that might have been created
    query.gsub!(/\n\s*\n+/, "\n")

    unless graph.blank?
      graph = graph.gsub($REST_URL, 'http://data.bioontology.org')

      if query.match?(/(?<=\s|^)FROM\s*\S+[^{ \n]/i)
        #  match FROM <URI> and FROM meta:User (only after space or start of line)
        query.gsub!(/(?<=\s|^)FROM\s*\S+[^{ \n]/i, "FROM <#{graph}>")
      elsif query.match?(/WHERE\s+\S+/i)
        # match WHERE without FROM
        query.gsub!(/WHERE/i, "FROM <#{graph}> WHERE")
      end
      # match GRAPH <URI> and GRAPH meta:User (only after space or start of line)
      query.gsub!(/(?<=\s|^)GRAPH\s*[^\{]+\{/i, "GRAPH <#{graph}> {")

      # match SELECT without FROM and WHERE and ignore the { inside quotes
      if query.match?(/(SELECT.*?\s*\S*)(?<!["'\s])\s*\{(?![^"]*["'])/im)
        query.sub!(/(SELECT.*?\s*\S*)(?<!["'\s])\s*\{(?![^"]*["'])/im) do |match|
          if match.downcase.match?(/(?<!["'(\s])\s*FROM(?![^"]*["')])/i)
            match
          else
            out = "#{$1}"
            out = out.gsub(/WHERE/i, '') if out.downcase.include?('where')
            "#{out.strip} FROM <#{graph}> WHERE {"
          end
        end
      end
    end

    validate_sparql_query(query)
    query
  end

  def ontology_sparql_query(query, graph = '')
    unless is_allowed_query?(query)
      return Faraday::Response.new(
        status: 403,
        body: 'INSERT Queries not permitted',
        response_headers: { 'content-type' => 'text/plain; charset=utf-8' }
      )
    end

    query = change_from_clause(query, graph)
    sparql_query(query)
  rescue StandardError => e
    Faraday::Response.new(
      status: 400,
      body: 'Failed to parse query',
      response_headers: { 'content-type' => 'text/plain; charset=utf-8' }
    )
  end

  def sparql_query(query)
    if $SPARQL_URL.blank?
      return Faraday::Response.new(
        status: 503,
        body: 'No SPARQL endpoint configured',
        response_headers: { 'content-type' => 'text/plain; charset=utf-8' }
      )
    end

    unless is_allowed_query?(query)
      return Faraday::Response.new(
        status: 403,
        body: 'INSERT Queries not permitted',
        response_headers: { 'content-type' => 'text/plain; charset=utf-8' }
      )
    end

    endpoint = $SPARQL_URL.gsub('test', 'sparql')
    begin
      conn = Faraday.new do |conn|
        conn.options.timeout = 10
      end
      response = conn.get("#{endpoint}?query=#{encode_param(query)}")
      body = normalize_body_encoding(response.body)
      if response.respond_to?(:env) && response.env
        response.env.body = body
        response
      else
        Faraday::Response.new(
          status: response.status,
          body: body,
          response_headers: response.headers
        )
      end
    rescue StandardError => e
      Faraday::Response.new(
        status: 504,
        body: 'Query timeout',
        response_headers: { 'content-type' => 'text/plain; charset=utf-8' }
      )
    end
  end

  def sparql_query_container(username: current_user&.username, graph: nil, apikey: get_apikey, sample_queries: nil, sparql_endpoint: $SPARQL_ENDPOINT_URL)
    if sample_queries.nil? 
      sample_queries = get_catalog_sample_queries
    end
    content_tag(:div, '', data: { controller: 'sparql',
                                  'sparql-proxy-value': sparql_endpoint,
                                  'sparql-apikey-value': apikey,
                                  'sparql-username-value': username,
                                  'sparql-graph-value': graph,
                                  'sparql-sample-queries-value': sample_queries,
                                })
  end
  NO_CACHE_HEADERS = {
    'Cache-Control' => 'no-cache, no-store, must-revalidate',
    'Pragma' => 'no-cache',
    'Expires' => '0'
  }.freeze
  def get_catalog_sample_queries
    begin
      response = LinkedData::Client::HTTP.get("#{$REST_URL}", {include: "sampleQueries", display_context: false, display_links: false, _ts: Time.now.to_i})
      response.to_hash[:sampleQueries]
    rescue => e
      logger.error "Failed to fetch catalog sample queries: #{e.message}"
      []
    end
  end

  def get_ontology_sample_queries(graph)
    begin
      response = LinkedData::Client::Models::Ontology.find_by_acronym(graph.gsub($REST_URL + '/ontologies/', '').split("/")[0], {include: "sampleQueries", display_context: false, display_links: false, _ts: Time.now.to_i}).first.sampleQueries
    rescue => e
      logger.error "Failed to fetch ontology sample queries: #{e.message}"
      []
    end
  end 
  private

  def is_allowed_query?(sparql_query)
    forbidden_operations = [
      'INSERT DATA',
      'DELETE DATA',
      'DELETE/INSERT',
      'DELETE',
      'INSERT',
      'DELETE WHERE',
      'LOAD',
      'CLEAR',
      'CREATE',
      'DROP',
      'COPY',
      'MOVE',
      'ADD'
    ]

    # Define a regular expression to match SELECT queries
    select_query_regex = /\A\s*SELECT\b/m

    # Check if the query contains any forbidden operations outside SELECT queries
    if forbidden_operations.any? { |op| sparql_query.upcase.include?(op) && !sparql_query.match(select_query_regex) }
      return false
    end

    true
  end

  def remove_sparql_comments(query)
    # Remove everything from # to end of line, unless the # is inside angle brackets
    lines = query.split("\n")
    cleaned_lines = lines.map do |line|
      inside_uri = false
      comment_start = nil

      line.each_char.with_index do |char, i|
        if char == '<'
          inside_uri = true
        elsif char == '>'
          inside_uri = false
        elsif char == '#' && !inside_uri
          comment_start = i
          break
        end
      end

      comment_start ? line[0...comment_start] : line
    end

    cleaned_lines.join("\n")
  end

  def validate_sparql_query(query)
    if defined?(SPARQL::Grammar)
      SPARQL::Grammar.parse(query)
    else
      raise StandardError, 'Failed to parse query: unclosed brace' if query.to_s.count('{') != query.to_s.count('}')
      raise StandardError, 'Failed to parse query: empty query' if query.to_s.strip.empty?
    end
  rescue StandardError => e
    raise StandardError, "Failed to parse query: #{e.message}"
  end

end
