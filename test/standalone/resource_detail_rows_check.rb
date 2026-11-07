# frozen_string_literal: true

# Set up gem paths for native docker image if present
if Dir.exist?('/usr/local/bundle/ruby/3.1.0/gems') && (ENV['GEM_PATH'].nil? || !ENV['GEM_PATH'].include?('/usr/local/bundle/ruby/3.1.0'))
  Gem.use_paths(nil, Gem.path + ['/usr/local/bundle/ruby/3.1.0'])
end

require 'minitest/autorun'
require 'active_support/all'
require 'rails'
require 'action_controller'
require 'action_view'
require 'view_component'
require 'haml'
require 'haml/template'
require 'ostruct'
require 'nokogiri'

# =============================================================================
# Standalone Resource Detail Rows Check (ONTO-T-U06 independent row repair)
#
# Validates that ConceptDetailsComponent renders raw property rows even when
# bottom_keys is empty (e.g. app/views/collections/_show.html.haml passing
# bottom_keys: []), which previously suppressed all top, leftover, custom
# section, and bottom rows behind Haml guard `if @bottom_keys.present?`.
#
# Contracts verified:
# 1. Collection details with empty bottom_keys renders top and leftover rows,
#    while respecting exclude_keys (e.g. members remain excluded).
# 2. Existing nonempty-bottom ordering and custom sections are preserved:
#    top rows -> leftover rows -> custom sections -> bottom rows.
# 3. Nil and empty properties remain safe (no NoMethodError / empty table).
# 4. Raw IRI tooltip, multilingual values, date conversion, and export modal
#    controls are retained.
# =============================================================================

# Setup paths and environment
$LOAD_PATH.unshift File.expand_path('../../app/components', __dir__)
$LOAD_PATH.unshift File.expand_path('../../app/helpers', __dir__)
$LOAD_PATH.unshift File.expand_path('../../app/controllers/concerns', __dir__)

$REST_URL = 'http://localhost:9393'
$API_KEY = 'dummy'

module OntologiesHelper; end
module Display; end

require 'terms_reuses'
require 'modal_helper'
require 'urls_helper'
require 'components_helper'
require 'multi_languages_helper'
require 'ontologies_helper'
require 'application_helper'

