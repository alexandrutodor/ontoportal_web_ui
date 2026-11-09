# frozen_string_literal: true

require 'minitest/autorun'
require 'logger'
require 'ostruct'
require 'uri'
require 'cgi'
require 'rack'

# Ensure gem load paths in native container environment
if Dir.exist?('/usr/local/bundle/ruby/3.1.0/gems') && (ENV['GEM_PATH'].nil? || !ENV['GEM_PATH'].include?('/usr/local/bundle/ruby/3.1.0'))
  Gem.use_paths(nil, Gem.path + ['/usr/local/bundle/ruby/3.1.0'])
end

WORKTREE_ROOT = File.expand_path('../..', __dir__)
worktree_root = WORKTREE_ROOT
$LOAD_PATH.unshift(File.join(worktree_root, 'app/helpers'))
$LOAD_PATH.unshift(File.join(worktree_root, 'app/controllers/concerns'))
$LOAD_PATH.unshift(File.join(worktree_root, 'app/controllers'))
$LOAD_PATH.unshift(File.join(worktree_root, 'app/components'))

require 'active_support/all'
require 'rails'
require 'action_controller'
require 'action_view'
require 'view_component'
require 'nokogiri'
require 'haml'
require 'haml/template'
require 'turbo-rails'

module Turbo
  module Frames; end
end
require '/usr/local/bundle/ruby/3.1.0/gems/turbo-rails-2.0.12/app/helpers/turbo/frames_helper.rb' rescue nil

ActionController::Base.logger = Logger.new(nil)
Rails.logger = Logger.new(nil)
$REST_URL = 'http://example.com'
$API_KEY = 'test'

# Minimal ActiveRecord stub for ApplicationController error handling
module ActiveRecord
  class RecordNotFound < StandardError; end
end

# Real production helpers
require 'urls_helper'
require 'terms_reuses'
require 'components_helper'
require 'ontologies_helper'
require 'internationalisation_helper'
require 'multi_languages_helper'
require 'modal_helper'
require 'application_helper'
require 'federation_helper'
require 'search_helper'
require 'collections_helper'
require 'mappings_helper'
require 'concepts_helper'
require 'turbo_helper'

# Real production components
module Display; end
module Buttons; end

require 'turbo_frame_component'
require 'loader_component'
require 'display/search_result_component'
require 'display/image_component'
require 'buttons/regular_button_component'
require 'infinite_scroll_component'
require 'link_text_component'
require 'popup_link_text_component'
require 'tree_link_component'
require 'tree_view_component'
require 'tree_infinite_scroll_component'


# Stub ConceptDetailsComponent block wrapper for isolated view testing
class ConceptDetailsComponent < ViewComponent::Base
  def initialize(**kwargs); @kwargs = kwargs; end
  def header(**kwargs, &block)
    tbl = Object.new
    tbl.define_singleton_method(:add_row) do |*args, &row_block|
      if row_block
        row_wrapper = Object.new
        row_wrapper.define_singleton_method(:td) { |&td_block| td_block.call }
        row_block.call(row_wrapper)
      end
    end
    block.call(tbl)
    tbl
  end
end

class TurboFrameComponent < ViewComponent::Base
  def render_in(view_context, &block)
    "<turbo-frame id=\"#{@id}\" src=\"#{@src}\"></turbo-frame>".html_safe
  end
end

class ViewComponent::Base
  def inline_svg(*_args); '<svg></svg>'.html_safe; end
  def inline_svg_tag(*_args); '<svg></svg>'.html_safe; end
  def t(key, *_args); key.to_s; end
end

