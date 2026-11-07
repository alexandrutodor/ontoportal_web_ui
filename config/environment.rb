# Load the Rails application.
require_relative 'application'
require 'securerandom'


# Remove this after migrating to Rails 7.1 (https://github.com/rails/rails/issues/32947#issuecomment-1356391185)
class Rails::Application
  def secret_key_base
    if Rails.env.development? || Rails.env.test?
      secrets.secret_key_base ||= generate_development_secret
    elsif (configured_secret = find_configured_secret_key_base)
      validate_secret_key_base(configured_secret)
    elsif dummy_secret_key_base?
      @dummy_secret_key_base ||= SecureRandom.hex(64)
    else
      validate_secret_key_base(nil)
    end
  end

  private

  def find_configured_secret_key_base
    secret = ENV["SECRET_KEY_BASE"]
    return secret if secret && !secret.strip.empty?

    cred_secret = credentials&.secret_key_base
    return cred_secret if cred_secret && !cred_secret.to_s.strip.empty?

    sec_secret = secrets&.secret_key_base
    return sec_secret if sec_secret && !sec_secret.to_s.strip.empty?

    nil
  end

  def dummy_secret_key_base?
    value = ENV["SECRET_KEY_BASE_DUMMY"]
    return false if value.nil? || value.to_s.strip.empty?

    !%w[0 false f no off].include?(value.to_s.strip.downcase)
  end
end

# Initialize the Rails application.
Rails.application.initialize!
