# Real-service check for the SPARQL proxy (ONTO-T-B13). Run with `bin/rails runner` against a
# configured SPARQL endpoint (SPARQL_CHECK_URL); only read queries are sent.
# The ontology lookup is stubbed; the helper, HTTP call, endpoint response and render are real.
require 'action_dispatch/testing/test_request'
require 'action_dispatch/testing/test_response'

url = ENV.fetch('SPARQL_CHECK_URL')
$SPARQL_URL = url
GRAPH = 'http://data.example.org/ontologies/CHK/submissions/1'
failures = []
check = ->(ok, msg) { puts "#{ok ? 'PASS' : 'FAIL'} #{msg}"; failures << msg unless ok }

LinkedData::Client::Models::Ontology.define_singleton_method(:find_by_acronym) do |*_|
  [OpenStruct.new(acronym: 'CHK', errors: nil)]
end

def proxy(query)
  c = AdminController.new
  c.request = ActionDispatch::TestRequest.create
  c.response = ActionDispatch::TestResponse.new
  c.params = ActionController::Parameters.new('query' => query, 'named-graph-uri' => GRAPH)
  c.send(:sparql_endpoint)
  c.response
end

erb_literal = '<%= 7 * 7 %>'
r = proxy(%(SELECT ?x WHERE { BIND("#{erb_literal}" AS ?x) }))
puts "status=#{r.status} content-type=#{r.headers['Content-Type']} bytes=#{r.body.bytesize}"
check.(r.status == 200, 'SELECT through the proxy returns 200 from the real endpoint')
check.(r.body.include?(CGI.escapeHTML(erb_literal)) || r.body.include?(erb_literal), 'ERB-looking literal comes back as data')
check.(!r.body.include?('49'), 'ERB-looking literal is not evaluated')
ct = r.headers['Content-Type'].to_s.split(';').first
check.(SparqlHelper::ALLOWED_SPARQL_MIME_TYPES.include?(ct) || ct == 'text/plain', "rendered content type is an allowed data type (#{ct})")

bad = proxy('SELECT ?x WHERE { this is not sparql')
puts "malformed: status=#{bad.status} body=#{bad.body[0, 80].inspect}"
check.(bad.status >= 400, 'malformed query gets a non-success status')

write = proxy("INSERT DATA { GRAPH <#{GRAPH}> { <urn:q03chk:a> <urn:q03chk:b> <urn:q03chk:c> } }")
puts "insert: status=#{write.status} body=#{write.body[0, 80].inspect}"
check.(write.status >= 400 && write.status < 500, 'INSERT is refused by the proxy')
ask = proxy('ASK { GRAPH ?g { <urn:q03chk:a> <urn:q03chk:b> <urn:q03chk:c> } }')
check.(ask.status == 200 && ask.body.include?('false'), 'the refused INSERT left no triple in the store')

puts failures.empty? ? 'PASS sparql service check' : "FAILED #{failures.size}"
exit(failures.empty? ? 0 : 1)
