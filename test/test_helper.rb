ENV['RAILS_ENV'] ||= 'test'
require_relative 'coverage_helper'
require_relative '../config/environment'
require 'rails/test_help'
require 'webmock/minitest'
require_relative 'helpers/test_target_guard'
require_relative 'helpers/external_portal_stub_helper'

# Configure explicit Capybara test server host and port before policy
if defined?(Capybara)
  Capybara.server_host = ENV['CAPYBARA_SERVER_HOST'] || '0.0.0.0'
  Capybara.server_port = (ENV['CAPYBARA_SERVER_PORT'] || TestTargetGuard::DEFAULT_CAPYBARA_PORT).to_i
  Capybara.app_host = "http://#{Socket.gethostname}:#{Capybara.server_port}"
end

# Preflight test target before suite setup; enforces default-deny WebMock except validated local API
TestTargetGuard.enforce_isolated_test_target!

class ActiveSupport::TestCase
  # Run tests in parallel with specified workers
  parallelize(workers: 1)

  if defined?(Capybara)
    Capybara.server_host = ENV['CAPYBARA_SERVER_HOST'] || '0.0.0.0'
    Capybara.server_port ||= (ENV['CAPYBARA_SERVER_PORT'] || TestTargetGuard::DEFAULT_CAPYBARA_PORT).to_i
    Capybara.app_host = "http://#{Socket.gethostname}:#{Capybara.server_port}"
  end

  # Default network access denied; narrowly permit the validated local API
  TestTargetGuard.configure_webmock!

  setup do
    TestTargetGuard.enforce_isolated_test_target!
    FlipperSetup.test_configure!
    ExternalPortalStubHelper.stub_isolated_external_services
  end
end

# Define the fixtures helper method
def fixtures(fixture_name)
  @global_fixtures ||= load_all_fixtures
  @global_fixtures[fixture_name.to_s]
end

# Load all fixtures method
def load_all_fixtures
  fixtures_directory = Rails.root.join('test', 'fixtures')
  fixture_files = Dir.glob(File.join(fixtures_directory, '*.yml'))

  fixtures_data = {}

  fixture_files.each do |fixture_file|
    fixture_name = File.basename(fixture_file, '.yml')
    data = YAML.load_file(fixture_file)
    if data["yaml_structure"].eql?("regular")
      fixtures_data[fixture_name] = data
    else
      fixtures_data[fixture_name] = OpenStruct.new(Array(data).map{|key, hash| [key , OpenStruct.new(hash)]}.to_h)
    end
  end

  fixtures_data
end