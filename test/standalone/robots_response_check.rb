# frozen_string_literal: true

require 'minitest/autorun'
require 'pathname'

# In native container (onto-q02-proof:af254f34), ensure gem bundle path is available
if Dir.exist?('/usr/local/bundle/ruby/3.1.0/gems') && (ENV['GEM_PATH'].nil? || !ENV['GEM_PATH'].include?('/usr/local/bundle/ruby/3.1.0'))
  Gem.use_paths(nil, Gem.path + ['/usr/local/bundle/ruby/3.1.0'])
end

begin
  require 'action_controller'
  require 'action_dispatch'
rescue LoadError => e
  abort "ActionController/ActionDispatch required for real Rails response regression check: #{e.message}"
end

REPO_ROOT = Pathname.new(File.expand_path('../..', __dir__))

# Minimal Rails shim providing root and env for actual RobotsController#index
module Rails
  def self.root
    REPO_ROOT
  end

  def self.env
    @env || 'appliance'
  end

  def self.env=(env_name)
    @env = env_name
  end
end

# Minimal ApplicationController base for isolated request dispatch.
# Framework / fixture boundary disclosure:
# Real ApplicationController#domain_ontology_set inspects request.host and calls
# LinkedData::Client::Models::Slice.all via live API. In this offline library-only
# harness, @subdomain_filter is injected synthetically to test RobotsController#index
# branch execution without network, API dependencies, or full application boot.
class ApplicationController < ActionController::Base
  cattr_accessor :subdomain_filter_override, default: { active: false }
  before_action :set_subdomain_filter

  def set_subdomain_filter
    @subdomain_filter = self.class.subdomain_filter_override
  end
end

# Load actual unmodified controller source
require_relative '../../app/controllers/robots_controller'

class RobotsResponseCheck < Minitest::Test
  def setup
    Rails.env = 'appliance'
    ApplicationController.subdomain_filter_override = { active: false }

    # Route shape matches config/routes.rb:176
    @routes = ActionDispatch::Routing::RouteSet.new
    @routes.draw do
      get '/robots.txt' => 'robots#index'
    end
  end

  def test_real_framework_and_routing_dispatch
    assert defined?(ActionController::Base), 'ActionController::Base must be defined'
    assert defined?(ActionDispatch::Routing::RouteSet), 'ActionDispatch::Routing::RouteSet must be defined'
    assert_match(/\A7\./, ActionPack::VERSION::STRING, 'Must run against real Rails 7 ActionPack')
    assert RobotsController < ApplicationController, 'RobotsController must inherit from ApplicationController'
  end

  def test_appliance_non_slice_response_matches_corrected_profile
    Rails.env = 'appliance'
    ApplicationController.subdomain_filter_override = { active: false }

    status, headers, body = dispatch_get('/robots.txt')

    assert_equal 200, status
    assert_match(%r{\Atext/plain}, headers['Content-Type'])

    expected_appliance = File.read(REPO_ROOT + 'config/robots/appliance.txt')
    assert_equal expected_appliance, body
    assert_includes body, 'Disallow: /widgets'
    refute_includes body, 'Disalow: /widgets'
    assert_includes body, 'User-agent: MTRobot'
    refute_includes body, 'User agent: MTRobot'
    assert_includes body, 'User-agent: SemrushBot'
    assert_includes body, 'Crawl-delay: 5'
  end

  def test_active_slice_response_returns_controller_generated_disallow_all
    Rails.env = 'appliance'
    ApplicationController.subdomain_filter_override = { active: true, name: 'Chemistry', acronym: 'CHEM' }

    status, headers, body = dispatch_get('/robots.txt')

    assert_equal 200, status
    assert_match(%r{\Atext/plain}, headers['Content-Type'])
    assert_equal "User-agent: *\nDisallow: /\n", body
    refute_equal File.read(REPO_ROOT + 'config/robots/appliance.txt'), body
  end

  def test_production_non_slice_response_matches_profile
    Rails.env = 'production'
    ApplicationController.subdomain_filter_override = { active: false }

    status, headers, body = dispatch_get('/robots.txt')

    assert_equal 200, status
    assert_match(%r{\Atext/plain}, headers['Content-Type'])
    assert_equal File.read(REPO_ROOT + 'config/robots/production.txt'), body
    assert_includes body, 'Disallow: /projects'
    assert_includes body, 'User-agent: SemrushBot'
  end

  def test_development_non_slice_response_matches_profile
    Rails.env = 'development'
    ApplicationController.subdomain_filter_override = { active: false }

    status, headers, body = dispatch_get('/robots.txt')

    assert_equal 200, status
    assert_match(%r{\Atext/plain}, headers['Content-Type'])
    assert_equal File.read(REPO_ROOT + 'config/robots/development.txt'), body
    assert_equal "User-Agent: *\nDisallow: /\n", body
  end

  def test_staging_non_slice_response_matches_profile
    Rails.env = 'staging'
    ApplicationController.subdomain_filter_override = { active: false }

    status, headers, body = dispatch_get('/robots.txt')

    assert_equal 200, status
    assert_match(%r{\Atext/plain}, headers['Content-Type'])
    assert_equal File.read(REPO_ROOT + 'config/robots/staging.txt'), body
    assert_equal "User-Agent: *\nDisallow: /\n", body
  end

  private

  def dispatch_get(path)
    env = Rack::MockRequest.env_for(path, method: 'GET')
    status, headers, body = @routes.call(env)
    body_content = +''
    body.each { |part| body_content << part }
    [status, headers, body_content]
  end
end
