Rails.application.config.middleware.use OmniAuth::Builder do
  Array($OMNIAUTH_PROVIDERS).each do |provider, config|
    next if config[:enable] == false

    # name sets the /auth/<name> path the login button posts to; pkce and scope are strategy options.
    options = { client_options: {}.merge(config[:client_options].to_h) }
    options.merge!(config.slice(:name, :pkce, :scope).compact)
    provider config[:strategy] || provider, config[:client_id], config[:client_secret], **options
  end
end
