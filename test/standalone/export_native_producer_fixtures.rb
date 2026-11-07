# frozen_string_literal: true

# =============================================================================
# Standalone Native Producer Fixture Exporter (ONTO-T-J02)
#
# Executes actual loaded Rails SearchController#json_search ActionDispatch
# under frozen Ruby 3.1.7 and exports genuine response status, contentType,
# and BODY without minitest execution or manual JSON.stringify serialization.
# =============================================================================

require 'ostruct'
require 'uri'
require 'json'
require 'cgi'

if Dir.exist?('/usr/local/bundle/ruby/3.1.0/gems') && (ENV['GEM_PATH'].nil? || !ENV['GEM_PATH'].include?('/usr/local/bundle/ruby/3.1.0'))
  Gem.use_paths(nil, Gem.path + ['/usr/local/bundle/ruby/3.1.0'])
end

require 'rails'
require 'active_support/all'
require 'action_controller'
require 'action_view'
require 'action_dispatch'

class ApplicationController < ActionController::Base
  def self.skip_before_action(*); end
  def determine_layout; false; end
  def t(key, **); key; end
  def helpers; self; end
  def request_lang; 'en'; end
  def escape(val); URI.encode_www_form_component(val.to_s); end
  def link_last_part(url); url.to_s.split('/').last; end
end

module OntologiesHelper; end
module ComponentsHelper; end
module UrlsHelper; end
module FederationHelper
  def federated_request?; false; end
  def class_federation_configuration(*); {}; end
end
module SearchContent; end

module LinkedData
  module Client
    module Models
      class Class
        def self.search(*); end
      end
      class Ontology
        def self.all(*); []; end
      end
    end
  end
end

require_relative '../../app/helpers/multi_languages_helper'
require_relative '../../app/controllers/concerns/search_aggregator'
require_relative '../../app/controllers/search_controller'

class MockClassResult < OpenStruct
  def [](k)
    k == '@id' ? id : super
  end

  def obsolete?
    !!self[:obsolete]
  end
end

def build_mock_class(id:, pref_label:, obsolete: false, synonyms: [], definition: [])
  MockClassResult.new(
    id: id,
    prefLabel: pref_label,
    links: { 'ontology' => 'http://data.bioontology.org/ontologies/TEST' },
    obsolete: obsolete,
    synonym: synonyms,
    definition: definition
  )
end

def dispatch_native(query_string_or_path, class_results = [])
  ctrl = SearchController.new
  env = ActionDispatch::TestRequest.create.env
  uri = URI.parse(query_string_or_path.start_with?('/') ? query_string_or_path : "/search/json_search?#{query_string_or_path}")
  env['PATH_INFO'] = uri.path
  env['QUERY_STRING'] = uri.query || ''
  if uri.path =~ %r{\A/search/json_search/(.+)\z}
    id_param = Regexp.last_match(1)
    env['action_dispatch.request.path_parameters'] = { controller: 'search', action: 'json_search', id: id_param }
  end
  req = ActionDispatch::Request.new(env)
  res = ActionDispatch::Response.new

  singleton = class << LinkedData::Client::Models::Class; self; end
  orig_method = singleton.instance_method(:search)
  singleton.send(:define_method, :search) do |_query, _params|
    OpenStruct.new(collection: class_results)
  end

  begin
    ctrl.dispatch(:json_search, req, res)
  ensure
    singleton.send(:define_method, :search, orig_method)
  end

  {
    status: res.status,
    contentType: res.content_type,
    body: res.body
  }
end

cls_complex = build_mock_class(
  id: 'http://example.org/test#Complex\\Cat"1"',
  pref_label: 'Complex | "Cat" \\ \n 🌍 ~!~',
  synonyms: ['Syn | 1', 'Syn "2"'],
  definition: ['Def | 1', 'Def ~!~ 2']
)

cls_legacy = build_mock_class(
  id: 'http://example.org/test#Cat',
  pref_label: 'Cat Concept',
  synonyms: ['Syn1', 'Syn2'],
  definition: ['Def']
)

cls_obsolete = build_mock_class(
  id: 'http://example.org/test#OldCat',
  pref_label: 'OldCat',
  obsolete: true,
  synonyms: ['OldSyn'],
  definition: ['OldDef']
)

cls_probe = build_mock_class(
  id: 'http://example.org/test#XSS',
  pref_label: '<script>window.__xssTriggered.push("probe_fail")</script><b id="injected_dom">Injected</b>',
  synonyms: ['SynXSS'],
  definition: ['DefXSS']
)

fixtures = {
  rows_single: dispatch_native('/search/json_search/TEST?q=cat&response=rows', [cls_complex, cls_obsolete]),
  rows_all: dispatch_native('/search/json_search?q=cat&response=rows', [cls_complex, cls_obsolete]),
  rows_empty: dispatch_native('/search/json_search/TEST?q=nomatch&response=rows', []),
  rows_xss_probe: dispatch_native('/search/json_search?q=probe&response=rows', [cls_probe]),
  legacy_text: dispatch_native('/search/json_search?q=cat', [cls_legacy, cls_obsolete]),
  legacy_jsonp: dispatch_native('/search/json_search?q=cat&response=json&callback=PORTAL_JSONP_CALLBACK', [cls_legacy, cls_obsolete]),
  legacy_empty_text: dispatch_native('/search/json_search?q=nomatch', []),
  legacy_empty_jsonp: dispatch_native('/search/json_search?q=nomatch&response=json&callback=PORTAL_JSONP_CALLBACK', [])
}

puts JSON.pretty_generate(fixtures)
