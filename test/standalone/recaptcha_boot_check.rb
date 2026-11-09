# frozen_string_literal: true

# ONTO-T-Q04: reCAPTCHA enablement after the real application configuration loads.
# Run with `rails runner` (RAILS_ENV=test, no network) once per mode; EXPECT_ENABLED and
# EXPECT_SITE_KEY state what the boot must produce. Renders the real feedback template.

abort 'refusing to run outside RAILS_ENV=test' unless Rails.env.test?

failures = []
expect_enabled = ENV.fetch('EXPECT_ENABLED') == 'true'
expected_key = ENV['EXPECT_SITE_KEY'].to_s

controller = ApplicationController.new
enabled = controller.send(:using_captcha?)
failures << "using_captcha? #{enabled}, expected #{expect_enabled}" unless enabled == expect_enabled

site_key = Recaptcha.configuration.site_key.to_s
failures << "configured site key #{site_key.inspect}, expected #{expected_key.inspect}" unless site_key == expected_key

# The gem omits the widget's site key and script in its skip environments (test by default); render as production does.
Recaptcha.configuration.skip_verify_env = []
html = ApplicationController.render(template: 'home/feedback/feedback', layout: false, assigns: { errors: [], tags: [] })
challenge = html.include?('g-recaptcha')
failures << "feedback challenge rendered=#{challenge}, expected #{expect_enabled}" unless challenge == expect_enabled
failures << 'feedback challenge has the wrong site key' if expect_enabled && !html.include?(%(data-sitekey="#{expected_key}"))

puts "USE_RECAPTCHA=#{ENV['USE_RECAPTCHA'].inspect}: using_captcha?=#{enabled}, site_key=#{site_key.empty? ? '(none)' : 'synthetic'}, feedback challenge=#{challenge}"
if failures.empty?
  puts 'PASS recaptcha boot check'
else
  puts failures.map { |f| "FAIL #{f}" }
  exit 1
end
