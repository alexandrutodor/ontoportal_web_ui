# frozen_string_literal: true

require 'minitest/autorun'
require 'ostruct'

# =============================================================================
# Standalone Offline Rendered Component Response Regression Test (ONTO-T-B13)
#
# Validates the B13 contract for already-rendered component HTML responses:
# 1. SubmissionsController#edit_properties renders already-rendered helper output
#    via normal Rails html rendering (render html:) ONCE without ERB re-evaluation.
# 2. SearchHelper#render_search_paginated_list returns paginated_list_component
#    directly on non-show-count branch without invoking render inline.
# 3. Harmless literal ERB arithmetic (<%= 7 * 6 %> / <%= 9 * 9 %>) stays literal.
# 4. Existing SafeBuffer, Turbo Frame / Stream structures, and stream branch behavior
#    are preserved.
# =============================================================================

# Load actual Rails ActionController & ActionView libraries when available (e.g. in container),
# or provide minimal standalone doubles for host execution without booting Rails or downloading gems.
begin
  require 'action_controller'
  require 'action_view'

  class ApplicationController < ActionController::Base
    def determine_layout; false; end
    def authorize_and_redirect; end
    def authorize_read_only; end
    def submission_metadata; end
  end
rescue LoadError
  class Object
    def presence
      present? ? self : nil
    end

    def present?
      !blank?
    end

    def blank?
      respond_to?(:empty?) ? !!empty? : !self
    end
  end

  class String
    def blank?
      strip.empty?
    end

    def html_safe
      SafeBuffer.new(self)
    end
  end

  class SafeBuffer < String
    def html_safe?; true; end
    def to_s; self; end
  end

  module Rack
    module MockRequest
      def self.env_for(uri)
        { 'PATH_INFO' => uri }
      end
    end
  end

  module ActionDispatch
    class Request
      attr_reader :env, :params

      def initialize(env)
        @env = env
        @params = {}
        if (query = env['PATH_INFO']&.split('?')&.at(1))
          query.split('&').each do |pair|
            k, v = pair.split('=')
            @params[k.to_sym] = v
            @params[k] = v
          end
        end
      end
    end

    class Response
      attr_accessor :status, :content_type, :body

      def initialize
        @status = 200
        @content_type = nil
        @body = +''
      end
    end
  end

  class ApplicationController
    def self.layout(*); end
    def self.before_action(*); end

    attr_accessor :params, :response

    def render(options = {})
      @response ||= ActionDispatch::Response.new
      if options[:html]
        @response.status = 200
        @response.content_type = 'text/html; charset=utf-8'
        @response.body = options[:html].to_s
      end
    end

    def dispatch(action, req, res)
      @params = req.params
      @response = res
      send(action)
    end
  end

  module ActionView
    module Helpers
      module TagHelper
        def content_tag(tag, content = nil, &block)
          inner = block ? block.call : content
          "<#{tag}>#{inner}</#{tag}>".html_safe
        end
      end
    end
  end
end

module SubmissionUpdater; end
module OntologyUpdater; end
module SubmissionsHelper; end

# Load actual modified files
require_relative '../../app/controllers/submissions_controller'
require_relative '../../app/helpers/search_helper'

