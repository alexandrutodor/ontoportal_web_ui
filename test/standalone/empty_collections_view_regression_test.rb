# frozen_string_literal: true

require 'minitest/autorun'
require 'haml'
require 'cgi'
require 'ostruct'

# =============================================================================
# Standalone Offline Empty Collection View Regression Test (ONTO-T-U07)
#
# Validates the U07 contract for collections list view rendering:
# 1. Empty collections array ([]) renders existing turbo frame and no_collections_alert
#    without dereferencing nil or raising NoMethodError.
# 2. One collection with no selected ID deterministically selects the single collection.
# 3. Multiple collections with no selected ID deterministically selects the first sorted collection.
# 4. Multiple collections with a valid selected ID preserves the requested selection.
# 5. Multiple collections with an unknown selected ID safely falls back to the first sorted collection.
# 6. Nil collections (@collections = nil) raises NoMethodError and is NOT caught/normalized as empty success.
# 7. Upstream API errors are NOT swallowed or disguised as legitimate empty collections.
# 8. Verifies get_collections_labels contract on empty collection input returns [[], nil].
# =============================================================================

# In native container (onto-q02-proof:af254f34), gems are located in /usr/local/bundle/ruby/3.1.0
if Dir.exist?('/usr/local/bundle/ruby/3.1.0/gems') && (ENV['GEM_PATH'].nil? || !ENV['GEM_PATH'].include?('/usr/local/bundle/ruby/3.1.0'))
  Gem.use_paths(nil, Gem.path + ['/usr/local/bundle/ruby/3.1.0'])
end

begin
  require 'active_support'
  require 'active_support/concern'
rescue LoadError
  module ActiveSupport
    module Concern
      def self.extended(base); end
    end
  end
end

# Stubs for unused helpers required by multi_languages_helper
module OntologiesHelper; end
module ComponentsHelper; end

# Load actual production helpers
$LOAD_PATH.unshift File.expand_path('../../app/helpers', __dir__)
$LOAD_PATH.unshift File.expand_path('../../app/controllers/concerns', __dir__)

require 'urls_helper'

# Color gem fallback if running on minimal host environment without color gem
$LOADED_FEATURES << 'color.rb' unless defined?(Color)
module Color
  class HSL
    def initialize(*); end
    def html; '#000000'; end
  end
end unless defined?(Color::HSL)

require 'multi_languages_helper'
require 'collections_helper'
require 'terms_reuses'

module Display
  class AlertComponent
    attr_reader :message
    def initialize(message: nil, **); @message = message; end
  end
end

class TreeViewComponent
  attr_reader :id, :auto_click
  def initialize(id: nil, auto_click: false, **); @id = id; @auto_click = auto_click; end
end

class CollectionsListViewTestContext
  include Haml::Helpers
  include UrlsHelper
  include MultiLanguagesHelper
  include CollectionsHelper
  include TermsReuses

  attr_accessor :ontology, :submission, :collections, :params, :session, :rendered_children, :rendered_alerts

  def initialize(collections: [], selected_id: nil, acronym: 'TEST_ONTO')
    init_haml_helpers
    @ontology = OpenStruct.new(acronym: acronym)
    @submission = OpenStruct.new(uriRegexPattern: nil, preferredNamespaceUri: nil)
    @collections = collections
    @params = { collectionid: selected_id, ontology: acronym }
    @session = { locale: 'en' }
    @rendered_children = []
    @rendered_alerts = []
  end

  def turbo_frame_tag(id, &block)
    content = block_given? ? capture_haml(&block) : ''
    "<turbo-frame id=\"#{id}\">\n#{content}</turbo-frame>"
  end

  def t(key, **options)
    if key == 'collections.no_collections_alert'
      "#{options[:acronym]} does not contain collections (skos:Collection)"
    else
      "#{key} #{options.inspect}"
    end
  end

  def render(comp, &block)
    if comp.is_a?(Display::AlertComponent)
      msg = block_given? ? capture_haml(&block).strip : comp.message
      @rendered_alerts << msg
      "<div class=\"alert alert-info\">#{msg}</div>"
    elsif comp.is_a?(TreeViewComponent)
      collector = TreeChildCollector.new(self)
      body = capture_haml(collector, &block)
      "<div class=\"tree-view\">\n#{body}</div>"
    else
      ''
    end
  end
