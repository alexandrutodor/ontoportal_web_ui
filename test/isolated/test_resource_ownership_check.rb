# frozen_string_literal: true

# Standalone isolated test for ONTO-T-Q06 owned-resource tracking and cleanup contract.
# Run directly with plain Ruby:
#   ruby test/isolated/test_resource_ownership_check.rb
#
# Validates:
#   1. Broad default .all deletion is replaced by exact owned ID cleanup.
#   2. Pre-seeded and unrelated categories, groups, agents, ontologies, and users (including admin) are preserved.
#   3. Explicit caller-supplied lists cannot delete unowned resources.
#   4. Midway setup failure cleans only previously recorded owned resources.
#   5. Direct / UI-created resources can be explicitly registered and reconciled.
#   6. Preflight enforcement (verify_test_target!) runs before client/cleanup calls.
#   7. Authentic admin credentials and user protection cannot be bypassed.
#   8. Entire check executes 100% offline with zero sockets or remote connections.

require 'socket'
require 'ostruct'
require 'json'

# --- Offline Socket Guard ---
class DisallowedSocketError < StandardError; end

module SocketGuard
  def open(*)
    raise DisallowedSocketError, "TCPSocket.open called during offline check"
  end
  def initialize(*)
    raise DisallowedSocketError, "TCPSocket.new called during offline check"
  end
end
TCPSocket.singleton_class.prepend(SocketGuard)

# Set test marker and isolated test target for preflight
ENV['ONTOPORTAL_ISOLATED_TEST'] = '1'

require_relative '../helpers/test_target_guard'
require_relative '../helpers/test_resource_ownership'
require_relative '../helpers/application_test_helpers'

# --- Offline Mock Datastore & Client Models ---
class MockDatastore
  attr_reader :categories, :groups, :agents, :ontologies, :submissions, :users, :deleted_log, :read_log, :delete_calls

  def initialize
    @categories = {}
    @groups = {}
    @agents = {}
    @ontologies = {}
    @submissions = {}
    @users = {}
    @deleted_log = []
    @read_log = []
    @delete_calls = []
  end

  def seed_defaults!
    @read_log = []
    @delete_calls = []
    @categories['SEEDED_CAT_1'] = { acronym: 'SEEDED_CAT_1', name: 'Seeded Category 1', id: 'http://localhost:9393/categories/SEEDED_CAT_1' }
    @categories['SEEDED_CAT_2'] = { acronym: 'SEEDED_CAT_2', name: 'Seeded Category 2', id: 'http://localhost:9393/categories/SEEDED_CAT_2' }

    @groups['SEEDED_GRP_1'] = { acronym: 'SEEDED_GRP_1', name: 'Seeded Group 1', id: 'http://localhost:9393/groups/SEEDED_GRP_1' }
    @groups['SEEDED_GRP_2'] = { acronym: 'SEEDED_GRP_2', name: 'Seeded Group 2', id: 'http://localhost:9393/groups/SEEDED_GRP_2' }

    @agents['http://localhost:9393/agents/SEEDED_AGENT_1'] = { id: 'http://localhost:9393/agents/SEEDED_AGENT_1', name: 'Seeded Agent 1' }
    @agents['http://localhost:9393/agents/SEEDED_AGENT_2'] = { id: 'http://localhost:9393/agents/SEEDED_AGENT_2', name: 'Seeded Agent 2' }

    @ontologies['SEEDED_ONT_1'] = { acronym: 'SEEDED_ONT_1', name: 'Seeded Ontology 1', id: 'http://localhost:9393/ontologies/SEEDED_ONT_1' }

    @users['admin'] = { username: 'admin', apikey: 'secret_admin_token', password: 'password', role: ['ADMINISTRATOR'] }
    @users['SEEDED_USER_1'] = { username: 'SEEDED_USER_1', apikey: 'user_token_1', password: 'password', role: [] }
  end
end

$datastore = MockDatastore.new
$datastore.seed_defaults!

# Mock Faraday response for client models and REST
class MockFaradayResponse
  attr_accessor :status, :body
  def initialize(status: 200, body: '{}')
    @status = status
    @body = body
  end
end