class StandaloneViewContext < ActionView::Base
  include UrlsHelper
  include ModalHelper
  include MultiLanguagesHelper
  include FederationHelper
  include ComponentsHelper
  include SearchHelper
  include CollectionsHelper
  include Turbo::FramesHelper if defined?(Turbo::FramesHelper)

  def inline_svg(*_args); '<svg></svg>'.html_safe; end
  def inline_svg_tag(*_args); '<svg></svg>'.html_safe; end
  def t(key, *_args); key.to_s; end
  def request_lang; 'en'; end
  def concept_reused?(**_); false; end
  def replace(id, content); "replace:#{id}:#{content}"; end
  def prepend(id, content); "prepend:#{id}:#{content}"; end

  def render(comp, &block)
    if comp.is_a?(ViewComponent::Base)
      comp.render_in(self, &block)
    else
      super
    end
  end
end

# Real production ApplicationController and Models
require 'ontologies_api_client'
require 'application_controller'

# Skip session/network before_actions on real ApplicationController for offline test safety
ApplicationController.skip_before_action :set_locale, :set_global_thread_values, :domain_ontology_set,
                                        :clean_empty_strings_from_params_arrays, :init_trial_license,
                                        raise: false

class ApplicationController
  def concept_not_found(id); raise "404: #{id}"; end
  def ontology_not_found(id); raise "404: #{id}"; end
end

# Upstream model doubles for ConceptsController
module LinkedData
  module Client
    module Models
      class Ontology
        def self.find_by_acronym(acronym)
          ont = new
          ont.acronym = acronym
          [ont]
        end
        attr_accessor :acronym, :errors
        def explore
          self
        end
        def single_class(_options, conceptid)
          $received_conceptid = conceptid
          OpenStruct.new(id: conceptid, errors: nil)
        end
      end
    end
  end
end

require 'concepts_controller'
ConceptsController.layout false

