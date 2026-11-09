# frozen_string_literal: true

require_relative 'offline_helper'
require_relative '../app/helpers/sparql_helper'
require 'net/http'

RSpec.describe 'Offline Network Boundary and Guard' do
  include SparqlHelper

  before do
    $REST_URL = 'http://example.org'
  end

  describe 'default deny external network access' do
    it 'rejects outgoing HTTP GET requests with WebMock error' do
      expect do
        Net::HTTP.get(URI('http://data.bioontology.org/ontologies'))
      end.to raise_error(WebMock::NetConnectNotAllowedError)
    end

    it 'rejects outgoing HTTP POST requests with WebMock error' do
      expect do
        Net::HTTP.post(URI('http://example.org/sparql'), 'query=SELECT *')
      end.to raise_error(WebMock::NetConnectNotAllowedError)
    end

    it 'rejects loopback and localhost connections' do
      expect do
        Net::HTTP.get(URI('http://127.0.0.1:9393/health'))
      end.to raise_error(WebMock::NetConnectNotAllowedError)

      expect do
        Net::HTTP.get(URI('http://localhost:3000/'))
      end.to raise_error(WebMock::NetConnectNotAllowedError)
    end
  end

  describe 'pure SPARQL helper execution' do
    it 'transforms queries offline without triggering any network request' do
      query = 'SELECT * WHERE { ?s ?p ?o }'
      result = change_from_clause(query, 'http://test.graph/ont')
      expect(result).to include('FROM <http://test.graph/ont>')
      expect(WebMock).not_to have_requested(:any, /.*/)
    end
  end

  describe 'offline boundary guards' do
    it 'runs without full Rails application boot' do
      expect(defined?(Rails.application)).to be_falsey
    end

    it 'runs without database connection' do
      connected = defined?(ActiveRecord::Base) && (ActiveRecord::Base.connected? rescue false)
      expect(connected).to be_falsey
    end
  end
end