# Mock LinkedData Client
module LinkedData
  module Client
    class Base
      # Provenance: ontologies-api-client-6257685-base.rb:109-155
      def initialize(values = {})
        data = values.is_a?(Hash) ? values.dup : {}
        create_attributes(data.keys)
        populate_attributes(data)
      end

      def method_missing(meth, *args, &block)
        if meth.to_s[-1].eql?("=")
          attr = meth.to_s.chomp("=").to_sym
          create_attributes([attr])
          populate_attributes(attr => args.first)
        else
          nil
        end
      end

      def respond_to?(meth, include_all = false)
        true
      end

      def [](key)
        key = "@#{key}" unless key.to_s.start_with?("@")
        instance_variable_get(key)
      end

      def []=(key, value)
        create_attributes([key])
        populate_attributes({ key.to_sym => value })
      end

      private

      def create_attributes(attributes)
        attributes.each do |attr|
          attr = attr.to_s[1..-1].to_sym if attr.to_s.start_with?("@")
          self.class.class_eval do
            unless method_defined?(attr.to_sym)
              define_method attr.to_sym do
                instance_variable_get("@#{attr}")
              end
            end
            unless method_defined?("#{attr}=".to_sym)
              define_method "#{attr}=" do |val|
                instance_variable_set("@#{attr}", val)
              end
            end
          end
        end
      end

      def populate_attributes(hash)
        hash.each do |k, v|
          k = "@#{k}" unless k.to_s.start_with?("@")
          instance_variable_set(k, v)
        end
      end
    end

    class CreatedResponse < Base
      attr_accessor :values

      def initialize(attrs = {})
        attrs = attrs.dup
        @values = attrs
        super(attrs)
        create_attributes(attrs.keys)
        populate_attributes(attrs)
        @status ||= (attrs[:status] || attrs['status'] || 201)
      end

      def to_h
        @values
      end

      def delete
        if @id&.include?('/categories/') || (@acronym && $datastore.categories.key?(@acronym))
          $datastore.deleted_log << [:category, @acronym]
          $datastore.categories.delete(@acronym)
        elsif @id&.include?('/groups/') || (@acronym && $datastore.groups.key?(@acronym))
          $datastore.deleted_log << [:group, @acronym]
          $datastore.groups.delete(@acronym)
        elsif @id&.include?('/ontologies/') || (@acronym && $datastore.ontologies.key?(@acronym))
          $datastore.deleted_log << [:ontology, @acronym]
          $datastore.ontologies.delete(@acronym)
        elsif @username
          $datastore.deleted_log << [:user, @username]
          $datastore.users.delete(@username)
        elsif @id
          $datastore.deleted_log << [:submission, @id]
        end
        MockFaradayResponse.new(status: 204)
      end
    end

    class Settings
      attr_accessor :rest_url
      def initialize
        @rest_url = 'http://localhost:9393'
      end
    end

    def self.settings
      @settings ||= Settings.new
    end

    module ReadWrite
      private

      def cache_refresh(options = {})
        self.class.all if self.class.respond_to?(:all)
      end
    end

    module HTTP
      def self.post(path, payload, options = {})
        case path
        when '/categories'
          acronym = (payload[:acronym] || payload['acronym']).to_s
          if payload[:errors]
            CreatedResponse.new(status: 400, errors: payload[:errors])
          else
            id = (payload[:id] || payload['id'] || "http://localhost:9393/categories/#{acronym}").to_s
            $datastore.categories[acronym] = { acronym: acronym, name: payload[:name], id: id }
            CreatedResponse.new(id: id, acronym: acronym, name: payload[:name], status: 201)
          end
        when '/groups'
          acronym = (payload[:acronym] || payload['acronym']).to_s
          if payload[:errors]
            CreatedResponse.new(status: 400, errors: payload[:errors])
          else
            id = (payload[:id] || payload['id'] || "http://localhost:9393/groups/#{acronym}").to_s
            $datastore.groups[acronym] = { acronym: acronym, name: payload[:name], id: id }
            CreatedResponse.new(id: id, acronym: acronym, name: payload[:name], status: 201)
          end
        when '/ontologies'
          acronym = (payload[:acronym] || payload['acronym']).to_s
          if payload[:errors]
            CreatedResponse.new(status: 400, errors: payload[:errors])
          else
            id = (payload[:id] || payload['id'] || "http://localhost:9393/ontologies/#{acronym}").to_s
            $datastore.ontologies[acronym] = { acronym: acronym, name: payload[:name], id: id }
            CreatedResponse.new(id: id, acronym: acronym, name: payload[:name], status: 201)
          end
        when '/submissions', '/ontologies/submissions'
          if payload[:errors]
            CreatedResponse.new(status: 400, errors: payload[:errors])
          else
            id = "http://localhost:9393/submissions/#{rand(1000..9999)}"
            $datastore.submissions[id] = payload
            CreatedResponse.new(id: id, ontology: payload[:ontology], status: 201)
          end
        when '/users'
          username = (payload[:username] || payload['username']).to_s
          if payload[:errors]
            CreatedResponse.new(status: 400, errors: payload[:errors])
          else
            id = (payload[:id] || payload['id'] || "http://localhost:9393/users/#{username}").to_s
            $datastore.users[username] = payload.merge(apikey: "apikey_#{username}", id: id)
            CreatedResponse.new(id: id, username: username, status: 201)
          end
        else
          CreatedResponse.new(status: 200)
        end
      end
    end

    module Models
      class Category
        include LinkedData::Client::ReadWrite

        attr_accessor :acronym, :name, :id, :errors, :delete_error, :delete_status

        def initialize(values: {})
          @acronym = (values[:acronym] || values['acronym']).to_s
          @name = (values[:name] || values['name']).to_s
          @id = (values[:id] || values['id'] || "http://localhost:9393/categories/#{@acronym}").to_s
          @errors = values[:errors]
          @delete_error = values[:delete_error]
          @delete_status = values[:delete_status]
        end

        def to_h
          { acronym: @acronym, name: @name, id: @id, errors: @errors, delete_error: @delete_error, delete_status: @delete_status }.compact
        end
        alias to_hash to_h

        def self.collection_path
          '/categories'
        end

        def save
          if @errors
            self
          else
            $datastore.categories[@acronym] = to_h
            self
          end
        end

        def delete
          $datastore.delete_calls << [:category, @acronym]
          if @delete_error
            raise @delete_error
          end
          if @delete_status && @delete_status >= 400
            return MockFaradayResponse.new(status: @delete_status, body: "Error #{@delete_status}")
          end
          $datastore.deleted_log << [:category, @acronym]
          $datastore.categories.delete(@acronym)
          MockFaradayResponse.new(status: 204)
        end

        def self.all
          $datastore.categories.values.map { |v| Category.new(values: v) }
        end

        def self.find_by_acronym(acronym, options = {})
          $datastore.read_log << [:category_find, acronym.to_s, options]
          if $datastore.categories[acronym.to_s] && $datastore.categories[acronym.to_s][:find_error]
            raise $datastore.categories[acronym.to_s][:find_error]
          end
          v = $datastore.categories[acronym.to_s]
          v ? [Category.new(values: v)] : []
        end

        def self.find(id, options = {})
          $datastore.read_log << [:category_find, id.to_s, options]
          if $datastore.categories[id.to_s] && $datastore.categories[id.to_s][:find_error]
            raise $datastore.categories[id.to_s][:find_error]
          end
          acronym = id.to_s.split('/').last
          v = $datastore.categories[id.to_s] || $datastore.categories[acronym]
          v ? Category.new(values: v) : nil
        end
      end

      class Group
        include LinkedData::Client::ReadWrite

        attr_accessor :acronym, :name, :id, :errors, :delete_error, :delete_status

        def initialize(values: {})
          @acronym = (values[:acronym] || values['acronym']).to_s
          @name = (values[:name] || values['name']).to_s
          @id = (values[:id] || values['id'] || "http://localhost:9393/groups/#{@acronym}").to_s
          @errors = values[:errors]
          @delete_error = values[:delete_error]
          @delete_status = values[:delete_status]
        end

        def to_h
          { acronym: @acronym, name: @name, id: @id, errors: @errors, delete_error: @delete_error, delete_status: @delete_status }.compact
        end
        alias to_hash to_h

        def self.collection_path
          '/groups'
        end

        def save
          if @errors
            self
          else
            $datastore.groups[@acronym] = to_h
            self
          end
        end

        def delete
          $datastore.delete_calls << [:group, @acronym]
          if @delete_error
            raise @delete_error
          end
          if @delete_status && @delete_status >= 400
            return MockFaradayResponse.new(status: @delete_status, body: "Error #{@delete_status}")
          end
          $datastore.deleted_log << [:group, @acronym]
          $datastore.groups.delete(@acronym)
          MockFaradayResponse.new(status: 204)
        end

        def self.all
          $datastore.groups.values.map { |v| Group.new(values: v) }
        end

        def self.find_by_acronym(acronym, options = {})
          $datastore.read_log << [:group_find, acronym.to_s, options]
          if $datastore.groups[acronym.to_s] && $datastore.groups[acronym.to_s][:find_error]
            raise $datastore.groups[acronym.to_s][:find_error]
          end
          v = $datastore.groups[acronym.to_s]
          v ? [Group.new(values: v)] : []
        end

        def self.find(id, options = {})
          $datastore.read_log << [:group_find, id.to_s, options]
          if $datastore.groups[id.to_s] && $datastore.groups[id.to_s][:find_error]
            raise $datastore.groups[id.to_s][:find_error]
          end
          acronym = id.to_s.split('/').last
          v = $datastore.groups[id.to_s] || $datastore.groups[acronym]
          v ? Group.new(values: v) : nil
        end
      end

      class Agent
        attr_accessor :id, :name, :errors, :delete_error, :delete_status

        def initialize(values: {})
          @id = (values[:id] || values['id']).to_s
          @name = (values[:name] || values['name']).to_s
          @errors = values[:errors]
          @delete_error = values[:delete_error]
          @delete_status = values[:delete_status]
        end

        def to_h
          { id: @id, name: @name, errors: @errors, delete_error: @delete_error, delete_status: @delete_status }
        end

        def delete
          $datastore.delete_calls << [:agent, @id]
          if @delete_error
            raise @delete_error
          end
          if @delete_status && @delete_status >= 400
            return MockFaradayResponse.new(status: @delete_status, body: "Error #{@delete_status}")
          end
          $datastore.deleted_log << [:agent, @id]
          $datastore.agents.delete(@id)
          MockFaradayResponse.new(status: 204)
        end

        def self.all
          $datastore.agents.values.map { |v| Agent.new(values: v) }
        end

        def self.find(id, options = {})
          $datastore.read_log << [:agent_find, id.to_s, options]
          if $datastore.agents[id.to_s] && $datastore.agents[id.to_s][:find_error]
            raise $datastore.agents[id.to_s][:find_error]
          end
          v = $datastore.agents[id.to_s]
          v ? Agent.new(values: v) : nil
        end
      end

      class Ontology
        include LinkedData::Client::ReadWrite

        attr_accessor :acronym, :name, :id, :errors, :delete_error, :delete_status

        def initialize(values: {})
          @acronym = (values[:acronym] || values['acronym']).to_s
          @name = (values[:name] || values['name']).to_s
          @id = (values[:id] || values['id'] || "http://localhost:9393/ontologies/#{@acronym}").to_s
          @errors = values[:errors]
          @delete_error = values[:delete_error]
          @delete_status = values[:delete_status]
        end

        def to_h
          { acronym: @acronym, name: @name, id: @id, errors: @errors, delete_error: @delete_error, delete_status: @delete_status }.compact
        end
        alias to_hash to_h

        def self.collection_path
          '/ontologies'
        end

        def save
          if @errors
            self
          else
            $datastore.ontologies[@acronym] = to_h
            self
          end
        end

        def delete
          $datastore.delete_calls << [:ontology, @acronym]
          if @delete_error
            raise @delete_error
          end
          if @delete_status && @delete_status >= 400
            return MockFaradayResponse.new(status: @delete_status, body: "Error #{@delete_status}")
          end
          $datastore.deleted_log << [:ontology, @acronym]
          $datastore.ontologies.delete(@acronym)
          MockFaradayResponse.new(status: 204)
        end

        def self.all
          $datastore.ontologies.values.map { |v| Ontology.new(values: v) }
        end

        def self.find_by_acronym(acronym, options = {})
          $datastore.read_log << [:ontology_find, acronym.to_s, options]
          if $datastore.ontologies[acronym.to_s] && $datastore.ontologies[acronym.to_s][:find_error]
            raise $datastore.ontologies[acronym.to_s][:find_error]
          end
          v = $datastore.ontologies[acronym.to_s]
          v ? [Ontology.new(values: v)] : []
        end

        def self.find(id, options = {})
          $datastore.read_log << [:ontology_find, id.to_s, options]
          if $datastore.ontologies[id.to_s] && $datastore.ontologies[id.to_s][:find_error]
            raise $datastore.ontologies[id.to_s][:find_error]
          end
          acronym = id.to_s.split('/').last
          v = $datastore.ontologies[id.to_s] || $datastore.ontologies[acronym]
          v ? Ontology.new(values: v) : nil
        end
      end

      class OntologySubmission
        include LinkedData::Client::ReadWrite

        attr_accessor :id, :ontology, :errors, :delete_error, :delete_status

        def initialize(values: {})
          @id = (values[:id] || values['id'] || "http://localhost:9393/submissions/#{rand(1000..9999)}").to_s
          @ontology = values[:ontology] || values['ontology']
          @errors = values[:errors]
          @delete_error = values[:delete_error]
          @delete_status = values[:delete_status]
        end

        def to_h
          { id: @id, ontology: @ontology, errors: @errors }.compact
        end
        alias to_hash to_h

        def self.collection_path
          '/submissions'
        end

        def save
          if @errors
            self
          else
            $datastore.submissions[@id] = to_h
            self
          end
        end

        def delete
          $datastore.delete_calls << [:submission, @id]
          if @delete_error
            raise @delete_error
          end
          if @delete_status && @delete_status >= 400
            return MockFaradayResponse.new(status: @delete_status, body: "Error #{@delete_status}")
          end
          $datastore.deleted_log << [:submission, @id]
          $datastore.submissions.delete(@id)
          MockFaradayResponse.new(status: 204)
        end
      end

      class User
        include LinkedData::Client::ReadWrite

        attr_accessor :username, :password, :role, :apikey, :id, :errors

        def initialize(values: {})
          @username = (values[:username] || values['username']).to_s
          @password = (values[:password] || values['password']).to_s
          @role = values[:role] || values['role']
          @apikey = values[:apikey] || values['apikey'] || "apikey_#{@username}"
          @id = (values[:id] || values['id'] || "http://localhost:9393/users/#{@username}").to_s
          @errors = values[:errors]
        end

        def to_h
          { username: @username, password: @password, role: @role, apikey: @apikey, id: @id, errors: @errors }.compact
        end
        alias to_hash to_h

        def self.collection_path
          '/users'
        end

        def self.authenticate(username, password)
          return nil unless password == 'password'
          data = $datastore.users[username.to_s]
          data ? User.new(values: data) : nil
        end

        def self.find_by_username(username, options = {})
          $datastore.read_log << [:user_find, username.to_s, options]
          if $datastore.users[username.to_s] && $datastore.users[username.to_s][:find_error]
            raise $datastore.users[username.to_s][:find_error]
          end
          v = $datastore.users[username.to_s]
          v ? [User.new(values: v)] : []
        end

        def self.find(username, options = {})
          $datastore.read_log << [:user_find, username.to_s, options]
          if $datastore.users[username.to_s] && $datastore.users[username.to_s][:find_error]
            raise $datastore.users[username.to_s][:find_error]
          end
          v = $datastore.users[username.to_s]
          v ? User.new(values: v) : nil
        end

        def self.all
          $datastore.users.values.map { |v| User.new(values: v) }
        end
      end
    end
  end
end

class MockFaradayConnection
  class << self
    attr_accessor :delete_error, :delete_status
  end

  def initialize(url)
    @url = url
    @headers = {}
  end

  def request(*); end
  def response(*); end
  def adapter(*); end
  def headers=(h); @headers = h; end

  def post(path, body = nil, headers = {})
    if path == '/users'
      data = JSON.parse(body) rescue {}
      username = data['username'] || data[:username]
      $datastore.users[username] = data.merge(apikey: "apikey_#{username}")
      MockFaradayResponse.new(status: 201, body: JSON.dump($datastore.users[username]))
    else
      MockFaradayResponse.new(status: 200)
    end
  end

  def delete(path)
    $datastore.delete_calls << [:faraday_delete, path]
    if path.start_with?('/users/')
      if MockFaradayConnection.delete_error
        raise MockFaradayConnection.delete_error
      end
      if MockFaradayConnection.delete_status && MockFaradayConnection.delete_status >= 400
        return MockFaradayResponse.new(status: MockFaradayConnection.delete_status, body: "Error #{MockFaradayConnection.delete_status}")
      end
      username = path.sub('/users/', '')
      $datastore.deleted_log << [:user, username]
      $datastore.users.delete(username)
      MockFaradayResponse.new(status: 204)
    else
      MockFaradayResponse.new(status: 200)
    end
  end
end

class Faraday
  def self.default_adapter; :net_http; end
  def self.new(url:, &block)
    conn = MockFaradayConnection.new(url)
    block.call(conn) if block_given?
    conn
  end
end

# Test Harness including application helpers
class TestHarness
  include ApplicationTestHelpers
  include ApplicationTestHelpers::Users
  include ApplicationTestHelpers::Categories
  include ApplicationTestHelpers::Groups
  include ApplicationTestHelpers::Agents
  include ApplicationTestHelpers::Ontologies
end

# --- Assertions Runner ---
$failures = []
def assert(condition, message)
  if condition
    puts "  [PASS] #{message}"
  else
    puts "  [FAIL] #{message}"
    $failures << message
  end
end

puts "============================================================"
puts "Running ONTO-T-Q06 Isolated Owned-Resource Ownership Checks"
puts "============================================================"

harness = TestHarness.new

# -----------------------------------------------------------------------------
puts "\n=== Step 1: Preflight Enforcement on Cleanup & Client Helpers ==="
# -----------------------------------------------------------------------------
ENV[TestTargetGuard::MARKER_ENV_VAR] = '1'
LinkedData::Client.settings.rest_url = 'https://data.bioontology.org'

disallowed_error = false
begin
  harness.delete_categories
rescue TestTargetGuard::DisallowedTargetError
  disallowed_error = true
end
assert(disallowed_error, "delete_categories against remote destination raises DisallowedTargetError before client calls")

ENV[TestTargetGuard::MARKER_ENV_VAR] = nil
LinkedData::Client.settings.rest_url = 'http://localhost:9393'

missing_marker_error = false
begin
  harness.delete_groups
rescue TestTargetGuard::MissingMarkerError
  missing_marker_error = true
end
assert(missing_marker_error, "delete_groups with missing marker raises MissingMarkerError before client calls")

# Restore valid isolated target
ENV[TestTargetGuard::MARKER_ENV_VAR] = '1'
LinkedData::Client.settings.rest_url = 'http://localhost:9393'

# -----------------------------------------------------------------------------
puts "\n=== Step 2: Empty Setup / Teardown Preserves All Seeded Resources ==="
# -----------------------------------------------------------------------------
$datastore.seed_defaults!
$datastore.deleted_log.clear
TestResourceOwnership.reset!

