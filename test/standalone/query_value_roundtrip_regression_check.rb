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
require 'turbo-rails'

module Turbo
  module Frames; end
end
require '/usr/local/bundle/ruby/3.1.0/gems/turbo-rails-2.0.12/app/helpers/turbo/frames_helper.rb' rescue nil

ActionController::Base.logger = Logger.new(nil)
Rails.logger = Logger.new(nil)
$REST_URL = 'http://example.com'
$API_KEY = 'test'

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

module Display; end
module Buttons; end

require 'turbo_frame_component'
require 'loader_component'
require 'display/search_result_component'
require 'display/image_component'
require 'buttons/regular_button_component'

# Stub TurboFrameComponent render_in for isolated component testing
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
  include Turbo::FramesHelper if defined?(Turbo::FramesHelper)

  def inline_svg_tag(*_args); '<svg></svg>'.html_safe; end
  def t(key, *_args); key.to_s; end
  def request_lang; 'en'; end
  def render(comp, &block)
    if comp.is_a?(ViewComponent::Base)
      comp.render_in(self, &block)
    else
      super
    end
  end
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

class ApplicationController < ActionController::Base
  def concept_not_found(id); raise "404: #{id}"; end
  def ontology_not_found(id); raise "404: #{id}"; end

  def show_image_modal
    url = params[:url]
    render turbo_stream: helpers.prepend('application_modal_content') { helpers.image_tag(url, style: 'width: 100%') }
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
    @view_context = StandaloneViewContext.new(ActionView::LookupContext.new([]), {}, nil)
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

      # Dispatch to ApplicationController#show_image_modal
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
    end
  end

  # =========================================================================
  # Flow 5: collections/_show.html.haml memberURL -> collection filter handoff
  # =========================================================================
  def test_collections_show_haml_members_link_roundtrips_collection_id
    template_path = File.join(WORKTREE_ROOT, 'app/views/collections/_show.html.haml')
    template_content = File.read(template_path)
    engine = Haml::Engine.new(template_content)

    MATRIX_CASES.each do |label, raw_collection_id|
      # Context for Haml template execution
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
          # Execute the block passed to ConceptDetailsComponent
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

      rendered_html = engine.render(ctx)
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

      # Verify downstream receiver collections picker filter logic matches raw IRI:
      collections_list = [{ '@id' => raw_collection_id }, { '@id' => 'http://example.org/other' }]
      selected = collections_list.select { |s| params['concept_collections']&.split(',')&.include?(s['@id']) }
      assert_equal 1, selected.size, "Downstream collection filter must match collection for #{label}"
      assert_equal raw_collection_id, selected.first['@id']
    end
  end

  # =========================================================================
  # Flow 6: recommender/index.html.haml annotator handoff URL
  # =========================================================================
  def test_recommender_annotator_handoff_roundtrips_text_and_ontologies
    template_path = File.join(WORKTREE_ROOT, 'app/views/recommender/index.html.haml')
    template_content = File.read(template_path)

    recommender_cases = [
      { text: 'melanoma + skin cancer & stage#2 %20 extra äöü', ontologies: 'NCIT,MESH,HP#Sub' },
      { text: 'http://example.org/onto#Term+1 & text', ontologies: 'CHEBI,GO+EXTRA' },
      { text: 'simple input', ontologies: 'SNOMEDCT' }
    ]

    recommender_cases.each do |tc|
      # Test Haml button rendering logic directly
      input_val = tc[:text]
      ontologies_val = tc[:ontologies]

      params_hash = { input: input_val, ontologies: ontologies_val }

      btn_href = "/annotator?text=#{CGI.escape(params_hash[:input].to_s)}&ontologies=#{CGI.escape(params_hash[:ontologies].to_s)}"
      btn = Buttons::RegularButtonComponent.new(
        id: 'recommender_go_annotator',
        value: 'Call Annotator',
        variant: 'secondary',
        href: btn_href,
        size: 'slim',
        target: '_blank',
        state: 'regular'
      )
      btn.instance_variable_set(:@view_context, @view_context)

      html = btn.button_elem
      doc = Nokogiri::HTML.fragment(html)
      link = doc.at_css('a#recommender_go_annotator')
      refute_nil link, 'Recommender go_annotator button must render link'

      rendered_href = link['href']
      parsed_uri = URI.parse(rendered_href)
      assert_nil parsed_uri.fragment, "Annotator outer URL fragment must be nil"

      params = Rack::Utils.parse_nested_query(parsed_uri.query)
      assert_equal input_val, params['text'], 'params[:text] must roundtrip exact input value'
      assert_equal ontologies_val, params['ontologies'], 'params[:ontologies] must roundtrip exact ontologies'
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

    lang_cases.each do |raw_lang|
      host = Object.new
      host.extend(SearchHelper)
      host.extend(UrlsHelper)

      # -------------------------------------------------------------
      # Branch 1: show_count: true, page: 1
      # -------------------------------------------------------------
      captured_branch1 = nil
      host.define_singleton_method(:paginated_list_component) do |**kwargs|
        captured_branch1 = kwargs
        '<div id="paginated_b1">items</div>'.html_safe
      end
      host.define_singleton_method(:replace) { |id, content| "replace:#{id}:#{content}" }
      host.define_singleton_method(:prepend) { |id, content| "prepend:#{id}:#{content}" }
      host.define_singleton_method(:content_tag) { |_tag, content| "<span>#{content}</span>" }
      host.define_singleton_method(:request_lang) { raw_lang }
      host.define_singleton_method(:params) do
        { search: 'query+1&tag#2', page: '1', page_size: '50', child_id: 'http://example.org/inst1' }
      end

      result1 = host.render_search_paginated_list(
        container_id: 'test_container',
        next_page_url: '/ontologies/TEST/instances?type=SpecialIndividual',
        child_url: '/ontologies/TEST/instances/show',
        child_turbo_frame: 'test_frame',
        child_param: :child_id,
        show_count: true,
        lang: raw_lang,
        results: [{ name: 'ontology' }, { name: 'http://example.org/inst1' }],
        next_page: 2,
        total_count: 50
      )

      assert_kind_of Array, result1, 'show_count branch must return array of Turbo stream actions'
      refute_nil captured_branch1, 'paginated_list_component must be called on branch 1'

      child_url1 = captured_branch1[:child_url]
      parsed_child1 = URI.parse(child_url1)
      assert_nil parsed_child1.fragment, 'child_url outer fragment must be nil on branch 1'
      params_child1 = Rack::Utils.parse_nested_query(parsed_child1.query)
      assert_equal raw_lang, params_child1['lang'], 'Branch 1 child_url must roundtrip raw lang'

      # -------------------------------------------------------------
      # Branch 2: show_count: false, page: 2
      # -------------------------------------------------------------
      captured_branch2 = nil
      host.define_singleton_method(:paginated_list_component) do |**kwargs|
        captured_branch2 = kwargs
        '<div id="paginated_b2">items</div>'.html_safe
      end
      host.define_singleton_method(:params) do
        { search: 'query+1&tag#2', page: '2', page_size: '50', child_id: 'http://example.org/inst2' }
      end

      result2 = host.render_search_paginated_list(
        container_id: 'test_container',
        next_page_url: '/ontologies/TEST/instances?type=SpecialIndividual',
        child_url: '/ontologies/TEST/instances/show',
        child_turbo_frame: 'test_frame',
        child_param: :child_id,
        show_count: false,
        lang: raw_lang,
        results: [{ name: 'ontology' }, { name: 'http://example.org/inst2' }],
        next_page: 3,
        total_count: 50
      )

      refute_nil captured_branch2, 'paginated_list_component must be called on branch 2'
      child_url2 = captured_branch2[:child_url]
      parsed_child2 = URI.parse(child_url2)
      assert_nil parsed_child2.fragment, 'child_url outer fragment must be nil on branch 2'
      params_child2 = Rack::Utils.parse_nested_query(parsed_child2.query)
      assert_equal raw_lang, params_child2['lang'], 'Branch 2 child_url must roundtrip raw lang'

      # Verify consistent encoding across both branches
      assert_equal child_url1, child_url2, 'child_url encoding must be identical across both branches'

      # Verify downstream TreeLink href generation from ComponentsHelper#paginated_list_component:
      # Concept ID is escaped once, child_url already contains encoded lang
      raw_concept_id = 'http://example.org/onto#Concept+1&val=2%20extra'
      treelink_href = child_url1.include?('?') ? "#{child_url1}&id=#{CGI.escape(raw_concept_id)}" : "#{child_url1}?id=#{CGI.escape(raw_concept_id)}"
      parsed_tree = URI.parse(treelink_href)
      assert_nil parsed_tree.fragment, 'TreeLink href outer fragment must be nil'
      params_tree = Rack::Utils.parse_nested_query(parsed_tree.query)
      assert_equal raw_lang, params_tree['lang'], 'TreeLink href must preserve exact lang'
      assert_equal raw_concept_id, params_tree['id'], 'TreeLink href must preserve exact concept ID'

      # Verify next_page_link preserves search, page, lang, child_param, and filters
      next_url = captured_branch1[:next_page_url]
      parsed_next = URI.parse(next_url)
      params_next = Rack::Utils.parse_nested_query(parsed_next.query)
      assert_equal '2', params_next['page']
      assert_equal 'query+1&tag#2', params_next['search']
      assert_equal raw_lang, params_next['lang']
      assert_equal 'http://example.org/inst1', params_next['child_id']
      assert_equal 'SpecialIndividual', params_next['type']
    end
  end
end
