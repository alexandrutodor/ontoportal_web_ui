# frozen_string_literal: true

# ONTO-T-B12: the homepage agent summary is cached for all visitors, so it must be fetched
# with the public key regardless of the signed-in user, and failures must not be cached.
require 'minitest/autorun'
require 'ostruct'
require 'net/http'
require 'active_support/all'

API_KEY = 'public-portal-key'
module Rails
  def self.cache
    @cache ||= ActiveSupport::Cache::MemoryStore.new
  end
end
# Only HomeController#agents is under test; its parent and helper modules are not needed.
class ApplicationController
  def self.layout(*); end
  attr_accessor :session
end
module FairScoreHelper; end
module FederationHelper; end
module MetricsHelper; end
module AgentHelper
  def agents_rest_url(*)
    'https://api.example.org/agents?page=1'
  end
end
require_relative '../../app/controllers/home_controller'

class HomeAgentsCacheCheck < Minitest::Test
  Response = Struct.new(:body, :success) do
    def is_a?(klass)
      klass == Net::HTTPSuccess ? success : super
    end
  end

  def setup
    Rails.cache.clear
    @requests = []
    @next = Response.new('{"collection":[{"name":"Public agent"}]}', true)
    requests = @requests
    nxt = -> { @next }
    Net::HTTP.class_eval do
      alias_method :__orig_request, :request unless method_defined?(:__orig_request)
      define_method(:request) { |req| requests << req.path; nxt.call }
    end
  end

  def teardown
    Net::HTTP.class_eval { alias_method :request, :__orig_request }
  end

  def run_agents(user: nil)
    c = HomeController.new
    c.session = user ? { user: OpenStruct.new(apikey: 'private-user-key') } : {}
    c.define_singleton_method(:respond_to) { |*| nil }
    c.agents
    c.instance_variable_get(:@agents_data)
  end

  def test_signed_in_user_key_is_never_used_for_the_shared_cache
    data = run_agents(user: true)
    assert_equal 1, @requests.length
    assert_includes @requests.first, 'apikey=public-portal-key'
    refute_includes @requests.first, 'private-user-key'
    assert_equal 'Public agent', data['collection'].first['name']

    assert_equal data, run_agents, 'anonymous visitor reads the same public entry'
    assert_equal 1, @requests.length, 'served from cache'
  end

  def test_versioned_key_ignores_entries_cached_by_the_old_per_user_key
    Rails.cache.write('agents_data_home_page', { 'collection' => [{ 'name' => 'Private agent' }] })
    assert_equal 'Public agent', run_agents['collection'].first['name']
  end

  def test_failures_are_not_cached
    @next = Response.new('error', false)
    assert_equal({ 'collection' => [] }, run_agents)
    refute Rails.cache.exist?(HomeController::HOME_AGENTS_CACHE_KEY), 'failure not cached'

    @next = Response.new('{"collection":[{"name":"Recovered"}]}', true)
    assert_equal 'Recovered', run_agents['collection'].first['name']
    assert_equal 2, @requests.length
  end
end
