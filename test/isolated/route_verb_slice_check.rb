#!/usr/bin/env ruby
# frozen_string_literal: true

# Standalone isolated regression check for ONTO-T-B02 (Routing / Verb Slice):
# Verifies removal of generic GET catchall route, elimination of obsolete GET update/delete aliases,
# preservation of legitimate read routes (landscape, about, content finder, bookmarked ontology pages),
# preservation of legitimate write routes (POST/PATCH/PUT/DELETE), and isolation with API write doubles.
#
# Runs entirely offline without booting full Rails, binding servers, starting containers,
# network requests, or credentials.

failures = []

def assert(condition, message, failures)
  if condition
    puts "  [PASS] #{message}"
  else
    puts "  [FAIL] #{message}"
    failures << message
  end
end

puts "=== Step 1: Initialize isolated Rails routing DSL double ==="

class RouteSet
  Route = Struct.new(:verb, :path_spec, :controller, :action, :constraints)
  attr_reader :routes

  def initialize
    @routes = []
    @scope_stack = []
  end

  def match(*args, **kwargs)
    path, options = normalize_args(*args, **kwargs)
    verbs = Array(options[:via] || [:get, :post, :put, :patch, :delete])
    verbs = [:get, :post, :put, :patch, :delete] if verbs.include?(:all)
    ctrl, act = parse_to(options[:to], options, path)
    verbs.each do |v|
      add_route(v.to_s.upcase, path, ctrl, act, options)
    end
  end

  def get(*args, **kwargs)
    add_verb_route("GET", *args, **kwargs)
  end

  def post(*args, **kwargs)
    add_verb_route("POST", *args, **kwargs)
  end

  def put(*args, **kwargs)
    add_verb_route("PUT", *args, **kwargs)
  end

  def patch(*args, **kwargs)
    add_verb_route("PATCH", *args, **kwargs)
  end

  def delete(*args, **kwargs)
    add_verb_route("DELETE", *args, **kwargs)
  end

  def root(options = {})
    get("/", options)
  end

  def mount(app, options = {})
    # No-op for mounted engines in route check
  end

  def scope(*args, **kwargs, &block)
    options = kwargs.dup
    path = args.first.to_s
    @scope_stack.push(path: path, options: options)
    instance_eval(&block)
    @scope_stack.pop
  end

  def namespace(name, &block)
    scope(name.to_s, module: name.to_s, as: name.to_s, &block)
  end

  def constraints(constraint_arg, &block)
    instance_eval(&block)
  end

  def resources(name, options = {}, &block)
    name_str = name.to_s
    actions = options[:only] ? Array(options[:only]).map(&:to_s) : %w[index create new show edit update destroy]
    actions -= Array(options[:except]).map(&:to_s) if options[:except]

    base_path = full_path(name_str)
    ctrl = current_controller(name_str)

    get(base_path, to: "#{ctrl}#index") if actions.include?("index")
    post(base_path, to: "#{ctrl}#create") if actions.include?("create")
    get("#{base_path}/new", to: "#{ctrl}#new") if actions.include?("new")
    get("#{base_path}/:id", to: "#{ctrl}#show", constraints: options[:constraints]) if actions.include?("show")
    get("#{base_path}/:id/edit", to: "#{ctrl}#edit", constraints: options[:constraints]) if actions.include?("edit")
    put("#{base_path}/:id", to: "#{ctrl}#update", constraints: options[:constraints]) if actions.include?("update")
    patch("#{base_path}/:id", to: "#{ctrl}#update", constraints: options[:constraints]) if actions.include?("update")
    delete("#{base_path}/:id", to: "#{ctrl}#destroy", constraints: options[:constraints]) if actions.include?("destroy")

    if block_given?
      parent_param = "#{name_str.singularize}_id"
      scope("#{name_str}/:#{parent_param}", &block)
    end
  end

  def resource(name, options = {}, &block)
    name_str = name.to_s
    actions = options[:only] ? Array(options[:only]).map(&:to_s) : %w[show new create edit update destroy]
    ctrl = options[:controller] || current_controller(name_str.pluralize)
    base_path = full_path(name_str)
    get(base_path, to: "#{ctrl}#show") if actions.include?("show")
    put(base_path, to: "#{ctrl}#update") if actions.include?("update")
    patch(base_path, to: "#{ctrl}#update") if actions.include?("update")
  end

  def match_request(verb, path)
    routes.each do |r|
      next unless r.verb == verb.upcase
      pattern = r.path_spec.dup
      pattern = pattern.sub("(/:action(/:id))", "(?:/:action(?:/:id)?)?")
      constraints = r.constraints || {}
      pattern = pattern.gsub(/:([a-zA-Z0-9_]+)/) do |_m|
        param = $1.to_sym
        if constraints[param]
          c = constraints[param].is_a?(Regexp) ? constraints[param].source : constraints[param].to_s
          "(?<#{param}>#{c})"
        else
          "(?<#{param}>[^\\/]+)"
        end
      end
      regex = Regexp.new("\\A#{pattern}\\z")
      if (m = regex.match(path))
        ctrl = r.controller.empty? ? (m.names.include?("controller") ? m[:controller] : "") : r.controller
        act = r.action.empty? ? (m.names.include?("action") ? m[:action] : "index") : r.action
        return { controller: ctrl, action: act, path_spec: r.path_spec, params: m.named_captures }
      end
    end
    nil
  end

  private

  def normalize_args(*args, **kwargs)
    options = kwargs.dup
    path = args.first
    if path.nil?
      path_key = options.keys.find { |k| k.to_s.start_with?("/") || k.to_s.include?(":") || k.to_s == "" }
      if path_key
        path = path_key.to_s
        options[:to] = options.delete(path_key)
      end
    end
    [path.to_s, options]
  end

  def add_verb_route(verb, *args, **kwargs)
    path, options = normalize_args(*args, **kwargs)
    ctrl, act = parse_to(options[:to], options, path)
    add_route(verb, path, ctrl, act, options)
  end

  def full_path(path)
    prefix = @scope_stack.map { |s| s[:path] }.reject(&:empty?).join("/")
    p = [prefix, path].reject(&:empty?).join("/")
    p.start_with?("/") ? p : "/#{p}"
  end

  def current_controller(default_ctrl)
    mod = @scope_stack.map { |s| s[:options][:module] }.compact.join("/")
    mod.empty? ? default_ctrl : "#{mod}/#{default_ctrl}"
  end

  def parse_to(to, options, path = "")
    if to.is_a?(String) && to.include?("#")
      ctrl, act = to.split("#")
      [current_controller(ctrl), act]
    elsif options[:controller] && options[:action]
      [current_controller(options[:controller]), options[:action].to_s]
    elsif path.to_s =~ /^\/?([a-zA-Z0-9_]+)\/([a-zA-Z0-9_]+)$/
      [current_controller($1), $2]
    else
      [current_controller(""), ""]
    end
  end

  def add_route(verb, path, ctrl, act, options)
    fpath = full_path(path)
    constraints = options[:constraints] || {}
    constraints[:id] = options[:id] if options[:id]
    constraints[:ontology_id] = options[:ontology_id] if options[:ontology_id]
    constraints[:purl_conceptid] = options[:purl_conceptid] if options[:purl_conceptid]
    @routes << Route.new(verb, fpath, ctrl, act, constraints)
  end