# Calling teardown / cleanup on empty ownership state
harness.cleanup_owned_resources!

assert($datastore.deleted_log.empty?, "Empty teardown dispatched exactly 0 deletion calls (got: #{$datastore.deleted_log.inspect})")
assert($datastore.categories.key?('SEEDED_CAT_1') && $datastore.categories.key?('SEEDED_CAT_2'), "Seeded categories survived empty teardown")
assert($datastore.groups.key?('SEEDED_GRP_1') && $datastore.groups.key?('SEEDED_GRP_2'), "Seeded groups survived empty teardown")
assert($datastore.agents.key?('http://localhost:9393/agents/SEEDED_AGENT_1'), "Seeded agents survived empty teardown")
assert($datastore.ontologies.key?('SEEDED_ONT_1'), "Seeded ontology survived empty teardown")
assert($datastore.users.key?('admin') && $datastore.users.key?('SEEDED_USER_1'), "Seeded admin and users survived empty teardown")

# -----------------------------------------------------------------------------
puts "\n=== Step 3: Owned Creations Tracked and Deleted by Exact ID ==="
# -----------------------------------------------------------------------------
$datastore.seed_defaults!
$datastore.deleted_log.clear
TestResourceOwnership.reset!

cat_test = harness.create_category({ acronym: 'TEST_CAT_1', name: 'Test Category 1' })
grp_test = harness.create_group({ acronym: 'TEST_GRP_1', name: 'Test Group 1' })
user_test = harness.create_user(OpenStruct.new(username: 'test_user_bob', password: 'password', to_h: { username: 'test_user_bob', password: 'password' }))
ont_sub = harness.create_ontology({ acronym: 'TEST_ONT_1', name: 'Test Ontology 1' }, { URI: 'http://test.org/ont1', description: 'desc' })

assert(TestResourceOwnership.owned?(:category, 'TEST_CAT_1'), "TEST_CAT_1 is registered as owned")
assert(TestResourceOwnership.owned?(:group, 'TEST_GRP_1'), "TEST_GRP_1 is registered as owned")
assert(TestResourceOwnership.owned?(:user, 'test_user_bob'), "test_user_bob is registered as owned")
assert(TestResourceOwnership.owned?(:ontology, 'TEST_ONT_1'), "TEST_ONT_1 is registered as owned")

# Verify datastore contains both seeded and test resources
assert($datastore.categories.key?('TEST_CAT_1') && $datastore.categories.key?('SEEDED_CAT_1'), "Datastore contains both owned and seeded categories")

# Perform teardown
harness.cleanup_owned_resources!

# Verify ONLY test resources were deleted
deleted_types_ids = $datastore.deleted_log
assert(!deleted_types_ids.include?([:category, 'SEEDED_CAT_1']), "SEEDED_CAT_1 was NOT deleted")
assert(!deleted_types_ids.include?([:category, 'SEEDED_CAT_2']), "SEEDED_CAT_2 was NOT deleted")
assert(!deleted_types_ids.include?([:group, 'SEEDED_GRP_1']), "SEEDED_GRP_1 was NOT deleted")
assert(!deleted_types_ids.include?([:ontology, 'SEEDED_ONT_1']), "SEEDED_ONT_1 was NOT deleted")
assert(!deleted_types_ids.include?([:user, 'admin']), "admin was NOT deleted")
assert(!deleted_types_ids.include?([:user, 'SEEDED_USER_1']), "SEEDED_USER_1 was NOT deleted")

assert(deleted_types_ids.include?([:category, 'TEST_CAT_1']), "TEST_CAT_1 was cleanly deleted")
assert(deleted_types_ids.include?([:group, 'TEST_GRP_1']), "TEST_GRP_1 was cleanly deleted")
assert(deleted_types_ids.include?([:user, 'test_user_bob']), "test_user_bob was cleanly deleted")
assert(deleted_types_ids.include?([:ontology, 'TEST_ONT_1']), "TEST_ONT_1 was cleanly deleted")
assert(TestResourceOwnership.empty?, "Ownership registry is empty after teardown")

# -----------------------------------------------------------------------------
puts "\n=== Step 4: Midway Setup Failure Cleans Only Recorded Owned Resources ==="
# -----------------------------------------------------------------------------
$datastore.seed_defaults!
$datastore.deleted_log.clear
TestResourceOwnership.reset!

# Create two valid categories
cat_a = harness.create_category({ acronym: 'CAT_MIDWAY_A', name: 'Midway A' })
cat_b = harness.create_category({ acronym: 'CAT_MIDWAY_B', name: 'Midway B' })

# Third creation fails with client errors
cat_c_failed = harness.create_category({ acronym: 'CAT_MIDWAY_C', name: 'Midway C', errors: ['Acronym invalid'] })

assert(TestResourceOwnership.owned?(:category, 'CAT_MIDWAY_A'), "CAT_MIDWAY_A recorded before failure")
assert(TestResourceOwnership.owned?(:category, 'CAT_MIDWAY_B'), "CAT_MIDWAY_B recorded before failure")
assert(!TestResourceOwnership.owned?(:category, 'CAT_MIDWAY_C'), "Failed CAT_MIDWAY_C was NOT recorded as owned")

# Simulate runner executing teardown on setup failure
harness.delete_categories

assert($datastore.deleted_log.include?([:category, 'CAT_MIDWAY_A']), "CAT_MIDWAY_A deleted during partial cleanup")
assert($datastore.deleted_log.include?([:category, 'CAT_MIDWAY_B']), "CAT_MIDWAY_B deleted during partial cleanup")
assert(!$datastore.deleted_log.include?([:category, 'CAT_MIDWAY_C']), "CAT_MIDWAY_C deletion never attempted")
assert($datastore.categories.key?('SEEDED_CAT_1'), "SEEDED_CAT_1 preserved after midway failure teardown")
assert($datastore.categories.key?('SEEDED_CAT_2'), "SEEDED_CAT_2 preserved after midway failure teardown")

# -----------------------------------------------------------------------------
puts "\n=== Step 5: Explicit Unowned Deletion Attempts are Refused ==="
# -----------------------------------------------------------------------------
$datastore.seed_defaults!
$datastore.deleted_log.clear
TestResourceOwnership.reset!

# 5a: Attempt to delete seeded admin
harness.delete_user(OpenStruct.new(username: 'admin'))
harness.delete_user('admin')
harness.delete_user('ADMIN')
assert(!$datastore.deleted_log.include?([:user, 'admin']), "delete_user('admin') refused; admin is preserved")
assert($datastore.users.key?('admin'), "admin exists in datastore")

# 5b: Attempt to delete unowned seeded user
harness.delete_user(OpenStruct.new(username: 'SEEDED_USER_1'))
assert(!$datastore.deleted_log.include?([:user, 'SEEDED_USER_1']), "delete_user('SEEDED_USER_1') refused; unowned user preserved")
assert($datastore.users.key?('SEEDED_USER_1'), "SEEDED_USER_1 exists in datastore")

# 5c: Attempt caller-supplied list deletion of seeded categories
harness.delete_categories([
  OpenStruct.new(acronym: 'SEEDED_CAT_1', to_s: 'SEEDED_CAT_1'),
  OpenStruct.new(acronym: 'SEEDED_CAT_2', to_s: 'SEEDED_CAT_2')
])
assert(!$datastore.deleted_log.include?([:category, 'SEEDED_CAT_1']), "Caller-supplied unowned SEEDED_CAT_1 was NOT deleted")
assert(!$datastore.deleted_log.include?([:category, 'SEEDED_CAT_2']), "Caller-supplied unowned SEEDED_CAT_2 was NOT deleted")
assert($datastore.categories.key?('SEEDED_CAT_1') && $datastore.categories.key?('SEEDED_CAT_2'), "Seeded categories intact")

# 5d: Attempt caller-supplied list deletion of seeded groups
harness.delete_groups([OpenStruct.new(acronym: 'SEEDED_GRP_1', to_s: 'SEEDED_GRP_1')])
assert(!$datastore.deleted_log.include?([:group, 'SEEDED_GRP_1']), "Caller-supplied unowned SEEDED_GRP_1 was NOT deleted")
assert($datastore.groups.key?('SEEDED_GRP_1'), "Seeded group intact")

# 5e: Attempt caller-supplied deletion of seeded ontology
harness.delete_ontologies([OpenStruct.new(acronym: 'SEEDED_ONT_1', to_s: 'SEEDED_ONT_1')])
assert(!$datastore.deleted_log.include?([:ontology, 'SEEDED_ONT_1']), "Caller-supplied unowned SEEDED_ONT_1 was NOT deleted")
assert($datastore.ontologies.key?('SEEDED_ONT_1'), "Seeded ontology intact")

# 5f: Attempt caller-supplied deletion of seeded agent
harness.delete_agents([OpenStruct.new(id: 'http://localhost:9393/agents/SEEDED_AGENT_1')])
assert(!$datastore.deleted_log.include?([:agent, 'http://localhost:9393/agents/SEEDED_AGENT_1']), "Caller-supplied unowned agent was NOT deleted")
assert($datastore.agents.key?('http://localhost:9393/agents/SEEDED_AGENT_1'), "Seeded agent intact")

# -----------------------------------------------------------------------------
puts "\n=== Step 6: Representative Direct / UI-Created Flow Registration ==="
# -----------------------------------------------------------------------------
$datastore.seed_defaults!
$datastore.deleted_log.clear
TestResourceOwnership.reset!

# Simulating Capybara UI submission creating an ontology directly
$datastore.ontologies['UI_ONT_SUBMITTED'] = { acronym: 'UI_ONT_SUBMITTED', name: 'UI Ontology' }
harness.register_owned_ontology('UI_ONT_SUBMITTED')

# Simulating Capybara UI agent modal creating an agent
agent_uri = 'http://localhost:9393/agents/9999'
$datastore.agents[agent_uri] = { id: agent_uri, name: 'UI Agent Person' }
harness.register_owned_agent(agent_uri)

# Simulating controller POST creating a registered user
$datastore.users['ui_registered_user'] = { username: 'ui_registered_user', password: 'password' }
harness.register_owned_user('ui_registered_user')

assert(TestResourceOwnership.owned?(:ontology, 'UI_ONT_SUBMITTED'), "UI_ONT_SUBMITTED registered as owned")
assert(TestResourceOwnership.owned?(:agent, agent_uri), "UI agent registered as owned")
assert(TestResourceOwnership.owned?(:user, 'ui_registered_user'), "ui_registered_user registered as owned")

# Run teardown
harness.cleanup_owned_resources!

assert($datastore.deleted_log.include?([:ontology, 'UI_ONT_SUBMITTED']), "UI_ONT_SUBMITTED cleaned up on teardown")
assert($datastore.deleted_log.include?([:agent, agent_uri]), "UI agent cleaned up on teardown")
assert($datastore.deleted_log.include?([:user, 'ui_registered_user']), "ui_registered_user cleaned up on teardown")
assert($datastore.ontologies.key?('SEEDED_ONT_1'), "SEEDED_ONT_1 preserved after UI cleanup")

# -----------------------------------------------------------------------------
puts "\n=== Step 7: In-Memory Namespace Helper & Admin Protection ==="
# -----------------------------------------------------------------------------
namespaced_ont = TestResourceOwnership.namespaced('MY_ONT')
assert(namespaced_ont.start_with?('MY_ONT_t'), "namespaced produces unique suffixed identifier")

namespaced_admin = TestResourceOwnership.namespaced('admin')
assert(namespaced_admin == 'admin', "namespaced('admin') never mutates admin username")

admin_reg = TestResourceOwnership.register(:user, 'admin')
assert(admin_reg.nil?, "register(:user, 'admin') returns nil")
assert(!TestResourceOwnership.owned?(:user, 'admin'), "TestResourceOwnership.owned?(:user, 'admin') is strictly false")

