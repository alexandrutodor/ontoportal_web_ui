# frozen_string_literal: true

# ONTO-T-B13: already rendered component HTML must not be evaluated again as a template.
# Real ActionController shows the difference on a helper result that contains ERB-looking
# text, and a source check confirms no controller still uses render inline:.
require 'minitest/autorun'
require 'action_controller'
require 'action_view'

class NoInlineRerenderCheck < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  RENDERED = ActiveSupport::SafeBuffer.new('<turbo-frame id="t"><span>label <%= 6 * 7 %></span></turbo-frame>')

  class Probe < ActionController::Base
    def as_inline = render(inline: RENDERED)
    def as_html = render(html: RENDERED)
  end

  def body(action)
    Probe.action(action).call(Rack::MockRequest.env_for('/')).last.each.to_a.join
  end

  def test_render_inline_would_evaluate_rendered_content
    assert_includes body(:as_inline), 'label 42', 'baseline: inline evaluates the ERB tag'
  end

  def test_render_html_returns_rendered_content_unchanged
    assert_equal RENDERED.to_s, body(:as_html)
  end

  def test_no_controller_renders_inline
    offenders = Dir[File.join(ROOT, 'app/controllers/**/*.rb')].flat_map do |f|
      File.readlines(f).each_with_index.select { |l, _| l.match?(/render\s*\(?\s*inline:/) }.map { |_, i| "#{f.delete_prefix(ROOT)}:#{i + 1}" }
    end
    assert_empty offenders
  end
end
