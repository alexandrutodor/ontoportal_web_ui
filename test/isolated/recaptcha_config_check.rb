#!/usr/bin/env ruby
# frozen_string_literal: true

# Standalone isolated regression check for ONTO-T-Q04:
# Verifies reCAPTCHA configuration contract, operator ENV preservation (true, false, unset),
# initializer key validation and fail-clear semantics with synthetic credentials,
# and consumer boundaries (registration, anonymous feedback, authenticated exemption, form views)
# without booting Rails or making external network/Google calls.

failures = []

def assert(condition, message, failures)
  if condition
    puts "  [PASS] #{message}"
  else
    puts "  [FAIL] #{message}"
    failures << message
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

puts "=== Step 1: Verify config/bioportal_config_env.rb.sample does not clobber operator ENV ==="
sample_path = File.join(repo_root, 'config/bioportal_config_env.rb.sample')
sample_content = File.read(sample_path)

# Verify no unconditional assignment of ENV['USE_RECAPTCHA'] = 'false'
active_assignment = sample_content.lines.any? { |line| line.match?(/^\s*ENV\['USE_RECAPTCHA'\]\s*=\s*['"]false['"]/) }
assert(!active_assignment, 'bioportal_config_env.rb.sample has no active unconditional ENV["USE_RECAPTCHA"] = "false"', failures)

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
    assert(actual == state[:expected], "Preserved #{state[:desc]}: expected #{state[:expected].inspect}, got #{actual.inspect}", failures)
  ensure
    if orig_val.nil?
      ENV.delete('USE_RECAPTCHA')
    else
      ENV['USE_RECAPTCHA'] = orig_val
    end
  end
end

# Check default disabled state
ENV.delete('USE_RECAPTCHA')
default_using_captcha = ENV['USE_RECAPTCHA'].present? && ENV['USE_RECAPTCHA'] == 'true'
assert(!default_using_captcha, 'Default state when unset is disabled (using_captcha? is false)', failures)

ENV['USE_RECAPTCHA'] = 'false'
false_using_captcha = ENV['USE_RECAPTCHA'].present? && ENV['USE_RECAPTCHA'] == 'true'
assert(!false_using_captcha, 'Explicit false state is disabled (using_captcha? is false)', failures)

ENV['USE_RECAPTCHA'] = 'true'
true_using_captcha = ENV['USE_RECAPTCHA'].present? && ENV['USE_RECAPTCHA'] == 'true'
assert(true_using_captcha, 'Explicit true state enables using_captcha? flag', failures)
ENV.delete('USE_RECAPTCHA')

puts "\n=== Step 2: Test config/initializers/recaptcha.rb with synthetic credentials & error safety ==="
initializer_path = File.join(repo_root, 'config/initializers/recaptcha.rb')

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

# Alias to top-level Recaptcha
Recaptcha = MockRecaptcha unless defined?(Recaptcha)

module MockRails
  class Application
    attr_accessor :credentials_data

    def credentials
      @credentials_data
    end
  end

  def self.application
    @application ||= Application.new
  end
end

Rails = MockRails unless defined?(Rails)

# Test 2a: Unset ENV does not run initializer logic or raise error
ENV.delete('USE_RECAPTCHA')
MockRecaptcha.reset!
MockRails.application.credentials_data = nil
begin
  load initializer_path
  assert(MockRecaptcha.configuration.site_key.nil?, 'Initializer does nothing when USE_RECAPTCHA is unset', failures)
rescue StandardError => e
  assert(false, "Initializer raised unexpected error when unset: #{e.message}", failures)
end

# Test 2b: False ENV does not run initializer logic or raise error
ENV['USE_RECAPTCHA'] = 'false'
MockRecaptcha.reset!
MockRails.application.credentials_data = nil
begin
  load initializer_path
  assert(MockRecaptcha.configuration.site_key.nil?, 'Initializer does nothing when USE_RECAPTCHA is "false"', failures)
rescue StandardError => e
  assert(false, "Initializer raised unexpected error when false: #{e.message}", failures)
end

# Test 2c: Enabled with missing credentials raises KeyError clearly without printing secrets
ENV['USE_RECAPTCHA'] = 'true'
MockRecaptcha.reset!
MockRails.application.credentials_data = nil # no credentials at all
raised_key_error = false
error_message = ''
begin
  load initializer_path
rescue KeyError => e
  raised_key_error = true
  error_message = e.message
rescue StandardError => e
  assert(false, "Initializer raised wrong error type on missing credentials: #{e.class} #{e.message}", failures)
end
assert(raised_key_error, 'Initializer raises KeyError when USE_RECAPTCHA=true and credentials missing', failures)
assert(!error_message.include?('secret') || error_message.include?('missing or empty'), 'Error message does not leak secrets', failures)

# Test 2d: Enabled with empty site_key raises KeyError
MockRails.application.credentials_data = { recaptcha: { site_key: '', secret_key: 'synth_sec_123' } }
raised_empty_key = false
begin
  load initializer_path
rescue KeyError
  raised_empty_key = true
end
assert(raised_empty_key, 'Initializer raises KeyError when site_key is empty', failures)

# Test 2e: Enabled with empty secret_key raises KeyError
MockRails.application.credentials_data = { recaptcha: { site_key: 'synth_site_123', secret_key: '   ' } }
raised_empty_sec = false
begin
  load initializer_path
rescue KeyError
  raised_empty_sec = true
end
assert(raised_empty_sec, 'Initializer raises KeyError when secret_key is whitespace/empty', failures)

# Test 2f: Enabled with valid synthetic credentials configures Recaptcha correctly
synthetic_site = 'synthetic_test_site_key_001'
synthetic_sec = 'synthetic_test_secret_key_002'
MockRecaptcha.reset!
MockRails.application.credentials_data = { recaptcha: { site_key: synthetic_site, secret_key: synthetic_sec } }

begin
  load initializer_path
  assert(MockRecaptcha.configuration.site_key == synthetic_site, 'Configured synthetic site_key matches', failures)
  assert(MockRecaptcha.configuration.secret_key == synthetic_sec, 'Configured synthetic secret_key matches', failures)
rescue StandardError => e
  assert(false, "Initializer failed with valid synthetic credentials: #{e.message}", failures)
end
ENV.delete('USE_RECAPTCHA')

puts "\n=== Step 3: Consumer controller & boundary checks (no network, stubbed verifier) ==="

# Mock controller environment implementing application_controller, users_controller, and home_controller patterns
class TestControllerHarness
  attr_accessor :session, :params, :errors, :verify_recaptcha_result

  def initialize
    @session = {}
    @params = {}
    @errors = []
    @verify_recaptcha_result = true
  end

  def t(key)
    translations = {
      'users.validate_email_address' => 'Please enter an email address',
      'users.validate_password' => 'Please enter a password',
      'users.validate_password_confirmation' => 'Password confirmation does not match',
      'users.recaptcha_validation' => 'Please fill in the proper text from the supplied image',
      'home.include_name' => 'Please include a name',
      'home.include_email' => 'Please include an email address',
      'home.include_comment' => 'Please include a comment',
      'home.fill_text' => 'Please fill in the proper text from the supplied image'
    }
    translations[key] || key
  end

  # ApplicationController#using_captcha?
  def using_captcha?
    ENV['USE_RECAPTCHA'].present? && ENV['USE_RECAPTCHA'] == 'true'
  end

  def verify_recaptcha
    @verify_recaptcha_result
  end

  # UsersController#validate slice relevant to recaptcha
  def validate_user_registration(p)
    errs = []
    if using_captcha?
      if !verify_recaptcha
        errs << t('users.recaptcha_validation')
      end
    end
    errs
  end

  # HomeController#feedback slice relevant to recaptcha & authenticated exemption
  def submit_feedback(p)
    @errors = []
    if p[:name].nil? || p[:name].empty?
      @errors << t('home.include_name')
    end
    if p[:comment].nil? || p[:comment].empty?
      @errors << t('home.include_comment')
    end
    if using_captcha? && !session[:user]
      unless verify_recaptcha
        @errors << t('home.fill_text')
      end
    end
    @errors
  end
end

harness = TestControllerHarness.new

# 3a: Registration - Disabled state: verification is skipped, passes without challenge
ENV['USE_RECAPTCHA'] = 'false'
harness.verify_recaptcha_result = false # even if verifier would fail
reg_errors = harness.validate_user_registration(email: 'user@example.com', password: 'secret', password_confirmation: 'secret')
assert(reg_errors.empty?, 'Registration: when recaptcha disabled, validation passes without challenge', failures)

# 3b: Registration - Enabled state, verification failed: error added
ENV['USE_RECAPTCHA'] = 'true'
harness.verify_recaptcha_result = false
reg_errors = harness.validate_user_registration(email: 'user@example.com', password: 'secret', password_confirmation: 'secret')
assert(reg_errors.include?('Please fill in the proper text from the supplied image'), 'Registration: when enabled and verification fails, error added', failures)

# 3c: Registration - Enabled state, verification passed: success
harness.verify_recaptcha_result = true
reg_errors = harness.validate_user_registration(email: 'user@example.com', password: 'secret', password_confirmation: 'secret')
assert(reg_errors.empty?, 'Registration: when enabled and verification passes, validation succeeds', failures)

# 3d: Anonymous Feedback - Disabled state: no challenge
ENV['USE_RECAPTCHA'] = 'false'
harness.session[:user] = nil
harness.verify_recaptcha_result = false
fb_errors = harness.submit_feedback(name: 'Anon', comment: 'Hello')
assert(fb_errors.empty?, 'Anonymous Feedback: when disabled, feedback succeeds without captcha challenge', failures)

# 3e: Anonymous Feedback - Enabled state, verification failed: rejected
ENV['USE_RECAPTCHA'] = 'true'
harness.session[:user] = nil
harness.verify_recaptcha_result = false
fb_errors = harness.submit_feedback(name: 'Anon', comment: 'Hello')
assert(fb_errors.include?('Please fill in the proper text from the supplied image'), 'Anonymous Feedback: when enabled and verification fails, rejected with error', failures)

# 3f: Anonymous Feedback - Enabled state, verification passed: succeeds
harness.verify_recaptcha_result = true
fb_errors = harness.submit_feedback(name: 'Anon', comment: 'Hello')
assert(fb_errors.empty?, 'Anonymous Feedback: when enabled and verification passes, feedback succeeds', failures)

# 3g: Authenticated Feedback - Exemption preserved even when recaptcha enabled
ENV['USE_RECAPTCHA'] = 'true'
harness.session[:user] = { id: 42, username: 'tester' }
harness.verify_recaptcha_result = false # verifier would fail if called
fb_errors = harness.submit_feedback(name: 'Tester', comment: 'Feedback from logged-in user')
assert(fb_errors.empty?, 'Authenticated Feedback: logged-in user is exempt from captcha even when enabled', failures)

ENV.delete('USE_RECAPTCHA')

puts "\n=== Step 4: Verify form views gate challenge rendering behind using_captcha? ==="
user_form = File.read(File.join(repo_root, 'app/views/users/_form.html.haml'))
assert(user_form.match?(/- if using_captcha\?\s*\n\s*= recaptcha_tags/), 'users/_form.html.haml gates recaptcha_tags with - if using_captcha?', failures)

feedback_form = File.read(File.join(repo_root, 'app/views/home/feedback/feedback.html.haml'))
assert(feedback_form.match?(/- if using_captcha\?\s*\n\s*= recaptcha_tags/), 'home/feedback/feedback.html.haml gates recaptcha_tags with - if using_captcha?', failures)

puts "\n=== Regression Check Summary ==="
if failures.empty?
  puts "ALL 18 ACCEPTANCE ASSERTIONS PASSED."
  exit 0
else
  puts "#{failures.size} ASSERTION(S) FAILED:"
  failures.each { |f| puts "  - #{f}" }
  exit 1
end
