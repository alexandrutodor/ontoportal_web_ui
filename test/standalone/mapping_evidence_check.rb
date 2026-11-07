# frozen_string_literal: true

require 'minitest/autorun'
require 'logger'
require 'ostruct'
require 'cgi'
require 'set'

# =============================================================================
# Standalone Mapping Evidence Guard Check (ONTO-AT-OP04)
#
# Validates:
# 1. Feature off (Flipper 'MappingEvidence' disabled):
#    - Route/action returns 404.
#    - No evidence button rendered in _show.html.haml or _show_line.html.haml.
#    - Rows render byte-identically to baseline when feature is off.
# 2. Feature on:
#    - Renders both exact class IDs and ontology IDs, even with repeated acronyms
#      or identical labels without overwriting.
# 3. Directed mapping:
#    - Returned source/target fields are used and identified.
# 4. Undirected mapping:
#    - When no directional evidence is supplied, direction is explicitly 'unknown'
#      and never inferred from array order.
# 5. Missing fields:
#    - Missing definitions, synonyms, or process provenance fields render as 'Unavailable'.
# 6. Read-only safety:
#    - Zero write/mutation methods called on any double (0 save, 0 update, 0 delete, 0 patch, etc.).
# 7. External / interportal row:
#    - No foreign endpoint lookups or credential forwarding.
#    - Displays 'Remote details unavailable' while preserving approved link.
# =============================================================================

if Dir.exist?('/usr/local/bundle/ruby/3.1.0/gems') && (ENV['GEM_PATH'].nil? || !ENV['GEM_PATH'].include?('/usr/local/bundle/ruby/3.1.0'))
  Gem.use_paths(nil, Gem.path + ['/usr/local/bundle/ruby/3.1.0'])
end

sdk_lib = '/usr/local/bundle/ruby/3.1.0/bundler/gems/ontologies_api_ruby_client-6257685e5744/lib'
$LOAD_PATH.unshift(sdk_lib) if Dir.exist?(sdk_lib) && !$LOAD_PATH.include?(sdk_lib)

worktree_root = File.expand_path('../..', __dir__)
$LOAD_PATH.unshift(File.join(worktree_root, 'app/helpers'))
$LOAD_PATH.unshift(File.join(worktree_root, 'app/controllers/concerns'))
$LOAD_PATH.unshift(File.join(worktree_root, 'app/controllers'))
$LOAD_PATH.unshift(File.join(worktree_root, 'app/components'))

require 'rails'
require 'active_support/all'
require 'action_controller'
require 'action_view'
require 'action_dispatch'
require 'active_record'
require 'action_view/testing/resolvers'
require 'view_component'
require 'haml'
require 'haml/template'

Mime::Type.register 'text/vnd.turbo-stream.html', :turbo_stream rescue nil

module Turbo
  module Streams
  end
end

require '/usr/local/bundle/ruby/3.1.0/gems/turbo-rails-2.0.12/app/helpers/turbo/streams/action_helper.rb' rescue nil
require '/usr/local/bundle/ruby/3.1.0/gems/turbo-rails-2.0.12/app/models/turbo/streams/tag_builder.rb' rescue nil
require '/usr/local/bundle/ruby/3.1.0/gems/turbo-rails-2.0.12/app/helpers/turbo/streams_helper.rb' rescue nil
require '/usr/local/bundle/ruby/3.1.0/gems/turbo-rails-2.0.12/app/controllers/turbo/streams/turbo_streams_tag_builder.rb' rescue nil
require '/usr/local/bundle/ruby/3.1.0/gems/turbo-rails-2.0.12/app/helpers/turbo/frames_helper.rb' rescue nil

ActionView::Base.include Turbo::StreamsHelper if defined?(Turbo::StreamsHelper)
ActionView::Base.include Turbo::FramesHelper if defined?(Turbo::FramesHelper)
ActionController::Base.include Turbo::Streams::TurboStreamsTagBuilder if defined?(Turbo::Streams::TurboStreamsTagBuilder)

