#!/usr/bin/env ruby
# frozen_string_literal: true

# Standalone isolated regression check for ONTO-T-Q03:
# Verifies production Compose profile configuration (DB_HOST, cache, image override,
# PUMA_BIND, RAILS_LOG_TO_STDOUT) and Puma DSL binding / stdout redirection behavior
# across synthetic environments without booting Rails or executing fork callbacks.

require 'yaml'

failures = []

def assert(condition, message, failures)
  if condition
    puts "  [PASS] #{message}"
  else
    puts "  [FAIL] #{message}"
    failures << message
  end
end

puts "=== Part 1: Verify docker-compose.yml production profile configuration ==="
compose_path = File.expand_path('../../docker-compose.yml', __dir__)
raw_compose = YAML.safe_load(File.read(compose_path), aliases: true)

services = raw_compose['services'] || {}
prod = services['production'] || {}
prod_env = prod['environment'] || {}

# 1. Image override
expected_image = '${UI_IMAGE:-agroportal/ontoportal_web_ui:master}'
assert(prod['image'] == expected_image,
       "Production service image is '#{expected_image}' (got: #{prod['image'].inspect})", failures)

# 2. Database host
assert(prod_env['DB_HOST'] == 'db',
       "Production DB_HOST is 'db' (got: #{prod_env['DB_HOST'].inspect})", failures)

# 3. Cache server
assert(prod_env['MEMCACHE_SERVERS'] == 'cache:11211',
       "Production MEMCACHE_SERVERS is 'cache:11211' (got: #{prod_env['MEMCACHE_SERVERS'].inspect})", failures)

# 4. Puma TCP bind
assert(prod_env['PUMA_BIND'] == 'tcp://0.0.0.0:3000',
       "Production PUMA_BIND is 'tcp://0.0.0.0:3000' (got: #{prod_env['PUMA_BIND'].inspect})", failures)

# 5. Rails stdout logging
assert(prod_env['RAILS_LOG_TO_STDOUT'] == 'true',
       "Production RAILS_LOG_TO_STDOUT is 'true' (got: #{prod_env['RAILS_LOG_TO_STDOUT'].inspect})", failures)

# 6. Service dependencies and links
prod_depends = prod['depends_on'] || {}
assert(prod_depends.dig('db', 'condition') == 'service_healthy',
       "Production service depends on db (service_healthy)", failures)
assert(prod_depends.dig('cache', 'condition') == 'service_started',
       "Production service depends on cache (service_started)", failures)
assert(prod['links']&.include?('db') && prod['links']&.include?('cache'),
       "Production service links db and cache services", failures)

# 7. Preserved volumes (app_ui:/app and assets preserved)
prod_volumes = prod['volumes'] || []
assert(prod_volumes.include?('app_ui:/app'),
       "Production service preserves 'app_ui:/app' volume", failures)
assert(prod_volumes.include?('assets:/app/public/assets'),
       "Production service preserves 'assets:/app/public/assets' volume", failures)

# 8. Dev and test baseline preservation
default_app = raw_compose['x-app'] || {}
assert(default_app['image'] == 'agroportal/ontoportal_web_ui:development',
       "Default app x-app image remains 'agroportal/ontoportal_web_ui:development'", failures)

dev_service = services['dev'] || {}
assert(dev_service['network_mode'] == 'host',
       "Dev service network_mode remains 'host'", failures)

test_service = services['test'] || {}
test_env = test_service['environment'] || {}
assert(test_service['network_mode'] == 'host',
       "Test service network_mode remains 'host'", failures)
assert(test_env['DB_HOST'] == '127.0.0.1',
       "Test service retains DB_HOST '127.0.0.1'", failures)
assert(test_env['MEMCACHE_SERVERS'] == '127.0.0.1:11211',
       "Test service retains MEMCACHE_SERVERS '127.0.0.1:11211'", failures)

puts "\n=== Part 2: Verify config/puma.rb nonexecuting DSL across synthetic environments ==="

class FakePumaContext
  attr_reader :calls

  def initialize
    @calls = Hash.new { |h, k| h[k] = [] }
  end

  def threads(min, max)
    @calls[:threads] << [min, max]
  end

  def environment(env)
    @calls[:environment] << env
  end

  def log_requests(enabled)
    @calls[:log_requests] << enabled
  end

  def bind(uri)
    @calls[:bind] << uri
  end

  def workers(count)
    @calls[:workers] << count
  end

  def preload_app!
    @calls[:preload_app!] << true
  end

  def before_fork(&block)
    @calls[:before_fork] << block
    # No execution of fork callbacks to avoid Rails/ActiveRecord dependency
  end

  def on_worker_boot(&block)
    @calls[:on_worker_boot] << block
    # No execution of fork callbacks
  end

  def pidfile(path)
    @calls[:pidfile] << path
  end

  def state_path(path)
    @calls[:state_path] << path
  end

  def stdout_redirect(stdout_path, stderr_path, append = false)
    @calls[:stdout_redirect] << [stdout_path, stderr_path, append]
  end

  def port(p)
    @calls[:port] << p
  end

  def plugin(name)
    @calls[:plugin] << name
  end

  def eval_puma_config(file_path)
    instance_eval(File.read(file_path), file_path, 1)
  end
end

puma_config_path = File.expand_path('../../config/puma.rb', __dir__)
saved_env = ENV.to_h
synthetic_base_env = saved_env.reject { |k, _v| %w[PORT WEB_CONCURRENCY].include?(k) }