end

class MiniRails
  def self.application; @app ||= MiniApp.new; end
  def self.env; @env ||= Struct.new(:development?, :test?, :production?).new(false, true, false); end
end

class MiniApp
  def routes; @routes ||= MiniRoutes.new; end
end

class MiniRoutes
  attr_reader :route_set
  def draw(&block)
    @route_set = RouteSet.new
    @route_set.instance_eval(&block)
  end
end

Object.const_set(:Rails, MiniRails) unless defined?(Rails)
module LetterOpenerWeb; class Engine; end; end unless defined?(LetterOpenerWeb)
module Flipper; class UI; def self.app(*); end; end; end unless defined?(Flipper)
module Lookbook; class Engine; end; end unless defined?(Lookbook)
class String
  def singularize; sub(/ies$/, "y").sub(/s$/, ""); end unless method_defined?(:singularize)
  def pluralize; "#{self}s"; end unless method_defined?(:pluralize)
end

routes_path = File.expand_path('../../config/routes.rb', __dir__)
load routes_path
route_set = Rails.application.routes.route_set
puts "Loaded #{route_set.routes.size} routes from config/routes.rb."

puts "\n=== Step 2: Source inspection of config/routes.rb ==="
routes_source = File.read(routes_path)

# 1. Generic catchall route must not exist
has_generic_catchall = routes_source.match?(/^\s*get\s+['"]\/:controller\(\/:action\(\/:id\)\)['"]/)
assert(!has_generic_catchall, "Generic catchall 'get /:controller(/:action(/:id))' is removed", failures)

# 2. Obsolete ajax notes delete GET alias must not exist
has_ajax_notes_delete = routes_source.match?(/^\s*get\s+['"]\/ajax\/notes\/delete['"]/)
assert(!has_ajax_notes_delete, "Obsolete 'get /ajax/notes/delete' route is removed", failures)

# 3. GET alias on ontologies update must not exist
has_get_ontologies_update = routes_source.match?(/match\s+['"]\/ontologies\/:acronym['"].*via:\s*\[?:get/)
assert(!has_get_ontologies_update, "GET alias for ontologies#update is removed", failures)

# 4. GET alias on submissions update must not exist
has_get_submissions_update = routes_source.match?(/match\s+['"]\/ontologies\/:acronym\/submissions\/:id['"].*via:\s*\[?:get/)
assert(!has_get_submissions_update, "GET alias for submissions#update is removed", failures)

# 5. Dead edit_metadata route must not exist
has_dead_edit_metadata = routes_source.match?(/edit_metadata/)
assert(!has_dead_edit_metadata, "Obsolete dead route edit_metadata is removed", failures)

puts "\n=== Step 3: Route rejection of mutating GET requests (Pass-After) ==="
# These paths previously reached mutation actions via catchall or obsolete GET aliases.
# Verify that routing either rejects them entirely (404) or routes only to safe read actions,
# never to a state-changing mutation action.
forbidden_get_mutations = [
  { path: "/ajax/notes/delete", desc: "Obsolete GET /ajax/notes/delete", require_404: true },
  { path: "/projects/destroy/test-project", desc: "Catchall GET /projects/destroy/:id", require_404: true },
  { path: "/admin/clearcache", desc: "Catchall GET /admin/clearcache", require_404: true },
  { path: "/admin/resetcache", desc: "Catchall GET /admin/resetcache", require_404: true },
  { path: "/admin/clear_goo_cache", desc: "Catchall GET /admin/clear_goo_cache", require_404: true },
  { path: "/admin/clear_http_cache", desc: "Catchall GET /admin/clear_http_cache", require_404: true },
  { path: "/admin/delete_ontologies", desc: "Catchall GET /admin/delete_ontologies", require_404: true },
  { path: "/admin/refresh_ontologies_report", desc: "Catchall GET /admin/refresh_ontologies_report", require_404: true },
  { path: "/ontologies/TEST_ONT", desc: "GET /ontologies/:acronym must NOT route to update", forbidden_action: "update" },
  { path: "/ontologies/TEST_ONT/submissions/1", desc: "GET /ontologies/:acronym/submissions/:id must NOT route to update", forbidden_action: "update" },
  { path: "/notes/destroy/123", desc: "GET /notes/destroy/123 must NOT route to destroy", forbidden_action: "destroy" },
  { path: "/mappings/destroy/456", desc: "GET /mappings/destroy/456 must NOT route to destroy", forbidden_action: "destroy" }
]

forbidden_get_mutations.each do |req|
  res = route_set.match_request("GET", req[:path])
  if req[:require_404]
    assert(res.nil?, "#{req[:desc]} (#{req[:path]}) is rejected by routing (returns 404/unroutable)", failures)
  else
    action = res ? res[:action] : nil
    assert(action != req[:forbidden_action],
           "#{req[:desc]} (#{req[:path]}) does not invoke #{req[:forbidden_action]} (resolved: #{res ? "#{res[:controller]}##{res[:action]}" : 'unroutable'})", failures)
  end
end

puts "\n=== Step 4: Route precedence & reachability verification ==="
# GET /ontologies/STY hits ontologies#show via resources :ontologies
res_ont_show = route_set.match_request("GET", "/ontologies/STY")
assert(res_ont_show && res_ont_show[:controller] == "ontologies" && res_ont_show[:action] == "show",
       "GET /ontologies/STY routes to ontologies#show via resources :ontologies", failures)

# POST /ontologies/STY hits ontologies#update via explicit POST route
res_ont_update = route_set.match_request("POST", "/ontologies/STY")
assert(res_ont_update && res_ont_update[:controller] == "ontologies" && res_ont_update[:action] == "update",
       "POST /ontologies/STY routes to ontologies#update", failures)

# POST /ontologies/STY/submissions/1 hits submissions#update
res_sub_update = route_set.match_request("POST", "/ontologies/STY/submissions/1")
assert(res_sub_update && res_sub_update[:controller] == "submissions" && res_sub_update[:action] == "update",
       "POST /ontologies/STY/submissions/1 routes to submissions#update", failures)

puts "\n=== Step 5: Preservation of legitimate read URLs ==="
required_read_urls = [
  { path: "/about", expected_ctrl: "about", expected_act: "index", desc: "About page" },
  { path: "/landscape", expected_ctrl: "landscape", expected_act: "index", desc: "Landscape overview" },
  { path: "/content_finder", expected_ctrl: "content_finder", expected_act: "index", desc: "Content finder" },
  { path: "/admin/metadata_administration", expected_ctrl: "admin", expected_act: "metadata_administration", desc: "Admin metadata administration" },
  { path: "/metadata_administration", expected_ctrl: "admin", expected_act: "metadata_administration", desc: "Metadata administration top-level" },
  { path: "/ontologies/STY/download", expected_ctrl: "ontologies_redirection", expected_act: "redirect_ontology", desc: "Ontology download redirection" },
  { path: "/ontologies/STY/classes/T071", expected_ctrl: "ontologies", expected_act: "show", desc: "Ontology class PURL redirection" },
  { path: "/ontologies/STY/123", expected_ctrl: "ontologies_redirection", expected_act: "redirect", desc: "Ontology resource URI redirection" },
  { path: "/ontologies_filter", expected_ctrl: "ontologies", expected_act: "ontologies_filter", desc: "Ontologies filter" },
  { path: "/search", expected_ctrl: "search", expected_act: "index", desc: "Search index" }
]

required_read_urls.each do |r|
  res = route_set.match_request("GET", r[:path])
  matched = res && res[:controller] == r[:expected_ctrl] && res[:action] == r[:expected_act]
  assert(matched, "#{r[:desc]} (#{r[:path]}) correctly resolves to #{r[:expected_ctrl]}##{r[:expected_act]}", failures)
end

puts "\n=== Step 6: Preservation of legitimate write verbs (POST / PATCH / PUT / DELETE) ==="
required_write_urls = [
  { verb: "DELETE", path: "/notes", expected_ctrl: "notes", expected_act: "destroy", desc: "Delete note via DELETE /notes" },
  { verb: "DELETE", path: "/projects/test-proj", expected_ctrl: "projects", expected_act: "destroy", desc: "Delete project via DELETE /projects/:id" },
  { verb: "DELETE", path: "/mappings/test-map", expected_ctrl: "mappings", expected_act: "destroy", desc: "Delete mapping via DELETE /mappings/:id" },
  { verb: "DELETE", path: "/admin/ontologies", expected_ctrl: "admin", expected_act: "delete_ontologies", desc: "Delete ontologies via DELETE /admin/ontologies" },
  { verb: "POST", path: "/admin/clearcache", expected_ctrl: "admin", expected_act: "clearcache", desc: "Clear cache via POST /admin/clearcache" },
  { verb: "POST", path: "/admin/resetcache", expected_ctrl: "admin", expected_act: "resetcache", desc: "Reset cache via POST /admin/resetcache" },
  { verb: "PUT", path: "/admin/ontologies", expected_ctrl: "admin", expected_act: "process_ontologies", desc: "Process ontologies via PUT /admin/ontologies" }
]

required_write_urls.each do |w|
  res = route_set.match_request(w[:verb], w[:path])
  matched = res && res[:controller] == w[:expected_ctrl] && res[:action] == w[:expected_act]
  assert(matched, "#{w[:desc]} correctly resolves to #{w[:expected_ctrl]}##{w[:expected_act]}", failures)
end

puts "\n=== Step 7: API write doubles verification ==="
# Verify that API mutation doubles are unreachable through GET navigation
class ProjectApiDouble
  attr_reader :delete_calls

  def initialize
    @delete_calls = []
  end

  def delete(acronym)
    @delete_calls << acronym
    { success: true }
  end
end

class NotesApiDouble
  attr_reader :delete_calls

  def initialize
    @delete_calls = []
  end

  def delete(note_id)
    @delete_calls << note_id
    { success: true }
  end
end

project_api = ProjectApiDouble.new
notes_api = NotesApiDouble.new

# Simulate request dispatcher pipeline:
# An incoming HTTP request must match a valid route before reaching a controller action.
def dispatch_request(route_set, verb, path, project_api, notes_api)
  route = route_set.match_request(verb, path)
  return :routing_error if route.nil?

  # If route matched, dispatch to mock controller logic:
  case "#{route[:controller]}##{route[:action]}"
  when "projects#destroy"
    project_api.delete(route[:params]["id"])
    :dispatched
  when "notes#destroy"
    notes_api.delete(route[:params]["id"] || "bulk")
    :dispatched
  else
    :dispatched
  end
end

# 1. Attacker attempts to delete project via GET prefetch / cross-site link
status_proj_get = dispatch_request(route_set, "GET", "/projects/destroy/target-project", project_api, notes_api)
assert(status_proj_get == :routing_error, "GET /projects/destroy/target-project is rejected with routing error", failures)
assert(project_api.delete_calls.empty?, "ProjectApiDouble.delete was NOT called by GET request", failures)

# 2. Attacker attempts to delete note via legacy GET alias
status_note_get = dispatch_request(route_set, "GET", "/ajax/notes/delete", project_api, notes_api)
assert(status_note_get == :routing_error, "GET /ajax/notes/delete is rejected with routing error", failures)
assert(notes_api.delete_calls.empty?, "NotesApiDouble.delete was NOT called by GET request", failures)

# 3. Legitimate authorized user issues DELETE /projects/target-project
status_proj_del = dispatch_request(route_set, "DELETE", "/projects/target-project", project_api, notes_api)
assert(status_proj_del == :dispatched, "DELETE /projects/target-project is successfully dispatched", failures)
assert(project_api.delete_calls == ["target-project"], "ProjectApiDouble.delete was invoked by authorized DELETE verb", failures)

# 4. Legitimate authorized user issues DELETE /notes
status_note_del = dispatch_request(route_set, "DELETE", "/notes", project_api, notes_api)
assert(status_note_del == :dispatched, "DELETE /notes is successfully dispatched", failures)
assert(notes_api.delete_calls == ["bulk"], "NotesApiDouble.delete was invoked by authorized DELETE verb", failures)

puts "\n=== Step 8: Deferred confirmation-flow inventory check ==="
# Ensure confirmation-flow routes that require dedicated read-form/write-action pairs
# are preserved in this slice and explicitly inventoried for the next B02 unit.
deferred_cases = [
  { name: "Logout", verb: "GET", path: "/logout", expected_ctrl: "login", expected_act: "destroy" },
  { name: "Impersonation", verb: "GET", path: "/login_as/admin_user", expected_ctrl: "login", expected_act: "login_as" },
  { name: "Password lost form", verb: "GET", path: "/lost_pass", expected_ctrl: "login", expected_act: "lost_password" },
  { name: "Password reset form", verb: "GET", path: "/reset_password", expected_ctrl: "login", expected_act: "reset_password" },
  { name: "Subscribe", verb: "GET", path: "/users/subscribe/test_user", expected_ctrl: "users", expected_act: "subscribe" },
  { name: "Unsubscribe", verb: "GET", path: "/users/un-subscribe/test@example.com", expected_ctrl: "users", expected_act: "un_subscribe" }
]

deferred_cases.each do |c|
  res = route_set.match_request(c[:verb], c[:path])
  matched = res && res[:controller] == c[:expected_ctrl] && res[:action] == c[:expected_act]
  assert(matched, "Deferred confirmation case '#{c[:name]}' (#{c[:path]}) is preserved for coupled B02 unit", failures)
end

puts "\n=== Summary ==="
if failures.empty?
  puts "ALL CHECKS PASSED: ONTO-T-B02 first routing/verb slice is clean and verified."
  exit 0
else
  puts "#{failures.size} CHECK(S) FAILED:"
  failures.each { |f| puts " - #{f}" }
  exit 1
end