class QueryValueRoundtripRegressionTest < Minitest::Test
  # Shared matrix covering:
  # 1. Full hash IRI
  # 2. Ampersands
  # 3. Literal plus
  # 4. Existing percent sequences
  # 5. Unicode characters
  # 6. Combined edge case with all delimiters
  MATRIX_CASES = {
    hash_iri: 'http://example.org/onto#Class_1',
    ampersands: 'http://example.org/onto?concept=A&B&group=C',
    literal_plus: 'http://example.org/onto/Class+Positive+Condition',
    percent_sequences: 'http://example.org/onto/item%20with%2Fescapes',
    unicode: 'http://example.org/onto/Phänomen_Entität_äöü_日本語',
    combined_complex: 'http://example.org/onto#Class+Positive&filter=A%20B&tag=äöü_日本語'
  }.freeze

  def setup
    lookup_context = ActionView::LookupContext.new([
      File.join(WORKTREE_ROOT, 'app/components'),
      File.join(WORKTREE_ROOT, 'app/components/buttons/regular_button_component'),
      File.join(WORKTREE_ROOT, 'app/components/tree_link_component'),
      File.join(WORKTREE_ROOT, 'app/components/tree_view_component'),
      File.join(WORKTREE_ROOT, 'app/components/infinite_scroll_component'),
      File.join(WORKTREE_ROOT, 'app/components/tree_infinite_scroll_component')
    ])
    controller = ActionController::Base.new
    @view_context = StandaloneViewContext.new(lookup_context, {}, controller)
    $received_conceptid = nil
  end

  # =========================================================================
  # Flow 1: SearchResultComponent#details_button -> ConceptsController#details
  # =========================================================================
  def test_search_result_details_button_roundtrips_to_concepts_details_receiver
    MATRIX_CASES.each do |label, raw_uri|
      comp = Display::SearchResultComponent.new(
        title: "Test #{label}",
        ontology_id: 'http://example.org/ontologies/TEST_ONTO',
        uri: raw_uri
      )
      comp.instance_variable_set(:@view_context, @view_context)

      # Render actual component button
      html = comp.details_button
      doc = Nokogiri::HTML.fragment(html)
      href = doc.at_css('a')['href']
      refute_nil href, "Details button must render href for #{label}"

      # Assert zero outer URL fragment
      parsed_uri = URI.parse(href)
      assert_nil parsed_uri.fragment, "Outer URL fragment must be nil (0 fragments) for #{label}, got #{parsed_uri.fragment.inspect}"

      # Parse query params exactly once with Rack
      params = Rack::Utils.parse_nested_query(parsed_uri.query)
      assert_equal raw_uri, params['conceptid'], "Rack query parse must yield original raw URI for #{label}"

      # Dispatch to actual receiver ConceptsController#details
      req = ActionDispatch::TestRequest.create
      params.each { |k, v| req.params[k] = v }
      res = ActionDispatch::TestResponse.create
      ctrl = ConceptsController.new
      ctrl.set_request!(req)
      ctrl.set_response!(res)
      ctrl.define_singleton_method(:render) { |*args| self.response_body = 'details rendered' }

      ctrl.process(:details)

      assert_equal raw_uri, $received_conceptid,
                   "ConceptsController#details receiver must receive EXACT uncorrupted raw URI for #{label}"
    end
  end

  # =========================================================================
  # Flow 2: SearchResultComponent#visualize_button -> ConceptsController#biomixer
  # =========================================================================
  def test_search_result_visualize_button_roundtrips_to_biomixer_receiver
    MATRIX_CASES.each do |label, raw_uri|
      comp = Display::SearchResultComponent.new(
        title: "Test #{label}",
        ontology_id: 'http://example.org/ontologies/TEST_ONTO',
        uri: raw_uri
      )
      comp.instance_variable_set(:@view_context, @view_context)

      html = comp.visualize_button
      doc = Nokogiri::HTML.fragment(html)
      href = doc.at_css('a')['href']
      refute_nil href, "Visualize button must render href for #{label}"

      parsed_uri = URI.parse(href)
      assert_nil parsed_uri.fragment, "Outer URL fragment must be nil (0 fragments) for #{label}"

      params = Rack::Utils.parse_nested_query(parsed_uri.query)
      assert_equal raw_uri, params['conceptid'], "Rack query parse must yield original raw URI for #{label}"

      # Dispatch to ConceptsController#biomixer
      req = ActionDispatch::TestRequest.create
      params.each { |k, v| req.params[k] = v }
      res = ActionDispatch::TestResponse.create
      ctrl = ConceptsController.new
      ctrl.set_request!(req)
      ctrl.set_response!(res)
      ctrl.define_singleton_method(:render) { |*args| self.response_body = 'biomixer rendered' }

      ctrl.process(:biomixer)

      assert_equal raw_uri, $received_conceptid,
                   "ConceptsController#biomixer receiver must receive EXACT uncorrupted raw URI for #{label}"
    end
  end

  # =========================================================================
  # Flow 3: SearchResultComponent#mappings_button (no double-encoding)
  # =========================================================================
  def test_search_result_mappings_button_preserves_single_encoding_and_roundtrips
    MATRIX_CASES.each do |label, raw_uri|
      comp = Display::SearchResultComponent.new(
        title: "Test #{label}",
        ontology_id: 'http://example.org/ontologies/TEST_ONTO',
        uri: raw_uri
      )
      comp.instance_variable_set(:@view_context, @view_context)

      html = comp.mappings_button
      doc = Nokogiri::HTML.fragment(html)

      # 1. Check modal anchor href
      href = doc.at_css('a')['href']
      parsed_uri = URI.parse(href)
      assert_nil parsed_uri.fragment, "Modal href outer fragment must be nil for #{label}"

      params = Rack::Utils.parse_nested_query(parsed_uri.query)
      assert_equal raw_uri, params['conceptid'], "Mappings modal link must round-trip raw conceptid for #{label}"

      # Verify no double encoding occurred: raw '#' encoded as '%23', NOT '%2523'
      if raw_uri.include?('#')
        assert_includes href, '%23'
        refute_includes href, '%2523', "Mappings URL must not double-encode '#' to '%2523'"
      end

      # 2. Check turbo-frame src
      frame = doc.at_css('turbo-frame')
      frame_src = frame['src']
      parsed_frame_uri = URI.parse(frame_src)
      assert_nil parsed_frame_uri.fragment, "Turbo-frame src outer fragment must be nil for #{label}"

      frame_params = Rack::Utils.parse_nested_query(parsed_frame_uri.query)
      assert_equal raw_uri, frame_params['conceptid'], "Turbo-frame src must round-trip raw conceptid for #{label}"
    end
  end

  # =========================================================================
  # Flow 4: ImageComponent#depiction_with_modal -> ApplicationController#show_image_modal
  # =========================================================================
  def test_image_component_zoom_modal_roundtrips_nested_url
    image_cases = {
      simple: 'https://example.org/images/pic.png',
      with_query_and_fragment: 'https://example.org/images/pic.png?size=large&format=png#zoom-target',
      with_spaces_and_plus: 'https://example.org/images/scan+1 with spaces.jpg?thumb=200&v=1.2',
      with_percent_and_unicode: 'https://example.org/images/bild_%C3%A4%C3%B6%C3%BC_%E6%97%A5%E6%9C%AC%E8%AA%9E.png?tag=test%201'
    }

    image_cases.each do |label, raw_img_url|
      img_comp = Display::ImageComponent.new(src: raw_img_url, title: "Image #{label}")
      img_comp.instance_variable_set(:@view_context, @view_context)

      html = img_comp.depiction_with_modal(raw_img_url)
      doc = Nokogiri::HTML.fragment(html)
      href = doc.at_css('a')['href']
      refute_nil href, "Image zoom link must be present for #{label}"

      parsed_uri = URI.parse(href)
      assert_nil parsed_uri.fragment, "Outer modal URL fragment must be nil (0 fragments) for #{label}"

      params = Rack::Utils.parse_nested_query(parsed_uri.query)
      assert_equal raw_img_url, params['url'], "Rack query parse must yield original raw nested image URL for #{label}"

      # Dispatch to actual production ApplicationController#show_image_modal
      req = ActionDispatch::TestRequest.create
      params.each { |k, v| req.params[k] = v }
      res = ActionDispatch::TestResponse.create
      ctrl = ApplicationController.new
      ctrl.set_request!(req)
      ctrl.set_response!(res)

      rendered_image_src = nil
      mock_helpers = Object.new
      mock_helpers.define_singleton_method(:prepend) { |_frame, &b| b.call }
      mock_helpers.define_singleton_method(:image_tag) { |src, **_opts| rendered_image_src = src; "<img src=\"#{src}\">" }
      ctrl.define_singleton_method(:helpers) { mock_helpers }
      ctrl.define_singleton_method(:render) { |**kwargs| self.response_body = kwargs[:turbo_stream].to_s }

      ctrl.process(:show_image_modal)

      assert_equal raw_img_url, rendered_image_src,
                   "show_image_modal must receive EXACT uncorrupted nested image URL for #{label}"
      assert_includes Array(ctrl.response_body).join, raw_img_url,
                      "show_image_modal response must include EXACT uncorrupted nested image URL for #{label}"
    end
  end

  # =========================================================================
  # Flow 5: collections/_show.html.haml memberURL -> collections picker receiver
  # =========================================================================
  def test_collections_show_haml_members_link_roundtrips_collection_id
    show_template_path = File.join(WORKTREE_ROOT, 'app/views/collections/_show.html.haml')
    show_engine = Haml::Engine.new(File.read(show_template_path))

    picker_template_path = File.join(WORKTREE_ROOT, 'app/views/ontologies/concepts_browsers/_collections_picker.html.haml')
    picker_engine = Haml::Engine.new(File.read(picker_template_path))

    MATRIX_CASES.each do |label, raw_collection_id|
      # Context for collections/_show.html.haml template execution
      ctx = StandaloneViewContext.new(ActionView::LookupContext.new([]), {}, nil)
      ctx.instance_variable_set(:@ontology, OpenStruct.new(acronym: 'TEST_ONTO'))

      coll = OpenStruct.new(id: raw_collection_id, properties: {}, memberCount: 77)
      coll['@id'] = raw_collection_id
      coll['memberCount'] = 77
      coll['@type'] = 'skos:Collection'
      ctx.instance_variable_set(:@collection, coll)

      ctx.define_singleton_method(:ontology_object_details_component) { |**_kwargs, &block| block.call }
      ctx.define_singleton_method(:render) do |comp, &block|
        if comp.class.name.to_s.include?('ConceptDetailsComponent')
          builder = Object.new
          builder.define_singleton_method(:header) do |**_opts, &tbl_block|
            tbl = Object.new
            tbl.define_singleton_method(:add_row) do |*args, &row_block|
              if row_block
                row_wrapper = Object.new
                row_wrapper.define_singleton_method(:td) { |&td_block| td_block.call }
                row_block.call(row_wrapper)
              end
            end
            tbl_block.call(tbl)
          end
          block.call(builder)
        else
          ''
        end
      end
      ctx.define_singleton_method(:link_to_with_actions) { |*_args| '' }
      ctx.define_singleton_method(:display_in_multiple_languages) { |*_args| '' }
      ctx.define_singleton_method(:get_collection_label) { |*_args| '' }

      rendered_html = show_engine.render(ctx)
      doc = Nokogiri::HTML.fragment(rendered_html)
      link = doc.at_css('a[data-turbo-frame="_top"]')
      refute_nil link, "Collection memberCount link must render for #{label}"

      href = link['href']
      parsed_uri = URI.parse(href)
      assert_nil parsed_uri.fragment, "Outer URL fragment must be nil (0 fragments) for #{label}"

      params = Rack::Utils.parse_nested_query(parsed_uri.query)
      assert_equal 'classes', params['p']
      assert_equal 'list', params['sub_menu']
      assert_equal raw_collection_id, params['concept_collections'],
                   "collection member URL must roundtrip exact raw collection IRI for #{label}"

      # Feed Rack-parsed query params into the actual receiver collections picker template
      picker_ctx = StandaloneViewContext.new(ActionView::LookupContext.new([]), {}, nil)
      picker_ctx.instance_variable_set(:@collections, [
        { '@id' => raw_collection_id, 'prefLabel' => ['Selected Collection'], 'color' => '#ffffff' },
        { '@id' => 'http://example.org/other_collection', 'prefLabel' => ['Other Collection'], 'color' => '#000000' }
      ])
      picker_ctx.define_singleton_method(:params) { params.symbolize_keys }
      picker_ctx.define_singleton_method(:id) { 'collections_picker_test' }
      picker_ctx.define_singleton_method(:multiple) { true }
      picker_ctx.define_singleton_method(:data) { {} }

      picker_html = picker_engine.render(picker_ctx)
      picker_doc = Nokogiri::HTML.fragment(picker_html)
      selected_option = picker_doc.at_css('option[selected="selected"]')
      refute_nil selected_option, "Receiver collections picker must select the matching collection option for #{label}"
      assert_equal raw_collection_id, selected_option['value'],
                   "Receiver collections picker selected option must match exact raw collection IRI for #{label}"
    end
  end

  # =========================================================================
  # Flow 6: recommender/index.html.haml annotator handoff URL
  # =========================================================================
  def test_recommender_annotator_handoff_roundtrips_text_and_ontologies
    template_path = File.join(WORKTREE_ROOT, 'app/views/recommender/index.html.haml')
    template_content = File.read(template_path)

    # Extract actual unchanged .go-to-annotator Haml fragment from recommender template
    match = template_content.match(/^\s*\.go-to-annotator\n(?:\s{12,}.*\n?)+/)
    refute_nil match, 'recommender/index.html.haml must contain .go-to-annotator block'
    flines = match[0].lines
    indent = flines.first[/^\s*/].size
    dedented_fragment = flines.map { |l| l.sub(/^\s{0,#{indent}}/, '') }.join
    engine = Haml::Engine.new(dedented_fragment)

    recommender_cases = [
      { text: 'melanoma + skin cancer & stage#2 %20 extra äöü', ontologies: 'NCIT,MESH,HP#Sub' },
      { text: 'http://example.org/onto#Term+1 & text', ontologies: 'CHEBI,GO+EXTRA' },
      { text: 'Class+Positive Condition', ontologies: 'ONTO+PLUS,CHEBI' },
      { text: 'item%20with%2Fescapes', ontologies: 'ONT%201,ONT%2F2' },
      { text: 'Phänomen_Entität_äöü_日本語', ontologies: 'ONTO_äöü,MESH_日本語' },
      { text: 'http://example.org/onto#Class+Positive&filter=A%20B&tag=äöü_日本語', ontologies: 'NCIT#1,GO+2&3%20äöü' }
    ]

    recommender_cases.each do |tc|
      input_val = tc[:text]
      ontologies_val = tc[:ontologies]

      ctx = StandaloneViewContext.new(@view_context.lookup_context, {}, nil)
      ctx.define_singleton_method(:params) { { input: input_val, ontologies: ontologies_val } }

      rendered_html = engine.render(ctx)
      doc = Nokogiri::HTML.fragment(rendered_html)
      link = doc.at_css('a#recommender_go_annotator')
      refute_nil link, "Recommender go_annotator button must render link for #{input_val}"

      rendered_href = link['href']
      parsed_uri = URI.parse(rendered_href)
      assert_nil parsed_uri.fragment, "Annotator outer URL fragment must be nil for #{input_val}"

      params = Rack::Utils.parse_nested_query(parsed_uri.query)
      assert_equal input_val, params['text'], "params[:text] must roundtrip exact input value for #{input_val}"
      assert_equal ontologies_val, params['ontologies'], "params[:ontologies] must roundtrip exact ontologies for #{ontologies_val}"
    end
  end

  # =========================================================================
  # Flow 7: SearchHelper#render_search_paginated_list lang encoding both branches
  # =========================================================================
  def test_search_helper_render_search_paginated_list_encodes_lang_consistently_both_branches
    lang_cases = [
      'en',
      'de-AT+latin#dialect',
      'zh-CN',
      'fr&style=compact%20special'
    ]

    lookup_context = ActionView::LookupContext.new([
      File.join(WORKTREE_ROOT, 'app/components'),
      File.join(WORKTREE_ROOT, 'app/components/tree_link_component'),
      File.join(WORKTREE_ROOT, 'app/components/tree_view_component'),
      File.join(WORKTREE_ROOT, 'app/components/infinite_scroll_component'),
      File.join(WORKTREE_ROOT, 'app/components/tree_infinite_scroll_component')
    ])

    lang_cases.each do |raw_lang|
      controller = ActionController::Base.new
      host = StandaloneViewContext.new(lookup_context, {}, controller)

      raw_concept_id = 'http://example.org/onto#Concept+1&val=2%20extra'
      results_list = [{ name: 'ontology' }, { name: raw_concept_id }]

      # -------------------------------------------------------------
      # Branch 1: show_count: true, page: 1
      # -------------------------------------------------------------
      host.define_singleton_method(:params) do
        { search: 'query+1&tag#2', page: '1', page_size: '50', child_id: raw_concept_id, type: 'SpecialIndividual' }
      end

      result1 = host.render_search_paginated_list(
        container_id: 'test_container',
        next_page_url: '/ontologies/TEST/instances?type=SpecialIndividual',
        child_url: '/ontologies/TEST/instances/show',
        child_turbo_frame: 'test_frame',
        child_param: :child_id,
        show_count: true,
        lang: raw_lang,
        results: results_list,
        next_page: 2,
        total_count: 50
      )

      assert_kind_of Array, result1, 'show_count branch must return array of Turbo stream actions'
      doc1 = Nokogiri::HTML.fragment(result1[1])
      link1 = doc1.at_css('a')
      refute_nil link1, 'Branch 1 must render child tree link'

      child_url1 = link1['href']
      parsed_child1 = URI.parse(child_url1)
      assert_nil parsed_child1.fragment, 'child_url outer fragment must be nil on branch 1'
      params_child1 = Rack::Utils.parse_nested_query(parsed_child1.query)
      assert_equal raw_lang, params_child1['lang'], 'Branch 1 child_url must roundtrip raw lang'
      assert_equal raw_concept_id, params_child1['id'], 'Branch 1 child_url must roundtrip raw concept id'

      # Verify next_page_url emitted in lazy-loading turbo-frame
      next_frame1 = doc1.at_css('turbo-frame[loading="lazy"]')
      refute_nil next_frame1, 'Branch 1 must emit lazy-loading turbo-frame for next page'
      next_params1 = Rack::Utils.parse_nested_query(URI.parse(next_frame1['src']).query)
      assert_equal '2', next_params1['page']
      assert_equal 'query+1&tag#2', next_params1['search']
      assert_equal raw_lang, next_params1['lang']
      assert_equal raw_concept_id, next_params1['child_id']
      assert_equal 'SpecialIndividual', next_params1['type']

      # -------------------------------------------------------------
      # Branch 2: show_count: false, page: 2
      # -------------------------------------------------------------
      host.define_singleton_method(:params) do
        { search: 'query+1&tag#2', page: '2', page_size: '50', child_id: raw_concept_id, type: 'SpecialIndividual' }
      end

      result2 = host.render_search_paginated_list(
        container_id: 'test_container',
        next_page_url: '/ontologies/TEST/instances?type=SpecialIndividual',
        child_url: '/ontologies/TEST/instances/show',
        child_turbo_frame: 'test_frame',
        child_param: :child_id,
        show_count: false,
        lang: raw_lang,
        results: results_list,
        next_page: 3,
        total_count: 50
      )

      assert_kind_of String, result2, 'show_count=false branch must return rendered HTML string'
      doc2 = Nokogiri::HTML.fragment(result2)
      link2 = doc2.at_css('a')
      refute_nil link2, 'Branch 2 must render child tree link'

      child_url2 = link2['href']
      parsed_child2 = URI.parse(child_url2)
      assert_nil parsed_child2.fragment, 'child_url outer fragment must be nil on branch 2'
      params_child2 = Rack::Utils.parse_nested_query(parsed_child2.query)
      assert_equal raw_lang, params_child2['lang'], 'Branch 2 child_url must roundtrip raw lang'
      assert_equal raw_concept_id, params_child2['id'], 'Branch 2 child_url must roundtrip raw concept id'

      # Verify consistent encoding across both branches
      assert_equal child_url1, child_url2, 'child_url encoding must be identical across both branches'

      # Verify next_page_url emitted in lazy-loading turbo-frame for branch 2
      next_frame2 = doc2.at_css('turbo-frame[loading="lazy"]')
      refute_nil next_frame2, 'Branch 2 must emit lazy-loading turbo-frame for next page'
      next_params2 = Rack::Utils.parse_nested_query(URI.parse(next_frame2['src']).query)
      assert_equal '3', next_params2['page']
      assert_equal 'query+1&tag#2', next_params2['search']
      assert_equal raw_lang, next_params2['lang']
      assert_equal raw_concept_id, next_params2['child_id']
      assert_equal 'SpecialIndividual', next_params2['type']
    end
  end
end
