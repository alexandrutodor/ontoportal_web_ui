# frozen_string_literal: true

# ONTO-T-Q08 coverage startup and tracking policy:
# - Opt-in instrumentation: runs only when COVERAGE=true or COVERAGE=1.
# - Preboot start: starts SimpleCov before any Rails environment or application files load.
# - Whole application tracking: track_files 'app/**/*.rb' to include unexecuted files with 0 coverage.
# - Preserve standard Rails profile and directory filters (/bin/, /db/, /test/, /vendor/).
# - No coverage threshold or historical percentage enforcement.
# - Command and namespace isolation: default suite is Minitest (coverage/minitest/); explicit COVERAGE_SUITE
#   (e.g. system) receives a sanitized command name and isolated namespace under coverage/<suite>/.
# - Distinct per-suite directories prevent cross-suite overwrite or stale automatic merging.
# - Current CI runs single-worker Minitest; RSpec uncollected, system suites opt-in only.
# - Pure Ruby stdlib preboot checks: no Rails.root or ActiveSupport .present? assumptions.

coverage_enabled = %w[true 1].include?(ENV['COVERAGE'].to_s.strip.downcase)

if coverage_enabled
  require 'simplecov'

  suite_raw = ENV['COVERAGE_SUITE'].to_s.strip
  suite_key = suite_raw.empty? ? 'minitest' : suite_raw.downcase.gsub(/[^a-z0-9_-]/, '_')
  cmd_name = suite_raw.empty? ? 'Minitest' : suite_key

  app_root = File.expand_path('..', __dir__)

  SimpleCov.start 'rails' do
    root app_root
    coverage_dir File.join('coverage', suite_key)
    command_name cmd_name
    track_files 'app/**/*.rb'

    add_filter '/bin/'
    add_filter '/db/'
    add_filter '/test/'
    add_filter '/vendor/'
  end
end