begin
  # Synthetic Case A: Production Compose container profile
  # (PUMA_BIND=tcp://0.0.0.0:3000, RAILS_LOG_TO_STDOUT=true)
  puts "\n--- Synthetic Case A: Production Compose container ---"
  ENV.replace(synthetic_base_env)
  ENV['RAILS_ENV'] = 'production'
  ENV['PUMA_BIND'] = 'tcp://0.0.0.0:3000'
  ENV['RAILS_LOG_TO_STDOUT'] = 'true'

  ctx_a = FakePumaContext.new
  ctx_a.eval_puma_config(puma_config_path)

  assert(ctx_a.calls[:bind] == ['tcp://0.0.0.0:3000'],
         "Production Compose binds explicit PUMA_BIND tcp://0.0.0.0:3000", failures)
  assert(ctx_a.calls[:stdout_redirect].empty?,
         "Production Compose omits stdout_redirect when RAILS_LOG_TO_STDOUT is present", failures)
  assert(ctx_a.calls[:workers] == [2],
         "Clustered workers configured (2)", failures)
  assert(ctx_a.calls[:preload_app!] == [true],
         "preload_app! enabled in production", failures)
  assert(ctx_a.calls[:port].empty?,
         "Port directive not called in production clustered mode", failures)

  # Synthetic Case B: Production/Appliance Host profile
  # (No PUMA_BIND, No RAILS_LOG_TO_STDOUT -> Unix socket + file logging)
  puts "\n--- Synthetic Case B: Production/Appliance host profile ---"
  ENV.replace(synthetic_base_env)
  ENV['RAILS_ENV'] = 'production'
  ENV.delete('PUMA_BIND')
  ENV.delete('RAILS_LOG_TO_STDOUT')

  ctx_b = FakePumaContext.new
  ctx_b.eval_puma_config(puma_config_path)

  expected_sock = 'unix:///opt/ontoportal/bioportal_web_ui/shared/tmp/sockets/puma.sock'
  assert(ctx_b.calls[:bind] == [expected_sock],
         "Host production falls back to default Unix socket", failures)
  assert(ctx_b.calls[:stdout_redirect] == [['log/puma.stdout.log', 'log/puma.stderr.log', true]],
         "Host production redirects stdout/stderr to log files when RAILS_LOG_TO_STDOUT is absent", failures)

  # Synthetic Case C: Staging/Appliance with empty env strings
  puts "\n--- Synthetic Case C: Staging profile with empty string overrides ---"
  ENV.replace(synthetic_base_env)
  ENV['RAILS_ENV'] = 'staging'
  ENV['PUMA_BIND'] = ''
  ENV['RAILS_LOG_TO_STDOUT'] = ''

  ctx_c = FakePumaContext.new
  ctx_c.eval_puma_config(puma_config_path)

  assert(ctx_c.calls[:bind] == [expected_sock],
         "Empty PUMA_BIND string correctly falls back to default Unix socket", failures)
  assert(ctx_c.calls[:stdout_redirect] == [['log/puma.stdout.log', 'log/puma.stderr.log', true]],
         "Empty RAILS_LOG_TO_STDOUT string correctly preserves file logging redirect", failures)

  # Synthetic Case D: Appliance profile with explicit PUMA_BIND but no stdout redirect flag
  puts "\n--- Synthetic Case D: Appliance profile with custom TCP bind and file logs ---"
  ENV.replace(synthetic_base_env)
  ENV['RAILS_ENV'] = 'appliance'
  ENV['PUMA_BIND'] = 'tcp://127.0.0.1:8080'
  ENV.delete('RAILS_LOG_TO_STDOUT')

  ctx_d = FakePumaContext.new
  ctx_d.eval_puma_config(puma_config_path)

  assert(ctx_d.calls[:bind] == ['tcp://127.0.0.1:8080'],
         "Appliance profile honors explicit PUMA_BIND tcp://127.0.0.1:8080", failures)
  assert(ctx_d.calls[:stdout_redirect] == [['log/puma.stdout.log', 'log/puma.stderr.log', true]],
         "Appliance profile preserves file logging when RAILS_LOG_TO_STDOUT is absent", failures)

  # Synthetic Case E: Development profile
  puts "\n--- Synthetic Case E: Development profile ---"
  ENV.replace(synthetic_base_env)
  ENV['RAILS_ENV'] = 'development'
  ENV.delete('PUMA_BIND')
  ENV.delete('RAILS_LOG_TO_STDOUT')

  ctx_e = FakePumaContext.new
  ctx_e.eval_puma_config(puma_config_path)

  assert(ctx_e.calls[:port] == [3000],
         "Development profile listens on default port 3000", failures)
  assert(ctx_e.calls[:bind].empty?,
         "Development profile does not call bind", failures)
  assert(ctx_e.calls[:stdout_redirect].empty?,
         "Development profile does not call stdout_redirect", failures)
  assert(ctx_e.calls[:workers].empty?,
         "Development profile runs single-mode (no workers)", failures)

  # Synthetic Case F: Test profile
  puts "\n--- Synthetic Case F: Test profile ---"
  ENV.replace(synthetic_base_env)
  ENV['RAILS_ENV'] = 'test'
  ENV.delete('PUMA_BIND')
  ENV.delete('RAILS_LOG_TO_STDOUT')

  ctx_f = FakePumaContext.new
  ctx_f.eval_puma_config(puma_config_path)

  assert(ctx_f.calls[:port] == [3000],
         "Test profile listens on default port 3000", failures)
  assert(ctx_f.calls[:bind].empty?,
         "Test profile does not call bind", failures)

ensure
  ENV.replace(saved_env)
end

puts "\n=== Summary ==="
if failures.empty?
  puts "ALL CHECKS PASSED: ONTO-T-Q03 runtime profile configuration is clean."
  exit 0
else
  puts "#{failures.size} CHECK(S) FAILED:"
  failures.each { |f| puts " - #{f}" }
  exit 1
end