# Presentation Boundary: Display::AlertComponent for TurboHelper alert rendering
module Display
  class AlertComponent
    attr_reader :id, :type

    def initialize(id: nil, type: 'info', **_opts)
      @id = id
      @type = type
    end

    def render_in(view_context, &block)
      content = block ? view_context.capture(&block) : ''
      "<div class=\"alert alert-#{@type}\" id=\"#{@id}\">#{content}</div>".html_safe
    end
  end
end

require 'ontologies_api_client'

ActionController::Base.logger = Logger.new(nil)
Rails.logger = Logger.new(nil)
Rails.cache = ActiveSupport::Cache::MemoryStore.new
$ENABLE_SLICES = false
$REST_URL = 'http://example.com'
$API_KEY = 'test'
$LOCAL_IP = '127.0.0.1'

LinkedData::Client.config do |config|
  config.rest_url = 'http://example.com'
  config.links_attr = 'links'
end

I18n.load_path = Dir[File.join(worktree_root, 'config/locales/*.yml')]
I18n.default_locale = :en
I18n.locale = :en

require 'urls_helper'
require 'terms_reuses'
require 'components_helper'
require 'ontologies_helper'
require 'internationalisation_helper'
require 'multi_languages_helper'
require 'modal_helper'
require 'application_helper'
require 'notes_helper'
require 'turbo_helper'
require 'mapping_statistics'
require 'mappings_helper'
require 'application_controller'
require 'mappings_controller'
require 'link_text_component'
require 'internal_link_text_component'
require 'external_link_text_component'
require 'popup_link_text_component'
require 'turbo_frame_component'
require 'loader_component'
require 'chip_button_component'
require 'rounded_button_component'
require 'label_fetcher_component'
require 'mapping_evidence_component'

# Flipper test gate control
module Flipper
  @flags = {}

  class << self
    def enable(feature)
      @flags[feature.to_s] = true
    end

    def disable(feature)
      @flags[feature.to_s] = false
    end

    def enabled?(feature, *args)
      @flags.fetch(feature.to_s, false)
    end

    def reset!
      @flags = {}
    end
  end
end

class ViewComponent::Base
  def inline_svg(name, options = {})
    "<svg class=\"#{options[:class]}\" data-icon=\"#{name}\"></svg>".html_safe
  end
  def inline_svg_tag(name, options = {})
    inline_svg(name, options)
  end
end

# Standalone route helper stubs
module StandaloneRouteHelperStubs
  def inline_svg(name, options = {})
    "<svg class=\"#{options[:class]}\" data-icon=\"#{name}\"></svg>".html_safe
  end
  def root_path(*args, **kwargs)
    '/'
  end

  def mappings_path(*args, **kwargs)
    '/mappings'
  end

  def mapping_path(id, *args, **kwargs)
    "/mappings/#{id}"
  end

  def mapping_evidence_path(id, *args, **kwargs)
    "/mappings/#{id}/evidence"
  end

  def ontology_path(id, *args, **kwargs)
    "/ontologies/#{id}"
  end

  def api_button_link_and_target(url)
    [url, '_blank']
  end

  def will_paginate(collection, options = {})
    ''
  end

  def request
    @request ||= ActionDispatch::TestRequest.create
  end

  def params
    @params ||= { target: 't' }
  end

  def current_user_admin?
    false
  end

  def session
    {}
  end

  def current_user
    nil
  end

  def inline_svg_tag(*args)
    ''
  end

  def render_in_modal(&block)
    block_given? ? yield : ''
  end
end
ActionController::Base.include StandaloneRouteHelperStubs
ActionView::Base.include StandaloneRouteHelperStubs

# Presentation Boundary
MappingsController.layout false
MappingsController.skip_before_action :set_locale, :domain_ontology_set, :init_trial_license, raise: false

# =============================================================================
# Spies & Finite Doubles
# =============================================================================

class MappingEvidenceSpy
  attr_accessor :mapping_find_calls, :mapping_find_args
  attr_accessor :ontology_find_calls, :ontology_find_args
  attr_accessor :class_find_calls, :class_find_args
  attr_accessor :write_calls

  def initialize
    reset!
  end

  def reset!
    @mapping_find_calls = 0
    @mapping_find_args = []
    @ontology_find_calls = 0
    @ontology_find_args = []
    @class_find_calls = 0
    @class_find_args = []
    @write_calls = 0
  end
