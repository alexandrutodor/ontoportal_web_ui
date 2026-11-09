# frozen_string_literal: true

# ONTO-T-Q09: the federation browse wait must end: it returns once loading finishes and
# fails with a scoped message at the deadline or when results stop growing.
require 'minitest/autorun'
require_relative '../helpers/browse_wait'

class BrowseWaitCheck < Minitest::Test
  include BrowseWait

  # Finite Capybara page double: skeleton visible for `loading_polls` polls; results grow by `growth`.
  class FakePage
    attr_reader :scrolls, :current_url
    def initialize(loading_polls:, growth: 1)
      @left = loading_polls
      @growth = growth
      @count = 0
      @scrolls = 0
      @current_url = 'http://ui.test/ontologies?portals=agroportal'
    end

    def has_css?(_selector, wait:)
      raise 'must not block' unless wait.zero?
      return false if @left <= 0

      @left -= 1
      @count += @growth
      true
    end

    def all(_selector, wait:) = Array.new(@count)
    def execute_script(_js) = @scrolls += 1
  end

  attr_reader :page

  def sleep(_seconds) = nil # polls are counted, not timed

  def test_returns_when_loading_finishes_and_scrolls
    @page = FakePage.new(loading_polls: 5)
    wait_for_browse_loaded
    assert_equal 5, page.scrolls
  end

  def test_without_scroll_does_not_scroll
    @page = FakePage.new(loading_polls: 3)
    wait_for_browse_loaded(scroll: false)
    assert_equal 0, page.scrolls
  end

  def test_fails_at_deadline_when_skeleton_never_clears
    @page = FakePage.new(loading_polls: Float::INFINITY)
    error = assert_raises(Minitest::Assertion) { wait_for_browse_loaded(timeout: 0.05, stall_timeout: 10) }
    assert_match(/still loading after 0.05s at http:\/\/ui.test\/ontologies\?portals=agroportal/, error.message)
  end

  def test_fails_when_results_stop_growing
    @page = FakePage.new(loading_polls: Float::INFINITY, growth: 0)
    error = assert_raises(Minitest::Assertion) { wait_for_browse_loaded(timeout: 10, stall_timeout: 0.05) }
    assert_match(/no progress for 0.05s \(0 results\)/, error.message)
  end
end
