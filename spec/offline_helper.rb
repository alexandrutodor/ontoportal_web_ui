# frozen_string_literal: true

require 'logger'
require 'active_support'
require 'active_support/all'
require 'webmock/rspec'
require_relative 'spec_helper'

WebMock.disable_net_connect!(allow_localhost: false)

RSpec.configure do |config|
  config.before(:suite) do
    WebMock.disable_net_connect!(allow_localhost: false)
  end
end
