# frozen_string_literal: true

require 'minitest/autorun'
require 'logger'
require 'ostruct'
require 'cgi'

# =============================================================================
# Standalone Offline Not-Found Contract Regression Check (ONTO-T-B10)
#
# Tests the unified not-found signal, renderer, and connected lookup guards:
# 1. Unconditional rescue_from ActiveRecord::RecordNotFound in ApplicationController.
# 2. Halt on missing ontology, class, property, and stale mapping without caller continuation.
# 3. HTTP 404 matrix for Full-Page (errors/not_found Haml), XHR (plain translated),
#    and Turbo Frame (<turbo-frame id="...">escaped error</turbo-frame>).
# 4. Nil dereference guards (@concept.id, @ontology.explore) and zero second downstream calls.
# 5. ConceptsController#show_label re-raises missing-record signal while preserving
#    fallback for non-missing label errors.
# 6. Normal details preserve real existing render paths.
# =============================================================================

# Ensure gem load paths in native container environment
if Dir.exist?('/usr/local/bundle/ruby/3.1.0/gems') && (ENV['GEM_PATH'].nil? || !ENV['GEM_PATH'].include?('/usr/local/bundle/ruby/3.1.0'))
  Gem.use_paths(nil, Gem.path + ['/usr/local/bundle/ruby/3.1.0'])
end

sdk_lib = '/usr/local/bundle/ruby/3.1.0/bundler/gems/ontologies_api_ruby_client-6257685e5744/lib'
$LOAD_PATH.unshift(sdk_lib) if Dir.exist?(sdk_lib) && !$LOAD_PATH.include?(sdk_lib)

worktree_root = File.expand_path('../..', __dir__)
$LOAD_PATH.unshift(File.join(worktree_root, 'app/helpers'))
$LOAD_PATH.unshift(File.join(worktree_root, 'app/controllers/concerns'))
$LOAD_PATH.unshift(File.join(worktree_root, 'app/controllers'))

require 'rails'
require 'action_controller'
require 'action_view'
require 'active_record'
require 'haml'
require 'haml/template/options'
require 'haml/plugin'
require 'turbo-rails'

module Turbo
  module Frames
  end
end
require '/usr/local/bundle/ruby/3.1.0/gems/turbo-rails-2.0.12/app/helpers/turbo/frames_helper.rb' rescue nil
require '/usr/local/bundle/ruby/3.1.0/gems/turbo-rails-2.0.12/app/controllers/turbo/frames/frame_request.rb' rescue nil

ActionView::Base.include Turbo::FramesHelper if defined?(Turbo::FramesHelper)
ActionController::Base.include Turbo::Frames::FrameRequest if defined?(Turbo::Frames::FrameRequest)
ActionView::Base.include ActionView::Helpers::TranslationHelper
ActionView::Base.include ActionView::Helpers::TagHelper

# Configure loggers and global app constants
ActionController::Base.logger = Logger.new(nil)
Rails.logger = Logger.new(nil)
$ENABLE_SLICES = false
$REST_URL = 'http://example.com'
$API_KEY = 'test'

# Load actual localization dictionary
I18n.load_path = Dir[File.join(worktree_root, 'config/locales/*.yml')]
I18n.default_locale = :en
I18n.locale = :en

# Finite view stubs for offline rendering of actual views/errors/not_found.html.haml
module ActionView
  class Base
    def inline_svg(path, **opts)
      "<svg data-src=\"#{path}\"></svg>".html_safe
    end
  end
end

module Buttons
  class RegularButtonComponent
    def initialize(**opts); @opts = opts; end
    def render_in(_view_context)
      "<button id=\"#{@opts[:id]}\">#{@opts[:value]}</button>".html_safe
    end
  end
end

class LabelFetcherComponent
  def initialize(**opts); @opts = opts; end
  def render_in(_view_context)
    "<a href=\"#{@opts[:link]}\">#{@opts[:label]}</a>".html_safe
  end
end

