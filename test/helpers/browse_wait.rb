# frozen_string_literal: true

# Bounded wait for lazily loaded browse results (ONTO-T-Q09). Needs Capybara's page and Minitest's flunk.
module BrowseWait
  # Waits until no browse skeleton remains, optionally scrolling to trigger lazy loading.
  # Fails when the total deadline passes or the result count stops growing for stall_timeout seconds.
  def wait_for_browse_loaded(scroll: true, timeout: 120, stall_timeout: 30)
    now = -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) }
    deadline = now.call + timeout
    last_progress = now.call
    last_count = -1
    while page.has_css?('.browse-sket', wait: 0)
      count = page.all('.browse-ontology-title', wait: 0).count
      last_progress, last_count = now.call, count if count > last_count
      flunk "Browse still loading after #{timeout}s at #{page.current_url}" if now.call > deadline
      flunk "Browse made no progress for #{stall_timeout}s (#{count} results) at #{page.current_url}" if now.call - last_progress > stall_timeout
      page.execute_script('window.scrollBy(0, window.innerHeight)') if scroll
      sleep 0.3
    end
  end
end