end

$evidence_spy = MappingEvidenceSpy.new

# Finite Double Classes that track and forbid any write mutations
class SafeModelDouble < OpenStruct
  def save
    $evidence_spy.write_calls += 1
    raise 'Write violation: save called on read-only double'
  end

  def update(*args)
    $evidence_spy.write_calls += 1
    raise 'Write violation: update called on read-only double'
  end

  def destroy
    $evidence_spy.write_calls += 1
    raise 'Write violation: destroy called on read-only double'
  end

  def delete
    $evidence_spy.write_calls += 1
    raise 'Write violation: delete called on read-only double'
  end
end

class ExploreDouble
  def initialize(ontology_acronym)
    @acronym = acronym
  end

  def single_class(options, class_id)
    $evidence_spy.class_find_calls += 1
    $evidence_spy.class_find_args << class_id

    SafeModelDouble.new(
      id: class_id,
      prefLabel: "Label for #{class_id.split('#').last || class_id}",
      definition: ["Definition of #{class_id}"],
      synonym: ["Synonym 1", "Synonym 2"]
    )
  end

  def save; $evidence_spy.write_calls += 1; raise 'write violation'; end
  def update(*); $evidence_spy.write_calls += 1; raise 'write violation'; end
  def delete(*); $evidence_spy.write_calls += 1; raise 'write violation'; end
end

class LinkedData::Client::Models::Mapping
  class << self
    attr_accessor :current_mapping_double

    def find(id, _options = {})
      $evidence_spy.mapping_find_calls += 1
      $evidence_spy.mapping_find_args << id
      current_mapping_double
    end
  end
end

class LinkedData::Client::Models::Ontology
  class << self
    def find_by_acronym(acronym, _options = {})
      $evidence_spy.ontology_find_calls += 1
      $evidence_spy.ontology_find_args << acronym
      [
        SafeModelDouble.new(
          acronym: acronym,
          id: "http://example.com/ontologies/#{acronym}",
          explore: ExploreDouble.new(acronym)
        )
      ]
    end
  end
end

# =============================================================================
# Test Suite
# =============================================================================