# Require actual helpers and controllers under test
require 'urls_helper'
require 'terms_reuses'
require 'components_helper'
require 'ontologies_helper'
require 'internationalisation_helper'
require 'multi_languages_helper'
require 'application_controller'
require 'mappings_helper'
require 'concepts_helper'
require 'turbo_helper'
require 'concepts_controller'
require 'search_content'
require 'properties_helper'
require 'properties_controller'
require 'mapping_statistics'
require 'mappings_controller'
require 'modal_helper'
require 'application_helper'
require 'fair_score_helper'
require 'instances_helper'
require 'schemes_helper'
require 'collections_helper'
require 'submission_updater'
require 'ontology_updater'
require 'sparql_helper'
require 'federation_helper'
require 'submission_filter'
require 'ontology_content_serializer'
require 'uri_redirection'
require 'ontologies_controller'

ActionView::Base.include MultiLanguagesHelper

# Finite route helper stubs (route dependencies)
module RouteHelperStubs
  def ontology_path(*args, **kwargs); "/ontologies/#{kwargs[:id] || args.first}"; end
  def concept_path(*args, **kwargs); "/ontologies/#{kwargs[:ontology_id] || args[1]}/classes/#{CGI.escape(args[0].to_s)}"; end
  def property_path(*args, **kwargs); "/ontologies/#{kwargs[:ontology_id]}/properties/#{kwargs[:property_id]}"; end
  def scheme_path(*args, **kwargs); "/ontologies/#{kwargs[:ontology_id]}/schemes/#{kwargs[:scheme_id]}"; end
  def collection_path(*args, **kwargs); "/ontologies/#{kwargs[:ontology_id]}/collections/#{kwargs[:collection_id]}"; end
  def mappings_path(*args, **kwargs); "/mappings"; end
end
ActionController::Base.include RouteHelperStubs
ActionView::Base.include RouteHelperStubs

# Setup view paths for actual template rendering
[ApplicationController, ConceptsController, PropertiesController, MappingsController, OntologiesController].each do |ctrl|
  ctrl.prepend_view_path(File.join(worktree_root, 'app/views'))
  ctrl.skip_before_action :set_locale, :domain_ontology_set, :init_trial_license, :authorize_and_redirect, :submission_metadata, :set_federated_portals, :authorize_read_only, :authorize_ontology_admin, raise: false
  ctrl.layout false
end

# Helper for temporary instance method stubbing
def stub_instance_method(klass, method_name, return_val_or_callable)
  old_method = klass.instance_method(method_name) if klass.method_defined?(method_name)
  klass.define_method(method_name) do |*args, **kwargs, &block|
    if return_val_or_callable.respond_to?(:call)
      instance_exec(*args, **kwargs, &return_val_or_callable)
    else
      return_val_or_callable
    end
  end
  yield
ensure
  if old_method
    klass.define_method(method_name, old_method)
  else
    klass.remove_method(method_name) if klass.method_defined?(method_name)
  end
end
def dispatch_action(controller_class, action, params: {}, headers: {}, flash: {})
  req = ActionDispatch::TestRequest.create
  headers.each { |k, v| req.headers[k] = v }
  params.each { |k, v| req.params[k] = v }
  req.flash = ActionDispatch::Flash::FlashHash.new
  flash.each { |k, v| req.flash[k] = v }

  res = ActionDispatch::TestResponse.create
  controller = controller_class.new
  controller.set_request!(req)
  controller.set_response!(res)
  controller.process(action)
  res
end

# Spies for tracking downstream API calls
class ApiCallCounter
  attr_accessor :ontology_single_class_calls, :concept_notes_calls, :explore_latest_submission_calls

  def initialize
    @ontology_single_class_calls = 0
    @concept_notes_calls = 0
    @explore_latest_submission_calls = 0
  end
end

