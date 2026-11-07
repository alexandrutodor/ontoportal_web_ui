#!/usr/bin/env ruby
# frozen_string_literal: true

# Standalone isolated regression check for ONTO-T-Q04:
# Verifies reCAPTCHA configuration contract, operator ENV preservation (true, false, unset),
# initializer key validation and fail-clear semantics with synthetic credentials,
# and consumer boundaries (registration, anonymous feedback, authenticated exemption, form views)
# invoking actual controller methods without booting Rails or making external network/Google calls.

$assertion_count = 0
$failures = []

def assert(condition, message)
  $assertion_count += 1
  if condition
    puts "  [PASS] #{message}"
  else
    puts "  [FAIL] #{message}"
    $failures << message
  end
end

repo_root = File.expand_path('../..', __dir__)

# ActiveSupport minimal doubles for plain Ruby execution
class Object
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
end

class NilClass
  def present?
    false
  end

  def blank?
    true
  end
end

# AST-based source method loader: extracts exact method definitions from actual controller files
def load_method_from_source(file_path, method_name, target_mod)
  ast = RubyVM::AbstractSyntaxTree.parse_file(file_path)
  find_node = lambda do |node|
    return node if node.is_a?(RubyVM::AbstractSyntaxTree::Node) && node.type == :DEFN && node.children[0] == method_name
    if node.is_a?(RubyVM::AbstractSyntaxTree::Node)
      node.children.each do |child|
        res = find_node.call(child)
        return res if res
      end
    end
    nil
  end

  node = find_node.call(ast)
  raise "Method #{method_name} not found in #{file_path}" unless node

  lines = File.readlines(file_path)
  code = lines[(node.first_lineno - 1)..(node.last_lineno - 1)].join
  target_mod.class_eval(code, file_path, node.first_lineno)
end

# Define test harness doubles for Recaptcha and Rails credentials
module MockRecaptcha
  class Configuration
    attr_accessor :site_key, :secret_key
  end

  def self.configuration
    @configuration ||= Configuration.new
  end

  def self.configure
    yield(configuration)
  end

  def self.reset!
    @configuration = Configuration.new
  end
end

Recaptcha = MockRecaptcha unless defined?(Recaptcha)

module MockRails
  class Credentials
    attr_accessor :recaptcha, :error_to_raise

    def initialize(recaptcha: nil, error_to_raise: nil)
      @recaptcha = recaptcha
      @error_to_raise = error_to_raise
    end

    def recaptcha
      raise @error_to_raise if @error_to_raise
      @recaptcha
    end
  end

  class Application
    attr_accessor :credentials

    def initialize
      @credentials = Credentials.new
    end
  end

  def self.application
    @application ||= Application.new
  end
end

Rails = MockRails unless defined?(Rails)

# Test harness class for actual controller methods
class TestControllerHarness
  attr_accessor :session, :params, :errors, :flash, :verify_recaptcha_result

  def initialize
    @session = {}
    @params = {}
    @errors = []
    @flash = {}
    @verify_recaptcha_result = true
  end

  def t(key, *args)
    key.to_s
  end

  def verify_recaptcha(*args)
    @verify_recaptcha_result
  end

  def render(*args); end
  def redirect_to_home(*args); end
end

# Minimal stub for Notifier to prevent mail sending
module MockNotifier
  def self.feedback(*args)
    self
  end

  def self.deliver_later; end
end
Notifier = MockNotifier unless defined?(Notifier)

# Dynamically load ACTUAL controller methods directly from source files
app_controller_path   = File.join(repo_root, 'app/controllers/application_controller.rb')
users_controller_path = File.join(repo_root, 'app/controllers/users_controller.rb')
home_controller_path  = File.join(repo_root, 'app/controllers/home_controller.rb')

load_method_from_source(app_controller_path, :using_captcha?, TestControllerHarness)
load_method_from_source(users_controller_path, :validate, TestControllerHarness)
load_method_from_source(home_controller_path, :feedback, TestControllerHarness)

harness = TestControllerHarness.new