# -----------------------------------------------------------------------------
puts "\n=== Step 8: Canonical Agent Identity and Hash-Safe Deletion Regressions ==="
# -----------------------------------------------------------------------------
$datastore.seed_defaults!
$datastore.deleted_log.clear
TestResourceOwnership.reset!

# 8a: Distinct unowned agent with same display name (Finding 1 / parent counterexample)
owned_agent_id = 'http://localhost:9393/agents/owned-agent-distinct'
owned_agent = OpenStruct.new(id: owned_agent_id, name: 'Shared Agent Name')
harness.register_owned_agent(owned_agent)
assert(TestResourceOwnership.owned?(:agent, owned_agent), "Owned agent object is registered as owned")

seeded_agent_id = 'http://localhost:9393/agents/SEEDED_AGENT_1'
seeded_same_name_obj = OpenStruct.new(id: seeded_agent_id, name: 'Shared Agent Name')
assert(!TestResourceOwnership.owned?(:agent, seeded_same_name_obj), "Seeded agent object with same display name is NOT owned")

before_delete_count = $datastore.deleted_log.size
harness.delete_agents([seeded_same_name_obj])
assert($datastore.deleted_log.size == before_delete_count, "Same-name/different-ID seeded agent object dispatched zero DELETE")
assert($datastore.agents.key?(seeded_agent_id), "Seeded agent intact in datastore")

# 8b: Distinct unowned agent Hash with same display name
seeded_same_name_hash = { id: seeded_agent_id, name: 'Shared Agent Name' }
assert(!TestResourceOwnership.owned?(:agent, seeded_same_name_hash), "Seeded agent Hash with same display name is NOT owned")
harness.delete_agents([seeded_same_name_hash])
assert($datastore.deleted_log.size == before_delete_count, "Same-name/different-ID seeded agent Hash dispatched zero DELETE")

# 8c: Unowned Hash with name only (no ID)
name_only_hash = { name: 'Shared Agent Name' }
assert(!TestResourceOwnership.owned?(:agent, name_only_hash), "Agent Hash with name only and no ID is NOT owned")
assert(TestResourceOwnership.register(:agent, name_only_hash).nil?, "register(:agent, name_only_hash) returns nil")
harness.delete_agents([name_only_hash])
assert($datastore.deleted_log.size == before_delete_count, "Name-only Hash dispatched zero DELETE")

# 8d: Distinct agent with conflicting basename
conflicting_agent = OpenStruct.new(id: 'http://other.org/agents/owned-agent-distinct', name: 'Shared Agent Name')
assert(!TestResourceOwnership.owned?(:agent, conflicting_agent), "Agent with conflicting basename on distinct URI is NOT owned")
harness.delete_agents([conflicting_agent])
assert($datastore.deleted_log.size == before_delete_count, "Conflicting basename agent dispatched zero DELETE")

# 8e: Successful owned-ID cleanup for Hash without calling zero-arg Hash#delete (Finding 3)
owned_hash_id = 'http://localhost:9393/agents/owned-hash-agent'
$datastore.agents[owned_hash_id] = { id: owned_hash_id, name: 'Owned Hash Agent' }
owned_hash = { id: owned_hash_id, name: 'Owned Hash Agent' }
harness.register_owned_agent(owned_hash)
assert(TestResourceOwnership.owned?(:agent, owned_hash), "Owned Hash agent registered as owned")

harness.delete_agents([owned_hash])
assert($datastore.deleted_log.include?([:agent, owned_hash_id]), "Owned Hash agent cleanly deleted via client model resolution without zero-arg Hash#delete")
assert(!$datastore.agents.key?(owned_hash_id), "Owned Hash agent removed from datastore")
assert(!TestResourceOwnership.owned?(:agent, owned_hash), "Owned Hash agent unregistered after cleanup")

# 8f: Successful owned-ID cleanup for String identifier
owned_str_id = 'http://localhost:9393/agents/owned-str-agent'
$datastore.agents[owned_str_id] = { id: owned_str_id, name: 'Owned String Agent' }
harness.register_owned_agent(owned_str_id)
assert(TestResourceOwnership.owned?(:agent, owned_str_id), "Owned String agent registered as owned")
harness.delete_agents([owned_str_id])
assert($datastore.deleted_log.include?([:agent, owned_str_id]), "Owned String agent cleanly deleted via client model resolution")
assert(!$datastore.agents.key?(owned_str_id), "Owned String agent removed from datastore")
assert(!TestResourceOwnership.owned?(:agent, owned_str_id), "Owned String agent unregistered after cleanup")

# 8g: Default delete_agents teardown path with registered Hash and Object
owned_hash_id2 = 'http://localhost:9393/agents/owned-hash-agent-default'
$datastore.agents[owned_hash_id2] = { id: owned_hash_id2, name: 'Owned Hash Agent Default' }
harness.register_owned_agent({ 'id' => owned_hash_id2, 'name' => 'Owned Hash Agent Default' })
assert(TestResourceOwnership.owned?(:agent, owned_hash_id2), "Registered Hash with string key owned")

$datastore.agents[owned_agent_id] = { id: owned_agent_id, name: 'Shared Agent Name' }
harness.delete_agents
assert($datastore.deleted_log.include?([:agent, owned_hash_id2]), "Default delete_agents cleaned up registered Hash agent without zero-arg Hash#delete")
assert(!$datastore.agents.key?(owned_hash_id2), "Registered Hash agent removed from datastore")
assert($datastore.deleted_log.include?([:agent, owned_agent_id]), "Default delete_agents cleaned up registered agent object")
assert(!$datastore.agents.key?(owned_agent_id), "Registered agent object removed from datastore")
assert(TestResourceOwnership.empty?(:agent), "Agent registry empty after default cleanup")

# -----------------------------------------------------------------------------
puts "\n=== Step 9: Failed-Cleanup Retention and Deletion-Result Contract Regressions ==="
# -----------------------------------------------------------------------------
$datastore.seed_defaults!
$datastore.deleted_log.clear
TestResourceOwnership.reset!
MockFaradayConnection.delete_error = nil
MockFaradayConnection.delete_status = nil

# 9a: Rejected DELETE (HTTP 403) retained in ownership and reported
reject_cat = { acronym: 'REJECT_CAT', name: 'Reject Cat', delete_status: 403 }
$datastore.categories['REJECT_CAT'] = reject_cat
harness.register_owned_resource(:category, 'REJECT_CAT')
assert(TestResourceOwnership.owned?(:category, 'REJECT_CAT'), "REJECT_CAT registered as owned")

failures = harness.delete_categories
assert(failures.size == 1, "delete_categories reported 1 failure for HTTP 403 (got: #{failures.size})")
assert(failures.first[:status] == 403, "Reported failure status is 403")
assert(failures.first[:type] == :category, "Reported failure type is :category")
assert(TestResourceOwnership.owned?(:category, 'REJECT_CAT'), "Rejected category RETAINED in ownership registry after 403 failure")
assert(!$datastore.deleted_log.include?([:category, 'REJECT_CAT']), "No delete logged in datastore for rejected category")
assert(ApplicationTestHelpers.last_cleanup_failures.size == 1, "ApplicationTestHelpers.last_cleanup_failures recorded the failure")

# 9b: Raised DELETE (HTTP >= 500 / StandardError) retained in ownership and reported
$datastore.seed_defaults!
$datastore.deleted_log.clear
TestResourceOwnership.reset!

raise_cat = { acronym: 'RAISE_CAT', name: 'Raise Cat', delete_error: StandardError.new('500 Server Error') }
$datastore.categories['RAISE_CAT'] = raise_cat
harness.register_owned_resource(:category, 'RAISE_CAT')
assert(TestResourceOwnership.owned?(:category, 'RAISE_CAT'), "RAISE_CAT registered as owned")

failures = harness.delete_categories
assert(failures.size == 1, "delete_categories reported 1 failure for raised StandardError")
assert(failures.first[:error].is_a?(StandardError), "Reported failure contains raised StandardError")
assert(failures.first[:error].message.include?('500'), "Reported failure error message contains '500'")
assert(TestResourceOwnership.owned?(:category, 'RAISE_CAT'), "Raised category RETAINED in ownership registry after exception")
assert(!$datastore.deleted_log.include?([:category, 'RAISE_CAT']), "No delete logged in datastore for raised category")

# 9c: Acknowledged DELETE (HTTP 204) and confirmed absence removed from ownership
$datastore.seed_defaults!
$datastore.deleted_log.clear
TestResourceOwnership.reset!

ack_cat = { acronym: 'ACK_CAT', name: 'Ack Cat' }
$datastore.categories['ACK_CAT'] = ack_cat
harness.register_owned_resource(:category, 'ACK_CAT')
harness.register_owned_resource(:category, 'ABSENT_CAT') # Not in datastore -> confirmed absence

assert(TestResourceOwnership.owned?(:category, 'ACK_CAT'), "ACK_CAT registered as owned")
assert(TestResourceOwnership.owned?(:category, 'ABSENT_CAT'), "ABSENT_CAT registered as owned")

failures = harness.delete_categories
assert(failures.empty?, "delete_categories reported 0 failures for acknowledged delete and confirmed absence")
assert(!TestResourceOwnership.owned?(:category, 'ACK_CAT'), "Acknowledged ACK_CAT unregistered from ownership")
assert(!TestResourceOwnership.owned?(:category, 'ABSENT_CAT'), "Confirmed absent ABSENT_CAT unregistered from ownership")
assert($datastore.deleted_log.include?([:category, 'ACK_CAT']), "ACK_CAT deleted from datastore")
assert(!$datastore.categories.key?('ACK_CAT'), "ACK_CAT removed from datastore")
assert(TestResourceOwnership.empty?(:category), "Category ownership registry empty after full successful cleanup")

# 9d: Remaining owned resources cleaned after one failure (independent loop execution)
$datastore.seed_defaults!
$datastore.deleted_log.clear
TestResourceOwnership.reset!

$datastore.categories['FAIL_CAT_1'] = { acronym: 'FAIL_CAT_1', name: 'Fail Cat 1', delete_status: 403 }
$datastore.categories['SUCCESS_CAT_2'] = { acronym: 'SUCCESS_CAT_2', name: 'Success Cat 2' }
harness.register_owned_resource(:category, 'FAIL_CAT_1')
harness.register_owned_resource(:category, 'SUCCESS_CAT_2')

failures = harness.delete_categories
assert(failures.size == 1, "delete_categories reported exactly 1 failure")
assert(failures.first[:target] == 'FAIL_CAT_1', "Reported failure is FAIL_CAT_1")
assert(TestResourceOwnership.owned?(:category, 'FAIL_CAT_1'), "FAIL_CAT_1 retained in ownership after failure")
assert(!TestResourceOwnership.owned?(:category, 'SUCCESS_CAT_2'), "SUCCESS_CAT_2 cleanly unregistered after cleanup")
assert($datastore.deleted_log.include?([:category, 'SUCCESS_CAT_2']), "SUCCESS_CAT_2 was cleanly deleted from datastore despite prior failure")
assert(!$datastore.categories.key?('SUCCESS_CAT_2'), "SUCCESS_CAT_2 absent from datastore")
assert($datastore.categories.key?('FAIL_CAT_1'), "FAIL_CAT_1 still present in datastore")

# 9e: User cleanup handles rejected DELETE and raised errors, retaining ownership
$datastore.seed_defaults!
$datastore.deleted_log.clear
TestResourceOwnership.reset!

$datastore.users['user_403'] = { username: 'user_403', apikey: 'token_403', password: 'password', role: [] }
$datastore.users['user_ack'] = { username: 'user_ack', apikey: 'token_ack', password: 'password', role: [] }
harness.register_owned_resource(:user, 'user_403')
harness.register_owned_resource(:user, 'user_ack')