# Minimal doubling for external presentation helpers
module ApplicationHelper
  def ajax_link_chip(id, ajax_src:, target: nil)
    %(<a class="ajax-chip" href="#{ajax_src}" data-target="#{target}">#{id}</a>).html_safe
  end
end

require 'table_cell_component'
require 'table_row_component'
require 'table_component'
require 'display/header_component'
require 'dropdown_container_component'
require 'list_items_show_more_component'
require 'concept_details_component'

ConceptDetailsComponent.include(Module.new {
  def inline_svg(path, _opts = {})
    %(<svg data-path="#{path}"></svg>).html_safe
  end
})

class ResourceDetailRowsCheck < Minitest::Test
  def setup
    lookup_context = ActionView::LookupContext.new([
      File.expand_path('../../app/components', __dir__),
      File.expand_path('../../app/views', __dir__)
    ])
    @view_context = ActionView::Base.new(lookup_context, {}, ActionController::Base.new)
    @view_context.extend(ActionView::Helpers::TagHelper)
    @view_context.extend(ActionView::Helpers::UrlHelper)
    @view_context.extend(ModalHelper)
    @view_context.extend(UrlsHelper)
    @view_context.extend(ComponentsHelper)
    @view_context.extend(MultiLanguagesHelper)
    @view_context.extend(ApplicationHelper)

    @view_context.define_singleton_method(:inline_svg) { |path, _opts = {}| %(<svg data-path="#{path}"></svg>).html_safe }
    @view_context.define_singleton_method(:link_to_modal) do |name, url, _opts = {}, &block|
      inner = block_given? ? block.call : name
      %(<a href="#{url}" data-modal="true">#{inner}</a>).html_safe
    end
    @view_context.define_singleton_method(:image_tag) { |src, _opts = {}| %(<img src="#{src}" />).html_safe }
    @view_context.define_singleton_method(:request_lang) { 'en' }
    @view_context.define_singleton_method(:t) { |k| k }
    @view_context.define_singleton_method(:l) { |d, opts = {}| "FORMATTED_DATE(#{d})" }
  end

  def parse_doc(html)
    Nokogiri::HTML::DocumentFragment.parse(html)
  end

  # Case 1: Collection-like top+leftover rows with empty bottom_keys, member/excluded absent
  def test_collection_details_with_empty_bottom_keys_renders_top_and_leftover_rows
    props_class = Struct.new(
      :"http://purl.org/dc/terms/created",
      :"http://purl.org/dc/terms/modified",
      :"http://www.w3.org/2000/01/rdf-schema#comment",
      :"http://www.w3.org/2004/02/skos/core#note",
      :"http://example.org/custom_prop",
      :"http://www.w3.org/2004/02/skos/core#member"
    )
    props = props_class.new(
      ['2023-01-15'],
      ['2023-06-20'],
      ['Curated collection of mineral specimens'],
      ['Working collection note'],
      ['Custom leftover property value'],
      ['http://example.org/specimen/001', 'http://example.org/specimen/002']
    )

    comp = ConceptDetailsComponent.new(
      id: 'collection-label',
      acronym: 'MIN-ONTO',
      concept_id: 'http://example.org/collections/minerals',
      properties: props,
      top_keys: %w[created modified comment note],
      bottom_keys: [],
      exclude_keys: %w[member]
    )

    html = comp.render_in(@view_context)
    doc = parse_doc(html)

    # Raw data table body rows (excluding format toolbar row)
    rows = doc.css('tbody tr').reject { |tr| tr.at_css('#content_resource_formats') }
    assert_equal 5, rows.size, "Expected 5 property rows (4 top + 1 leftover), got #{rows.size}"

    # Verify top row labels
    row_headers = rows.map { |r| r.at_css('th span')&.text&.strip }
    assert_equal ['dct:created', 'dct:modified', 'rdfs:comment', 'skos:note', 'custom_prop'], row_headers

    # Verify values appear
    assert_includes html, 'Curated collection of mineral specimens'
    assert_includes html, 'Working collection note'
    assert_includes html, 'Custom leftover property value'

    # Verify excluded member data is NOT in rendered HTML
    refute_includes html, 'http://example.org/specimen/001'
    refute_includes html, 'http://example.org/specimen/002'
    refute_includes html, 'member'
  end

  # Case 2: Existing nonempty-bottom ordering and custom sections
  def test_nonempty_bottom_ordering_and_custom_sections_preserved
    props_class = Struct.new(
      :"http://www.w3.org/2000/01/rdf-schema#comment",
      :"http://example.org/leftover_datum",
      :"http://example.org/schemes_key",
      :"http://www.w3.org/2000/01/rdf-schema#subClassOf"
    )
    props = props_class.new(
      ['Concept description comment'],
      ['Leftover metadata payload'],
      ['http://example.org/scheme/1'],
      ['http://example.org/ParentClass']
    )

    comp = ConceptDetailsComponent.new(
      id: 'concept-details',
      acronym: 'TEST-ONTO',
      concept_id: 'http://example.org/concept/123',
      properties: props,
      top_keys: %w[comment],
      bottom_keys: %w[subClassOf],
      exclude_keys: %w[schemes_key]
    )

    html = comp.render_in(@view_context) do |c|
      c.add_sections(['schemes_key']) do |val|
        %(<span class="custom-scheme-link">Scheme: #{val}</span>).html_safe
      end
    end
    doc = parse_doc(html)

    rows = doc.css('tbody tr').reject { |tr| tr.at_css('#content_resource_formats') || tr.text.strip.empty? }
    assert_equal 4, rows.size, "Expected 4 rows (1 top + 1 leftover + 1 section + 1 bottom), got #{rows.size}"

    # Verify sequential position in rendered table
    comment_pos = html.index('rdfs:comment')
    leftover_pos = html.index('leftover_datum')
    section_pos = html.index('custom-scheme-link')
    subclass_pos = html.index('rdfs:subClassOf')

    assert comment_pos, 'rdfs:comment must be rendered'
    assert leftover_pos, 'leftover_datum must be rendered'
    assert section_pos, 'custom section must be rendered'
    assert subclass_pos, 'rdfs:subClassOf must be rendered'

    assert comment_pos < leftover_pos, 'Top keys must precede leftover keys'
    assert leftover_pos < section_pos, 'Leftover keys must precede custom sections'
    assert section_pos < subclass_pos, 'Custom sections must precede bottom keys'
  end

  # Case 3: Nil and empty properties safety
  def test_nil_properties_remain_safe
    comp = ConceptDetailsComponent.new(
      id: 'instance-details',
      acronym: 'TEST-ONTO',
      concept_id: 'http://example.org/instances/inst1',
      properties: nil,
      top_keys: [],
      bottom_keys: [],
      exclude_keys: []
    )

    html = comp.render_in(@view_context)
    doc = parse_doc(html)

    assert doc.at_css('.concept_details_component')
    assert doc.at_css('.raw-table')
    # No property rows, only export format toolbar
    property_rows = doc.css('tbody tr').reject { |tr| tr.at_css('#content_resource_formats') }
    assert_empty property_rows
    assert doc.at_css('#content_resource_formats'), 'Export toolbar must still render when concept_id is present'
  end

  def test_empty_properties_struct_remains_safe
    empty_props_class = Struct.new(:dummy)
    empty_props = empty_props_class.new(nil)

    comp = ConceptDetailsComponent.new(
      id: 'empty-details',
      acronym: 'TEST-ONTO',
      concept_id: nil,
      properties: empty_props,
      top_keys: %w[created],
      bottom_keys: %w[subClassOf],
      exclude_keys: []
    )

    html = comp.render_in(@view_context)
    doc = parse_doc(html)

    assert doc.at_css('.concept_details_component')
    property_rows = doc.css('tbody tr')
    assert_empty property_rows
  end

  # Case 4: Raw IRI tooltip, multilingual values, dates, and export links retained
  def test_raw_iri_tooltip_multilingual_values_and_export_controls_retained
    props_class = Struct.new(
      :"http://example.org/ontology#multilingualField",
      :"http://purl.org/dc/terms/created"
    )
    props = props_class.new(
      OpenStruct.new(en: ['Sample Specimen'], fr: ['Échantillon Type']),
      ['2024-03-01']
    )

    comp = ConceptDetailsComponent.new(
      id: 'multilingual-details',
      acronym: 'TEST-ONTO',
      concept_id: 'http://example.org/items/item1',
      properties: props,
      top_keys: [],
      bottom_keys: [],
      exclude_keys: []
    )

    html = comp.render_in(@view_context)
    doc = parse_doc(html)

    # 1. IRI tooltip preserved on th span
    th_span = doc.at_css('th span[title="http://example.org/ontology#multilingualField"]')
    assert th_span, 'Property header must retain raw IRI in title attribute'
    assert_equal 'tooltip', th_span['data-controller'], 'Property header must retain tooltip controller attribute'

    # 2. Multilingual values with badges preserved
    en_def = doc.at_css('.definition span:contains("Sample Specimen")')
    assert en_def, 'English value must be rendered'
    en_badge = doc.at_css('.definition .badge:contains("EN")')
    assert en_badge, 'English language badge EN must be rendered'

    fr_def = doc.at_css('.definition span:contains("Échantillon Type")')
    assert fr_def, 'French value must be rendered'
    fr_badge = doc.at_css('.definition .badge:contains("FR")')
    assert fr_badge, 'French language badge FR must be rendered'

    # 3. Date handling via convert_dates
    assert_includes html, '2024-03-01', 'Date values must be preserved and rendered'

    # 4. Export format links present with correct identifiers
    assert doc.at_css('#content_resource_formats')
    assert doc.at_css('#resource_content_json')
    assert doc.at_css('#resource_content_xml')
    assert doc.at_css('#resource_content_ntriples')
    assert doc.at_css('#resource_content_turtle')

    json_wrapper = doc.at_css('[title="Export in JSON"]')
    assert json_wrapper
    assert_equal 'tooltip', json_wrapper['data-controller']
  end

  # Case 5: Direct regression proof of the missing-row defect fix
  def test_empty_bottom_keys_unblocks_raw_data_regression
    # In unpatched Haml, lines 8-24 put top_set, leftover_set, sections, and bottom_set
    # inside `if @bottom_keys.present?`. When @bottom_keys was [], 0 rows were emitted.
    # With the fix, nonempty top_set and leftover_set are emitted even when @bottom_keys is [].
    props_class = Struct.new(
      :"http://www.w3.org/2000/01/rdf-schema#comment",
      :"http://example.org/ns#unbucketedProperty"
    )
    props = props_class.new(
      ['A meaningful collection comment'],
      ['Unbucketed raw metadata value']
    )

    comp = ConceptDetailsComponent.new(
      id: 'regression-proof',
      acronym: 'TEST-ONTO',
      concept_id: 'http://example.org/collections/col99',
      properties: props,
      top_keys: %w[comment],
      bottom_keys: [],
      exclude_keys: []
    )

    html = comp.render_in(@view_context)
    doc = parse_doc(html)

    # Both top_keys row and unbucketed leftover row MUST be present
    assert_includes html, 'A meaningful collection comment'
    assert_includes html, 'Unbucketed raw metadata value'

    rows = doc.css('tbody tr').reject { |tr| tr.at_css('#content_resource_formats') || tr.text.strip.empty? }
    assert_equal 2, rows.size, 'Expected exactly 2 rows unblocked by removing bottom_keys guard'
  end
end