class RenderedComponentResponseRegressionTest < Minitest::Test
  def test_submissions_controller_edit_properties_renders_html_once_without_erb_evaluation
    controller = SubmissionsController.new
    env = Rack::MockRequest.env_for('/ontologies/TEST/submissions/1/edit_properties?container_id=ontology-content-0')
    req = ActionDispatch::Request.new(env)
    res = ActionDispatch::Response.new

    controller.define_singleton_method(:display_submission_attributes) do |*args, **kwargs|
      @submission = Object.new
    end

    producer_calls = 0
    mock_helpers = Object.new
    mock_helpers.define_singleton_method(:render_submission_inputs) do |frame_id, _submission|
      producer_calls += 1
      "<turbo-frame id=\"#{frame_id}\"><div class=\"field\"><%= 7 * 6 %></div></turbo-frame>".html_safe
    end

    controller.define_singleton_method(:helpers) { mock_helpers }

    controller.dispatch(:edit_properties, req, res)

    assert_equal 200, res.status, 'Expected HTTP 200 OK'
    assert_includes res.content_type, 'text/html', 'Expected text/html content-type'
    assert_equal 1, producer_calls, 'Producer helper render_submission_inputs must be invoked exactly once'
    assert_includes res.body, '<%= 7 * 6 %>', 'Harmless literal ERB arithmetic must remain literal bytes'
    refute_includes res.body, '42', 'Literal ERB must never be evaluated in already-rendered component HTML'
    assert_includes res.body, '<turbo-frame id="ontology-content-0">', 'TurboFrame ID and container structure preserved'
  end

  def test_search_helper_render_search_paginated_list_non_show_count_returns_component_without_erb_evaluation
    host_class = Class.new do
      include ActionView::Helpers::TagHelper
      include SearchHelper

      attr_accessor :params, :producer_calls

      def initialize
        @params = { search: 'test', page: 2, page_size: 10 }
        @producer_calls = 0
      end

      def request_lang; 'en'; end
      def escape(val); val.to_s; end
      def replace(target, content); [:replace, target, content]; end
      def prepend(target, content); [:prepend, target, content]; end

      def paginated_list_component(id:, results:, next_page_url:, child_url:, child_turbo_frame:, child_param:, **_kwargs)
        @producer_calls += 1
        "<div id=\"#{id}\">paginated items count: <%= 9 * 9 %></div>".html_safe
      end

      def render(*_args)
        flunk 'SearchHelper#render_search_paginated_list must not invoke render inline'
      end
    end

    host = host_class.new
    result = host.render_search_paginated_list(
      container_id: 'props_list',
      next_page_url: '/ontologies/TEST/properties',
      child_url: '/ontologies/TEST/properties/show',
      child_turbo_frame: 'prop_frame',
      child_param: :prop_id,
      results: [{ name: 'ontology' }, { name: 'prop1' }],
      next_page: 3,
      total_count: 20
    )

    assert_equal 1, host.producer_calls, 'Producer component must be invoked exactly once'
    assert_includes result, '<%= 9 * 9 %>', 'Harmless literal ERB arithmetic must remain literal bytes'
    refute_includes result, '81', 'Literal ERB must never be evaluated on component output'
    assert_includes result, '<div id="props_list">', 'Container ID must be preserved'
    assert result.html_safe?, 'SafeBuffer contract must be preserved'
  end

  def test_search_helper_render_search_paginated_list_show_count_preserves_turbo_stream_array
    host_class = Class.new do
      include ActionView::Helpers::TagHelper
      include SearchHelper

      attr_accessor :params, :producer_calls

      def initialize
        @params = { search: 'test', page: 1, page_size: 10, child_key: 'item1' }
        @producer_calls = 0
      end

      def request_lang; 'en'; end
      def escape(val); val.to_s; end
      def replace(target, content); { action: :replace, target: target, content: content }; end
      def prepend(target, content); { action: :prepend, target: target, content: content }; end

      def paginated_list_component(id:, results:, next_page_url:, child_url:, child_turbo_frame:, child_param:, **_kwargs)
        @producer_calls += 1
        "<div id=\"#{id}_list\"><%= 3 * 3 %></div>".html_safe
      end
    end

    host = host_class.new
    result = host.render_search_paginated_list(
      container_id: 'instances_sorted_list',
      next_page_url: '/ontologies/TEST/instances',
      child_url: '/ontologies/TEST/instances/show',
      child_turbo_frame: 'instance_show',
      child_param: :child_key,
      show_count: true,
      results: [{ name: 'ontology' }, { name: 'item1' }, { name: 'item2' }],
      next_page: 2,
      total_count: 2
    )

    assert_instance_of Array, result, 'Stream branch must return stream action array'
    assert_equal 2, result.size, 'Expected 2 stream actions (replace count and prepend view)'
    assert_equal :replace, result[0][:action]
    assert_equal 'instances_sorted_list_count', result[0][:target]
    assert_equal :prepend, result[1][:action]
    assert_equal 'instances_sorted_list_view-page-1', result[1][:target]
    assert_equal 1, host.producer_calls, 'Producer component must be invoked once in stream branch'
  end
end
