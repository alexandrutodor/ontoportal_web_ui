#!/usr/bin/env ruby
# frozen_string_literal: true

# Standalone isolated regression check for ONTO-T-Q02:
# Verifies production runtime signing-secret handling, asset-build dummy flag scoping,
# and exclusion of build-time secret artifacts without booting Rails or calling remote APIs.

require 'securerandom'

failures = []

def assert(condition, message, failures)
  if condition
    puts "  [PASS] #{message}"
  else
    puts "  [FAIL] #{message}"
    failures << message
  end
end

puts "=== Step 1: Inspect Dockerfile configuration ==="
dockerfile_path = File.expand_path('../../Dockerfile', __dir__)
dockerfile_content = File.read(dockerfile_path)

# Check persistent ENV instructions in Dockerfile
# Match any ENV instruction block until next Dockerfile instruction
env_blocks = dockerfile_content.scan(/^ENV\s+.*?(?=(?:^[A-Z]+\s+|\z))/m)
has_persistent_dummy = env_blocks.any? { |blk| blk.match?(/SECRET_KEY_BASE_DUMMY/) }
assert(!has_persistent_dummy, "Dockerfile must not persist SECRET_KEY_BASE_DUMMY in runtime ENV", failures)

# Check scoped dummy flag on assets:precompile
has_scoped_dummy = dockerfile_content.match?(/SECRET_KEY_BASE_DUMMY=1\s+\.\/bin\/rails\s+assets:precompile/)
assert(has_scoped_dummy, "Dockerfile must scope SECRET_KEY_BASE_DUMMY=1 to assets:precompile", failures)

# Check cleanup of generated build-time secret artifact in RUN layer
has_cleanup = dockerfile_content.match?(/rm\s+-f\s+tmp\/development_secret\.txt/)
assert(has_cleanup, "Dockerfile must clean up tmp/development_secret.txt in asset precompile layer", failures)

puts "\n=== Step 2: Load config/environment.rb in isolated harness ==="
# Harness stubbing Rails environment without booting the full Rails framework
module Kernel
  alias_method :original_require_relative, :require_relative
  def require_relative(path)
    return if path == 'application' || path == './application'
    original_require_relative(path)
  end
end

module Rails
  class StringInquirer < String
    def method_missing(method_name, *args)
      method_name.to_s.end_with?('?') ? (to_s == method_name.to_s[0..-2]) : super
    end
    def respond_to_missing?(method_name, include_private = false)
      method_name.to_s.end_with?('?') || super
    end
  end

  def self.env
    @env ||= StringInquirer.new('production')
  end

  def self.env=(value)
    @env = StringInquirer.new(value.to_s)
  end

  def self.application
    @application ||= Application.new
  end

  class Application
    attr_accessor :secrets, :credentials, :generate_development_secret_called

    def initialize
      @secrets = Struct.new(:secret_key_base).new
      @credentials = Struct.new(:secret_key_base).new
      @generate_development_secret_called = false
    end

    def generate_development_secret
      @generate_development_secret_called = true
      "dev_token_generated_by_disk_helper"
    end

    def validate_secret_key_base(secret_key_base)
      if secret_key_base.is_a?(String) && !secret_key_base.strip.empty?
        secret_key_base
      elsif Rails.env.test?
        secrets.secret_key_base ||= generate_development_secret
      else
        raise ArgumentError, "Missing `secret_key_base` for '#{Rails.env}' environment"
      end
    end

    def initialize!
      # No-op during isolated testing
    end
  end
end

# Preserve outer ENV
original_env = ENV.to_h

