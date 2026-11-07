# frozen_string_literal: true

require 'minitest/autorun'
require 'open3'
require 'tmpdir'
require 'fileutils'
require 'json'

# =============================================================================
# Standalone Coverage Startup & Instrumentation Regression Test (ONTO-T-Q08)
#
# Validates:
# 1. Static ordering in test/test_helper.rb (coverage preboot before Rails/environment).
# 2. Pure stdlib preboot execution without Rails, ActiveSupport, or Rails.root assumptions.
# 3. Real SimpleCov instrumentation begins before boot-loaded application probe.
# 4. Unexecuted application file included with zero lines via track_files 'app/**/*.rb'.
# 5. Distinct per-suite command and output namespaces under coverage/ (no overwrite/stale merge).
# 6. Flag-off behavior: no SimpleCov or Coverage overhead when COVERAGE is not true/1.
# =============================================================================

class CoverageStartupCheckTest < Minitest::Test
  def setup
    @repo_root = File.expand_path('../..', __dir__)
    @test_helper_path = File.join(@repo_root, 'test', 'test_helper.rb')
    @coverage_helper_path = File.join(@repo_root, 'test', 'coverage_helper.rb')
    @overlay_gem_path = File.join(@repo_root, '.remediation', 'runtime-simplecov', 'gems')
  end

  # --- 1. Static ordering in test/test_helper.rb ---

  def test_static_helper_ordering_preboots_coverage_before_rails_environment
    assert File.exist?(@test_helper_path), "Expected #{@test_helper_path} to exist"
    content = File.read(@test_helper_path)

    coverage_helper_idx = content.index("require_relative 'coverage_helper'")
    env_idx = content.index("require_relative '../config/environment'")
    rails_test_idx = content.index("require 'rails/test_help'")

    refute_nil coverage_helper_idx, "Expected test/test_helper.rb to require_relative 'coverage_helper'"
    refute_nil env_idx, "Expected test/test_helper.rb to require_relative '../config/environment'"
    refute_nil rails_test_idx, "Expected test/test_helper.rb to require 'rails/test_help'"

    assert coverage_helper_idx < env_idx,
      "Expected coverage_helper to be required BEFORE config/environment"
    assert env_idx < rails_test_idx,
      "Expected config/environment to be required BEFORE rails/test_help"

    # Confirm post-environment unconditional SimpleCov.start is removed from test_helper.rb
    refute content.include?("SimpleCov.start 'rails'"),
      "SimpleCov.start must not be invoked inside test_helper.rb after environment loading"
  end

  # --- 2. Pure stdlib preboot compatibility (no Rails/ActiveSupport assumptions) ---

  def test_coverage_helper_evaluates_without_rails_or_activesupport
    # Spawns a clean Ruby process without Rails, ActiveSupport, or Bundler
    script = <<~RUBY
      ENV['COVERAGE'] = nil
      require #{@coverage_helper_path.dump}
      puts :clean_preboot_ok
    RUBY

    out, err, status = Open3.capture3('ruby', '-e', script)
    assert_equal 0, status.exitstatus, "Preboot script failed with stderr: #{err}"
    assert_includes out, 'clean_preboot_ok'
  end

  # --- 3. Real SimpleCov instrumentation before boot & unexecuted file tracking ---

  def test_real_instrumentation_tracks_boot_loaded_probe_and_unexecuted_probe
    with_synthetic_app_fixture do |app_dir|
      runner = File.join(app_dir, 'run_minitest.rb')
      File.write(runner, <<~RUBY)
        require_relative 'test/coverage_helper'
        # Simulates Rails boot-time require:
        require_relative 'app/models/boot_probe'
        BootProbe.boot_method
      RUBY

      env = {
        'COVERAGE' => 'true',
        'COVERAGE_SUITE' => '' # Default suite
      }

      out, err, status = run_in_fixture(env, runner, app_dir)
      assert_equal 0, status.exitstatus, "Runner exited with error: #{err}\n#{out}"

      resultset_path = File.join(app_dir, 'coverage', 'minitest', '.resultset.json')
      assert File.exist?(resultset_path), "Expected report at #{resultset_path}"

      resultset = JSON.parse(File.read(resultset_path))
      assert_equal ['Minitest'], resultset.keys, "Expected command name 'Minitest'"

      coverage_data = resultset['Minitest']['coverage']

      # 3a: Boot-loaded probe must have executed lines captured (> 0)
      boot_file = coverage_data.keys.find { |k| k.end_with?('app/models/boot_probe.rb') }
      refute_nil boot_file, "Expected app/models/boot_probe.rb in coverage data"
      boot_lines = coverage_data[boot_file]['lines']
      refute_empty boot_lines
      executed_lines = boot_lines.compact.select { |count| count > 0 }
      assert executed_lines.size >= 2,
        "Expected at least 2 executed lines in boot_probe.rb (class definition + boot_method), got: #{boot_lines.inspect}"

      # 3b: Unexecuted probe must be present in report with 0 covered lines
      unexec_file = coverage_data.keys.find { |k| k.end_with?('app/models/unexecuted_probe.rb') }
      refute_nil unexec_file, "Expected unexecuted app/models/unexecuted_probe.rb in coverage data"
      unexec_lines = coverage_data[unexec_file]['lines']
      refute_empty unexec_lines
      assert unexec_lines.compact.all? { |count| count == 0 },
        "Expected all lines in unexecuted_probe.rb to have 0 hits, got: #{unexec_lines.inspect}"

      # 3c: HTML report and .last_run.json presence
      assert File.exist?(File.join(app_dir, 'coverage', 'minitest', 'index.html'))
      assert File.exist?(File.join(app_dir, 'coverage', 'minitest', '.last_run.json'))
    end
  end

  # --- 4. Counterexample contrast: Broken startup order misses boot execution ---

  def test_counterexample_broken_startup_order_misses_boot_execution
    with_synthetic_app_fixture do |app_dir|
      runner = File.join(app_dir, 'run_broken.rb')
      File.write(runner, <<~RUBY)
        # Broken order: load app code FIRST (like old test_helper.rb requiring environment before SimpleCov)
        require_relative 'app/models/boot_probe'
        BootProbe.boot_method

        require 'simplecov'
        SimpleCov.start 'rails' do
          root #{app_dir.dump}
          coverage_dir 'coverage/broken'
          track_files 'app/**/*.rb'
        end
      RUBY

      env = { 'COVERAGE' => 'true' }
      out, err, status = run_in_fixture(env, runner, app_dir)
      assert_equal 0, status.exitstatus, "Broken runner failed: #{err}\n#{out}"

      resultset_path = File.join(app_dir, 'coverage', 'broken', '.resultset.json')
      assert File.exist?(resultset_path)

      resultset = JSON.parse(File.read(resultset_path))
      coverage_data = resultset.values.first['coverage']

      boot_file = coverage_data.keys.find { |k| k.end_with?('app/models/boot_probe.rb') }
      refute_nil boot_file
      boot_lines = coverage_data[boot_file]['lines']

      # In broken startup, boot_probe was required BEFORE Coverage.start, so track_files
      # only loads it retrospectively with 0 executed hits!
      assert boot_lines.compact.all? { |count| count == 0 },
        "In broken startup order, boot_probe lines should have 0 recorded hits, got: #{boot_lines.inspect}"
    end
  end

  # --- 5. Separate suites retain distinct reports (no overwrite or stale merge) ---

  def test_separate_suites_retain_distinct_reports_without_cross_suite_merge
    with_synthetic_app_fixture do |app_dir|
      runner_minitest = File.join(app_dir, 'run_mini.rb')
      File.write(runner_minitest, <<~RUBY)
        require_relative 'test/coverage_helper'
        require_relative 'app/models/boot_probe'
        BootProbe.boot_method
      RUBY

      runner_system = File.join(app_dir, 'run_sys.rb')
      File.write(runner_system, <<~RUBY)
        require_relative 'test/coverage_helper'
        require_relative 'app/models/boot_probe'
        BootProbe.system_method
      RUBY

      # Suite 1: default minitest
      env1 = { 'COVERAGE' => 'true' }
      run_in_fixture(env1, runner_minitest, app_dir)

      # Suite 2: system
      env2 = { 'COVERAGE' => 'true', 'COVERAGE_SUITE' => 'system' }
      run_in_fixture(env2, runner_system, app_dir)

      path_minitest = File.join(app_dir, 'coverage', 'minitest', '.resultset.json')
      path_system = File.join(app_dir, 'coverage', 'system', '.resultset.json')

      assert File.exist?(path_minitest), "Minitest report must exist"
      assert File.exist?(path_system), "System report must exist"

      data_minitest = JSON.parse(File.read(path_minitest))
      data_system = JSON.parse(File.read(path_system))

      assert_equal ['Minitest'], data_minitest.keys, "Minitest resultset must have only 'Minitest'"
      assert_equal ['system'], data_system.keys, "System resultset must have only 'system'"

      # Verify Suite 2 did not overwrite Suite 1 report
      assert File.exist?(File.join(app_dir, 'coverage', 'minitest', 'index.html'))
      assert File.exist?(File.join(app_dir, 'coverage', 'system', 'index.html'))
    end
  end

  # --- 6. Flag-off behavior: no SimpleCov or Coverage overhead ---

  def test_flag_off_produces_no_instrumentation_or_coverage_files
    with_synthetic_app_fixture do |app_dir|
      runner = File.join(app_dir, 'run_off.rb')
      File.write(runner, <<~RUBY)
        require 'json'
        require_relative 'test/coverage_helper'
        require_relative 'app/models/boot_probe'
        BootProbe.boot_method

        result = {
          simplecov_defined: defined?(SimpleCov) != nil,
          coverage_running: defined?(Coverage) && Coverage.respond_to?(:running?) && Coverage.running?
        }
        File.write(File.join(#{app_dir.dump}, 'status.json'), JSON.generate(result))
      RUBY

      # Run with COVERAGE=false
      _out, err, status = run_in_fixture({ 'COVERAGE' => 'false' }, runner, app_dir)
      assert_equal 0, status.exitstatus, "Flag-off runner failed: #{err}"
      status1 = JSON.parse(File.read(File.join(app_dir, 'status.json')))
      refute status1['simplecov_defined'], "SimpleCov must not be defined when COVERAGE=false"
      refute status1['coverage_running'], "Coverage must not be running when COVERAGE=false"
      refute File.exist?(File.join(app_dir, 'coverage')), "coverage/ dir must not exist"

      # Reset and run with COVERAGE unset
      FileUtils.rm_f(File.join(app_dir, 'status.json'))
      _out, err, status = run_in_fixture({}, runner, app_dir)
      assert_equal 0, status.exitstatus, "Flag-unset runner failed: #{err}"
      status2 = JSON.parse(File.read(File.join(app_dir, 'status.json')))
      refute status2['simplecov_defined'], "SimpleCov must not be defined when COVERAGE is unset"
      refute status2['coverage_running'], "Coverage must not be running when COVERAGE is unset"
      refute File.exist?(File.join(app_dir, 'coverage')), "coverage/ dir must not exist"
    end
  end

  # --- 7. Suite name sanitization ---

  def test_suite_name_sanitization_for_output_directory
    with_synthetic_app_fixture do |app_dir|
      runner = File.join(app_dir, 'run_custom.rb')
      File.write(runner, <<~RUBY)
        require_relative 'test/coverage_helper'
        require_relative 'app/models/boot_probe'
        BootProbe.boot_method
      RUBY

      env = {
        'COVERAGE' => '1',
        'COVERAGE_SUITE' => 'integration/custom suite-1'
      }

      run_in_fixture(env, runner, app_dir)

      # Slashes and spaces should be safely sanitized to underscores
      expected_dir = File.join(app_dir, 'coverage', 'integration_custom_suite-1')
      assert File.exist?(expected_dir), "Expected sanitized directory #{expected_dir} to exist"
      assert File.exist?(File.join(expected_dir, '.resultset.json'))
    end
  end

  private

  def with_synthetic_app_fixture
    Dir.mktmpdir('onto_q08_fixture') do |dir|
      FileUtils.mkdir_p(File.join(dir, 'app', 'models'))
      FileUtils.mkdir_p(File.join(dir, 'test'))

      # Synthetic boot probe
      File.write(File.join(dir, 'app', 'models', 'boot_probe.rb'), <<~RUBY)
        class BootProbe
          BOOT_CONSTANT = :boot_constant_value
          def self.boot_method
            :boot_executed
          end
          def self.system_method
            :system_executed
          end
        end
      RUBY

      # Synthetic unexecuted probe
      File.write(File.join(dir, 'app', 'models', 'unexecuted_probe.rb'), <<~RUBY)
        class UnexecutedProbe
          def self.never_called
            :never_executed
          end
        end
      RUBY

      # Copy the EXACT production coverage_helper.rb into the synthetic tree
      # solely to reanchor __dir__ roots to the fixture root.
      FileUtils.cp(@coverage_helper_path, File.join(dir, 'test', 'coverage_helper.rb'))

      yield dir
    end
  end

  def run_in_fixture(env, script_path, app_dir)
    exec_env = env.dup
    if File.directory?(@overlay_gem_path)
      current_gem_path = ENV['GEM_PATH'] || ''
      exec_env['GEM_PATH'] = [@overlay_gem_path, current_gem_path].reject(&:empty?).join(':')
      exec_env['GEM_HOME'] = @overlay_gem_path
    end

    Open3.capture3(exec_env, 'ruby', script_path, chdir: app_dir)
  end
end