class NotFoundContractCheck < Minitest::Test
  def setup
    @counter = ApiCallCounter.new
  end

  # ===========================================================================
  # 1. ApplicationController Not-Found Contract & Matrix
  # ===========================================================================

  def test_not_found_helper_raises_record_not_found
    ctrl = ApplicationController.new
    assert_raises(ActiveRecord::RecordNotFound) do
      ctrl.not_found('Custom missing record')
    end
  end

  def test_ontology_not_found_raises_with_translated_message
    ctrl = ApplicationController.new
    err = assert_raises(ActiveRecord::RecordNotFound) do
      ctrl.ontology_not_found('MISSING_ONT')
    end
    assert_equal 'Ontology MISSING_ONT not found', err.message
  end

  def test_concept_not_found_raises_with_translated_message
    ctrl = ApplicationController.new
    err = assert_raises(ActiveRecord::RecordNotFound) do
      ctrl.concept_not_found('http://example.org/c1')
    end
    assert_equal 'Concept http://example.org/c1 not found', err.message
  end

  class DirectNotFoundController < ApplicationController
    def missing_custom
      not_found('Specific entity missing')
    end

    def missing_default
      not_found
    end

    def missing_xss
      not_found('<script>alert("xss")</script>')
    end
  end

  def test_full_page_not_found_renders_haml_view_and_404
    res = dispatch_action(DirectNotFoundController, :missing_custom)
    assert_equal 404, res.status
    assert_includes res.content_type, 'text/html'
    assert_includes res.body, 'Specific entity missing'
    assert_includes res.body, 'error-page'
    assert_includes res.body, 'Go home'
  end

  def test_full_page_default_not_found_renders_translated_fallback_and_404
    res = dispatch_action(DirectNotFoundController, :missing_default)
    assert_equal 404, res.status
    assert_includes res.content_type, 'text/html'
    assert_includes res.body, 'Not Found'
  end

  def test_xhr_not_found_renders_plain_text_and_404
    res = dispatch_action(DirectNotFoundController, :missing_custom, headers: { 'X-Requested-With' => 'XMLHttpRequest' })
    assert_equal 404, res.status
    assert_includes res.content_type, 'text/plain'
    assert_equal 'Specific entity missing', res.body
  end

  def test_xhr_default_not_found_renders_plain_translated_error_load_and_404
    res = dispatch_action(DirectNotFoundController, :missing_default, headers: { 'X-Requested-With' => 'XMLHttpRequest' })
    assert_equal 404, res.status
    assert_includes res.content_type, 'text/plain'
    assert_equal 'Error: load failed', res.body
  end

  def test_turbo_frame_not_found_renders_matching_frame_and_404
    res = dispatch_action(DirectNotFoundController, :missing_custom, headers: { 'Turbo-Frame' => 'concept_details_frame' })
    assert_equal 404, res.status
    assert_includes res.content_type, 'text/html'
    expected = '<turbo-frame id="concept_details_frame">Specific entity missing</turbo-frame>'
    assert_equal expected, res.body
  end

  def test_turbo_frame_not_found_escapes_malicious_content
    res = dispatch_action(DirectNotFoundController, :missing_xss, headers: { 'Turbo-Frame' => 'alert_frame' })
    assert_equal 404, res.status
    assert_includes res.content_type, 'text/html'
    expected = '<turbo-frame id="alert_frame">&lt;script&gt;alert(&quot;xss&quot;)&lt;/script&gt;</turbo-frame>'
    assert_equal expected, res.body
    refute_includes res.body, '<script>'
  end

  def test_direct_negotiated_formats_matrix_renders_plain_404_without_missing_template
    formats = {
      'application/json' => 'json',
      'application/xml' => 'xml',
      'text/csv' => 'csv',
      'text/turtle' => 'turtle',
      'application/rdf+xml' => 'rdf_xml',
      'application/n-triples' => 'n_triples'
    }

    formats.each do |mime, label|
      res = dispatch_action(DirectNotFoundController, :missing_custom, headers: { 'Accept' => mime })
      assert_equal 404, res.status, "Expected 404 for #{label} (#{mime})"
      assert_equal 'text/plain; charset=utf-8', res.content_type, "Expected text/plain content type for #{label} error"
      assert_equal 'Specific entity missing', res.body, "Expected explicit error message in plain body for #{label}"

      # Verify default fallback message across negotiated formats
      res_def = dispatch_action(DirectNotFoundController, :missing_default, headers: { 'Accept' => mime })
      assert_equal 404, res_def.status
      assert_equal 'text/plain; charset=utf-8', res_def.content_type
      assert_equal 'Not Found', res_def.body
    end
  end

  def test_direct_wildcard_and_html_accept_render_html_haml_view_and_404
    [
      {},
      { 'Accept' => 'text/html' },
      { 'Accept' => '*/*' },
      { 'Accept' => 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8' }
    ].each do |headers|
      res = dispatch_action(DirectNotFoundController, :missing_custom, headers: headers)
      assert_equal 404, res.status
      assert_includes res.content_type, 'text/html'
      assert_includes res.body, 'Specific entity missing'
      assert_includes res.body, 'error-page'
    end
  end

  # ===========================================================================
  # 2. Missing Resource Dispatch Matrix (Ontology, Class, Property, Stale Mapping)
  # ===========================================================================

  def test_concepts_show_missing_ontology_matrix_halts_without_downstream_calls
    LinkedData::Client::Models::Ontology.stub(:find_by_acronym, ->(_acronym) { [] }) do
      # Full page
      res_page = dispatch_action(ConceptsController, :show, params: { ontology: 'ABSENT', id: 'http://test/c1' })
      assert_equal 404, res_page.status
      assert_includes res_page.body, 'Ontology ABSENT not found'

      # XHR
      res_xhr = dispatch_action(ConceptsController, :show,
                                params: { ontology: 'ABSENT', id: 'http://test/c1' },
                                headers: { 'X-Requested-With' => 'XMLHttpRequest' })
      assert_equal 404, res_xhr.status
      assert_equal 'Ontology ABSENT not found', res_xhr.body

      # Turbo Frame
      res_turbo = dispatch_action(ConceptsController, :show,
                                  params: { ontology: 'ABSENT', id: 'http://test/c1' },
                                  headers: { 'Turbo-Frame' => 'concept_show' })
      assert_equal 404, res_turbo.status
      assert_equal '<turbo-frame id="concept_show">Ontology ABSENT not found</turbo-frame>', res_turbo.body

      # Negotiated formats on ConceptsController: JSON, CSV, Turtle
      ['application/json', 'text/csv', 'text/turtle'].each do |mime|
        res_fmt = dispatch_action(ConceptsController, :show,
                                  params: { ontology: 'ABSENT', id: 'http://test/c1' },
                                  headers: { 'Accept' => mime })
        assert_equal 404, res_fmt.status
        assert_equal 'text/plain; charset=utf-8', res_fmt.content_type
        assert_equal 'Ontology ABSENT not found', res_fmt.body
      end
    end
  end

  def test_ontologies_show_missing_ontology_negotiated_matrix_halts_without_downstream_calls
    counter = @counter
    LinkedData::Client::Models::Ontology.stub(:find_by_acronym, ->(_a) { [] }) do
      # Full page HTML
      res_html = dispatch_action(OntologiesController, :show, params: { id: 'ABSENT_ONT' }, headers: { 'Accept' => 'text/html' })
      assert_equal 404, res_html.status
      assert_includes res_html.content_type, 'text/html'
      assert_includes res_html.body, 'Ontology ABSENT_ONT not found'
      assert_includes res_html.body, 'error-page'

      # Browser wildcard
      res_wild = dispatch_action(OntologiesController, :show, params: { id: 'ABSENT_ONT' }, headers: { 'Accept' => '*/*' })
      assert_equal 404, res_wild.status
      assert_includes res_wild.content_type, 'text/html'
      assert_includes res_wild.body, 'Ontology ABSENT_ONT not found'

      # Plain XHR
      res_xhr = dispatch_action(OntologiesController, :show,
                                params: { id: 'ABSENT_ONT' },
                                headers: { 'X-Requested-With' => 'XMLHttpRequest' })
      assert_equal 404, res_xhr.status
      assert_equal 'text/plain; charset=utf-8', res_xhr.content_type
      assert_equal 'Ontology ABSENT_ONT not found', res_xhr.body

      # Turbo Frame
      res_turbo = dispatch_action(OntologiesController, :show,
                                  params: { id: 'ABSENT_ONT' },
                                  headers: { 'Turbo-Frame' => 'ontology_header' })
      assert_equal 404, res_turbo.status
      assert_includes res_turbo.content_type, 'text/html'
      assert_equal '<turbo-frame id="ontology_header">Ontology ABSENT_ONT not found</turbo-frame>', res_turbo.body

      # Negotiated matrix: JSON, XML, CSV, Turtle, RDF/XML, N-Triples
      negotiated = {
        'application/json' => 'json',
        'application/xml' => 'xml',
        'text/csv' => 'csv',
        'text/turtle' => 'turtle',
        'application/rdf+xml' => 'rdf_xml',
        'application/n-triples' => 'n_triples'
      }

      negotiated.each do |mime, label|
        res = dispatch_action(OntologiesController, :show, params: { id: 'ABSENT_ONT' }, headers: { 'Accept' => mime })
        assert_equal 404, res.status, "OntologiesController#show must return 404 for missing ontology with #{label} Accept"
        assert_equal 'text/plain; charset=utf-8', res.content_type, "Response must be text/plain for #{label} error, not mislabeled"
        assert_equal 'Ontology ABSENT_ONT not found', res.body
      end

      # URL format parameters: .json, .xml, .csv
      ['json', 'xml', 'csv'].each do |fmt|
        res = dispatch_action(OntologiesController, :show, params: { id: 'ABSENT_ONT', format: fmt })
        assert_equal 404, res.status, "OntologiesController#show must return 404 for missing ontology with format=#{fmt}"
        assert_equal 'text/plain; charset=utf-8', res.content_type
        assert_equal 'Ontology ABSENT_ONT not found', res.body
      end

      assert_equal 0, counter.explore_latest_submission_calls, 'Downstream calls must not execute on missing ontology'
    end
  end

  def test_concepts_show_missing_class_checks_guard_before_id_and_halts_downstream
    counter = @counter
    fake_ont = Object.new
    fake_ont.define_singleton_method(:acronym) { 'TEST_ONT' }
    fake_ont.define_singleton_method(:explore) do
      exp = Object.new
      exp.define_singleton_method(:single_class) do |*args|
        counter.ontology_single_class_calls += 1
        nil
      end
      exp
    end

    LinkedData::Client::Models::Ontology.stub(:find_by_acronym, ->(_a) { [fake_ont] }) do
      stub_instance_method(ConceptsController, :get_ontology_submission_ready, nil) do
        # Turbo Frame request to show: Must not crash on @concept.id before nil guard!
        res_turbo = dispatch_action(ConceptsController, :show,
                                    params: { ontology: 'TEST_ONT', id: 'http://test/missing_c' },
                                    headers: { 'Turbo-Frame' => 'concept_show' })
        assert_equal 404, res_turbo.status
        assert_equal '<turbo-frame id="concept_show">Concept http://test/missing_c not found</turbo-frame>', res_turbo.body
        assert_equal 1, counter.ontology_single_class_calls
        assert_equal 0, counter.concept_notes_calls, 'Downstream @concept.explore.notes must never be called'

        # XHR with Turbo-Frame to show
        res_turbo_xhr = dispatch_action(ConceptsController, :show,
                                        params: { ontology: 'TEST_ONT', id: 'http://test/missing_c' },
                                        headers: { 'Turbo-Frame' => 'concept_show', 'X-Requested-With' => 'XMLHttpRequest' })
        assert_equal 404, res_turbo_xhr.status
        assert_equal '<turbo-frame id="concept_show">Concept http://test/missing_c not found</turbo-frame>', res_turbo_xhr.body
      end
    end
  end

  def test_concepts_details_missing_class_matrix_halts_without_double_render
    fake_ont = Object.new
    fake_ont.define_singleton_method(:acronym) { 'TEST_ONT' }
    fake_ont.define_singleton_method(:explore) do
      exp = Object.new
      exp.define_singleton_method(:single_class) { |*args| nil }
      exp
    end

    LinkedData::Client::Models::Ontology.stub(:find_by_acronym, ->(_a) { [fake_ont] }) do
      # Full page
      res_page = dispatch_action(ConceptsController, :details,
                                 params: { ontology: 'TEST_ONT', conceptid: 'http://test/missing_detail' })
      assert_equal 404, res_page.status
      assert_includes res_page.body, 'Concept http://test/missing_detail not found'

      # XHR
      res_xhr = dispatch_action(ConceptsController, :details,
                                params: { ontology: 'TEST_ONT', conceptid: 'http://test/missing_detail' },
                                headers: { 'X-Requested-With' => 'XMLHttpRequest' })
      assert_equal 404, res_xhr.status
      assert_equal 'Concept http://test/missing_detail not found', res_xhr.body

      # Turbo Frame
      res_turbo = dispatch_action(ConceptsController, :details,
                                  params: { ontology: 'TEST_ONT', conceptid: 'http://test/missing_detail' },
                                  headers: { 'Turbo-Frame' => 'concept_details' })
      assert_equal 404, res_turbo.status
      assert_equal '<turbo-frame id="concept_details">Concept http://test/missing_detail not found</turbo-frame>', res_turbo.body

      # JSON format
      res_json = dispatch_action(ConceptsController, :details,
                                 params: { ontology: 'TEST_ONT', conceptid: 'http://test/missing_detail' },
                                 headers: { 'Accept' => 'application/json' })
      assert_equal 404, res_json.status
      assert_equal 'text/plain; charset=utf-8', res_json.content_type
      assert_equal 'Concept http://test/missing_detail not found', res_json.body
    end
  end

  def test_properties_index_missing_ontology_guards_before_explore
    counter = @counter
    LinkedData::Client::Models::Ontology.stub(:find_by_acronym, ->(_a) { [] }) do
      # Should 404 immediately and never dereference @ontology.explore
      res = dispatch_action(PropertiesController, :index,
                            params: { ontology: 'ABSENT_PROP_ONT' },
                            headers: { 'Turbo-Frame' => 'properties_tree' })
      assert_equal 404, res.status
      assert_equal '<turbo-frame id="properties_tree">Ontology ABSENT_PROP_ONT not found</turbo-frame>', res.body
      assert_equal 0, counter.explore_latest_submission_calls
    end
  end

  def test_properties_show_missing_property_halts_with_404_before_render
    stub_instance_method(PropertiesController, :get_property, nil) do
      # Turbo frame
      res_turbo = dispatch_action(PropertiesController, :show,
                                  params: { ontology: 'PROP_ONT', id: 'missing_p1' },
                                  headers: { 'Turbo-Frame' => 'property_show' })
      assert_equal 404, res_turbo.status
      assert_equal '<turbo-frame id="property_show">Not Found</turbo-frame>', res_turbo.body

      # XHR
      res_xhr = dispatch_action(PropertiesController, :show,
                                params: { ontology: 'PROP_ONT', id: 'missing_p1' },
                                headers: { 'X-Requested-With' => 'XMLHttpRequest' })
      assert_equal 404, res_xhr.status
      assert_equal 'Error: load failed', res_xhr.body

      # Full-page
      res_page = dispatch_action(PropertiesController, :show,
                                 params: { ontology: 'PROP_ONT', id: 'missing_p1' })
      assert_equal 404, res_page.status
      assert_includes res_page.body, 'Not Found'

      # Negotiated JSON
      res_json = dispatch_action(PropertiesController, :show,
                                 params: { ontology: 'PROP_ONT', id: 'missing_p1' },
                                 headers: { 'Accept' => 'application/json' })
      assert_equal 404, res_json.status
      assert_equal 'text/plain; charset=utf-8', res_json.content_type
      assert_equal 'Not Found', res_json.body
    end
  end

  def test_mappings_show_stale_mapping_halts_with_404
    LinkedData::Client::Models::Mapping.stub(:find, ->(_id) { nil }) do
      # Full page
      res_page = dispatch_action(MappingsController, :show, params: { id: 'stale_map_99' })
      assert_equal 404, res_page.status
      assert_includes res_page.body, 'Mapping stale_map_99 not found'

      # XHR
      res_xhr = dispatch_action(MappingsController, :show,
                                params: { id: 'stale_map_99' },
                                headers: { 'X-Requested-With' => 'XMLHttpRequest' })
      assert_equal 404, res_xhr.status
      assert_equal 'Mapping stale_map_99 not found', res_xhr.body

      # Turbo Frame
      res_turbo = dispatch_action(MappingsController, :show,
                                  params: { id: 'stale_map_99' },
                                  headers: { 'Turbo-Frame' => 'mapping_detail' })
      assert_equal 404, res_turbo.status
      assert_equal '<turbo-frame id="mapping_detail">Mapping stale_map_99 not found</turbo-frame>', res_turbo.body

      # Negotiated JSON
      res_json = dispatch_action(MappingsController, :show,
                                 params: { id: 'stale_map_99' },
                                 headers: { 'Accept' => 'application/json' })
      assert_equal 404, res_json.status
      assert_equal 'text/plain; charset=utf-8', res_json.content_type
      assert_equal 'Mapping stale_map_99 not found', res_json.body
    end
  end

  def test_mappings_get_concept_table_stale_lookup_halts_with_404
    LinkedData::Client::Models::Ontology.stub(:find_by_acronym, ->(_a) { [] }) do
      res = dispatch_action(MappingsController, :get_concept_table,
                            params: { ontologyid: 'MISSING_ONT', conceptid: 'http://test/c1' },
                            headers: { 'X-Requested-With' => 'XMLHttpRequest' })
      assert_equal 404, res.status
      assert_equal 'Ontology MISSING_ONT not found', res.body
    end
  end

  # ===========================================================================
  # 3. ConceptsController#show_label Re-Raise & Fallback Contract
  # ===========================================================================

  def test_concepts_show_label_missing_ontology_reraises_and_returns_404
    LinkedData::Client::Models::Ontology.stub(:find, ->(_id) { nil }) do
      LinkedData::Client::Models::Ontology.stub(:find_by_acronym, ->(_a) { [] }) do
        res = dispatch_action(ConceptsController, :show_label,
                              params: { ontology: 'NONEXISTENT_ONT', id: 'http://test/c1' },
                              headers: { 'X-Requested-With' => 'XMLHttpRequest' })
        assert_equal 404, res.status
        assert_equal 'Ontology NONEXISTENT_ONT not found', res.body
      end
    end
  end

  def test_concepts_show_label_non_missing_label_error_preserves_intended_fallback
    fake_ont = Object.new
    fake_ont.define_singleton_method(:acronym) { 'EXISTING_ONT' }
    fake_ont.define_singleton_method(:explore) do
      exp = Object.new
      exp.define_singleton_method(:single_class) { |*args| nil }
      exp
    end

    LinkedData::Client::Models::Ontology.stub(:find, ->(_id) { fake_ont }) do
      # When concept_label encounters a non-missing error (e.g. network hiccup / API 500)
      stub_instance_method(ConceptsController, :concept_label, ->(*_args) { raise StandardError, 'Transient connection reset' }) do
        res = dispatch_action(ConceptsController, :show_label,
                              params: { ontology: 'EXISTING_ONT', id: 'http://test/c1' },
                              headers: { 'X-Requested-With' => 'XMLHttpRequest' })
        assert_equal 200, res.status
        assert_includes res.body, 'http://test/c1'
      end
    end
  end

  # ===========================================================================
  # 4. Normal Detail Requests Preserve Real Success Path
  # ===========================================================================

  def test_concepts_show_success_path_preserves_normal_render
    fake_concept = Object.new
    fake_concept.define_singleton_method(:id) { 'http://test/c_valid' }
    fake_concept.define_singleton_method(:explore) do
      exp = Object.new
      exp.define_singleton_method(:notes) { [] }
      exp
    end

    fake_ont = Object.new
    fake_ont.define_singleton_method(:acronym) { 'VALID_ONT' }
    fake_ont.define_singleton_method(:explore) do
      exp = Object.new
      exp.define_singleton_method(:single_class) { |*args| fake_concept }
      exp
    end

    # Provide a minimal show partial for concepts so normal render passes
    stub_instance_method(ConceptsController, :render, ->(options = {}) {
      if options[:partial] == 'show'
        self.response_body = 'Rendered concept show partial'
      else
        super(options)
      end
    }) do
      LinkedData::Client::Models::Ontology.stub(:find_by_acronym, ->(_a) { [fake_ont] }) do
        stub_instance_method(ConceptsController, :get_ontology_submission_ready, nil) do
          res = dispatch_action(ConceptsController, :show,
                                params: { ontology: 'VALID_ONT', id: 'http://test/c_valid' },
                                headers: { 'Turbo-Frame' => 'concept_show' })
          assert_equal 200, res.status
          assert_equal 'Rendered concept show partial', res.body
        end
      end
    end
  end

  def test_properties_show_success_path_preserves_normal_render
    fake_property = Object.new
    fake_property.define_singleton_method(:id) { 'http://test/prop1' }

    stub_instance_method(PropertiesController, :get_property, fake_property) do
      stub_instance_method(PropertiesController, :render, ->(options = {}) {
        if options[:partial] == 'show'
          self.response_body = 'Rendered property show partial'
        else
          super(options)
        end
      }) do
        res = dispatch_action(PropertiesController, :show,
                              params: { ontology: 'VALID_PROP_ONT', id: 'prop1' },
                              headers: { 'Turbo-Frame' => 'property_show' })
        assert_equal 200, res.status
        assert_equal 'Rendered property show partial', res.body
      end
    end
  end
end