begin
  load File.expand_path('../../config/environment.rb', __dir__)

  puts "\n=== Step 3: Production configured-secret use ==="
  ENV.replace(original_env)
  ENV['RAILS_ENV'] = 'production'
  ENV['SECRET_KEY_BASE'] = 'prod_secret_token_1234567890abcdef1234567890abcdef'
  ENV.delete('SECRET_KEY_BASE_DUMMY')
  Rails.env = 'production'

  app = Rails::Application.new
  secret = app.secret_key_base
  assert(secret == 'prod_secret_token_1234567890abcdef1234567890abcdef',
         "Production runtime honors configured SECRET_KEY_BASE", failures)
  assert(!app.generate_development_secret_called,
         "Production runtime does not call generate_development_secret when secret is configured", failures)

  # Precedence test: even if dummy flag is passed, configured secret must be honored
  ENV['SECRET_KEY_BASE_DUMMY'] = '1'
  app_with_dummy_flag = Rails::Application.new
  secret_with_dummy = app_with_dummy_flag.secret_key_base
  assert(secret_with_dummy == 'prod_secret_token_1234567890abcdef1234567890abcdef',
         "Configured SECRET_KEY_BASE takes precedence over dummy mode flag", failures)

  puts "\n=== Step 4: Missing secret rejection in production ==="
  ENV.delete('SECRET_KEY_BASE')
  ENV.delete('SECRET_KEY_BASE_DUMMY')
  Rails.env = 'production'

  app = Rails::Application.new
  begin
    app.secret_key_base
    assert(false, "Production runtime without SECRET_KEY_BASE must raise ArgumentError", failures)
  rescue ArgumentError => e
    assert(e.message.include?("Missing `secret_key_base` for 'production'"),
           "Production runtime raises clear missing secret error: #{e.message}", failures)
  end

  # Deliberate disabled dummy values must still reject missing secret
  disabled_dummy_values = ['0', 'false', 'FALSE', 'no', 'off', '   ', '']
  disabled_dummy_values.each do |val|
    ENV.replace(original_env)
    ENV['RAILS_ENV'] = 'production'
    ENV.delete('SECRET_KEY_BASE')
    ENV['SECRET_KEY_BASE_DUMMY'] = val
    Rails.env = 'production'

    app = Rails::Application.new
    begin
      app.secret_key_base
      assert(false, "Disabled dummy flag '#{val}' must NOT enable dummy secret; must raise ArgumentError", failures)
    rescue ArgumentError
      assert(true, "Disabled dummy flag '#{val}' correctly rejected missing secret", failures)
    end
  end

  puts "\n=== Step 5: Explicit build-only dummy operation ==="
  ['1', 'true', 'TRUE'].each do |truthy_val|
    ENV.replace(original_env)
    ENV['RAILS_ENV'] = 'production'
    ENV.delete('SECRET_KEY_BASE')
    ENV['SECRET_KEY_BASE_DUMMY'] = truthy_val
    Rails.env = 'production'

    app = Rails::Application.new
    dummy_key = app.secret_key_base
    assert(dummy_key.is_a?(String) && dummy_key.length >= 32,
           "Dummy flag '#{truthy_val}' yields valid dummy signing key (length >= 32)", failures)
    assert(!app.generate_development_secret_called,
           "Dummy build mode does not invoke disk-persisting generate_development_secret", failures)

    # Memoization test: subsequent calls in same process yield identical key
    second_key = app.secret_key_base
    assert(dummy_key == second_key,
           "Dummy key is stable across repeated calls in the same process", failures)
  end

  puts "\n=== Step 6: Development and test compatibility ==="
  # Development mode
  ENV.replace(original_env)
  ENV.delete('SECRET_KEY_BASE')
  ENV.delete('SECRET_KEY_BASE_DUMMY')
  Rails.env = 'development'
  app_dev = Rails::Application.new
  dev_key = app_dev.secret_key_base
  assert(app_dev.generate_development_secret_called,
         "Development mode uses generate_development_secret when unconfigured", failures)
  assert(dev_key == "dev_token_generated_by_disk_helper",
         "Development mode retains development secret behavior", failures)

  # Test mode
  Rails.env = 'test'
  app_test = Rails::Application.new
  test_key = app_test.secret_key_base
  assert(app_test.generate_development_secret_called,
         "Test mode uses generate_development_secret when unconfigured", failures)
  assert(test_key == "dev_token_generated_by_disk_helper",
         "Test mode retains test secret behavior", failures)

ensure
  ENV.replace(original_env)
end

puts "\n=== Summary ==="
if failures.empty?
  puts "ALL CHECKS PASSED: ONTO-T-Q02 regression test is clean."
  exit 0
else
  puts "#{failures.size} CHECK(S) FAILED:"
  failures.each { |f| puts " - #{f}" }
  exit 1
end