MockFaradayConnection.delete_status = 403
failures = harness.delete_user('user_403')
assert(!failures.nil? && failures[:status] == 403, "delete_user('user_403') reported 403 failure")
assert(TestResourceOwnership.owned?(:user, 'user_403'), "user_403 RETAINED in ownership after 403 failure")
assert($datastore.users.key?('user_403'), "user_403 intact in datastore")

MockFaradayConnection.delete_status = nil
MockFaradayConnection.delete_error = StandardError.new('500 Faraday Error')
failures_raise = harness.delete_user('user_403')
assert(!failures_raise.nil? && failures_raise[:error].message.include?('500'), "delete_user('user_403') reported 500 error")
assert(TestResourceOwnership.owned?(:user, 'user_403'), "user_403 RETAINED in ownership after 500 error")

MockFaradayConnection.delete_error = nil
del_ack_res = harness.delete_user('user_ack')
assert(!del_ack_res.nil? && del_ack_res[:success], "delete_user('user_ack') succeeded")
assert(!TestResourceOwnership.owned?(:user, 'user_ack'), "user_ack unregistered after successful deletion")
assert(!$datastore.users.key?('user_ack'), "user_ack deleted from datastore")
assert($datastore.deleted_log.include?([:user, 'user_ack']), "user_ack delete logged in datastore")

# 9f: Agent cleanup handles rejected and raised DELETE
$datastore.seed_defaults!
$datastore.deleted_log.clear
TestResourceOwnership.reset!

fail_agent_id = 'http://localhost:9393/agents/owned_agent_fail'
ack_agent_id = 'http://localhost:9393/agents/owned_agent_ack'
$datastore.agents[fail_agent_id] = { id: fail_agent_id, name: 'Fail Agent', delete_status: 400 }
$datastore.agents[ack_agent_id] = { id: ack_agent_id, name: 'Ack Agent' }

harness.register_owned_resource(:agent, fail_agent_id)
harness.register_owned_resource(:agent, ack_agent_id)

failures = harness.delete_agents
assert(failures.size == 1, "delete_agents reported 1 failure for agent with 400 status")
assert(TestResourceOwnership.owned?(:agent, fail_agent_id), "fail_agent_id RETAINED in ownership after 400 status")
assert(!TestResourceOwnership.owned?(:agent, ack_agent_id), "ack_agent_id cleanly unregistered after cleanup")
assert($datastore.deleted_log.include?([:agent, ack_agent_id]), "ack_agent_id was cleanly deleted from datastore")
assert(!$datastore.agents.key?(ack_agent_id), "ack_agent_id absent from datastore")
assert($datastore.agents.key?(fail_agent_id), "fail_agent_id still in datastore")

# 9g: Group and Ontology cleanup handle rejected and raised DELETE
$datastore.seed_defaults!
$datastore.deleted_log.clear
TestResourceOwnership.reset!

$datastore.groups['FAIL_GRP'] = { acronym: 'FAIL_GRP', name: 'Fail Group', delete_status: 403 }
$datastore.groups['ACK_GRP'] = { acronym: 'ACK_GRP', name: 'Ack Group' }
harness.register_owned_resource(:group, 'FAIL_GRP')
harness.register_owned_resource(:group, 'ACK_GRP')

grp_failures = harness.delete_groups
assert(grp_failures.size == 1, "delete_groups reported 1 failure for 403")
assert(TestResourceOwnership.owned?(:group, 'FAIL_GRP'), "FAIL_GRP retained in ownership")
assert(!TestResourceOwnership.owned?(:group, 'ACK_GRP'), "ACK_GRP unregistered")
assert($datastore.deleted_log.include?([:group, 'ACK_GRP']), "ACK_GRP deleted from datastore")

$datastore.ontologies['FAIL_ONT'] = { acronym: 'FAIL_ONT', name: 'Fail Ont', delete_error: StandardError.new('Ontology delete 500') }
$datastore.ontologies['ACK_ONT'] = { acronym: 'ACK_ONT', name: 'Ack Ont' }
harness.register_owned_resource(:ontology, 'FAIL_ONT')
harness.register_owned_resource(:ontology, 'ACK_ONT')

ont_failures = harness.delete_ontologies
assert(ont_failures.size == 1, "delete_ontologies reported 1 failure for 500")
assert(TestResourceOwnership.owned?(:ontology, 'FAIL_ONT'), "FAIL_ONT retained in ownership")
assert(!TestResourceOwnership.owned?(:ontology, 'ACK_ONT'), "ACK_ONT unregistered")
assert($datastore.deleted_log.include?([:ontology, 'ACK_ONT']), "ACK_ONT deleted from datastore")

# 9h: Full cleanup_owned_resources! attempts all types and reports multi-type failures
$datastore.seed_defaults!
$datastore.deleted_log.clear
TestResourceOwnership.reset!

$datastore.categories['MULTI_FAIL_CAT'] = { acronym: 'MULTI_FAIL_CAT', name: 'Multi Fail Cat', delete_status: 403 }
$datastore.groups['MULTI_ACK_GRP'] = { acronym: 'MULTI_ACK_GRP', name: 'Multi Ack Grp' }
$datastore.agents['http://localhost:9393/agents/MULTI_FAIL_AGENT'] = {
  id: 'http://localhost:9393/agents/MULTI_FAIL_AGENT',
  name: 'Multi Fail Agent',
  delete_error: StandardError.new('Agent 500')
}
$datastore.users['multi_ack_user'] = { username: 'multi_ack_user', apikey: 'token_m', password: 'password', role: [] }

harness.register_owned_resource(:category, 'MULTI_FAIL_CAT')
harness.register_owned_resource(:group, 'MULTI_ACK_GRP')
harness.register_owned_resource(:agent, 'http://localhost:9393/agents/MULTI_FAIL_AGENT')
harness.register_owned_resource(:user, 'multi_ack_user')

all_cleanup_failures = harness.cleanup_owned_resources!
assert(all_cleanup_failures.size == 2, "cleanup_owned_resources! reported 2 failures across resource types (got: #{all_cleanup_failures.size})")
assert(TestResourceOwnership.owned?(:category, 'MULTI_FAIL_CAT'), "MULTI_FAIL_CAT retained in ownership")
assert(TestResourceOwnership.owned?(:agent, 'http://localhost:9393/agents/MULTI_FAIL_AGENT'), "MULTI_FAIL_AGENT retained in ownership")
assert(!TestResourceOwnership.owned?(:group, 'MULTI_ACK_GRP'), "MULTI_ACK_GRP cleaned and unregistered")
assert(!TestResourceOwnership.owned?(:user, 'multi_ack_user'), "multi_ack_user cleaned and unregistered")
assert($datastore.deleted_log.include?([:group, 'MULTI_ACK_GRP']), "MULTI_ACK_GRP deleted from datastore")
assert($datastore.deleted_log.include?([:user, 'multi_ack_user']), "multi_ack_user deleted from datastore")
assert(ApplicationTestHelpers.last_cleanup_failures.size == 2, "ApplicationTestHelpers.last_cleanup_failures contains both failures")

# 9i: Aliases removed together on acknowledged deletion, retained together on failure
$datastore.seed_defaults!
$datastore.deleted_log.clear
TestResourceOwnership.reset!

alias_ont_id = 'http://localhost:9393/ontologies/ALIAS_ONT'
alias_ont = OpenStruct.new(acronym: 'ALIAS_ONT', id: alias_ont_id, name: 'Alias Ont')
harness.register_owned_ontology(alias_ont)
assert(TestResourceOwnership.owned?(:ontology, 'ALIAS_ONT'), "ALIAS_ONT owned by acronym")
assert(TestResourceOwnership.owned?(:ontology, alias_ont_id), "ALIAS_ONT owned by URI ID")
assert(TestResourceOwnership.owned?(:ontology, alias_ont), "ALIAS_ONT owned by object")

# First: failure retains all aliases
$datastore.ontologies['ALIAS_ONT'] = { acronym: 'ALIAS_ONT', id: alias_ont_id, delete_status: 403 }
alias_fail = harness.delete_ontologies(['ALIAS_ONT'])
assert(alias_fail.size == 1, "Failed delete_ontologies reported 1 failure")
assert(TestResourceOwnership.owned?(:ontology, 'ALIAS_ONT'), "Acronym alias retained on failure")
assert(TestResourceOwnership.owned?(:ontology, alias_ont_id), "URI ID alias retained on failure")
assert(TestResourceOwnership.owned?(:ontology, alias_ont), "Object alias retained on failure")

# Second: success removes all aliases together
$datastore.ontologies['ALIAS_ONT'][:delete_status] = nil
alias_success = harness.delete_ontologies(['ALIAS_ONT'])
assert(alias_success.empty?, "Successful delete_ontologies reported 0 failures")
assert(!TestResourceOwnership.owned?(:ontology, 'ALIAS_ONT'), "Acronym alias unregistered on success")
assert(!TestResourceOwnership.owned?(:ontology, alias_ont_id), "URI ID alias unregistered on success")
assert(!TestResourceOwnership.owned?(:ontology, alias_ont), "Object alias unregistered on success")
assert(TestResourceOwnership.empty?(:ontology), "Ontology ownership completely empty (all aliases removed together)")

# 9j: R1 Regression - Two cleanup calls after lost response (timeout)
# Assert fresh read before repeat; failed reconcile causes no second DELETE; successful reconcile deletes and unregisters
$datastore.seed_defaults!
$datastore.deleted_log.clear
$datastore.read_log.clear
$datastore.delete_calls.clear
TestResourceOwnership.reset!

loss_cat_acronym = 'LOSS_CAT'
loss_cat_data = {
  acronym: loss_cat_acronym,
  name: 'Loss Cat',
  delete_error: StandardError.new('Faraday::TimeoutError: execution expired')
}
$datastore.categories[loss_cat_acronym] = loss_cat_data
cat_loss_model = LinkedData::Client::Models::Category.new(values: loss_cat_data)
harness.register_owned_resource(:category, cat_loss_model)
assert(TestResourceOwnership.owned?(:category, loss_cat_acronym), "LOSS_CAT registered as owned")

# First cleanup call: response lost during DELETE
failures1 = harness.delete_categories
assert(failures1.size == 1, "delete_categories reported 1 failure for lost response")
assert(TestResourceOwnership.owned?(:category, loss_cat_acronym), "LOSS_CAT retained in ownership after lost response")
assert(TestResourceOwnership.outcome_unknown?(:category, loss_cat_acronym), "LOSS_CAT marked as outcome-unknown after lost response")
assert($datastore.delete_calls.count { |c| c == [:category, loss_cat_acronym] } == 1, "Exactly 1 DELETE call attempted in first cleanup")

# Second cleanup call - subcase: reconciliation fails
$datastore.categories[loss_cat_acronym][:find_error] = StandardError.new('500 Reconcile GET Error')
failures2 = harness.delete_categories
assert(failures2.size == 1, "delete_categories reported failure when reconciliation read failed")
assert(TestResourceOwnership.owned?(:category, loss_cat_acronym), "LOSS_CAT retained in ownership when reconciliation fails")
assert(TestResourceOwnership.outcome_unknown?(:category, loss_cat_acronym), "LOSS_CAT still outcome-unknown after failed reconciliation")
# CRITICAL R1 ASSERTION: failed reconcile causes NO second DELETE!
assert($datastore.delete_calls.count { |c| c == [:category, loss_cat_acronym] } == 1,
       "failed reconcile causes no second DELETE (delete call count remained 1)")
assert($datastore.read_log.include?([:category_find, loss_cat_acronym, { invalidate_cache: true }]), "Fresh read reconciliation attempted with invalidate_cache: true before repeat DELETE")

