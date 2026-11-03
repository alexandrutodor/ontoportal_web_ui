# frozen_string_literal: true

require 'test_helper'

class OmniauthKeycloakTest < ActionDispatch::IntegrationTest
  def setup
    super
    @original_omniauth_providers = $OMNIAUTH_PROVIDERS.is_a?(Hash) ? $OMNIAUTH_PROVIDERS.dup : $OMNIAUTH_PROVIDERS
    @original_env = {}
    %w[KEYCLOAK_SITE KEYCLOAK_REALM KEYCLOAK_CLIENT_ID KEYCLOAK_CLIENT_SECRET KEYCLOAK_LABEL KEYCLOAK_ENABLED].each do |k|
      @original_env[k] = ENV[k]
    end
    @original_test_mode = OmniAuth.config.test_mode
  end

  def teardown
    $OMNIAUTH_PROVIDERS = @original_omniauth_providers
    @original_env.each do |k, v|
      if v.nil?
        ENV.delete(k)
      else
        ENV[k] = v
      end
    end
    OmniAuth.config.test_mode = @original_test_mode
    OmniAuth.config.mock_auth.delete(:keycloak)
    super
  end

  test 'omniauth providers env populates keycloak provider with default name, icon, and enabled state' do
    ENV['KEYCLOAK_SITE'] = 'https://auth.example.org'
    ENV['KEYCLOAK_REALM'] = 'matportal'
    ENV['KEYCLOAK_CLIENT_ID'] = 'matportal-ui'
    ENV['KEYCLOAK_CLIENT_SECRET'] = 'secret123'
    ENV['KEYCLOAK_LABEL'] = 'Sign in with MatPortal Keycloak'
    ENV.delete('KEYCLOAK_ENABLED')

    # Ensure frozen base config does not cause FrozenError
    $OMNIAUTH_PROVIDERS = {}.freeze

    load Rails.root.join('config/initializers/omniauth_providers_env.rb')

    assert $OMNIAUTH_PROVIDERS.key?(:keycloak)

    cfg = $OMNIAUTH_PROVIDERS[:keycloak]
    assert_equal :keycloak_openid, cfg[:strategy]
    assert_equal 'keycloak', cfg[:name]
    assert_equal 'keycloak.svg', cfg[:icon]
    assert_equal 'matportal-ui', cfg[:client_id]
    assert_equal 'secret123', cfg[:client_secret]
    assert_equal 'https://auth.example.org', cfg[:client_options][:site]
    assert_equal 'matportal', cfg[:client_options][:realm]
    assert_equal true, cfg[:enable]
    assert_equal 'Sign in with MatPortal Keycloak', cfg[:label]
  end

  test 'omniauth providers env respects KEYCLOAK_ENABLED false' do
    ENV['KEYCLOAK_SITE'] = 'https://auth.example.org'
    ENV['KEYCLOAK_REALM'] = 'matportal'
    ENV['KEYCLOAK_CLIENT_ID'] = 'matportal-ui'
    ENV['KEYCLOAK_CLIENT_SECRET'] = 'secret123'
    ENV['KEYCLOAK_ENABLED'] = 'false'

    $OMNIAUTH_PROVIDERS = {}.freeze

    load Rails.root.join('config/initializers/omniauth_providers_env.rb')

    assert $OMNIAUTH_PROVIDERS.key?(:keycloak)
    assert_equal false, $OMNIAUTH_PROVIDERS[:keycloak][:enable]
  end

  test 'omniauth providers env leaves providers unchanged when credentials are incomplete' do
    ENV['KEYCLOAK_SITE'] = 'https://auth.example.org'
    ENV['KEYCLOAK_REALM'] = 'matportal'
    ENV['KEYCLOAK_CLIENT_ID'] = 'matportal-ui'
    ENV.delete('KEYCLOAK_CLIENT_SECRET')

    $OMNIAUTH_PROVIDERS = { github: { client_id: 'gh-id', enable: true } }.freeze

    load Rails.root.join('config/initializers/omniauth_providers_env.rb')

    assert_equal true, $OMNIAUTH_PROVIDERS[:github][:enable]
    refute $OMNIAUTH_PROVIDERS.key?(:keycloak)
  end

  test 'omniauth providers env preserves existing per-portal options on keycloak' do
    ENV['KEYCLOAK_SITE'] = 'https://auth.example.org'
    ENV['KEYCLOAK_REALM'] = 'matportal'
    ENV['KEYCLOAK_CLIENT_ID'] = 'matportal-ui'
    ENV['KEYCLOAK_CLIENT_SECRET'] = 'secret123'

    $OMNIAUTH_PROVIDERS = {
      keycloak: {
        pkce: true,
        scope: 'openid profile',
        icon: 'custom.svg',
        name: 'kc_custom'
      }
    }.freeze

    load Rails.root.join('config/initializers/omniauth_providers_env.rb')

    cfg = $OMNIAUTH_PROVIDERS[:keycloak]
    assert_equal true, cfg[:pkce]
    assert_equal 'openid profile', cfg[:scope]
    assert_equal 'custom.svg', cfg[:icon]
    assert_equal 'kc_custom', cfg[:name]
    assert_equal 'https://auth.example.org', cfg[:client_options][:site]
    assert_equal 'matportal', cfg[:client_options][:realm]
  end

  test 'omniauth provider configuration skips disabled providers and forwards options' do
    providers = {
      disabled_provider: {
        client_id: 'd-id',
        client_secret: 'd-sec',
        enable: false
      },
      custom_keycloak: {
        strategy: :keycloak_openid,
        client_id: 'kc-id',
        client_secret: 'kc-sec',
        client_options: { site: 'https://auth.example.org', realm: 'kc' },
        name: 'keycloak',
        pkce: true,
        scope: 'openid email',
        enable: true
      }
    }

    configured = []
    Array(providers).each do |provider_key, config|
      next unless config.is_a?(Hash)
      next if config[:enable] == false

      options = { client_options: {}.merge(config[:client_options].to_h) }
      options[:name] = config[:name] if config[:name]
      options[:pkce] = config[:pkce] unless config[:pkce].nil?
      options[:scope] = config[:scope] if config[:scope]

      configured << [config[:strategy] || provider_key, config[:client_id], config[:client_secret], options]
    end

    assert_equal 1, configured.size
    strategy, client_id, client_secret, options = configured.first
    assert_equal :keycloak_openid, strategy
    assert_equal 'kc-id', client_id
    assert_equal 'kc-sec', client_secret
    assert_equal 'keycloak', options[:name]
    assert_equal true, options[:pkce]
    assert_equal 'openid email', options[:scope]
    assert_equal({ site: 'https://auth.example.org', realm: 'kc' }, options[:client_options])
  end

  test 'create_omniauth authentication failure sets flash error and renders index' do
    OmniAuth.config.test_mode = true
    OmniAuth.config.mock_auth[:keycloak] = OmniAuth::AuthHash.new(
      provider: 'keycloak',
      uid: 'kc-123',
      credentials: { token: 'mock-token' },
      info: { email: 'test@example.org', name: 'Test User' }
    )

    rest_url = LinkedData::Client.settings.rest_url
    WebMock.stub_request(:post, %r{#{Regexp.escape(rest_url)}/users/authenticate}).to_return(
      status: 200,
      headers: { 'Content-Type' => 'application/json' },
      body: '{"errors": ["Invalid token"]}'
    )

    get '/auth/keycloak/callback', env: {
      'omniauth.auth' => OmniAuth.config.mock_auth[:keycloak]
    }
    assert_response :success
    assert_select '.alert-message, .alert-container', /keycloak authentication failed/i
  end
end