end

class TreeChildCollector
  def initialize(view_context)
    @view_context = view_context
  end

  def child(**kwargs)
    @view_context.rendered_children << kwargs
    nil
  end
end

class EmptyCollectionsViewRegressionTest < Minitest::Test
  TEMPLATE_PATH = File.expand_path('../../app/views/collections/_list_view.html.haml', __dir__)

  def setup
    @template_content = File.read(TEMPLATE_PATH)
  end

  def render_template(context)
    Haml::Engine.new(@template_content).render(context)
  end

  # =========================================================================
  # 1. Empty collections: renders alert in exact turbo frame without exception
  # =========================================================================
  def test_empty_collections_renders_alert_in_exact_turbo_frame_without_exception
    view = CollectionsListViewTestContext.new(collections: [], selected_id: nil, acronym: 'MAT_ONTO')
    html = render_template(view)

    assert_includes html, '<turbo-frame id="collections_sorted_list_view-page-1">'
    assert_includes html, 'MAT_ONTO does not contain collections (skos:Collection)'
    assert_equal 1, view.rendered_alerts.length
    assert_equal 'MAT_ONTO does not contain collections (skos:Collection)', view.rendered_alerts.first
    assert_empty view.rendered_children
  end

  # =========================================================================
  # 2. Helper contract: get_collections_labels on empty collections returns [[], nil]
  # =========================================================================
  def test_helper_get_collections_labels_returns_empty_and_nil_for_empty_input
    helper_host = CollectionsListViewTestContext.new
    labels, selected = helper_host.get_collections_labels([], nil)
    assert_equal [], labels
    assert_nil selected

    labels_with_id, selected_with_id = helper_host.get_collections_labels([], 'http://example.org/c1')
    assert_equal [], labels_with_id
    assert_nil selected_with_id
  end

  # =========================================================================
  # 3. One collection, no selected ID: deterministically selects the item
  # =========================================================================
  def test_one_collection_without_selected_id_selects_first_item_deterministically
    collection = { '@id' => 'http://example.org/c1', 'prefLabel' => 'Single Collection' }
    view = CollectionsListViewTestContext.new(collections: [collection], selected_id: nil)
    html = render_template(view)

    assert_includes html, '<turbo-frame id="collections_sorted_list_view-page-1">'
    assert_empty view.rendered_alerts
    assert_equal 1, view.rendered_children.length

    child = view.rendered_children.first
    assert_equal 'http://example.org/c1', child[:child].id
    assert_equal true, child[:selected]
    assert_equal 'collection', child[:target_frame]
    assert_equal 'http://example.org/c1', child[:data][:collectionid]
  end

  # =========================================================================
  # 4. Many collections, no selected ID: selects first sorted label
  # =========================================================================
  def test_many_collections_without_selected_id_selects_first_sorted_label
    collections = [
      { '@id' => 'http://example.org/beta', 'prefLabel' => 'Beta Collection' },
      { '@id' => 'http://example.org/alpha', 'prefLabel' => 'Alpha Collection' },
      { '@id' => 'http://example.org/gamma', 'prefLabel' => 'Gamma Collection' }
    ]
    view = CollectionsListViewTestContext.new(collections: collections, selected_id: nil)
    html = render_template(view)

    assert_includes html, '<turbo-frame id="collections_sorted_list_view-page-1">'
    assert_empty view.rendered_alerts
    assert_equal 3, view.rendered_children.length

    selected_children = view.rendered_children.select { |c| c[:selected] }
    assert_equal 1, selected_children.length
    assert_equal 'http://example.org/alpha', selected_children.first[:child].id

    # Alpha is selected; Beta and Gamma are unselected
    child_map = view.rendered_children.to_h { |c| [c[:child].id, c[:selected]] }
    assert_equal({ 'http://example.org/alpha' => true,
                   'http://example.org/beta' => false,
                   'http://example.org/gamma' => false }, child_map)
  end

  # =========================================================================
  # 5. Many collections, valid selected ID: preserves requested selection
  # =========================================================================
  def test_many_collections_with_valid_selected_id_preserves_selection
    collections = [
      { '@id' => 'http://example.org/beta', 'prefLabel' => 'Beta Collection' },
      { '@id' => 'http://example.org/alpha', 'prefLabel' => 'Alpha Collection' },
      { '@id' => 'http://example.org/gamma', 'prefLabel' => 'Gamma Collection' }
    ]
    view = CollectionsListViewTestContext.new(collections: collections, selected_id: 'http://example.org/beta')
    render_template(view)

    assert_equal 3, view.rendered_children.length
    selected_children = view.rendered_children.select { |c| c[:selected] }
    assert_equal 1, selected_children.length
    assert_equal 'http://example.org/beta', selected_children.first[:child].id

    child_map = view.rendered_children.to_h { |c| [c[:child].id, c[:selected]] }
    assert_equal({ 'http://example.org/alpha' => false,
                   'http://example.org/beta' => true,
                   'http://example.org/gamma' => false }, child_map)
  end

  # =========================================================================
  # 6. Many collections, unknown selected ID: falls back to first sorted label
  # =========================================================================
  def test_many_collections_with_unknown_selected_id_falls_back_to_first_sorted_label
    collections = [
      { '@id' => 'http://example.org/beta', 'prefLabel' => 'Beta Collection' },
      { '@id' => 'http://example.org/alpha', 'prefLabel' => 'Alpha Collection' },
      { '@id' => 'http://example.org/gamma', 'prefLabel' => 'Gamma Collection' }
    ]
    view = CollectionsListViewTestContext.new(collections: collections, selected_id: 'http://example.org/nonexistent')
    render_template(view)

    assert_equal 3, view.rendered_children.length
    selected_children = view.rendered_children.select { |c| c[:selected] }
    assert_equal 1, selected_children.length
    assert_equal 'http://example.org/alpha', selected_children.first[:child].id

    child_map = view.rendered_children.to_h { |c| [c[:child].id, c[:selected]] }
    assert_equal({ 'http://example.org/alpha' => true,
                   'http://example.org/beta' => false,
                   'http://example.org/gamma' => false }, child_map)
  end

  # =========================================================================
  # 7. Separate API failure: nil collections raises NoMethodError (not empty)
  # =========================================================================
  def test_nil_collections_raises_nomethoderror_and_is_not_normalized_to_empty
    view = CollectionsListViewTestContext.new(collections: nil, selected_id: nil)

    err = assert_raises(NoMethodError) do
      render_template(view)
    end
    assert_match(/undefined method.*each.*nil/, err.message)
    assert_empty view.rendered_alerts
  end

  # =========================================================================
  # 8. Separate API failure: upstream exception is not swallowed as empty success
  # =========================================================================
  def test_upstream_api_failure_raises_and_is_not_swallowed_as_empty_success
    failing_collections = Object.new
    failing_collections.define_singleton_method(:each) do
      raise RuntimeError, 'Remote SPARQL/REST endpoint connection failed'
    end

    view = CollectionsListViewTestContext.new(collections: failing_collections, selected_id: nil)

    err = assert_raises(RuntimeError) do
      render_template(view)
    end
    assert_equal 'Remote SPARQL/REST endpoint connection failed', err.message
    assert_empty view.rendered_alerts
  end
end
