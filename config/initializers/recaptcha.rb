# frozen_string_literal: true

if ENV['USE_RECAPTCHA'].present? && ENV['USE_RECAPTCHA'] == 'true'
  creds = (Rails.application.credentials.recaptcha rescue nil) ||
          (Rails.application.credentials[:recaptcha] rescue nil)
  site_key = (creds[:site_key] rescue nil) || (creds['site_key'] rescue nil) || (creds.site_key rescue nil)
  secret_key = (creds[:secret_key] rescue nil) || (creds['secret_key'] rescue nil) || (creds.secret_key rescue nil)

  if site_key.to_s.strip.empty? || secret_key.to_s.strip.empty?
    raise KeyError, 'reCAPTCHA is enabled (USE_RECAPTCHA=true) but credentials (site_key, secret_key) are missing or empty'
  end

  Recaptcha.configure do |config|
    config.site_key   = site_key
    config.secret_key = secret_key
  end
end