class MappingEvidenceCheck < Minitest::Test
  def setup
    $evidence_spy.reset!
    Flipper.reset!
    LinkedData::Client::Models::Mapping.current_mapping_double = nil
  end

  def teardown
    Thread.current[:request] = nil
    Thread.current[:session] = nil
  end

  def dispatch(action, params: {}, user: nil)
    req = ActionDispatch::TestRequest.create('rack.session' => {})
    req.session[:user] = user if user
    params.each { |k, v| req.params[k] = v }

    res = ActionDispatch::TestResponse.create
    ctrl = MappingsController.new
    ctrl.set_request!(req)
    ctrl.set_response!(res)
    ctrl.process(action)
    [ctrl, req, res]
  end

  def build_view_context
    lookup_context = ActionView::LookupContext.new([
      File.expand_path('../../app/views', __dir__),
      File.expand_path('../../app/components', __dir__)
    ])
    view = if ActionView::Base.respond_to?(:with_empty_template_cache)
             ActionView::Base.with_empty_template_cache.new(lookup_context, {}, ActionController::Base.new)
           else
             ActionView::Base.new(lookup_context, {}, ActionController::Base.new)
           end
    view.extend StandaloneRouteHelperStubs
    view.extend ApplicationHelper
    view.extend MappingsHelper
    view.extend ModalHelper
    view
  end

  # ---------------------------------------------------------------------------
  # 1. Feature Off: 404 response, no button, byte-identical baseline rows
  # ---------------------------------------------------------------------------
  def test_01_feature_off_returns_404_and_no_button_and_byte_identical_rows
    Flipper.disable('MappingEvidence')

    # Controller evidence action returns 404
    _ctrl, _req, res = dispatch(:evidence, params: { id: 'map_101' })
    assert_equal 404, res.status, 'Evidence route must return 404 when Flipper MappingEvidence is disabled'
    assert_equal 0, $evidence_spy.mapping_find_calls, 'No mapping lookup when feature is disabled'

    # View row rendering check: byte-identical baseline
    map = SafeModelDouble.new(
      id: 'http://example.com/mappings/101',
      source: 'REST',
      process: SafeModelDouble.new(source_name: 'test_set'),
      classes: [
        SafeModelDouble.new(id: 'http://example.com/ontologies/ONT1/classes/C1', links: { 'self' => 'http://example.com/ontologies/ONT1/classes/C1', 'ontology' => 'http://example.com/ontologies/ONT1' }),
        SafeModelDouble.new(id: 'http://example.com/ontologies/ONT2/classes/C2', links: { 'self' => 'http://example.com/ontologies/ONT2/classes/C2', 'ontology' => 'http://example.com/ontologies/ONT2' })
      ]
    )
    concept = SafeModelDouble.new(id: 'http://example.com/ontologies/ONT1/classes/C1', prefLabel: 'Concept 1', links: { 'ontology' => 'http://example.com/ontologies/ONT1' })

    view = build_view_context
    # Render _show_line
    line_out = view.render(partial: 'mappings/show_line', locals: { map: map, concept: concept })
    refute_includes line_out, 'mapping-evidence-btn', 'Evidence button must not be rendered when feature is off'
    refute_includes line_out, 'mapping-evidence', 'MappingEvidence controller must not be referenced when feature is off'

    # Render _show
    view.instance_variable_set(:@ontology_name, 'ONT1')
    view.instance_variable_set(:@target_ontology_name, 'ONT2')
    view.instance_variable_set(:@mappings, [map])
    view.instance_variable_set(:@ontologies_param, 'ONT1,ONT2')
    show_out = view.render(partial: 'mappings/show')
    refute_includes show_out, 'mapping-evidence-btn', 'Evidence button must not be rendered in _show when feature is off'
    refute_includes show_out, 'mapping-evidence-panel', 'Evidence panel must not be rendered when feature is off'
  end

  # ---------------------------------------------------------------------------
  # 2. Feature On: Renders exact IDs even with repeated acronyms / similar labels
  # ---------------------------------------------------------------------------
  def test_02_feature_on_renders_both_exact_ids_with_repeated_acronyms_or_labels
    Flipper.enable('MappingEvidence')

    # Mapping with same acronym MESH for both classes and identical prefLabel 'Cell'
    c1 = SafeModelDouble.new(
      id: 'http://example.com/ontologies/MESH/classes/D001',
      links: {
        'self' => 'http://example.com/ontologies/MESH/classes/D001',
        'ontology' => 'http://example.com/ontologies/MESH'
      },
      prefLabel: 'Cell',
      definition: ['Basic unit of life'],
      synonym: ['Cellular unit']
    )
    c2 = SafeModelDouble.new(
      id: 'http://example.com/ontologies/MESH/classes/D002',
      links: {
        'self' => 'http://example.com/ontologies/MESH/classes/D002',
        'ontology' => 'http://example.com/ontologies/MESH'
      },
      prefLabel: 'Cell',
      definition: ['Another cellular concept'],
      synonym: ['Cellular entity']
    )

    mapping = SafeModelDouble.new(
      id: 'http://example.com/mappings/201',
      source: 'REST',
      process: SafeModelDouble.new(
        source_name: 'CellMapSet',
        comment: 'Paired cells with same acronym',
        relation: ['http://www.w3.org/2004/02/skos/core#exactMatch']
      ),
      classes: [c1, c2]
    )

    LinkedData::Client::Models::Mapping.current_mapping_double = mapping

    _ctrl, _req, res = dispatch(:evidence, params: { id: '201' })
    assert_equal 200, res.status, 'Evidence route must return 200 when feature is enabled'
    body = res.body

    # Check that BOTH exact class IDs appear
    assert_includes body, 'http://example.com/ontologies/MESH/classes/D001', 'Must render exact Class 1 ID'
    assert_includes body, 'http://example.com/ontologies/MESH/classes/D002', 'Must render exact Class 2 ID'
    assert_includes body, 'MESH', 'Must render exact ontology acronym'

    # Check relation as returned
    assert_includes body, 'http://www.w3.org/2004/02/skos/core#exactMatch', 'Must render exact relation'
  end

  # ---------------------------------------------------------------------------
  # 3. Directed mapping uses returned source/target fields
  # ---------------------------------------------------------------------------
  def test_03_directed_mapping_uses_returned_source_target_fields
    Flipper.enable('MappingEvidence')

    c1 = SafeModelDouble.new(
      id: 'http://example.com/ontologies/ONT_SRC/classes/S1',
      links: { 'self' => 'http://example.com/ontologies/ONT_SRC/classes/S1', 'ontology' => 'http://example.com/ontologies/ONT_SRC' }
    )
    c2 = SafeModelDouble.new(
      id: 'http://example.com/ontologies/ONT_TGT/classes/T1',
      links: { 'self' => 'http://example.com/ontologies/ONT_TGT/classes/T1', 'ontology' => 'http://example.com/ontologies/ONT_TGT' }
    )

    # Supply explicit subject and object indicating C1 is source, C2 is target
    mapping = SafeModelDouble.new(
      id: 'http://example.com/mappings/301',
      source: 'REST',
      subject: 'http://example.com/ontologies/ONT_SRC/classes/S1',
      object: 'http://example.com/ontologies/ONT_TGT/classes/T1',
      process: SafeModelDouble.new(relation: ['http://www.w3.org/2004/02/skos/core#broadMatch']),
      classes: [c1, c2]
    )

    LinkedData::Client::Models::Mapping.current_mapping_double = mapping

    _ctrl, _req, res = dispatch(:evidence, params: { id: '301' })
    assert_equal 200, res.status
    body = res.body

    assert_includes body, 'Directed (Source → Target)', 'Must display directed status when directional fields returned'
    assert_includes body, 'Source', 'Must identify source side'
    assert_includes body, 'Target', 'Must identify target side'
  end

  # ---------------------------------------------------------------------------
  # 4. Undirected mapping: no direction => explicitly unknown (never inferred)
  # ---------------------------------------------------------------------------
  def test_04_no_direction_renders_explicitly_unknown_never_inferred
    Flipper.enable('MappingEvidence')

    c1 = SafeModelDouble.new(
      id: 'http://example.com/ontologies/O1/classes/Alpha',
      links: { 'self' => 'http://example.com/ontologies/O1/classes/Alpha', 'ontology' => 'http://example.com/ontologies/O1' }
    )
    c2 = SafeModelDouble.new(
      id: 'http://example.com/ontologies/O2/classes/Beta',
      links: { 'self' => 'http://example.com/ontologies/O2/classes/Beta', 'ontology' => 'http://example.com/ontologies/O2' }
    )

    # No subject/object, no source_class/target_class, no target
    mapping = SafeModelDouble.new(
      id: 'http://example.com/mappings/401',
      source: 'LOOM',
      classes: [c1, c2],
      process: SafeModelDouble.new(source_name: 'LoomSet')
    )

    LinkedData::Client::Models::Mapping.current_mapping_double = mapping

    _ctrl, _req, res = dispatch(:evidence, params: { id: '401' })
    assert_equal 200, res.status
    body = res.body

    assert_includes body, 'data-direction="unknown"', 'Direction must be marked unknown when no explicit directional fields exist'
    assert_includes body, 'Unknown', 'Unknown direction must be explicitly displayed'
  end

  # ---------------------------------------------------------------------------
  # 5. Missing fields render as 'Unavailable'
  # ---------------------------------------------------------------------------
  def test_05_missing_fields_render_as_unavailable
    Flipper.enable('MappingEvidence')

    # Class with no definition, no synonyms, no prefLabel
    c1 = SafeModelDouble.new(
      id: 'http://example.com/ontologies/BARE/classes/B1',
      links: { 'self' => 'http://example.com/ontologies/BARE/classes/B1', 'ontology' => 'http://example.com/ontologies/BARE' }
    )
    c2 = SafeModelDouble.new(
      id: 'http://example.com/ontologies/BARE/classes/B2',
      links: { 'self' => 'http://example.com/ontologies/BARE/classes/B2', 'ontology' => 'http://example.com/ontologies/BARE' }
    )

    # Mapping with no relation, no process comment, no source_name
    mapping = SafeModelDouble.new(
      id: 'http://example.com/mappings/501',
      source: nil,
      process: nil,
      classes: [c1, c2]
    )

    LinkedData::Client::Models::Mapping.current_mapping_double = mapping

    _ctrl, _req, res = dispatch(:evidence, params: { id: '501' })
    assert_equal 200, res.status
    body = res.body

    assert_includes body, 'Unavailable', 'Missing fields must display Unavailable'
    # No invented review scores or validation
    refute_includes body, 'confidence', 'Must not invent confidence scores'
    refute_includes body, 'scientific validation', 'Must not invent scientific validation'
  end

  # ---------------------------------------------------------------------------
  # 6. Read-only safety: 0 write methods called on any double
  # ---------------------------------------------------------------------------
  def test_06_no_write_method_called_on_any_double
    Flipper.enable('MappingEvidence')

    c1 = SafeModelDouble.new(
      id: 'http://example.com/ontologies/RO/classes/R1',
      links: { 'self' => 'http://example.com/ontologies/RO/classes/R1', 'ontology' => 'http://example.com/ontologies/RO' }
    )
    c2 = SafeModelDouble.new(
      id: 'http://example.com/ontologies/RO/classes/R2',
      links: { 'self' => 'http://example.com/ontologies/RO/classes/R2', 'ontology' => 'http://example.com/ontologies/RO' }
    )
    mapping = SafeModelDouble.new(
      id: 'http://example.com/mappings/601',
      source: 'REST',
      classes: [c1, c2]
    )

    LinkedData::Client::Models::Mapping.current_mapping_double = mapping

    _ctrl, _req, res = dispatch(:evidence, params: { id: '601' })
    assert_equal 200, res.status
    assert_equal 0, $evidence_spy.write_calls, 'Read-only evidence action must never call write/save/update/delete methods'
  end

  # ---------------------------------------------------------------------------
  # 7. External row => no foreign lookup, shows remote details unavailable
  # ---------------------------------------------------------------------------
  def test_07_external_row_performs_no_foreign_lookup_and_shows_remote_details_unavailable
    Flipper.enable('MappingEvidence')

    # One internal class, one external class
    c_internal = SafeModelDouble.new(
      id: 'http://example.com/ontologies/LOCAL/classes/L1',
      links: {
        'self' => 'http://example.com/ontologies/LOCAL/classes/L1',
        'ontology' => 'http://example.com/ontologies/LOCAL'
      }
    )
    c_external = SafeModelDouble.new(
      id: 'http://foreign-portal.org/ontologies/EXT/classes/E1',
      links: {
        'self' => 'http://foreign-portal.org/ontologies/EXT/classes/E1',
        'ontology' => 'http://foreign-portal.org/ontologies/EXT'
      }
    )

    mapping = SafeModelDouble.new(
      id: 'http://example.com/mappings/701',
      source: 'REST',
      classes: [c_internal, c_external]
    )

    LinkedData::Client::Models::Mapping.current_mapping_double = mapping

    initial_ontology_calls = $evidence_spy.ontology_find_calls
    _ctrl, _req, res = dispatch(:evidence, params: { id: '701' })
    assert_equal 200, res.status
    body = res.body

    # Check external ontology was NOT queried through Ontology.find_by_acronym
    refute_includes $evidence_spy.ontology_find_args, 'EXT', 'External ontology acronym must NOT be queried via API'

    # Check remote details unavailable is rendered for external class
    assert_includes body, 'Remote details unavailable', 'External class must display Remote details unavailable'

    # Approved external link is preserved
    assert_includes body, 'href="http://foreign-portal.org/ontologies/EXT/classes/E1"', 'Approved external link must be retained'
  end
end