# Third cleanup call - subcase: reconciliation succeeds and confirms presence; repeat DELETE authorized
$datastore.categories[loss_cat_acronym][:find_error] = nil
$datastore.categories[loss_cat_acronym][:delete_error] = nil
failures3 = harness.delete_categories
assert(failures3.empty?, "delete_categories succeeded after successful reconciliation and second DELETE")
assert(!TestResourceOwnership.owned?(:category, loss_cat_acronym), "LOSS_CAT unregistered after successful deletion")
assert(!TestResourceOwnership.outcome_unknown?(:category, loss_cat_acronym), "LOSS_CAT outcome-unknown cleared after successful deletion")
assert($datastore.deleted_log.include?([:category, loss_cat_acronym]), "LOSS_CAT deleted from datastore")
assert($datastore.delete_calls.count { |c| c == [:category, loss_cat_acronym] } == 2, "Second DELETE call dispatched only after successful reconciliation")

# 9k: R1 Regression - Two cleanup calls after DELETE 204 / cache-refresh failure
# Double executes server delete (204) then raises SDK cache-refresh exception; fresh read confirms absence without second DELETE
$datastore.seed_defaults!
$datastore.deleted_log.clear
$datastore.read_log.clear
$datastore.delete_calls.clear
TestResourceOwnership.reset!

cache_cat_acronym = 'CACHE_CAT'
class CacheFailCategory < LinkedData::Client::Models::Category
  attr_accessor :delete_invocations
  def initialize(values: {})
    super
    @delete_invocations = 0
  end

  def delete
    @delete_invocations += 1
    $datastore.delete_calls << [:category, @acronym]
    # Simulate server processing DELETE 204 successfully
    $datastore.deleted_log << [:category, @acronym]
    $datastore.categories.delete(@acronym)
    # Simulate SDK cache-refresh post-DELETE raising base Exception from GET >= 500
    raise Exception.new("Problem retrieving:\n/categories/#{@acronym}\n500 Internal Server Error")
  end
end

cache_cat = CacheFailCategory.new(values: { acronym: cache_cat_acronym, name: 'Cache Cat' })
$datastore.categories[cache_cat_acronym] = cache_cat.to_h
harness.register_owned_resource(:category, cache_cat)
assert(TestResourceOwnership.owned?(:category, cache_cat_acronym), "CACHE_CAT registered as owned")

# First cleanup call: DELETE succeeds on server, but cache refresh raises SDK retrieval Exception
failures1 = harness.delete_categories
assert(failures1.size == 1, "delete_categories reported 1 failure for SDK cache-refresh exception")
assert(failures1.first[:error].class == Exception, "Caught SDK base Exception")
assert(failures1.first[:error].message.include?('Problem retrieving:'), "Exception is SDK retrieval exception")
assert(TestResourceOwnership.owned?(:category, cache_cat_acronym), "CACHE_CAT retained in ownership after cache-refresh failure")
assert(TestResourceOwnership.outcome_unknown?(:category, cache_cat_acronym), "CACHE_CAT marked as outcome-unknown")
assert(cache_cat.delete_invocations == 1, "Category#delete called exactly once during first cleanup")

# Second cleanup call: fresh read confirms absence; unregisters without second DELETE
$datastore.read_log.clear
failures2 = harness.delete_categories
assert(failures2.empty?, "delete_categories reported 0 failures on second cleanup")
assert($datastore.read_log.include?([:category_find, cache_cat_acronym, { invalidate_cache: true }]), "Fresh read reconciliation attempted with invalidate_cache: true before repeat")
# CRITICAL R1 ASSERTION: confirmed absence unregisters WITHOUT second DELETE!
assert(cache_cat.delete_invocations == 1, "NO second DELETE was dispatched (invocations stayed 1)")
assert(!TestResourceOwnership.owned?(:category, cache_cat_acronym), "CACHE_CAT unregistered after confirmed absence")
assert(!TestResourceOwnership.outcome_unknown?(:category, cache_cat_acronym), "CACHE_CAT outcome-unknown cleared")

# 9l: R2 Regression - Mixed parent success/failure in aggregate cleanup
# ACK child registered FIRST, FAIL/unresolved child SECOND, both canonical full URIs .../submissions/1
# Rejected parent (403) and FAIL child retained; ACK parent (204) and ACK child retired; unresolved child retained
$datastore.seed_defaults!
$datastore.deleted_log.clear
$datastore.read_log.clear
$datastore.delete_calls.clear
TestResourceOwnership.reset!

# 1. Acknowledged ontology O_ACK (status 204) and its submission S_ACK registered FIRST
o_ack_acronym = 'O_ACK'
$datastore.ontologies[o_ack_acronym] = { acronym: o_ack_acronym, name: 'O Ack' }
s_ack_id = "http://localhost:9393/ontologies/#{o_ack_acronym}/submissions/1"
s_ack = LinkedData::Client::Models::OntologySubmission.new(values: {
  id: s_ack_id,
  ontology: o_ack_acronym,
  URI: s_ack_id
})
harness.register_owned_resource(:ontology, o_ack_acronym)
harness.register_owned_resource(:submission, s_ack)

# 2. Rejected ontology O_FAIL (status 403) and its submission S_FAIL registered SECOND
o_fail_acronym = 'O_FAIL'
$datastore.ontologies[o_fail_acronym] = { acronym: o_fail_acronym, name: 'O Fail', delete_status: 403 }
s_fail_id = "http://localhost:9393/ontologies/#{o_fail_acronym}/submissions/1"
s_fail = LinkedData::Client::Models::OntologySubmission.new(values: {
  id: s_fail_id,
  ontology: o_fail_acronym,
  URI: s_fail_id
})
harness.register_owned_resource(:ontology, o_fail_acronym)
harness.register_owned_resource(:submission, s_fail)

# 3. Unresolved submission with unowned parent registered SECOND (canonical .../submissions/1)
s_unres_id = "http://localhost:9393/ontologies/SEEDED_ONT_1/submissions/1"
s_unresolved = LinkedData::Client::Models::OntologySubmission.new(values: {
  id: s_unres_id,
  ontology: 'SEEDED_ONT_1',
  URI: s_unres_id
})
harness.register_owned_resource(:submission, s_unresolved)

# 4. Submission linked to existing unowned ontology via full URI
s_uri_parent_id = "http://localhost:9393/ontologies/SEEDED_ONT_2/submissions/1"
s_uri_parent = LinkedData::Client::Models::OntologySubmission.new(values: {
  id: s_uri_parent_id,
  ontology: 'http://localhost:9393/ontologies/SEEDED_ONT_2',
  URI: s_uri_parent_id
})
harness.register_owned_resource(:submission, s_uri_parent)

# 5. Another owned resource with aliases (Category with acronym & URI)
alias_cat_uri = 'http://localhost:9393/categories/ALIAS_CAT'
alias_cat = OpenStruct.new(acronym: 'ALIAS_CAT', id: alias_cat_uri, name: 'Alias Cat')
$datastore.categories['ALIAS_CAT'] = { acronym: 'ALIAS_CAT', id: alias_cat_uri, name: 'Alias Cat' }
harness.register_owned_resource(:category, alias_cat)

assert(TestResourceOwnership.owned?(:ontology, o_ack_acronym), "O_ACK registered as owned")
assert(TestResourceOwnership.owned?(:submission, s_ack), "S_ACK registered as owned")
assert(TestResourceOwnership.owned?(:ontology, o_fail_acronym), "O_FAIL registered as owned")
assert(TestResourceOwnership.owned?(:submission, s_fail), "S_FAIL registered as owned")
assert(TestResourceOwnership.owned?(:submission, s_unresolved), "S_UNRESOLVED registered as owned")
assert(TestResourceOwnership.owned?(:submission, s_uri_parent), "S_URI_PARENT registered as owned")
assert(TestResourceOwnership.owned?(:category, 'ALIAS_CAT'), "ALIAS_CAT registered as owned")
assert(TestResourceOwnership.owned?(:category, alias_cat_uri), "ALIAS_CAT URI recognized as owned via alias")

# Pre-cleanup: terminal '1' is not an alias for submission
assert(!TestResourceOwnership.owned?(:submission, '1'), "Pre-cleanup: '1' is not owned")
assert(!TestResourceOwnership.owned?(:submission, { id: '1' }), "Pre-cleanup: Hash {id: '1'} is not owned")
assert(!TestResourceOwnership.owned?(:submission, OpenStruct.new(id: '1')), "Pre-cleanup: Model id '1' is not owned")

# Execute aggregate cleanup
cleanup_res = harness.cleanup_owned_resources!

# Verify reporting
assert(cleanup_res.size == 1, "cleanup_owned_resources! reported exactly 1 failure for rejected ontology (got: #{cleanup_res.size})")
assert(cleanup_res.first[:status] == 403, "Reported failure status is 403")
assert(cleanup_res.first[:type] == :ontology, "Reported failure type is :ontology")

# CRITICAL R2 ASSERTION: rejected parent O_FAIL and its child submission S_FAIL BOTH remain owned
assert(TestResourceOwnership.owned?(:ontology, o_fail_acronym), "O_FAIL RETAINED in ownership registry after 403 failure")
assert(TestResourceOwnership.owned?(:submission, s_fail), "S_FAIL RETAINED in ownership registry when parent ontology cleanup failed")
assert($datastore.ontologies.key?(o_fail_acronym), "O_FAIL intact in datastore")

# Successful parent O_ACK and child S_ACK both unregistered
assert(!TestResourceOwnership.owned?(:ontology, o_ack_acronym), "O_ACK unregistered after successful deletion")
assert(!TestResourceOwnership.owned?(:submission, s_ack), "S_ACK unregistered after corresponding parent deletion confirmed")
assert(!$datastore.ontologies.key?(o_ack_acronym), "O_ACK deleted from datastore")

# Unresolved submission with unowned parent retained
assert(TestResourceOwnership.owned?(:submission, s_unresolved), "S_UNRESOLVED retained in ownership registry (unresolved parent)")
# Unowned existing parent URI is not false absence; child submission is retained
assert(TestResourceOwnership.owned?(:submission, s_uri_parent), "S_URI_PARENT retained in ownership registry (unowned existing parent URI isn't falseabsence)")

# Other owned resources and all aliases cleanly removed
assert(!TestResourceOwnership.owned?(:category, 'ALIAS_CAT'), "ALIAS_CAT acronym unregistered")
assert(!TestResourceOwnership.owned?(:category, alias_cat_uri), "ALIAS_CAT URI unregistered")
assert(!$datastore.categories.key?('ALIAS_CAT'), "ALIAS_CAT deleted from datastore")

# Assert String/Hash/model queries do not alias '1' or cross-parent
assert(!TestResourceOwnership.owned?(:submission, '1'), "Post-cleanup: '1' String query is not owned")
assert(!TestResourceOwnership.owned?(:submission, { id: '1' }), "Post-cleanup: Hash { id: '1' } is not owned")
assert(!TestResourceOwnership.owned?(:submission, { 'id' => '1' }), "Post-cleanup: Hash { 'id' => '1' } is not owned")
assert(!TestResourceOwnership.owned?(:submission, OpenStruct.new(id: '1')), "Post-cleanup: Model with id '1' is not owned")

# Retired child S_ACK not owned via String, Hash, or model query
assert(!TestResourceOwnership.owned?(:submission, s_ack_id), "S_ACK full URI String query is not owned")
assert(!TestResourceOwnership.owned?(:submission, { id: s_ack_id }), "S_ACK Hash query is not owned")
assert(!TestResourceOwnership.owned?(:submission, OpenStruct.new(id: s_ack_id)), "S_ACK model query is not owned")

# Retained child S_FAIL is owned via String, Hash, and model query
assert(TestResourceOwnership.owned?(:submission, s_fail_id), "S_FAIL full URI String query is owned")
assert(TestResourceOwnership.owned?(:submission, { id: s_fail_id }), "S_FAIL Hash query is owned")
assert(TestResourceOwnership.owned?(:submission, OpenStruct.new(id: s_fail_id)), "S_FAIL model query is owned")