puts "=== Step 1: Verify config/bioportal_config_env.rb.sample does not clobber operator ENV ==="
sample_path = File.join(repo_root, 'config/bioportal_config_env.rb.sample')
sample_content = File.read(sample_path)

# Verify no unconditional assignment of ENV['USE_RECAPTCHA'] = 'false'
active_assignment = sample_content.lines.any? { |line| line.match?(/^\s*ENV\['USE_RECAPTCHA'\]\s*=\s*['"]false['"]/) }
assert(!active_assignment, 'bioportal_config_env.rb.sample has no active unconditional ENV["USE_RECAPTCHA"] = "false"')

# Test preservation across states: true, false, unset
test_states = [
  { initial: 'true', expected: 'true', desc: 'operator true' },
  { initial: 'false', expected: 'false', desc: 'operator false' },
  { initial: nil, expected: nil, desc: 'operator unset' }
]

test_states.each do |state|
  orig_val = ENV['USE_RECAPTCHA']
  begin
    if state[:initial].nil?
      ENV.delete('USE_RECAPTCHA')
    else
      ENV['USE_RECAPTCHA'] = state[:initial]
    end

    # Extract and evaluate only the recaptcha configuration section in isolation
    recaptcha_section = sample_content[/# reCAPTCHA.*?(?=\n# Custom BioPortal logging)/m]
    eval(recaptcha_section, binding, sample_path, 136)

    actual = ENV['USE_RECAPTCHA']
    assert(actual == state[:expected], "Preserved #{state[:desc]}: expected #{state[:expected].inspect}, got #{actual.inspect}")
  ensure
    if orig_val.nil?
      ENV.delete('USE_RECAPTCHA')
    else
      ENV['USE_RECAPTCHA'] = orig_val
    end
  end
end

# Check actual ApplicationController#using_captcha? behavior across ENV states
ENV.delete('USE_RECAPTCHA')
assert(!harness.using_captcha?, 'ApplicationController#using_captcha? is false when unset (default disabled)')

ENV['USE_RECAPTCHA'] = 'false'
assert(!harness.using_captcha?, 'ApplicationController#using_captcha? is false when USE_RECAPTCHA="false"')

ENV['USE_RECAPTCHA'] = 'true'
assert(harness.using_captcha?, 'ApplicationController#using_captcha? is true when USE_RECAPTCHA="true"')
ENV.delete('USE_RECAPTCHA')

puts "\n=== Step 2: Test config/initializers/recaptcha.rb with synthetic credentials & error safety ==="
initializer_path = File.join(repo_root, 'config/initializers/recaptcha.rb')

synthetic_site = 'synthetic_test_site_key_001'
synthetic_sec  = 'synthetic_test_secret_key_002'

# Test 2a: Unset ENV does not run initializer logic or raise error
ENV.delete('USE_RECAPTCHA')
MockRecaptcha.reset!
MockRails.application.credentials = MockRails::Credentials.new(recaptcha: nil)
begin
  load initializer_path
  assert(MockRecaptcha.configuration.site_key.nil?, 'Initializer does nothing when USE_RECAPTCHA is unset')
rescue StandardError => e
  assert(false, "Initializer raised unexpected error when unset: #{e.message}")
end

# Test 2b: False ENV does not run initializer logic or raise error
ENV['USE_RECAPTCHA'] = 'false'
MockRecaptcha.reset!
MockRails.application.credentials = MockRails::Credentials.new(recaptcha: nil)
begin
  load initializer_path
  assert(MockRecaptcha.configuration.site_key.nil?, 'Initializer does nothing when USE_RECAPTCHA is "false"')
rescue StandardError => e
  assert(false, "Initializer raised unexpected error when false: #{e.message}")
end

# Test 2c: Enabled with missing credentials raises KeyError clearly without leaking secrets
ENV['USE_RECAPTCHA'] = 'true'
MockRecaptcha.reset!
MockRails.application.credentials = MockRails::Credentials.new(recaptcha: nil)
raised_key_error = false
error_message = ''
begin
  load initializer_path
rescue KeyError => e
  raised_key_error = true
  error_message = e.message
rescue StandardError => e
  assert(false, "Initializer raised wrong error type on missing credentials: #{e.class} #{e.message}")
end
assert(raised_key_error, 'Initializer raises KeyError when USE_RECAPTCHA=true and credentials missing')
assert(!error_message.include?(synthetic_site) && !error_message.include?(synthetic_sec), 'KeyError on missing credentials does not leak synthetic secrets')

# Test 2d: Enabled with empty site_key raises KeyError without leaking secret_key
MockRails.application.credentials = MockRails::Credentials.new(
  recaptcha: { site_key: '', secret_key: synthetic_sec }
)
raised_empty_site = false
error_message_empty_site = ''
begin
  load initializer_path
rescue KeyError => e
  raised_empty_site = true
  error_message_empty_site = e.message
end
assert(raised_empty_site, 'Initializer raises KeyError when site_key is empty')
assert(!error_message_empty_site.include?(synthetic_sec), 'KeyError on empty site_key does not leak secret_key')

# Test 2e: Enabled with whitespace secret_key raises KeyError without leaking site_key
MockRails.application.credentials = MockRails::Credentials.new(
  recaptcha: { site_key: synthetic_site, secret_key: '   ' }
)
raised_empty_sec = false
error_message_empty_sec = ''
begin
  load initializer_path
rescue KeyError => e
  raised_empty_sec = true
  error_message_empty_sec = e.message
end
assert(raised_empty_sec, 'Initializer raises KeyError when secret_key is whitespace/empty')
assert(!error_message_empty_sec.include?(synthetic_site), 'KeyError on whitespace secret_key does not leak site_key')

# Test 2f: Enabled with valid synthetic credentials configures Recaptcha correctly
MockRecaptcha.reset!
MockRails.application.credentials = MockRails::Credentials.new(
  recaptcha: { site_key: synthetic_site, secret_key: synthetic_sec }
)
begin
  load initializer_path
  assert(MockRecaptcha.configuration.site_key == synthetic_site, 'Configured synthetic site_key matches')
  assert(MockRecaptcha.configuration.secret_key == synthetic_sec, 'Configured synthetic secret_key matches')
rescue StandardError => e
  assert(false, "Initializer failed with valid synthetic credentials: #{e.message}")
end

# Test 2g: Enabled with underlying credentials/decryption error propagates without reclassification
MockRails.application.credentials = MockRails::Credentials.new(
  error_to_raise: RuntimeError.new('ActiveSupport::MessageEncryptor::InvalidMessage: Decryption failed')
)
propagated_decryption_error = false
begin
  load initializer_path
rescue RuntimeError => e
  propagated_decryption_error = e.message.include?('Decryption failed')
rescue KeyError
  propagated_decryption_error = false
end
assert(propagated_decryption_error, 'Underlying credentials/decryption error propagates without reclassification')

ENV.delete('USE_RECAPTCHA')

puts "\n=== Step 3: Consumer controller & boundary checks using ACTUAL controller methods ==="

# Valid registration attributes satisfying UsersController#validate constraints
valid_reg_params = {
  email: 'user@example.com',
  password: 'validPassword123',
  password_confirmation: 'validPassword123',
  username: 'validuser',
  orcidId: '',
  terms_and_conditions: '1'
}

# 3a: Registration - Disabled state: verification is skipped, passes without challenge
ENV['USE_RECAPTCHA'] = 'false'
harness.verify_recaptcha_result = false
reg_errors = harness.validate(valid_reg_params)
assert(reg_errors.empty?, 'UsersController#validate: disabled skip (passes without challenge when USE_RECAPTCHA=false)')

# 3b: Registration - Enabled state, verification failed: error added
ENV['USE_RECAPTCHA'] = 'true'
harness.verify_recaptcha_result = false
reg_errors = harness.validate(valid_reg_params)
assert(reg_errors.include?('users.recaptcha_validation'), 'UsersController#validate: enabled failed verifier rejection (adds users.recaptcha_validation)')

# 3c: Registration - Enabled state, missing verifier response (nil): error added
ENV['USE_RECAPTCHA'] = 'true'
harness.verify_recaptcha_result = nil
reg_errors = harness.validate(valid_reg_params)
assert(reg_errors.include?('users.recaptcha_validation'), 'UsersController#validate: enabled missing verifier rejection (adds users.recaptcha_validation when verifier is nil)')

# 3d: Registration - Enabled state, verification passed: success
harness.verify_recaptcha_result = true
reg_errors = harness.validate(valid_reg_params)
assert(reg_errors.empty?, 'UsersController#validate: enabled successful synthetic verification (succeeds without error)')

# Valid feedback params satisfying HomeController#feedback constraints
valid_fb_params = {
  sim_submit: '1',
  name: 'FeedbackTester',
  email: 'tester@example.com',
  comment: 'Feedback message text'
}

# 3e: Anonymous Feedback - Disabled state: no challenge, passes
ENV['USE_RECAPTCHA'] = 'false'
harness.session[:user] = nil
harness.params = valid_fb_params
harness.verify_recaptcha_result = false
harness.feedback
assert(harness.errors.empty?, 'HomeController#feedback: disabled skip (anonymous feedback succeeds when USE_RECAPTCHA=false)')

# 3f: Anonymous Feedback - Enabled state, verification failed: rejected with error
ENV['USE_RECAPTCHA'] = 'true'
harness.session[:user] = nil
harness.params = valid_fb_params
harness.verify_recaptcha_result = false
harness.feedback
assert(harness.errors.include?('home.fill_text'), 'HomeController#feedback: enabled failed verifier rejection (anonymous rejected with home.fill_text)')

# 3g: Anonymous Feedback - Enabled state, missing verifier response (nil): rejected with error
ENV['USE_RECAPTCHA'] = 'true'
harness.session[:user] = nil
harness.params = valid_fb_params
harness.verify_recaptcha_result = nil
harness.feedback
assert(harness.errors.include?('home.fill_text'), 'HomeController#feedback: enabled missing verifier rejection (anonymous rejected when verifier returns nil)')

# 3h: Anonymous Feedback - Enabled state, verification passed: succeeds
harness.verify_recaptcha_result = true
harness.params = valid_fb_params
harness.feedback
assert(harness.errors.empty?, 'HomeController#feedback: enabled successful synthetic verification (anonymous feedback succeeds)')

# 3i: Authenticated Feedback - Exemption preserved even when recaptcha enabled
ENV['USE_RECAPTCHA'] = 'true'
harness.session[:user] = { id: 42, username: 'tester' }
harness.params = valid_fb_params
harness.verify_recaptcha_result = false
harness.feedback
assert(harness.errors.empty?, 'HomeController#feedback: authenticated-feedback exemption (logged-in user exempt even when enabled)')

ENV.delete('USE_RECAPTCHA')

puts "\n=== Step 4: Verify form views gate challenge rendering behind using_captcha? ==="
user_form = File.read(File.join(repo_root, 'app/views/users/_form.html.haml'))
assert(user_form.match?(/- if using_captcha\?\s*\n\s*= recaptcha_tags/), 'users/_form.html.haml gates recaptcha_tags with - if using_captcha? [static view guard]')

feedback_form = File.read(File.join(repo_root, 'app/views/home/feedback/feedback.html.haml'))
assert(feedback_form.match?(/- if using_captcha\?\s*\n\s*= recaptcha_tags/), 'home/feedback/feedback.html.haml gates recaptcha_tags with - if using_captcha? [static view guard]')

puts "\n=== Regression Check Summary ==="
if $failures.empty?
  puts "ALL #{$assertion_count} ACCEPTANCE ASSERTIONS PASSED."
  exit 0
else
  puts "#{$failures.size} OF #{$assertion_count} ASSERTION(S) FAILED:"
  $failures.each { |f| puts "  - #{f}" }
  exit 1
end
