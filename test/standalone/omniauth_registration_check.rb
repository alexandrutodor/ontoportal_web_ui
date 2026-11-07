# frozen_string_literal: true

# ONTO-T-K01: OmniAuth registration must follow the provider configuration the login page uses:
# explicitly disabled providers are not registered, and name/pkce/scope reach the strategy so
# /auth/<name> matches the login button. Callback lookup resolves name, strategy or key.
require 'minitest/autorun'
require 'active_support/all'

module Rails; end unless defined?(Rails)
module OmniAuth; Builder = Class.new unless const_defined?(:Builder); end
# Only the provider lookup is under test; included helper modules are not needed.
%w[ModalHelper MultiLanguagesHelper UrlsHelper ComponentsHelper].each { |m| Object.const_set(m, Module.new) }
require_relative '../../app/helpers/application_helper'

class OmniauthRegistrationCheck < Minitest::Test
  # Records what the initializer passes to OmniAuth::Builder#provider.
  class Recorder
    attr_reader :calls
    def initialize = @calls = []
    def provider(strategy, *args, **opts) = @calls << [strategy, args, opts]
  end

  PROVIDERS = {
    github: { client_id: 'id', client_secret: 's', enable: true },
    google: { strategy: :google_oauth2, client_id: 'id', client_secret: 's', enable: true, scope: 'email,profile' },
    orcid: { client_id: 'id', client_secret: 's', enable: false },
    keycloak: { strategy: :keycloak_openid, client_id: 'id', client_secret: 's',
                client_options: { site: 'https://kc.example', realm: 'r' }, name: 'keycloak', enable: true, pkce: true },
    sso: { strategy: :keycloak_openid, client_id: 'id', client_secret: 's', name: 'campus', enable: true }
  }.freeze

  def registrations
    $OMNIAUTH_PROVIDERS = PROVIDERS
    block = nil
    middleware = Object.new
    middleware.define_singleton_method(:use) { |_builder, &b| block = b }
    app = Struct.new(:config).new(Struct.new(:middleware).new(middleware))
    Rails.define_singleton_method(:application) { app }
    load File.expand_path('../../config/initializers/omniauth.rb', __dir__)
    recorder = Recorder.new
    recorder.instance_eval(&block)
    recorder.calls
  end

  def login_paths
    PROVIDERS.select { |_k, c| c[:enable] }.map { |k, c| (c[:name] || c[:strategy] || k).to_s }
  end

  def test_disabled_provider_is_not_registered
    assert_equal %i[github google_oauth2 keycloak_openid keycloak_openid], registrations.map(&:first)
  end

  def test_registered_path_names_match_login_buttons
    # OmniAuth serves /auth/<options[:name] || strategy name>.
    names = registrations.map { |strategy, _args, opts| (opts[:name] || strategy).to_s }
    assert_equal login_paths, names
  end

  def test_options_are_forwarded
    by_name = registrations.to_h { |strategy, args, opts| [(opts[:name] || strategy).to_s, [args, opts]] }
    assert_equal [%w[id s], { client_options: { site: 'https://kc.example', realm: 'r' }, name: 'keycloak', pkce: true }], by_name['keycloak']
    assert_equal 'email,profile', by_name['google_oauth2'][1][:scope]
    assert_equal({ client_options: {} }, by_name['github'][1])
  end

  def test_callback_lookup_resolves_name_strategy_and_key
    helper = Object.new.extend(ApplicationHelper)
    helper.define_singleton_method(:omniauth_providers_info) { PROVIDERS }
    assert_equal :keycloak, helper.omniauth_token_provider('keycloak')
    assert_equal :google, helper.omniauth_token_provider('google_oauth2')
    assert_equal :github, helper.omniauth_token_provider('github')
    assert_equal :sso, helper.omniauth_token_provider('campus'), 'alias differing from key and strategy'
  end
end