# Retained child S_UNRESOLVED is owned via String, Hash, and model query
assert(TestResourceOwnership.owned?(:submission, s_unres_id), "S_UNRESOLVED full URI String query is owned")
assert(TestResourceOwnership.owned?(:submission, { id: s_unres_id }), "S_UNRESOLVED Hash query is owned")
assert(TestResourceOwnership.owned?(:submission, OpenStruct.new(id: s_unres_id)), "S_UNRESOLVED model query is owned")

# Seeded resources survive
assert($datastore.categories.key?('SEEDED_CAT_1'), "SEEDED_CAT_1 survived aggregate cleanup")
assert($datastore.groups.key?('SEEDED_GRP_1'), "SEEDED_GRP_1 survived aggregate cleanup")
assert($datastore.ontologies.key?('SEEDED_ONT_1'), "SEEDED_ONT_1 survived aggregate cleanup")
assert($datastore.users.key?('admin'), "admin user survived aggregate cleanup")

# 9m: Targeted SDK retrieval exception handling vs fatal exceptions
$datastore.seed_defaults!
$datastore.deleted_log.clear
TestResourceOwnership.reset!

# SDK base Exception with "Problem retrieving:..." is caught and independent attempt continues
$datastore.categories['SDK_EXC_CAT'] = {
  acronym: 'SDK_EXC_CAT',
  name: 'SDK Exc Cat',
  delete_error: Exception.new("Problem retrieving:\n/categories/SDK_EXC_CAT\n500 Internal Server Error")
}
$datastore.categories['INDEP_CAT'] = { acronym: 'INDEP_CAT', name: 'Indep Cat' }
harness.register_owned_resource(:category, 'SDK_EXC_CAT')
harness.register_owned_resource(:category, 'INDEP_CAT')

failures = harness.delete_categories
assert(failures.size == 1, "delete_categories reported 1 failure for SDK Exception")
assert(TestResourceOwnership.owned?(:category, 'SDK_EXC_CAT'), "SDK_EXC_CAT retained in ownership")
assert(!TestResourceOwnership.owned?(:category, 'INDEP_CAT'), "Independent INDEP_CAT cleanly unregistered despite SDK Exception")
assert($datastore.deleted_log.include?([:category, 'INDEP_CAT']), "INDEP_CAT deleted from datastore")

# Arbitrary fatal exception (Interrupt / SignalException / SystemExit) is NEVER swallowed
$datastore.categories['FATAL_CAT'] = {
  acronym: 'FATAL_CAT',
  name: 'Fatal Cat',
  delete_error: Interrupt.new
}
harness.register_owned_resource(:category, 'FATAL_CAT')
fatal_raised = false
begin
  harness.delete_categories(['FATAL_CAT'])
rescue Interrupt
  fatal_raised = true
end
assert(fatal_raised, "Interrupt is NEVER swallowed by cleanup helpers")

# Fatal Interrupt and SystemExit propagate from aggregate cleanup_owned_resources!
$datastore.seed_defaults!
$datastore.deleted_log.clear
TestResourceOwnership.reset!
$datastore.ontologies['FATAL_ONT'] = {
  acronym: 'FATAL_ONT',
  name: 'Fatal Ont',
  delete_error: Interrupt.new
}
harness.register_owned_resource(:ontology, 'FATAL_ONT')
fatal_agg_raised = false
begin
  harness.cleanup_owned_resources!
rescue Interrupt
  fatal_agg_raised = true
end
assert(fatal_agg_raised, "Interrupt propagates cleanly from aggregate cleanup_owned_resources!")

$datastore.seed_defaults!
$datastore.deleted_log.clear
TestResourceOwnership.reset!
$datastore.ontologies['EXIT_ONT'] = {
  acronym: 'EXIT_ONT',
  name: 'Exit Ont',
  delete_error: SystemExit.new(1)
}
harness.register_owned_resource(:ontology, 'EXIT_ONT')
exit_agg_raised = false
begin
  harness.cleanup_owned_resources!
rescue SystemExit
  exit_agg_raised = true
end
assert(exit_agg_raised, "SystemExit propagates cleanly from aggregate cleanup_owned_resources!")

# 9n: Explicit 403 is a known rejection, not an outcome-unknown send
$datastore.seed_defaults!
$datastore.deleted_log.clear
$datastore.read_log.clear
$datastore.delete_calls.clear
TestResourceOwnership.reset!

cat_403_data = { acronym: 'KNOWN_403_CAT', name: 'Known 403 Cat', delete_status: 403 }
$datastore.categories['KNOWN_403_CAT'] = cat_403_data
cat_403_model = LinkedData::Client::Models::Category.new(values: cat_403_data)
harness.register_owned_resource(:category, cat_403_model)

failures1 = harness.delete_categories
assert(failures1.size == 1, "First delete_categories reported 403 failure")
assert(TestResourceOwnership.owned?(:category, 'KNOWN_403_CAT'), "KNOWN_403_CAT retained in ownership")
assert(!TestResourceOwnership.outcome_unknown?(:category, 'KNOWN_403_CAT'), "KNOWN_403_CAT is NOT marked outcome-unknown")

$datastore.read_log.clear
failures2 = harness.delete_categories
assert(failures2.size == 1, "Second delete_categories reported 403 failure")
# No reconciliation read was required
assert(!$datastore.read_log.any? { |r| r[0] == :category_find && r[1] == 'KNOWN_403_CAT' }, "No redundant reconciliation read for known 403 rejection")

# 9o: No seeded deletion or pending reset
assert($datastore.categories.key?('SEEDED_CAT_1') && $datastore.categories.key?('SEEDED_CAT_2'), "Seeded categories completely intact in datastore")
assert($datastore.groups.key?('SEEDED_GRP_1') && $datastore.groups.key?('SEEDED_GRP_2'), "Seeded groups completely intact in datastore")
assert($datastore.agents.key?('http://localhost:9393/agents/SEEDED_AGENT_1'), "Seeded agent completely intact in datastore")
assert($datastore.ontologies.key?('SEEDED_ONT_1'), "Seeded ontology completely intact in datastore")
assert($datastore.users.key?('admin') && $datastore.users.key?('SEEDED_USER_1'), "Seeded admin and user completely intact in datastore")

# 9p: R1 Regression - Fresh read returning SDK error object causes NO second DELETE
$datastore.seed_defaults!
$datastore.deleted_log.clear
$datastore.read_log.clear
$datastore.delete_calls.clear
TestResourceOwnership.reset!

err_cat_acronym = 'ERR_OBJ_CAT'
err_cat_data = {
  acronym: err_cat_acronym,
  name: 'Err Obj Cat',
  delete_error: StandardError.new('Faraday::TimeoutError: execution expired')
}
$datastore.categories[err_cat_acronym] = err_cat_data
err_cat_model = LinkedData::Client::Models::Category.new(values: err_cat_data)
harness.register_owned_resource(:category, err_cat_model)
assert(TestResourceOwnership.owned?(:category, err_cat_acronym), "ERR_OBJ_CAT registered as owned")

# First cleanup: response lost (timeout) -> marked outcome-unknown
failures1 = harness.delete_categories
assert(failures1.size == 1, "First cleanup reported 1 failure for lost response")
assert(TestResourceOwnership.owned?(:category, err_cat_acronym), "ERR_OBJ_CAT retained in ownership")
assert(TestResourceOwnership.outcome_unknown?(:category, err_cat_acronym), "ERR_OBJ_CAT marked outcome-unknown")
assert($datastore.delete_calls.count { |c| c == [:category, err_cat_acronym] } == 1, "First cleanup called delete once")

# Set up datastore so fresh read returns an error object (non-nil errors from converted 4xx body below 500)
$datastore.categories[err_cat_acronym][:errors] = ['SDK 4xx Error: Resource Locked or Inconsistent']
$datastore.read_log.clear

failures2 = harness.delete_categories
assert(failures2.size == 1, "Second cleanup reported failure for SDK error response")
assert(failures2.first[:error] == ['SDK 4xx Error: Resource Locked or Inconsistent'], "Reported error matches SDK error object")
assert(TestResourceOwnership.owned?(:category, err_cat_acronym), "ERR_OBJ_CAT RETAINED in ownership on SDK error response")
assert(TestResourceOwnership.outcome_unknown?(:category, err_cat_acronym), "ERR_OBJ_CAT REMAINS outcome-unknown on SDK error response")
assert($datastore.read_log.include?([:category_find, err_cat_acronym, { invalidate_cache: true }]),
       "Fresh read reconciliation passed invalidate_cache: true")
# CRITICAL R1 ASSERTION: Fresh read error object authorizes NO DELETE!
assert($datastore.delete_calls.count { |c| c == [:category, err_cat_acronym] } == 1,
       "CRITICAL: Fresh read error object caused NO second DELETE (count remained 1)")

# 9q: Exact alias behavior across mark, clear, and unregister
TestResourceOwnership.reset!
alias_uri = 'http://localhost:9393/categories/EXACT_ALIAS_CAT'
alias_model = LinkedData::Client::Models::Category.new(values: { acronym: 'EXACT_ALIAS_CAT', id: alias_uri, name: 'Exact Alias Cat' })
harness.register_owned_resource(:category, alias_model)

# 1. Ownership is recognized by any alias
assert(TestResourceOwnership.owned?(:category, 'EXACT_ALIAS_CAT'), "Owned by acronym")
assert(TestResourceOwnership.owned?(:category, alias_uri), "Owned by URI")
assert(TestResourceOwnership.owned?(:category, alias_model), "Owned by model object")

# 2. Mark outcome-unknown by acronym marks all aliases; cannot be evaded through URI or object
TestResourceOwnership.mark_outcome_unknown(:category, 'EXACT_ALIAS_CAT')
assert(TestResourceOwnership.outcome_unknown?(:category, 'EXACT_ALIAS_CAT'), "Acronym is outcome-unknown")
assert(TestResourceOwnership.outcome_unknown?(:category, alias_uri), "URI alias cannot evade outcome-unknown")
assert(TestResourceOwnership.outcome_unknown?(:category, alias_model), "Object alias cannot evade outcome-unknown")

# 3. Clear outcome-unknown by URI clears all aliases
TestResourceOwnership.clear_outcome_unknown(:category, alias_uri)
assert(!TestResourceOwnership.outcome_unknown?(:category, 'EXACT_ALIAS_CAT'), "Acronym outcome-unknown cleared")
assert(!TestResourceOwnership.outcome_unknown?(:category, alias_uri), "URI outcome-unknown cleared")
assert(!TestResourceOwnership.outcome_unknown?(:category, alias_model), "Object outcome-unknown cleared")

# 4. Mark outcome-unknown by object marks all aliases
TestResourceOwnership.mark_outcome_unknown(:category, alias_model)
assert(TestResourceOwnership.outcome_unknown?(:category, 'EXACT_ALIAS_CAT'), "Acronym marked unknown via object")
assert(TestResourceOwnership.outcome_unknown?(:category, alias_uri), "URI marked unknown via object")

# 5. Unregister by acronym removes all aliases together from ownership and unknown
TestResourceOwnership.unregister(:category, 'EXACT_ALIAS_CAT')
assert(!TestResourceOwnership.owned?(:category, 'EXACT_ALIAS_CAT'), "Acronym unregistered")
assert(!TestResourceOwnership.owned?(:category, alias_uri), "URI unregistered")
assert(!TestResourceOwnership.owned?(:category, alias_model), "Object unregistered")
assert(!TestResourceOwnership.outcome_unknown?(:category, 'EXACT_ALIAS_CAT'), "Acronym unknown cleared on unregister")
assert(!TestResourceOwnership.outcome_unknown?(:category, alias_uri), "URI unknown cleared on unregister")
assert(!TestResourceOwnership.outcome_unknown?(:category, alias_model), "Object unknown cleared on unregister")
assert(TestResourceOwnership.empty?(:category), "Category registry empty after unregister")

