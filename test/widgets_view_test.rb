# frozen_string_literal: true

require 'minitest/autorun'

class WidgetsViewTest < Minitest::Test
  def setup
    @view_path = File.expand_path('../app/views/ontologies/_widgets.html.haml', __dir__)
    @content = File.read(@view_path)
  end

  def test_view_file_exists
    assert File.exist?(@view_path), 'Widgets view file must exist'
  end

  def test_modern_custom_elements_present
    assert_includes @content, 'ontoportal-autocomplete'
    assert_includes @content, 'ontoportal-tree'
    assert_includes @content, 'ontoportal-concept-card'
  end

  def test_modern_assets_referenced
    assert_includes @content, '/widgets/modern/ontoportal-widgets.js'
    assert_includes @content, '/widgets/modern/ontoportal-widgets.css'
  end

  def test_legacy_shim_referenced
    assert_includes @content, '/widgets/jquery.ncbo.tree.shim.js'
  end

  def test_demo_link_present
    assert_includes @content, '/widgets/modern/demo.html'
  end
end
