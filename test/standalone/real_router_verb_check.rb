# frozen_string_literal: true

# ONTO-T-B02: verb safety of the real Rails route table (rails runner, RAILS_ENV=test, no DB or API).
# - no dynamic :controller/:action route;
# - no conventional write action (create/update/destroy/delete...) is reachable by GET;
# - every action routed by both GET and a write verb is listed in SHARED with its reason;
# - legacy read URLs still resolve to their read actions.

abort 'refusing to run outside RAILS_ENV=test' unless Rails.env.test?

# Actions routed by GET and a write verb; each GET/HEAD branch was reviewed to only read or confirm.
SHARED = {
  'admin#sparql_endpoint' => 'SPARQL query proxy; GET and POST are both SPARQL protocol query forms',
  'home#feedback' => 'GET renders the form; only a POSTed form sends feedback',
  'home#set_cookies' => 'permanent consent cookie written only on POST (B02 cookie unit)',
  'login#destroy' => 'GET/HEAD render a logout confirmation; POST/DELETE end the session',
  'login#login_as' => 'GET/HEAD render the impersonation confirmation; only POST switches',
  'login#reset_password' => 'GET/HEAD validate and show the form; only POST consumes the token',
  'users#subscribe' => 'GET/HEAD show a confirmation; POST subscribes (B02 subscription unit)',
  'users#un_subscribe' => 'GET/HEAD show a confirmation; POST unsubscribes (B02 subscription unit)'
}.freeze

# Write-named actions that GET legitimately reaches.
GET_NAMED_OK = {
  'login#create_omniauth' => 'OAuth provider redirect callback is a GET by protocol',
  'admin#update_check_enabled' => 'only GETs the update-check flag from the API',
  'change_requests#create_synonym' => 'renders the synonym request form (JS); create is a separate POST',
  'login#destroy' => 'GET renders the logout confirmation'
}.freeze

routes = Rails.application.routes.routes.map do |r|
  d = r.defaults
  next unless d[:controller] && d[:action]

  verbs = r.verb.to_s.split('|').map(&:upcase)
  { path: r.path.spec.to_s, verbs: verbs.empty? ? ['ANY'] : verbs, ca: "#{d[:controller]}##{d[:action]}", action: d[:action].to_s }
end.compact

failures = []

dynamic = routes.select { |r| r[:path].match?(/:controller|:action/) }
failures << "dynamic controller/action routes: #{dynamic.map { |r| r[:path] }.uniq}" if dynamic.any?

get_like = routes.select { |r| (r[:verbs] & %w[GET ANY]).any? }
write_like = routes.select { |r| (r[:verbs] & %w[POST PATCH PUT DELETE ANY]).any? && !(r[:verbs] == %w[GET]) }

named_writes = get_like.select { |r| r[:action].match?(/\A(create|update|destroy|delete|remove|save)(_|\z)/) && !GET_NAMED_OK.key?(r[:ca]) }
failures << "write-named actions reachable by GET: #{named_writes.map { |r| "#{r[:verbs].join('|')} #{r[:path]} -> #{r[:ca]}" }}" if named_writes.any?

any_verb = routes.select { |r| r[:verbs] == ['ANY'] }
puts "routes without verb restriction: #{any_verb.map { |r| "#{r[:path]} -> #{r[:ca]}" }.inspect}"

writes = write_like.reject { |r| r[:verbs] == ['ANY'] }.map { |r| r[:ca] }.uniq
shared = get_like.map { |r| r[:ca] }.uniq & writes
puts "actions routed by GET and a write verb: #{shared.sort.inspect}"
unexpected = shared - SHARED.keys
failures << "GET-reachable actions that also take writes, not reviewed: #{unexpected.sort}" if unexpected.any?

LEGACY_READS = {
  '/about' => 'about#index', '/landscape' => 'landscape#index', '/content_finder' => 'content_finder#index',
  '/ontologies' => 'ontologies#index', '/ontologies/STY' => 'ontologies#show', '/mappings' => 'mappings#index'
}.freeze
LEGACY_READS.each do |path, expected|
  got = Rails.application.routes.recognize_path(path, method: :get)
  ca = "#{got[:controller]}##{got[:action]}"
  failures << "GET #{path} -> #{ca}, expected #{expected}" unless ca == expected
rescue ActionController::RoutingError => e
  failures << "GET #{path} unroutable: #{e.message}"
end

puts "#{routes.size} routes checked; #{shared.size} shared GET/write actions; #{LEGACY_READS.size} legacy reads"
if failures.empty?
  puts 'PASS real router verb check'
else
  puts failures.map { |f| "FAIL #{f}" }
  exit 1
end