# 9r: Exact submission ID identity: no ontology-local numeric basename/name aliases, agent/other unchanged
sub_test_id = 'http://localhost:9393/ontologies/TEST_ONT/submissions/1'
sub_hash_sym = { id: sub_test_id, name: '1', acronym: 'TEST_ONT' }
sub_hash_str = { 'id' => sub_test_id, 'name' => '1', 'acronym' => 'TEST_ONT' }
sub_model = LinkedData::Client::Models::OntologySubmission.new(values: { id: sub_test_id, name: '1', acronym: 'TEST_ONT' })

assert(TestResourceOwnership.extract_keys(:submission, sub_test_id) == [sub_test_id], "Submission String extracts exact ID only")
assert(TestResourceOwnership.extract_keys(:submission, sub_test_id.to_sym) == [sub_test_id], "Submission Symbol extracts exact ID only")
assert(TestResourceOwnership.extract_keys(:submission, sub_hash_sym) == [sub_test_id], "Submission Hash (symbol key) extracts exact ID only")
assert(TestResourceOwnership.extract_keys(:submission, sub_hash_str) == [sub_test_id], "Submission Hash (string key) extracts exact ID only")
assert(TestResourceOwnership.extract_keys(:submission, sub_model) == [sub_test_id], "Submission model extracts exact ID only")
assert(TestResourceOwnership.extract_keys(:submission, '1') == ['1'], "Submission '1' extracts exact '1'")
assert(TestResourceOwnership.extract_keys(:submission, { id: '1' }) == ['1'], "Submission Hash id '1' extracts exact '1'")
assert(TestResourceOwnership.extract_keys(:submission, OpenStruct.new(id: '1')) == ['1'], "Submission Model id '1' extracts exact '1'")

# Agent identity unchanged
agent_test_id = 'http://localhost:9393/agents/1'
assert(TestResourceOwnership.extract_keys(:agent, agent_test_id) == [agent_test_id], "Agent extracts exact ID only")
assert(TestResourceOwnership.extract_keys(:agent, { id: agent_test_id, name: 'Agent 1' }) == [agent_test_id], "Agent Hash extracts exact ID only")

# Other resource types retain alias extraction (e.g. Category extracts URI and terminal basename)
cat_test_uri = 'http://localhost:9393/categories/1'
cat_keys = TestResourceOwnership.extract_keys(:category, cat_test_uri)
assert(cat_keys.include?(cat_test_uri) && cat_keys.include?('1'), "Category retains terminal basename alias")

# 9s: Direct ontology cleanup retires corresponding child submission bookkeeping directly
# ACK child registered FIRST, FAIL child registered SECOND, both canonical full URIs .../submissions/1
$datastore.seed_defaults!
$datastore.deleted_log.clear
$datastore.delete_calls.clear
TestResourceOwnership.reset!

# 1. Direct ACK ontology and child registered FIRST
direct_ack_acronym = 'DIRECT_ACK_ONT'
$datastore.ontologies[direct_ack_acronym] = { acronym: direct_ack_acronym, name: 'Direct Ack Ont' }
direct_ack_sub_id = "http://localhost:9393/ontologies/#{direct_ack_acronym}/submissions/1"
direct_ack_sub = LinkedData::Client::Models::OntologySubmission.new(values: {
  id: direct_ack_sub_id,
  ontology: direct_ack_acronym,
  URI: direct_ack_sub_id
})
harness.register_owned_resource(:ontology, direct_ack_acronym)
harness.register_owned_resource(:submission, direct_ack_sub)

# 2. Direct FAIL ontology (403) and child registered SECOND
direct_fail_acronym = 'DIRECT_FAIL_ONT'
$datastore.ontologies[direct_fail_acronym] = { acronym: direct_fail_acronym, name: 'Direct Fail Ont', delete_status: 403 }
direct_fail_sub_id = "http://localhost:9393/ontologies/#{direct_fail_acronym}/submissions/1"
direct_fail_sub = LinkedData::Client::Models::OntologySubmission.new(values: {
  id: direct_fail_sub_id,
  ontology: direct_fail_acronym,
  URI: direct_fail_sub_id
})
harness.register_owned_resource(:ontology, direct_fail_acronym)
harness.register_owned_resource(:submission, direct_fail_sub)

# 3. Direct unresolved child registered SECOND (canonical full URI)
direct_unresolved_sub_id = "http://localhost:9393/ontologies/SEEDED_ONT_1/submissions/1"
direct_unresolved_sub = LinkedData::Client::Models::OntologySubmission.new(values: {
  id: direct_unresolved_sub_id,
  ontology: 'SEEDED_ONT_1',
  URI: direct_unresolved_sub_id
})
harness.register_owned_resource(:submission, direct_unresolved_sub)

# 4. Another owned resource with aliases (Category with acronym & URI)
direct_cat_uri = 'http://localhost:9393/categories/DIRECT_CAT'
direct_cat = OpenStruct.new(acronym: 'DIRECT_CAT', id: direct_cat_uri, name: 'Direct Cat')
$datastore.categories['DIRECT_CAT'] = { acronym: 'DIRECT_CAT', id: direct_cat_uri, name: 'Direct Cat' }
harness.register_owned_resource(:category, direct_cat)

assert(TestResourceOwnership.owned?(:ontology, direct_ack_acronym), "DIRECT_ACK_ONT owned")
assert(TestResourceOwnership.owned?(:submission, direct_ack_sub), "DIRECT_ACK_SUB owned")
assert(TestResourceOwnership.owned?(:ontology, direct_fail_acronym), "DIRECT_FAIL_ONT owned")
assert(TestResourceOwnership.owned?(:submission, direct_fail_sub), "DIRECT_FAIL_SUB owned")
assert(TestResourceOwnership.owned?(:submission, direct_unresolved_sub), "DIRECT_UNRESOLVED_SUB owned")
assert(TestResourceOwnership.owned?(:category, 'DIRECT_CAT'), "DIRECT_CAT acronym owned")
assert(TestResourceOwnership.owned?(:category, direct_cat_uri), "DIRECT_CAT URI recognized as owned via alias")

# Pre-cleanup check: terminal '1' is not an alias for submission
assert(!TestResourceOwnership.owned?(:submission, '1'), "Direct pre-cleanup: '1' is not owned")
assert(!TestResourceOwnership.owned?(:submission, { id: '1' }), "Direct pre-cleanup: Hash {id: '1'} is not owned")
assert(!TestResourceOwnership.owned?(:submission, OpenStruct.new(id: '1')), "Direct pre-cleanup: Model id '1' is not owned")

# Step 1: Direct failed ontology cleanup (403) retains parent and linked submission
direct_fail_res = harness.delete_ontologies([direct_fail_acronym])
assert(direct_fail_res.size == 1, "direct delete_ontologies reported 403 failure")
assert(TestResourceOwnership.owned?(:ontology, direct_fail_acronym), "DIRECT_FAIL_ONT retained on failure")
assert(TestResourceOwnership.owned?(:submission, direct_fail_sub),
       "CRITICAL: direct delete_ontologies failure RETAINS linked child submission")
assert(TestResourceOwnership.owned?(:submission, direct_ack_sub), "DIRECT_ACK_SUB remains owned before its parent cleanup")
assert(TestResourceOwnership.owned?(:submission, direct_unresolved_sub), "DIRECT_UNRESOLVED_SUB remains owned")

# Step 2: Direct successful ontology cleanup retires linked submission ONLY
direct_ack_res = harness.delete_ontologies([direct_ack_acronym])
assert(direct_ack_res.empty?, "direct delete_ontologies succeeded")
assert(!TestResourceOwnership.owned?(:ontology, direct_ack_acronym), "DIRECT_ACK_ONT unregistered")
assert(!TestResourceOwnership.owned?(:submission, direct_ack_sub),
       "CRITICAL: direct delete_ontologies retired linked child submission directly (not stranded)")
assert($datastore.deleted_log.include?([:ontology, direct_ack_acronym]), "DIRECT_ACK_ONT deleted from datastore")

# CRITICAL R2 ASSERTION: failed parent 403 and its child remain owned; unresolved child remains owned
assert(TestResourceOwnership.owned?(:ontology, direct_fail_acronym), "DIRECT_FAIL_ONT still owned after ACK cleanup")
assert(TestResourceOwnership.owned?(:submission, direct_fail_sub),
       "CRITICAL: direct ACK delete retired ONLY linked child; FAIL child RETAINED")
assert(TestResourceOwnership.owned?(:submission, direct_unresolved_sub),
       "CRITICAL: direct ACK delete retired ONLY linked child; unresolved child RETAINED")

# Assert String/Hash/model queries do not alias '1' or cross-parent
assert(!TestResourceOwnership.owned?(:submission, '1'), "Direct post-cleanup: '1' String query is not owned")
assert(!TestResourceOwnership.owned?(:submission, { id: '1' }), "Direct post-cleanup: Hash { id: '1' } is not owned")
assert(!TestResourceOwnership.owned?(:submission, { 'id' => '1' }), "Direct post-cleanup: Hash { 'id' => '1' } is not owned")
assert(!TestResourceOwnership.owned?(:submission, OpenStruct.new(id: '1')), "Direct post-cleanup: Model with id '1' is not owned")

# Retired direct ACK child not owned via String, Hash, or model query
assert(!TestResourceOwnership.owned?(:submission, direct_ack_sub_id), "DIRECT_ACK_SUB full URI String query is not owned")
assert(!TestResourceOwnership.owned?(:submission, { id: direct_ack_sub_id }), "DIRECT_ACK_SUB Hash query is not owned")
assert(!TestResourceOwnership.owned?(:submission, OpenStruct.new(id: direct_ack_sub_id)), "DIRECT_ACK_SUB model query is not owned")

# Retained direct FAIL child is owned via String, Hash, and model query
assert(TestResourceOwnership.owned?(:submission, direct_fail_sub_id), "DIRECT_FAIL_SUB full URI String query is owned")
assert(TestResourceOwnership.owned?(:submission, { id: direct_fail_sub_id }), "DIRECT_FAIL_SUB Hash query is owned")
assert(TestResourceOwnership.owned?(:submission, OpenStruct.new(id: direct_fail_sub_id)), "DIRECT_FAIL_SUB model query is owned")

# Retained direct unresolved child is owned via String, Hash, and model query
assert(TestResourceOwnership.owned?(:submission, direct_unresolved_sub_id), "DIRECT_UNRESOLVED_SUB full URI String query is owned")
assert(TestResourceOwnership.owned?(:submission, { id: direct_unresolved_sub_id }), "DIRECT_UNRESOLVED_SUB Hash query is owned")
assert(TestResourceOwnership.owned?(:submission, OpenStruct.new(id: direct_unresolved_sub_id)), "DIRECT_UNRESOLVED_SUB model query is owned")

# Category aliases unchanged: acronym, URI, and model all recognized and cleanly removed together
assert(TestResourceOwnership.owned?(:category, 'DIRECT_CAT'), "Category acronym owned")
assert(TestResourceOwnership.owned?(:category, direct_cat_uri), "Category URI alias owned")
assert(TestResourceOwnership.owned?(:category, direct_cat), "Category model owned")
TestResourceOwnership.unregister(:category, 'DIRECT_CAT')
assert(!TestResourceOwnership.owned?(:category, 'DIRECT_CAT'), "Category acronym unregistered")
assert(!TestResourceOwnership.owned?(:category, direct_cat_uri), "Category URI alias unregistered")
assert(!TestResourceOwnership.owned?(:category, direct_cat), "Category model unregistered")

# -----------------------------------------------------------------------------
# Summary
# -----------------------------------------------------------------------------
puts "\n============================================================"
if $failures.empty?
  puts "ALL CHECKS PASSED: ONTO-T-Q06 owned-resource tracking & cleanup verified offline."
  exit 0
else
  puts "FAILED with #{$failures.size} failure(s):"
  $failures.each { |f| puts " - #{f}" }
  exit 1
end
