# frozen_string_literal: true

# Standalone isolated test for ONTO-T-Q06 acknowledged-create/cache ordering (Finding 5).
# Run directly with plain Ruby:
#   ruby -I. -Itest test/isolated/test_creation_ack_check.rb
#
# Validates:
#   1. Acknowledged successful HTTP POST is registered in TestResourceOwnership BEFORE fallible cache refresh.
#   2. POST success + cache refresh failure remains owned for cleanup in teardown.
#   3. Cache invalidation is preserved and dispatched on successful creation with exact call counts & options.
#   4. Failed, duplicate, unacknowledged 3xx, or malformed body never adopts seeded/request fixtures and is never registered.
#   5. Unknown or failed POST outcomes are not repeated; ontology failure stops immediately without creating submission.
#   6. Faraday admin-user creation respects actual 2xx status/body contract; missing admin never POSTs; no admin cache calls.
#   7. Creator helpers preserve positive return semantics and authentic admin credentials.
#   8. Seeded resources survive all creation attempts and teardown.
#   9. 100% offline with zero sockets or remote network access.

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

# Prevent NameError when rails gem is present without full Rails application boot
$LOADED_FEATURES << 'rails/test_help' << 'rails/test_help.rb'

ENV['ONTOPORTAL_ISOLATED_TEST'] = '1'

REAL_SDK_MODE = begin
  require 'bundler/setup'
  require 'ontologies_api_client'
  true
rescue StandardError, LoadError, ScriptError
  false
end

if REAL_SDK_MODE
  LinkedData::Client.config do |c|
    c.rest_url = 'http://localhost:9393'
  end
  LinkedData::Client.settings.federated_portals = {}

  rest_url = 'http://localhost:9393'
  top_level_links = {
    users: LinkedData::Client::HTTP::Link.new("#{rest_url}/users").tap { |l| l.media_type = 'http://data.bioontology.org/metadata/User' },
    categories: LinkedData::Client::HTTP::Link.new("#{rest_url}/categories").tap { |l| l.media_type = 'http://data.bioontology.org/metadata/Category' },
    groups: LinkedData::Client::HTTP::Link.new("#{rest_url}/groups").tap { |l| l.media_type = 'http://data.bioontology.org/metadata/Group' },
    ontologies: LinkedData::Client::HTTP::Link.new("#{rest_url}/ontologies").tap { |l| l.media_type = 'http://data.bioontology.org/metadata/Ontology' },
    submissions: LinkedData::Client::HTTP::Link.new("#{rest_url}/submissions").tap { |l| l.media_type = 'http://data.bioontology.org/metadata/OntologySubmission' }
  }
  top_level_obj = OpenStruct.new(links: top_level_links)
  [
    LinkedData::Client::Models::User,
    LinkedData::Client::Models::Category,
    LinkedData::Client::Models::Group,
    LinkedData::Client::Models::Ontology,
    LinkedData::Client::Models::OntologySubmission
  ].each do |model_cls|
    model_cls.instance_variable_set(:@top_level_links, { rest_url => top_level_obj })
  end
end

require_relative '../helpers/test_target_guard'
require_relative '../helpers/test_resource_ownership'
require_relative '../helpers/application_test_helpers'

# --- Custom Errors ---
class CacheRefreshException < StandardError; end

# --- Offline Datastore ---
class MockDatastore
  attr_reader :categories, :groups, :agents, :ontologies, :submissions, :users, :deleted_log

  def initialize
    @categories = {}
    @groups = {}
    @agents = {}
    @ontologies = {}
    @submissions = {}
    @users = {}
    @deleted_log = []
  end

  def seed_defaults!
    @categories['SEEDED_CAT_1'] = { acronym: 'SEEDED_CAT_1', name: 'Seeded Category 1', id: 'http://localhost:9393/categories/SEEDED_CAT_1' }
    @groups['SEEDED_GRP_1'] = { acronym: 'SEEDED_GRP_1', name: 'Seeded Group 1', id: 'http://localhost:9393/groups/SEEDED_GRP_1' }
    @agents['http://localhost:9393/agents/SEEDED_AGENT_1'] = { id: 'http://localhost:9393/agents/SEEDED_AGENT_1', name: 'Seeded Agent 1' }
    @ontologies['SEEDED_ONT_1'] = { acronym: 'SEEDED_ONT_1', name: 'Seeded Ontology 1', id: 'http://localhost:9393/ontologies/SEEDED_ONT_1' }
    @users['admin'] = { username: 'admin', apikey: 'secret_admin_token', password: 'password', role: ['ADMINISTRATOR'] }
    @users['SEEDED_USER_1'] = { username: 'SEEDED_USER_1', apikey: 'user_token_1', password: 'password', role: [] }
  end
end

$datastore = MockDatastore.new
$datastore.seed_defaults!

# Spy tracking for cache refresh, HTTP POST, and Faraday POST calls
$cache_refresh_log = []
$http_post_log = []
$faraday_post_log = []
$fail_cache_refresh = {}
$faraday_custom_response = nil
$http_custom_response = nil
$http_return_nil = false

# --- LinkedData Client Double Hierarchy ---
module LinkedData
  module Client
    class Base
      # Provenance: ontologies-api-client-6257685-base.rb:109-155
      def initialize(values: {}, **kwargs)
        data = values.is_a?(Hash) ? values.dup : {}
        data.merge!(kwargs)
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
    end unless defined?(LinkedData::Client::Base)

    class Settings
      attr_accessor :rest_url
      def initialize
        @rest_url = 'http://localhost:9393'
      end
    end unless defined?(LinkedData::Client::Settings)

    def self.settings
      @settings ||= Settings.new
    end unless respond_to?(:settings)
    self.settings.rest_url = 'http://localhost:9393'

    # Response returned by HTTP.post reflecting distinct response identity
    class CreatedResponse < Base
      attr_accessor :values

      def initialize(attrs = {})
        attrs = attrs.dup
        @values = attrs
        super(values: attrs)
        if respond_to?(:create_attributes, true)
          create_attributes(attrs.keys)
          populate_attributes(attrs)
        else
          attrs.each do |k, v|
            singleton_class.class_eval { attr_accessor k.to_sym } unless respond_to?(k.to_sym)
            send("#{k}=", v)
          end
        end
        @status ||= (attrs[:status] || attrs['status'] || 201)
      end

      def to_h
        @values
      end

      def delete
        if @acronym
          $datastore.deleted_log << [:category, @acronym] if @id&.include?('/categories/')
          $datastore.deleted_log << [:group, @acronym] if @id&.include?('/groups/')
          $datastore.deleted_log << [:ontology, @acronym] if @id&.include?('/ontologies/')
          $datastore.categories.delete(@acronym)
          $datastore.groups.delete(@acronym)
          $datastore.ontologies.delete(@acronym)
        elsif @username
          $datastore.deleted_log << [:user, @username]
          $datastore.users.delete(@username)
        elsif @id
          $datastore.deleted_log << [:submission, @id]
        end
        OpenStruct.new(status: 204)
      end
    end

    module HTTP
      def self.post(path, payload, options = {})
        $http_post_log << { path: path, payload: payload }

        return nil if $http_return_nil
        return $http_custom_responses.shift if defined?($http_custom_responses) && $http_custom_responses && !$http_custom_responses.empty?
        return $http_custom_response if $http_custom_response

        norm_path = path.to_s.sub(%r{\Ahttps?://[^/]+}, '')
        case norm_path
        when '/categories'
          acronym = (payload[:acronym] || payload['acronym']).to_s
          if acronym == 'SEEDED_CAT_1'
            CreatedResponse.new(status: 409, errors: ['Category already exists'])
          elsif payload[:errors]
            CreatedResponse.new(status: 400, errors: payload[:errors])
          else
            id = "http://localhost:9393/categories/#{acronym}"
            $datastore.categories[acronym] = { acronym: acronym, name: payload[:name], id: id }
            CreatedResponse.new(id: id, acronym: acronym, name: payload[:name], status: 201)
          end
        when '/groups'
          acronym = (payload[:acronym] || payload['acronym']).to_s
          if acronym == 'SEEDED_GRP_1'
            CreatedResponse.new(status: 409, errors: ['Group already exists'])
          elsif payload[:errors]
            CreatedResponse.new(status: 400, errors: payload[:errors])
          else
            id = "http://localhost:9393/groups/#{acronym}"
            $datastore.groups[acronym] = { acronym: acronym, name: payload[:name], id: id }
            CreatedResponse.new(id: id, acronym: acronym, name: payload[:name], status: 201)
          end
        when '/ontologies'
          acronym = (payload[:acronym] || payload['acronym']).to_s
          if acronym == 'SEEDED_ONT_1'
            CreatedResponse.new(status: 409, errors: ['Ontology already exists'])
          elsif payload[:errors]
            CreatedResponse.new(status: 400, errors: payload[:errors])
          else
            id = "http://localhost:9393/ontologies/#{acronym}"
            $datastore.ontologies[acronym] = { acronym: acronym, name: payload[:name], id: id }
            CreatedResponse.new(id: id, acronym: acronym, name: payload[:name], status: 201)
          end
        when '/submissions', '/ontologies/submissions'
          if payload[:errors]
            CreatedResponse.new(status: 400, errors: payload[:errors])
          else
            id = "http://localhost:9393/submissions/sub_#{rand(1000..9999)}"
            $datastore.submissions[id] = payload
            CreatedResponse.new(id: id, ontology: payload[:ontology], status: 201)
          end
        when '/users'
          username = (payload[:username] || payload['username']).to_s
          if username == 'SEEDED_USER_1' || username == 'admin'
            CreatedResponse.new(status: 409, errors: ['Username already taken'])
          elsif payload[:errors]
            CreatedResponse.new(status: 400, errors: payload[:errors])
          else
            id = "http://localhost:9393/users/#{username}"
            $datastore.users[username] = payload.merge(apikey: "apikey_#{username}", id: id)
            CreatedResponse.new(id: id, username: username, status: 201)
          end
        else
          CreatedResponse.new(status: 200)
        end
      end

      def self.get(id, options = {})
        OpenStruct.new(id: id)
      end

      def self.delete(id)
        if id.to_s.include?('/categories/')
          acronym = id.to_s.split('/').last
          $datastore.deleted_log << [:category, acronym]
          $datastore.categories.delete(acronym)
        elsif id.to_s.include?('/groups/')
          acronym = id.to_s.split('/').last
          $datastore.deleted_log << [:group, acronym]
          $datastore.groups.delete(acronym)
        elsif id.to_s.include?('/ontologies/')
          acronym = id.to_s.split('/').last
          $datastore.deleted_log << [:ontology, acronym]
          $datastore.ontologies.delete(acronym)
        elsif id.to_s.include?('/users/')
          username = id.to_s.split('/').last
          $datastore.deleted_log << [:user, username]
          $datastore.users.delete(username)
        end
        OpenStruct.new(status: 204)
      end

      unless REAL_SDK_MODE
        def self.object_from_json(json_str)
          data = JSON.parse(json_str)
          CreatedResponse.new(data.transform_keys(&:to_sym))
        end
      end

      def self.load_json(json_str)
        raise Interrupt, "Simulated SIGINT" if json_str == '__TEST_INTERRUPT__'
        raise SystemExit.new(1) if json_str == '__TEST_SYSTEM_EXIT__'
        if REAL_SDK_MODE && defined?(MultiJson)
          MultiJson.load(json_str)
        else
          JSON.parse(json_str)
        end
      end
    end

    module ReadWrite
      private

      def cache_refresh(options = {})
        cls_key = self.class.name.split('::').last.downcase.to_sym
        $cache_refresh_log << [cls_key, options]
        if $fail_cache_refresh[cls_key]
          raise CacheRefreshException, "Simulated cache refresh failure for #{cls_key}"
        end
        self.class.all(invalidate_cache: true) if self.class.respond_to?(:all)
      end
    end

    if REAL_SDK_MODE
      module Models
        class Category
          def self.all(options = {})
            $datastore.categories.values.map { |v| Category.new(values: v) }
          end
          def self.find_by_acronym(acronym)
            v = $datastore.categories[acronym.to_s]
            v ? [CreatedResponse.new(v)] : []
          end
        end

        class Group
          def self.all(options = {})
            $datastore.groups.values.map { |v| Group.new(values: v) }
          end
          def self.find_by_acronym(acronym)
            v = $datastore.groups[acronym.to_s]
            v ? [CreatedResponse.new(v)] : []
          end
        end

        class Ontology
          def self.all(options = {})
            $datastore.ontologies.values.map { |v| Ontology.new(values: v) }
          end
          def self.find_by_acronym(acronym)
            v = $datastore.ontologies[acronym.to_s]
            v ? [CreatedResponse.new(v)] : []
          end
        end

        class OntologySubmission
          def self.all(options = {})
            $datastore.submissions.values.map { |v| OntologySubmission.new(values: v) }
          end
        end

        class User
          def self.authenticate(username, password)
            user = $datastore.users[username.to_s]
            if user && user[:password] == password
              User.new(values: user)
            else
              nil
            end
          end

          def self.find_by_username(username)
            user = $datastore.users[username.to_s]
            user ? [User.new(values: user)] : []
          end

          def self.all(options = {})
            $datastore.users.values.map { |v| User.new(values: v) }
          end
        end
      end
    else
      module Models
        class Category
          include LinkedData::Client::ReadWrite

          attr_accessor :acronym, :name, :id, :errors

          def initialize(values: {})
            @acronym = (values[:acronym] || values['acronym']).to_s
            @name = (values[:name] || values['name']).to_s
            @id = values[:id] || values['id']
            @errors = values[:errors]
          end

          def to_hash
            { acronym: @acronym, name: @name, errors: @errors }.compact
          end
          alias to_h to_hash

          def self.collection_path
            '/categories'
          end

          def self.all(options = {})
            $datastore.categories.values.map { |v| Category.new(values: v) }
          end

          def self.find_by_acronym(acronym)
            v = $datastore.categories[acronym.to_s]
            v ? [CreatedResponse.new(v)] : []
          end

          def delete
            $datastore.deleted_log << [:category, @acronym]
            $datastore.categories.delete(@acronym)
            OpenStruct.new(status: 204)
          end
        end

        class Group
          include LinkedData::Client::ReadWrite

          attr_accessor :acronym, :name, :id, :errors

          def initialize(values: {})
            @acronym = (values[:acronym] || values['acronym']).to_s
            @name = (values[:name] || values['name']).to_s
            @id = values[:id] || values['id']
            @errors = values[:errors]
          end

          def to_hash
            { acronym: @acronym, name: @name, errors: @errors }.compact
          end
          alias to_h to_hash

          def self.collection_path
            '/groups'
          end

          def self.all(options = {})
            $datastore.groups.values.map { |v| Group.new(values: v) }
          end

          def self.find_by_acronym(acronym)
            v = $datastore.groups[acronym.to_s]
            v ? [CreatedResponse.new(v)] : []
          end

          def delete
            $datastore.deleted_log << [:group, @acronym]
            $datastore.groups.delete(@acronym)
            OpenStruct.new(status: 204)
          end
        end

        class Ontology
          include LinkedData::Client::ReadWrite

          attr_accessor :acronym, :name, :id, :errors

          def initialize(values: {})
            @acronym = (values[:acronym] || values['acronym']).to_s
            @name = (values[:name] || values['name']).to_s
            @id = values[:id] || values['id']
            @errors = values[:errors]
          end

          def to_hash
            { acronym: @acronym, name: @name, errors: @errors }.compact
          end
          alias to_h to_hash

          def self.collection_path
            '/ontologies'
          end

          def self.all(options = {})
            $datastore.ontologies.values.map { |v| Ontology.new(values: v) }
          end

          def self.find_by_acronym(acronym)
            v = $datastore.ontologies[acronym.to_s]
            v ? [CreatedResponse.new(v)] : []
          end

          def delete
            $datastore.deleted_log << [:ontology, @acronym]
            $datastore.ontologies.delete(@acronym)
            OpenStruct.new(status: 204)
          end
        end

        class OntologySubmission
          include LinkedData::Client::ReadWrite

          attr_accessor :ontology, :id, :errors

          def initialize(values: {})
            @ontology = values[:ontology] || values['ontology']
            @id = values[:id] || values['id']
            @errors = values[:errors]
          end

          def to_hash
            { ontology: @ontology, errors: @errors }.compact
          end
          alias to_h to_hash

          def self.collection_path
            '/submissions'
          end

          def self.all(options = {})
            $datastore.submissions.values.map { |v| OntologySubmission.new(values: v) }
          end
        end

        class User
          include LinkedData::Client::ReadWrite

          attr_accessor :username, :password, :apikey, :role, :id, :errors

          def initialize(values: {})
            @username = (values[:username] || values['username']).to_s
            @password = values[:password] || values['password']
            @apikey = values[:apikey] || values['apikey']
            @role = values[:role] || values['role'] || []
            @id = values[:id] || values['id']
            @errors = values[:errors]
          end

          def to_hash
            { username: @username, password: @password, apikey: @apikey, role: @role, errors: @errors }.compact
          end
          alias to_h to_hash

          def self.collection_path
            'http://localhost:9393/users'
          end

          def self.authenticate(username, password)
            user = $datastore.users[username.to_s]
            if user && user[:password] == password
              User.new(values: user)
            else
              nil
            end
          end

          def self.find_by_username(username)
            user = $datastore.users[username.to_s]
            user ? [User.new(values: user)] : []
          end

          def self.all(options = {})
            $datastore.users.values.map { |v| User.new(values: v) }
          end
        end
      end
    end
  end
end

# --- Mock Faraday Connection with Actual Status/Body Contract ---
class MockFaradayResponse
  attr_accessor :status, :body
  def initialize(status: 200, body: '{}')
    @status = status
    @body = body
  end
end

class MockFaradayConnection
  attr_reader :url
  def initialize(url = nil)
    @url = url
    @headers = {}
  end

  def request(*); end
  def response(*); end
  def adapter(*); end
  def use(*); end
  def headers=(h); @headers = h; end
  def url_prefix; URI.parse(@url || 'http://localhost:9393'); end
  def in_parallel?; false; end

  def post(path, body = nil, headers = {})
    $faraday_post_log << { path: path, body: body, headers: @headers.dup }

    return $faraday_custom_response if $faraday_custom_response

    data = JSON.parse(body) rescue {}
    username = data['username'] || data[:username]

    if username == 'SEEDED_USER_1' || username == 'admin'
      # Duplication rejection: actual status/body contract
      MockFaradayResponse.new(status: 409, body: JSON.dump({ errors: ["User '#{username}' already exists"] }))
    elsif data['errors'] || data[:errors]
      MockFaradayResponse.new(status: 400, body: JSON.dump({ errors: data['errors'] || data[:errors] }))
    else
      user_record = data.merge(
        'id' => "http://localhost:9393/users/#{username}",
        '@type' => "http://data.bioontology.org/metadata/User",
        'apikey' => "apikey_#{username}"
      )
      $datastore.users[username] = user_record
      MockFaradayResponse.new(status: 201, body: JSON.dump(user_record))
    end
  end

  def delete(path)
    if path.start_with?('/users/')
      username = path.sub('/users/', '')
      $datastore.deleted_log << [:user, username]
      $datastore.users.delete(username)
      MockFaradayResponse.new(status: 204)
    else
      MockFaradayResponse.new(status: 204)
    end
  end
end

module Faraday
  def self.default_adapter; :net_http; end
  def self.new(*args, **kwargs, &block)
    url = kwargs[:url] || args.first
    conn = MockFaradayConnection.new(url)
    block.call(conn) if block_given?
    conn
  end
end

# --- Test Harness invoking ACTUAL creator helpers ---
class TestHarness
  include ApplicationTestHelpers
  include ApplicationTestHelpers::Users
  include ApplicationTestHelpers::Categories
  include ApplicationTestHelpers::Groups
  include ApplicationTestHelpers::Ontologies
  include ApplicationTestHelpers::Agents
end

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
puts "Running ONTO-T-Q06 Acknowledged-Create/Cache Ordering Checks"
puts "Execution Mode: #{REAL_SDK_MODE ? 'REAL-SDK (pinned native image onto-q02-proof:af254f34)' : 'OFFLINE (minimal cached Base semantics: ontologies-api-client-6257685-base.rb:109-122)'}"
puts "============================================================"

harness = TestHarness.new

# -----------------------------------------------------------------------------
puts "\n=== Step 0: Pinned SDK Base and Native Converter Provenance Check ==="
# -----------------------------------------------------------------------------
if REAL_SDK_MODE
  base_init_loc = LinkedData::Client::Base.instance_method(:initialize).source_location
  conv_loc = LinkedData::Client::HTTP.method(:object_from_json).source_location
  coll_loc = LinkedData::Client::Models::User.method(:collection_path).source_location

  assert(!base_init_loc.nil? && base_init_loc.first.include?('ontologies_api_ruby_client-6257685e5744') && base_init_loc.first.end_with?('/base.rb'), "Pinned Base source location remains real native SDK (got: #{base_init_loc.inspect})")
  assert(!conv_loc.nil? && conv_loc.first.include?('ontologies_api_ruby_client-6257685e5744') && conv_loc.first.end_with?('/http.rb'), "Pinned HTTP.object_from_json converter source location remains real native SDK (got: #{conv_loc.inspect})")
  assert(!coll_loc.nil? && coll_loc.first.include?('ontologies_api_ruby_client-6257685e5744') && coll_loc.first.end_with?('/collection.rb'), "Pinned Collection.collection_path source location remains real native SDK (got: #{coll_loc.inspect})")

  # Test valid actual typed server payload through original converter (actual model media type)
  typed_user_server_payload = MultiJson.dump({
    '@id' => 'http://localhost:9393/users/real_sdk_user_test',
    '@type' => 'http://data.bioontology.org/metadata/User',
    'username' => 'real_sdk_user_test',
    'email' => 'realsdk@example.com'
  })
  native_parsed_user = LinkedData::Client::HTTP.object_from_json(typed_user_server_payload)
  assert(native_parsed_user.is_a?(LinkedData::Client::Models::User), "Real converter returns actual LinkedData::Client::Models::User instance")
  assert(native_parsed_user.is_a?(LinkedData::Client::Base), "Real converter returns instance of LinkedData::Client::Base")
  assert(native_parsed_user.id == 'http://localhost:9393/users/real_sdk_user_test', "Real converter preserves exact response ID")
  assert(native_parsed_user.username == 'real_sdk_user_test', "Real converter populates exact username")
  assert(ApplicationTestHelpers.extract_created_identity(native_parsed_user, :user) == 'real_sdk_user_test', "extract_created_identity extracts username from real converted model")
else
  # Fallback mode honesty assertions
  assert(defined?(LinkedData::Client::Base), "Fallback Base double defined")
  assert(defined?(LinkedData::Client::HTTP), "Fallback HTTP double defined")
  assert(defined?(LinkedData::Client::CreatedResponse), "Fallback CreatedResponse double defined")
end

# -----------------------------------------------------------------------------
puts "\n=== Step 1: Category Acknowledged POST Retained on Refresh Exception ==="
# -----------------------------------------------------------------------------
$datastore.seed_defaults!
$datastore.deleted_log.clear
$cache_refresh_log.clear
$http_post_log.clear
$fail_cache_refresh.clear
TestResourceOwnership.reset!

# Configure cache refresh failure on Category
$fail_cache_refresh[:category] = true

raised = false
begin
  harness.create_category({ acronym: 'ACK_CAT_FAIL', name: 'Ack Cat Fail' })
rescue CacheRefreshException
  raised = true
end

assert(raised, "create_category propagates CacheRefreshException on fallible cache refresh")
assert(TestResourceOwnership.owned?(:category, 'ACK_CAT_FAIL'), "Acknowledged Category POST acronym retained in ownership registry")
assert(TestResourceOwnership.owned?(:category, 'http://localhost:9393/categories/ACK_CAT_FAIL'), "Acknowledged Category POST exact URI retained in ownership registry")
assert(!TestResourceOwnership.owned?(:category, 'SEEDED_CAT_1'), "Seeded category SEEDED_CAT_1 remains unowned")

# Teardown must cleanly delete the retained category
$fail_cache_refresh.clear
harness.delete_categories
assert($datastore.deleted_log.include?([:category, 'ACK_CAT_FAIL']), "Retained ACK_CAT_FAIL deleted during cleanup")
assert(!$datastore.deleted_log.include?([:category, 'SEEDED_CAT_1']), "Seeded category was NOT deleted during cleanup")
assert($datastore.categories.key?('SEEDED_CAT_1'), "Seeded category survives in datastore")

# -----------------------------------------------------------------------------
puts "\n=== Step 2: Category Positive Return Semantics, Exact Calls & Cache Options ==="
# -----------------------------------------------------------------------------
$cache_refresh_log.clear
$http_post_log.clear
cat_result = harness.create_category({ acronym: 'ACK_CAT_OK', name: 'Ack Cat OK' })

assert(cat_result.is_a?(LinkedData::Client::CreatedResponse), "Positive return returns distinct CreatedResponse object")
assert(cat_result.id == 'http://localhost:9393/categories/ACK_CAT_OK', "Returned object contains exact created ID")
assert(TestResourceOwnership.owned?(:category, 'ACK_CAT_OK'), "ACK_CAT_OK is registered as owned")
assert($http_post_log.size == 1, "Category creation dispatches exactly 1 HTTP POST (got: #{$http_post_log.size})")
assert($cache_refresh_log.size == 1, "Category creation dispatches exactly 1 cache refresh call (got: #{$cache_refresh_log.size})")
assert($cache_refresh_log.first == [:category, {}], "Category cache refresh called with expected options (got: #{$cache_refresh_log.first.inspect})")

# -----------------------------------------------------------------------------
puts "\n=== Step 3: Category Error / Duplicate Never Registered, Dispatches SDK Cache Refresh ==="
# -----------------------------------------------------------------------------
$cache_refresh_log.clear
$http_post_log.clear

# Attempt duplicate of seeded category
dup_cat = harness.create_category({ acronym: 'SEEDED_CAT_1', name: 'Duplicate Seed' })
assert(dup_cat.respond_to?(:errors) && dup_cat.errors, "Duplicate category creation returns response with errors")
assert(!TestResourceOwnership.owned?(:category, 'SEEDED_CAT_1'), "Duplicate attempt never registers seeded SEEDED_CAT_1 as owned")
assert($cache_refresh_log.size == 1, "Duplicate category creation dispatches cache refresh per SDK ReadWrite.save contract")
assert($cache_refresh_log.first == [:category, {}], "Cache refresh called once with exact options")

# Attempt category with client error
$cache_refresh_log.clear
err_cat = harness.create_category({ acronym: 'INVALID_CAT', errors: ['Acronym format invalid'] })
assert(!TestResourceOwnership.owned?(:category, 'INVALID_CAT'), "Failed category creation is never registered in ownership registry")
assert($cache_refresh_log.size == 1, "Failed category creation dispatches cache refresh per SDK ReadWrite.save contract")
assert($cache_refresh_log.first == [:category, {}], "Cache refresh called once with exact options")

# -----------------------------------------------------------------------------
puts "\n=== Step 4: Group Acknowledged POST Retained on Refresh Exception ==="
# -----------------------------------------------------------------------------
$cache_refresh_log.clear
$http_post_log.clear
$fail_cache_refresh[:group] = true

grp_raised = false
begin
  harness.create_group({ acronym: 'ACK_GRP_FAIL', name: 'Ack Group Fail' })
rescue CacheRefreshException
  grp_raised = true
end

assert(grp_raised, "create_group propagates CacheRefreshException on fallible cache refresh")
assert(TestResourceOwnership.owned?(:group, 'ACK_GRP_FAIL'), "Acknowledged Group POST acronym retained in ownership registry")
assert(TestResourceOwnership.owned?(:group, 'http://localhost:9393/groups/ACK_GRP_FAIL'), "Acknowledged Group POST exact URI retained in ownership registry")
assert(!TestResourceOwnership.owned?(:group, 'SEEDED_GRP_1'), "Seeded group SEEDED_GRP_1 remains unowned")

# Teardown cleans retained group
$fail_cache_refresh.clear
harness.delete_groups
assert($datastore.deleted_log.include?([:group, 'ACK_GRP_FAIL']), "Retained ACK_GRP_FAIL deleted during cleanup")
assert($datastore.groups.key?('SEEDED_GRP_1'), "Seeded group survives in datastore")

# Group error/duplicate never registered
$cache_refresh_log.clear
dup_grp = harness.create_group({ acronym: 'SEEDED_GRP_1', name: 'Duplicate Seed' })
assert(!TestResourceOwnership.owned?(:group, 'SEEDED_GRP_1'), "Duplicate group attempt never registers seeded SEEDED_GRP_1")
assert($cache_refresh_log.size == 1, "Duplicate group dispatches cache refresh per SDK contract")
assert($cache_refresh_log.first == [:group, {}], "Group cache refresh called with exact options")

# Positive group creation
$cache_refresh_log.clear
$http_post_log.clear
ok_grp = harness.create_group({ acronym: 'ACK_GRP_OK', name: 'Ack Group OK' })
assert(TestResourceOwnership.owned?(:group, 'ACK_GRP_OK'), "Successful group is registered as owned")
assert($http_post_log.size == 1, "Group creation dispatches exactly 1 HTTP POST")
assert($cache_refresh_log.size == 1, "Group creation dispatches exactly 1 cache refresh call")
assert($cache_refresh_log.first == [:group, {}], "Group cache refresh called with expected options")

# -----------------------------------------------------------------------------
puts "\n=== Step 5: Ontology Acknowledged POST Retained on Refresh Exception ==="
# -----------------------------------------------------------------------------
$cache_refresh_log.clear
$http_post_log.clear
$fail_cache_refresh[:ontology] = true

ont_raised = false
begin
  harness.create_ontology({ acronym: 'ACK_ONT_FAIL', name: 'Ack Ont Fail' }, { URI: 'http://example.org/sub1' })
rescue CacheRefreshException
  ont_raised = true
end

assert(ont_raised, "create_ontology propagates CacheRefreshException on fallible cache refresh")
assert(TestResourceOwnership.owned?(:ontology, 'ACK_ONT_FAIL'), "Acknowledged Ontology POST acronym retained in ownership registry")
assert(TestResourceOwnership.owned?(:ontology, 'http://localhost:9393/ontologies/ACK_ONT_FAIL'), "Acknowledged Ontology POST exact URI retained in ownership registry")
assert(!TestResourceOwnership.owned?(:ontology, 'SEEDED_ONT_1'), "Seeded ontology SEEDED_ONT_1 remains unowned")

# Teardown cleans retained ontology
$fail_cache_refresh.clear
harness.delete_ontologies
assert($datastore.deleted_log.include?([:ontology, 'ACK_ONT_FAIL']), "Retained ACK_ONT_FAIL deleted during cleanup")
assert($datastore.ontologies.key?('SEEDED_ONT_1'), "Seeded ontology survives in datastore")

# -----------------------------------------------------------------------------
puts "\n=== Step 6: Ontology Failure Stops Immediately and Never Creates Submission ==="
# -----------------------------------------------------------------------------
$http_post_log.clear
$cache_refresh_log.clear

# Attempt creating ontology with errors
failed_ont_sub = harness.create_ontology({ acronym: 'FAIL_ONT', errors: ['Invalid schema'] }, { URI: 'http://example.org/sub_orphaned' })

assert(failed_ont_sub[0].respond_to?(:errors) && failed_ont_sub[0].errors, "Failed ontology response contains errors")
assert(failed_ont_sub[1].nil?, "Submission is strictly nil when ontology creation fails")
assert(!TestResourceOwnership.owned?(:ontology, 'FAIL_ONT'), "Failed ontology is NOT registered in ownership registry")

# Verify POST calls: exactly 1 ontology POST, 0 submission POSTs, no retry loop
ont_posts = $http_post_log.select { |p| ['/ontologies', 'http://localhost:9393/ontologies'].include?(p[:path]) }
sub_posts = $http_post_log.select { |p| ['/submissions', '/ontologies/submissions', 'http://localhost:9393/submissions'].include?(p[:path]) }

assert(ont_posts.size == 1, "Failed ontology POST was never repeated (exact count: 1)")
assert(sub_posts.size == 0, "No submission POST was dispatched after ontology creation failed")
assert($cache_refresh_log.size == 1, "Cache refresh dispatched once for failed ontology per SDK contract")
assert($cache_refresh_log.first == [:ontology, {}], "Ontology cache refresh called with exact options")

# Duplicate ontology creation attempt never registers seeded ontology
$cache_refresh_log.clear
$http_post_log.clear
dup_ont = harness.create_ontology({ acronym: 'SEEDED_ONT_1', name: 'Duplicate' }, nil)
assert(!TestResourceOwnership.owned?(:ontology, 'SEEDED_ONT_1'), "Duplicate ontology attempt never adopts seeded SEEDED_ONT_1")
assert($cache_refresh_log.size == 1, "Duplicate ontology dispatches cache refresh per SDK contract")

# Successful ontology and submission creation
$cache_refresh_log.clear
$http_post_log.clear
ok_ont_sub = harness.create_ontology({ acronym: 'ACK_ONT_OK', name: 'Ack Ont OK' }, { URI: 'http://example.org/sub_ok' })
assert(TestResourceOwnership.owned?(:ontology, 'ACK_ONT_OK'), "Successful ontology is registered as owned")
assert(TestResourceOwnership.owned?(:submission, ok_ont_sub[1].id), "Successful submission is registered as owned")
assert(ok_ont_sub[0].is_a?(LinkedData::Client::CreatedResponse), "Ontology return is distinct CreatedResponse")
assert(ok_ont_sub[1].is_a?(LinkedData::Client::CreatedResponse), "Submission return is distinct CreatedResponse")
assert($http_post_log.select { |p| ['/ontologies', 'http://localhost:9393/ontologies'].include?(p[:path]) }.size == 1, "Exact 1 ontology POST on success")
assert($http_post_log.select { |p| ['/submissions', '/ontologies/submissions', 'http://localhost:9393/submissions'].include?(p[:path]) }.size == 1, "Exact 1 submission POST on success")
assert($cache_refresh_log.size == 2, "Exact 2 cache refresh calls (ontology and submission)")

# Verify Submission response object registered with parent association (Item 1)
owned_submissions = TestResourceOwnership.owned_resources(:submission)
assert(owned_submissions.first.is_a?(LinkedData::Client::CreatedResponse), "Submission registered as response object, preserving type")
assert(owned_submissions.first.id == ok_ont_sub[1].id, "Registered submission preserves exact ID")
assert(owned_submissions.first.ontology == ok_ont_sub[0].id, "Registered submission preserves ontology linkage")

# -----------------------------------------------------------------------------
puts "\n=== Step 7: User (admin: false) Acknowledged POST Retained on Refresh Exception ==="
# -----------------------------------------------------------------------------
$cache_refresh_log.clear
$http_post_log.clear
$fail_cache_refresh[:user] = true

user_raised = false
begin
  harness.create_user(OpenStruct.new(username: 'ack_user_fail', password: 'password', to_h: { username: 'ack_user_fail', password: 'password' }), admin: false)
rescue CacheRefreshException
  user_raised = true
end

assert(user_raised, "create_user propagates CacheRefreshException on fallible cache refresh")
assert(TestResourceOwnership.owned?(:user, 'ack_user_fail'), "Acknowledged User POST username retained in ownership registry")
assert(!TestResourceOwnership.owned?(:user, 'SEEDED_USER_1'), "Seeded user SEEDED_USER_1 remains unowned")

# Teardown cleans retained user
$fail_cache_refresh.clear
harness.delete_user('ack_user_fail')
assert($datastore.deleted_log.include?([:user, 'ack_user_fail']), "Retained ack_user_fail deleted during cleanup")
assert($datastore.users.key?('SEEDED_USER_1'), "Seeded user survives in datastore")

# Non-admin duplicate never registered
$cache_refresh_log.clear
dup_user = harness.create_user(OpenStruct.new(username: 'SEEDED_USER_1', password: 'password', to_h: { username: 'SEEDED_USER_1', password: 'password' }), admin: false)
assert(!TestResourceOwnership.owned?(:user, 'SEEDED_USER_1'), "Duplicate user attempt never adopts seeded SEEDED_USER_1")
assert($cache_refresh_log.size == 1, "Duplicate user dispatches cache refresh per SDK contract")

# Positive non-admin creation
$cache_refresh_log.clear
$http_post_log.clear
ok_user = harness.create_user(OpenStruct.new(username: 'ack_user_ok', password: 'secretpassword', to_h: { username: 'ack_user_ok', password: 'secretpassword' }), admin: false)
assert(TestResourceOwnership.owned?(:user, 'ack_user_ok'), "Successful non-admin user is registered as owned")
assert(ok_user.password == 'secretpassword', "User password preserved on returned object")
assert($http_post_log.size == 1, "Non-admin user dispatched exact 1 POST")
assert($cache_refresh_log.size == 1, "Non-admin user dispatched exact 1 cache refresh call")
assert($cache_refresh_log.first == [:user, {}], "User cache refresh called with expected options")

# -----------------------------------------------------------------------------
puts "\n=== Step 8: Faraday Admin-User Creation Status/Body Contract ==="
# -----------------------------------------------------------------------------
# Check 1: Missing admin never POSTs (strict admin_user.apikey lookup)
saved_admin = $datastore.users.delete('admin')
$faraday_post_log.clear
missing_admin_raised = false
begin
  harness.create_user(OpenStruct.new(username: 'unauth_admin', password: 'p', to_h: { username: 'unauth_admin', password: 'p' }), admin: true)
rescue StandardError, NoMethodError
  missing_admin_raised = true
end
assert(missing_admin_raised, "Missing administrator raises before request dispatched")
assert($faraday_post_log.empty?, "Missing admin never dispatches Faraday POST (exact count: 0)")
$datastore.users['admin'] = saved_admin

# Check 2: Faraday admin successful creation without cache refresh
$cache_refresh_log.clear
$faraday_post_log.clear
ok_admin = harness.create_user(OpenStruct.new(username: 'ack_admin_ok', password: 'newadminpassword', to_h: { username: 'ack_admin_ok', password: 'newadminpassword' }), admin: true)
assert(TestResourceOwnership.owned?(:user, 'ack_admin_ok'), "Successful admin user is registered as owned")
assert(ok_admin.password == 'newadminpassword', "Admin user password preserved on returned object")
assert($faraday_post_log.size == 1, "Faraday admin dispatched exactly 1 POST (got: #{$faraday_post_log.size})")
assert($faraday_post_log.first[:headers]["Authorization"] == "apikey token=secret_admin_token", "Faraday admin uses authentic admin apikey header")
assert($cache_refresh_log.empty?, "Original direct admin Faraday POST does not call cache refresh (exact count: 0)")

# Check 3: Faraday admin duplicate rejection via status/body contract
dup_admin = harness.create_user(OpenStruct.new(username: 'admin', password: 'password', to_h: { username: 'admin', password: 'password' }), admin: true)
assert(dup_admin.respond_to?(:errors) && dup_admin.errors, "Faraday 409 duplicate returns user object with errors")
assert(!TestResourceOwnership.owned?(:user, 'admin'), "Admin duplicate rejection never marks seeded admin as owned")

# Check 4: Faraday 3xx redirect is never accepted as creation
$faraday_custom_response = MockFaradayResponse.new(status: 302, body: '<html>Redirect</html>')
redirect_admin = harness.create_user(OpenStruct.new(username: 'redirect_admin', password: 'p', to_h: { username: 'redirect_admin', password: 'p' }), admin: true)
assert(!TestResourceOwnership.owned?(:user, 'redirect_admin'), "Faraday 3xx redirect is never registered as owned")
assert(!TestResourceOwnership.owned?(:user, 'admin'), "Seeded admin never adopted on 3xx redirect")
$faraday_custom_response = nil

# Check 5: Faraday malformed JSON body raises parse error and never adopts fixture
$faraday_custom_response = MockFaradayResponse.new(status: 200, body: '{ malformed json')
bad_body_raised = false
begin
  harness.create_user(OpenStruct.new(username: 'bad_body_admin', password: 'p', to_h: { username: 'bad_body_admin', password: 'p' }), admin: true)
rescue StandardError, JSON::ParserError
  bad_body_raised = true
end
assert(bad_body_raised, "Malformed response body stops/raises without adopting fixture")
assert(!TestResourceOwnership.owned?(:user, 'bad_body_admin'), "Malformed body never registered as owned")
$faraday_custom_response = nil

# Check 6: Faraday 200 with missing created identifier stops/reports unknown rather than returning no-error created_user
$faraday_custom_response = MockFaradayResponse.new(status: 200, body: '{}')
stopped_missing_id = false
begin
  harness.create_user(OpenStruct.new(username: 'missing_id_admin', password: 'p', to_h: { username: 'missing_id_admin', password: 'p' }), admin: true)
rescue StandardError => e
  stopped_missing_id = true
end
assert(stopped_missing_id, "Faraday 200 with missing created identifier stops/reports unknown rather than returning no-error created_user")
assert(!TestResourceOwnership.owned?(:user, 'missing_id_admin'), "Response missing created identifier is never registered")
$faraday_custom_response = nil

# Check 7: Fatal control exceptions (Interrupt / SystemExit) propagate out of admin error-body parse
$faraday_custom_response = MockFaradayResponse.new(status: 400, body: '__TEST_INTERRUPT__')
interrupt_raised = false
begin
  harness.create_user(OpenStruct.new(username: 'test_interrupt', password: 'p', to_h: { username: 'test_interrupt', password: 'p' }), admin: true)
rescue Interrupt
  interrupt_raised = true
end
assert(interrupt_raised, "Fatal Interrupt exception propagates without being swallowed by error-body parse")
$faraday_custom_response = nil

$faraday_custom_response = MockFaradayResponse.new(status: 400, body: '__TEST_SYSTEM_EXIT__')
exit_raised = false
begin
  harness.create_user(OpenStruct.new(username: 'test_sysexit', password: 'p', to_h: { username: 'test_sysexit', password: 'p' }), admin: true)
rescue SystemExit
  exit_raised = true
end
assert(exit_raised, "Fatal SystemExit exception propagates without being swallowed by error-body parse")
$faraday_custom_response = nil

# -----------------------------------------------------------------------------
puts "\n=== Step 9: Actual Helper Unknown No-ID and Nil Responses Stop/Reconcile ==="
# -----------------------------------------------------------------------------
# Actual helper create_ontology with no-ID response: stops clearly, zero submission POSTs, no retry/adoption
$http_post_log.clear
$cache_refresh_log.clear
$http_custom_response = LinkedData::Client::CreatedResponse.new(status: 200) # no id or acronym
stopped_noid_ont = false
begin
  harness.create_ontology({ acronym: 'NOID_ONT', name: 'No ID' }, { URI: 'http://example.org/sub_noid' })
rescue StandardError
  stopped_noid_ont = true
end
$http_custom_response = nil
assert(stopped_noid_ont, "Unknown no-ID ontology response stops clearly for reconciliation")
assert($http_post_log.select { |p| ['/ontologies', 'http://localhost:9393/ontologies'].include?(p[:path]) }.size == 1, "Exactly 1 ontology POST dispatched (no retry)")
assert($http_post_log.select { |p| p[:path].to_s =~ /submissions/ }.size == 0, "Zero submission POSTs dispatched when ontology returns no identity")
assert(!TestResourceOwnership.owned?(:ontology, 'NOID_ONT'), "No-ID ontology never registered in ownership")
assert($cache_refresh_log.empty?, "Zero cache refresh calls on unknown no-ID response")

# Actual helper create_ontology with nil response: stops clearly, zero submission POSTs, no retry/adoption
$http_post_log.clear
$cache_refresh_log.clear
$http_return_nil = true
stopped_nil_ont = false
begin
  harness.create_ontology({ acronym: 'NIL_ONT', name: 'Nil Ont' }, { URI: 'http://example.org/sub_nil' })
rescue StandardError
  stopped_nil_ont = true
end
$http_return_nil = false
assert(stopped_nil_ont, "Unknown nil ontology response stops clearly for reconciliation")
assert($http_post_log.select { |p| ['/ontologies', 'http://localhost:9393/ontologies'].include?(p[:path]) }.size == 1, "Exactly 1 ontology POST dispatched (no retry)")
assert($http_post_log.select { |p| p[:path].to_s =~ /submissions/ }.size == 0, "Zero submission POSTs dispatched when ontology returns nil")
assert(!TestResourceOwnership.owned?(:ontology, 'NIL_ONT'), "Nil ontology never registered in ownership")
assert($cache_refresh_log.empty?, "Zero cache refresh calls on unknown nil response")

# Actual helper create_category with no-ID response
$http_post_log.clear
$cache_refresh_log.clear
$http_custom_response = LinkedData::Client::CreatedResponse.new(status: 200)
stopped_noid_cat = false
begin
  harness.create_category({ acronym: 'NOID_CAT', name: 'No ID Cat' })
rescue StandardError
  stopped_noid_cat = true
end
$http_custom_response = nil
assert(stopped_noid_cat, "Unknown no-ID category response stops clearly for reconciliation")
assert($http_post_log.size == 1, "Category no-ID dispatched exactly 1 POST (no retry)")
assert(!TestResourceOwnership.owned?(:category, 'NOID_CAT'), "No-ID category never registered in ownership")
assert($cache_refresh_log.empty?, "Zero cache refresh calls on unknown no-ID category")

# Actual helper create_category with nil response
$http_post_log.clear
$cache_refresh_log.clear
$http_return_nil = true
stopped_nil_cat = false
begin
  harness.create_category({ acronym: 'NIL_CAT', name: 'Nil Cat' })
rescue StandardError
  stopped_nil_cat = true
end
$http_return_nil = false
assert(stopped_nil_cat, "Unknown nil category response stops clearly for reconciliation")
assert($http_post_log.size == 1, "Category nil dispatched exactly 1 POST (no retry)")
assert(!TestResourceOwnership.owned?(:category, 'NIL_CAT'), "Nil category never registered in ownership")
assert($cache_refresh_log.empty?, "Zero cache refresh calls on unknown nil category")

# -----------------------------------------------------------------------------
puts "\n=== Step 10: Real SDK / Cached Base Contract & Server JSON -> Base Responses (C1) ==="
# -----------------------------------------------------------------------------
# Native library assertion: Base#respond_to? always true, missing reader returns nil
base_inst = LinkedData::Client::Base.new
assert(base_inst.respond_to?(:success?) == true, "SDK Base#respond_to? is ALWAYS true for arbitrary method names")
assert(base_inst.success?.nil?, "SDK Base#success? returns nil via method_missing")
assert(base_inst.respond_to?(:errors) == true, "SDK Base#respond_to?(:errors) is true")
assert(base_inst.errors.nil?, "SDK Base#errors returns nil when no errors")

# Server JSON -> Base separate created response for category
cat_json = JSON.dump({
  '@id' => 'http://localhost:9393/categories/BASE_CAT_OK',
  '@type' => 'http://data.bioontology.org/metadata/Category',
  'id' => 'http://localhost:9393/categories/BASE_CAT_OK',
  'acronym' => 'BASE_CAT_OK',
  'name' => 'Base Cat OK'
})
cat_base_resp = LinkedData::Client::HTTP.object_from_json(cat_json)
assert(cat_base_resp.is_a?(LinkedData::Client::Base), "Category server JSON converts to Base response")
assert(cat_base_resp.respond_to?(:success?) == true, "Category Base response responds to success?")
assert(cat_base_resp.success?.nil?, "Category Base response success? returns nil")
assert(!ApplicationTestHelpers.acknowledged_has_errors?(cat_base_resp), "Category Base response is NOT classified as error")

# Helper create_category with Base response registers BEFORE cache refresh failure
$http_post_log.clear
$cache_refresh_log.clear
$fail_cache_refresh[:category] = true
$datastore.categories['BASE_CAT_OK'] = { acronym: 'BASE_CAT_OK', name: 'Base Cat OK', id: 'http://localhost:9393/categories/BASE_CAT_OK' }
$http_custom_response = cat_base_resp
refresh_raised = false
begin
  harness.create_category({ acronym: 'BASE_CAT_OK', name: 'Base Cat OK' })
rescue CacheRefreshException
  refresh_raised = true
ensure
  $fail_cache_refresh.delete(:category)
  $http_custom_response = nil
end
assert(refresh_raised, "create_category with Base response propagates CacheRefreshException")
assert(TestResourceOwnership.owned?(:category, 'BASE_CAT_OK'), "Base response category retained in ownership registry before refresh failure")

# Clean up the retained category
harness.delete_categories(['BASE_CAT_OK'])
assert(!TestResourceOwnership.owned?(:category, 'BASE_CAT_OK'), "Retained Base response category deleted during cleanup")
assert($datastore.deleted_log.include?([:category, 'BASE_CAT_OK']), "Backend delete occurred for BASE_CAT_OK")
assert(!$datastore.categories.key?('BASE_CAT_OK'), "BASE_CAT_OK row removed from datastore")

# Category known error with Base response refreshes once and never adopts/registers
$http_post_log.clear
$cache_refresh_log.clear
cat_err_base = LinkedData::Client::CreatedResponse.new(status: 400, errors: ['Invalid category payload'])
assert(cat_err_base.respond_to?(:errors) == true, "Error Base response responds to errors")
assert(cat_err_base.errors == ['Invalid category payload'], "Error Base response contains errors")
assert(ApplicationTestHelpers.acknowledged_has_errors?(cat_err_base), "Error Base response is classified as having errors")
$http_custom_response = cat_err_base
err_cat_res = harness.create_category({ acronym: 'BASE_CAT_ERR', name: 'Error Cat' })
$http_custom_response = nil
assert(err_cat_res.errors == ['Invalid category payload'], "create_category returns error model")
assert(!TestResourceOwnership.owned?(:category, 'BASE_CAT_ERR'), "Error Base response never registered in ownership")
assert($cache_refresh_log.size == 1, "Error Base response dispatches cache refresh once per SDK contract")

# Identity-less Base response (no acronym, no id, no errors): must stop and raise for reconciliation
$http_post_log.clear
$cache_refresh_log.clear
noid_base_resp = LinkedData::Client::Base.new
assert(noid_base_resp.respond_to?(:success?) == true, "Identity-less Base responds to success?")
assert(noid_base_resp.success?.nil?, "Identity-less Base success? returns nil")
assert(!ApplicationTestHelpers.acknowledged_has_errors?(noid_base_resp), "Identity-less Base is NOT classified as known error")
$http_custom_response = noid_base_resp
stopped_noid_base = false
begin
  harness.create_category({ acronym: 'NOID_BASE_CAT', name: 'No ID Base' })
rescue StandardError => e
  stopped_noid_base = true if e.message.include?("missing created identity")
ensure
  $http_custom_response = nil
end
assert(stopped_noid_base, "Identity-less Base response stops/raises reconciliation exception rather than taking error branch")
assert(!TestResourceOwnership.owned?(:category, 'NOID_BASE_CAT'), "Identity-less Base response never registered")
assert($cache_refresh_log.empty?, "Identity-less Base response never dispatches cache refresh")

# Ontology and Submission creation with Base responses: preserves submission creation
$http_post_log.clear
$cache_refresh_log.clear
ont_base = LinkedData::Client::CreatedResponse.new(
  id: "http://localhost:9393/ontologies/BASE_ONT_OK",
  acronym: "BASE_ONT_OK",
  name: "Base Ont OK",
  status: 201
)
sub_base = LinkedData::Client::CreatedResponse.new(
  id: "http://localhost:9393/submissions/sub_base_1",
  ontology: "http://localhost:9393/ontologies/BASE_ONT_OK",
  status: 201
)
$datastore.ontologies['BASE_ONT_OK'] = { acronym: 'BASE_ONT_OK', id: 'http://localhost:9393/ontologies/BASE_ONT_OK' }
$datastore.submissions['http://localhost:9393/submissions/sub_base_1'] = { ontology: 'http://localhost:9393/ontologies/BASE_ONT_OK' }
$http_custom_responses = [ont_base, sub_base]
ont_res, sub_res = harness.create_ontology({ acronym: 'BASE_ONT_OK', name: 'Base Ont OK' }, { URI: 'http://example.org/sub_base_1' })
$http_custom_responses = nil
assert(ont_res.acronym == 'BASE_ONT_OK', "create_ontology succeeds with Base response")
assert(!sub_res.nil?, "Submission is successfully created when ontology response is Base object")
assert(sub_res.id == "http://localhost:9393/submissions/sub_base_1", "Submission Base response preserves exact ID")
assert(TestResourceOwnership.owned?(:ontology, 'BASE_ONT_OK'), "Base ontology registered in ownership")
assert(TestResourceOwnership.owned?(:submission, sub_base), "Base submission registered in ownership")
harness.delete_ontologies(['BASE_ONT_OK'])
assert(!TestResourceOwnership.owned?(:ontology, 'BASE_ONT_OK'), "Base ontology cleaned up")

# Pinned Real SDK Typed OntologySubmission Lifecycle Domain Status Regression
if REAL_SDK_MODE
  # 1. Converted via actual SDK converter LinkedData::Client::HTTP.object_from_json
  real_sub_payload = JSON.dump({
    '@id' => 'http://localhost:9393/ontologies/REAL_ONT_SUB/submissions/1',
    '@type' => 'http://data.bioontology.org/metadata/OntologySubmission',
    'id' => 'http://localhost:9393/ontologies/REAL_ONT_SUB/submissions/1',
    'ontology' => 'http://localhost:9393/ontologies/REAL_ONT_SUB',
    'status' => 'production'
  })
  typed_sub_dto = LinkedData::Client::HTTP.object_from_json(real_sub_payload)
  assert(typed_sub_dto.is_a?(LinkedData::Client::Models::OntologySubmission), "Real converter returns actual OntologySubmission model")
  assert(typed_sub_dto.is_a?(LinkedData::Client::Base), "Typed submission is an instance of Base")
  assert(typed_sub_dto.status == 'production', "Typed submission retains lifecycle status 'production'")
  assert(typed_sub_dto.errors.nil?, "Typed submission has nil errors")

  # 2. Domain lifecycle status 'production' is positive ACK, not HTTP error
  assert(!ApplicationTestHelpers.acknowledged_has_errors?(typed_sub_dto), "Typed OntologySubmission lifecycle 'production' is domain data and NOT classified as error")
  assert(ApplicationTestHelpers.acknowledged_success?(typed_sub_dto, :submission), "Typed OntologySubmission acknowledged_success? is true")
  assert(ApplicationTestHelpers.extract_created_identity(typed_sub_dto, :submission) == 'http://localhost:9393/ontologies/REAL_ONT_SUB/submissions/1', "extract_created_identity extracts exact submission ID")

  # 3. Registration BEFORE induced cache refresh failure
  $http_post_log.clear
  $cache_refresh_log.clear
  $fail_cache_refresh[:ontologysubmission] = true
  $http_custom_response = typed_sub_dto
  sub_input = LinkedData::Client::Models::OntologySubmission.new(values: {
    ontology: 'http://localhost:9393/ontologies/REAL_ONT_SUB'
  })
  refresh_raised = false
  begin
    ApplicationTestHelpers.acknowledged_save(sub_input, :submission)
  rescue CacheRefreshException
    refresh_raised = true
  ensure
    $fail_cache_refresh.delete(:ontologysubmission)
    $http_custom_response = nil
  end
  assert(refresh_raised, "acknowledged_save with typed submission propagates CacheRefreshException")
  assert(TestResourceOwnership.owned?(:submission, typed_sub_dto), "Positive production lifecycle DTO registered in ownership BEFORE cache refresh failure")
  assert(TestResourceOwnership.owned_resources(:submission).include?(typed_sub_dto), "Ownership registry contains exact typed submission object")

  # 4. Clean up submission via parent ontology deletion cascade (retire_linked_submissions)
  TestResourceOwnership.register(:ontology, 'REAL_ONT_SUB')
  $datastore.ontologies['REAL_ONT_SUB'] = { acronym: 'REAL_ONT_SUB', id: 'http://localhost:9393/ontologies/REAL_ONT_SUB' }
  harness.delete_ontologies(['REAL_ONT_SUB'])
  assert(!TestResourceOwnership.owned?(:submission, typed_sub_dto), "Typed submission retired upon parent ontology deletion")
  assert(!TestResourceOwnership.owned?(:ontology, 'REAL_ONT_SUB'), "Parent ontology cleaned up")

  # 5. Genuine error body on typed submission
  sub_err_payload = JSON.dump({
    '@id' => 'http://localhost:9393/ontologies/REAL_ONT_SUB/submissions/2',
    '@type' => 'http://data.bioontology.org/metadata/OntologySubmission',
    'id' => 'http://localhost:9393/ontologies/REAL_ONT_SUB/submissions/2',
    'ontology' => 'http://localhost:9393/ontologies/REAL_ONT_SUB',
    'status' => 'production',
    'errors' => ['Validation failed: missing description']
  })
  typed_sub_err = LinkedData::Client::HTTP.object_from_json(sub_err_payload)
  assert(ApplicationTestHelpers.acknowledged_has_errors?(typed_sub_err), "Typed submission with errors array is classified as having errors")
  assert(!ApplicationTestHelpers.acknowledged_success?(typed_sub_err, :submission), "Typed submission with errors acknowledged_success? is false")

  # 6. Missing identity on typed submission: stops and raises rather than registering
  sub_noid_payload = JSON.dump({
    '@type' => 'http://data.bioontology.org/metadata/OntologySubmission',
    'status' => 'production'
  })
  typed_sub_noid = LinkedData::Client::HTTP.object_from_json(sub_noid_payload)
  assert(!ApplicationTestHelpers.acknowledged_success?(typed_sub_noid, :submission), "Typed submission without id acknowledged_success? is false")
  $http_custom_response = typed_sub_noid
  stopped_noid = false
  begin
    ApplicationTestHelpers.acknowledged_save(sub_input, :submission)
  rescue StandardError => e
    stopped_noid = true if e.message.include?("missing created identity")
  ensure
    $http_custom_response = nil
  end
  assert(stopped_noid, "Typed submission without id stops and raises missing created identity rather than registering")
  assert(!TestResourceOwnership.owned?(:submission, typed_sub_noid), "Typed submission without id is never registered")
end

# Negative envelope checks: HTTP transport errors and unknown payloads preserve prior classification
http_err_400 = LinkedData::Client::CreatedResponse.new(status: 400, errors: ['Bad Request'])
assert(ApplicationTestHelpers.acknowledged_has_errors?(http_err_400), "HTTP 400 response is classified as having errors")
assert(!ApplicationTestHelpers.acknowledged_success?(http_err_400, :submission), "HTTP 400 acknowledged_success? is false")

http_err_403 = OpenStruct.new(status: 403)
assert(ApplicationTestHelpers.acknowledged_has_errors?(http_err_403), "HTTP 403 envelope is classified as having errors")

http_err_500 = OpenStruct.new(status: 500)
assert(ApplicationTestHelpers.acknowledged_has_errors?(http_err_500), "HTTP 500 envelope is classified as having errors")

http_err_500_str = OpenStruct.new(status: '500')
assert(ApplicationTestHelpers.acknowledged_has_errors?(http_err_500_str), "HTTP '500' string envelope is classified as having errors")

unknown_envelope = OpenStruct.new(id: 'http://localhost:9393/submissions/unknown_1', status: 'production')
assert(ApplicationTestHelpers.acknowledged_has_errors?(unknown_envelope), "Non-submission payload with non-numeric status is classified as error")
assert(!ApplicationTestHelpers.acknowledged_success?(unknown_envelope, :submission), "Non-submission payload with non-numeric status acknowledged_success? is false")

# -----------------------------------------------------------------------------
puts "\n=== Step 11: Actual create_user -> delete_users for Id-Only 201 Response & Canonical URI Bounds (C2) ==="
# -----------------------------------------------------------------------------
# 1. Normal user (admin: false) with id-only 201 response
$http_post_log.clear
$cache_refresh_log.clear
$datastore.deleted_log.clear
$http_custom_response = LinkedData::Client::CreatedResponse.new(
  id: "http://localhost:9393/users/ack_id_only_normal"
)
$datastore.users['ack_id_only_normal'] = { 'id' => "http://localhost:9393/users/ack_id_only_normal", 'apikey' => 'key_norm' }

user_norm_model = OpenStruct.new(username: 'ack_id_only_normal', password: 'password123', to_h: { username: 'ack_id_only_normal', password: 'password123' })
created_norm = harness.create_user(user_norm_model, admin: false)
$http_custom_response = nil

assert(created_norm.id == "http://localhost:9393/users/ack_id_only_normal", "Normal creator returns object with exact response ID")
assert(TestResourceOwnership.owned?(:user, 'ack_id_only_normal'), "Normal creator registers cleanup-compatible username in ownership")
assert(TestResourceOwnership.owned_resources(:user).include?('ack_id_only_normal'), "Ownership registry stores username string")
assert(!TestResourceOwnership.owned_resources(:user).include?('http://localhost:9393/users/ack_id_only_normal'), "Ownership registry does NOT store full URI string")

# Delete users via harness.delete_users
harness.delete_users
assert($datastore.deleted_log.include?([:user, 'ack_id_only_normal']), "delete_users dispatched DELETE for derived username")
assert(!$datastore.users.key?('ack_id_only_normal'), "ack_id_only_normal removed from datastore")
assert($datastore.users.key?('admin'), "admin preserved in datastore after id-only cleanup")
assert($datastore.users.key?('SEEDED_USER_1'), "SEEDED_USER_1 preserved in datastore after id-only cleanup")
assert(!TestResourceOwnership.owned?(:user, 'ack_id_only_normal'), "ack_id_only_normal unregistered after cleanup")

# 2. Admin user (admin: true) with id-only 201 response and typed server payload through original converter
$faraday_post_log.clear
$datastore.deleted_log.clear
$faraday_custom_response = MockFaradayResponse.new(
  status: 201,
  body: JSON.dump({
    'id' => "http://localhost:9393/users/ack_id_only_admin",
    '@type' => "http://data.bioontology.org/metadata/User"
  })
)
$datastore.users['ack_id_only_admin'] = { 'id' => "http://localhost:9393/users/ack_id_only_admin", 'apikey' => 'key_admin_user' }

user_admin_model = OpenStruct.new(username: 'ack_id_only_admin', password: 'adminsecretpass', to_h: { username: 'ack_id_only_admin', password: 'adminsecretpass' })
created_admin = harness.create_user(user_admin_model, admin: true)
$faraday_custom_response = nil

assert(created_admin.id == "http://localhost:9393/users/ack_id_only_admin", "Admin creator returns object with exact response ID")
assert(created_admin.password == 'adminsecretpass', "Admin creator preserves requested password")
assert(TestResourceOwnership.owned?(:user, 'ack_id_only_admin'), "Admin creator registers cleanup-compatible username in ownership")
assert(TestResourceOwnership.owned_resources(:user).include?('ack_id_only_admin'), "Admin creator stores username string in ownership")
assert(!TestResourceOwnership.owned_resources(:user).include?('http://localhost:9393/users/ack_id_only_admin'), "Admin creator does NOT store full URI string")

# Delete admin user via harness.delete_users
harness.delete_users
assert($datastore.deleted_log.include?([:user, 'ack_id_only_admin']), "delete_users dispatched DELETE for admin derived username")
assert(!$datastore.users.key?('ack_id_only_admin'), "ack_id_only_admin removed from datastore")
assert($datastore.users.key?('admin'), "admin preserved in datastore after id-only admin cleanup")
assert($datastore.users.key?('SEEDED_USER_1'), "SEEDED_USER_1 preserved in datastore after id-only admin cleanup")
assert(!TestResourceOwnership.owned?(:user, 'ack_id_only_admin'), "ack_id_only_admin unregistered after cleanup")

# 3. Foreign portal URI: stops and raises reconciliation error, never falls back to request fixture
$faraday_custom_response = MockFaradayResponse.new(
  status: 201,
  body: JSON.dump({ 'id' => "https://data.bioontology.org/users/foreign_user" })
)
stopped_foreign = false
begin
  harness.create_user(OpenStruct.new(username: 'foreign_user', password: 'p', to_h: { username: 'foreign_user', password: 'p' }), admin: true)
rescue StandardError => e
  stopped_foreign = true if e.message.include?("missing created user identifier")
ensure
  $faraday_custom_response = nil
end
assert(stopped_foreign, "Admin creator stops/reconciles when response ID is from foreign portal")
assert(!TestResourceOwnership.owned?(:user, 'foreign_user'), "Foreign portal user never registered in ownership")

# 4. URI with query: stops and raises reconciliation error
$faraday_custom_response = MockFaradayResponse.new(
  status: 201,
  body: JSON.dump({ 'id' => "http://localhost:9393/users/user_with_query?token=xyz" })
)
stopped_query = false
begin
  harness.create_user(OpenStruct.new(username: 'user_with_query', password: 'p', to_h: { username: 'user_with_query', password: 'p' }), admin: true)
rescue StandardError => e
  stopped_query = true if e.message.include?("missing created user identifier")
ensure
  $faraday_custom_response = nil
end
assert(stopped_query, "Admin creator stops/reconciles when response ID contains query string")
assert(!TestResourceOwnership.owned?(:user, 'user_with_query'), "User with query never registered in ownership")

# 5. URI with fragment: stops and raises reconciliation error
$faraday_custom_response = MockFaradayResponse.new(
  status: 201,
  body: JSON.dump({ 'id' => "http://localhost:9393/users/user_with_frag#hash" })
)
stopped_frag = false
begin
  harness.create_user(OpenStruct.new(username: 'user_with_frag', password: 'p', to_h: { username: 'user_with_frag', password: 'p' }), admin: true)
rescue StandardError => e
  stopped_frag = true if e.message.include?("missing created user identifier")
ensure
  $faraday_custom_response = nil
end
assert(stopped_frag, "Admin creator stops/reconciles when response ID contains URL fragment")
assert(!TestResourceOwnership.owned?(:user, 'user_with_frag'), "User with fragment never registered in ownership")

# 6. URI with wrong collection path: stops and raises reconciliation error
$faraday_custom_response = MockFaradayResponse.new(
  status: 201,
  body: JSON.dump({ 'id' => "http://localhost:9393/ontologies/user_wrong_path" })
)
stopped_wrong_path = false
begin
  harness.create_user(OpenStruct.new(username: 'user_wrong_path', password: 'p', to_h: { username: 'user_wrong_path', password: 'p' }), admin: true)
rescue StandardError => e
  stopped_wrong_path = true if e.message.include?("missing created user identifier")
ensure
  $faraday_custom_response = nil
end
assert(stopped_wrong_path, "Admin creator stops/reconciles when response ID has wrong collection path")
assert(!TestResourceOwnership.owned?(:user, 'user_wrong_path'), "User with wrong collection path never registered in ownership")

# 7. URI with nested subpath: stops and raises reconciliation error
$faraday_custom_response = MockFaradayResponse.new(
  status: 201,
  body: JSON.dump({ 'id' => "http://localhost:9393/users/user/extra" })
)
stopped_subpath = false
begin
  harness.create_user(OpenStruct.new(username: 'user_extra', password: 'p', to_h: { username: 'user_extra', password: 'p' }), admin: true)
rescue StandardError => e
  stopped_subpath = true if e.message.include?("missing created user identifier")
ensure
  $faraday_custom_response = nil
end
assert(stopped_subpath, "Admin creator stops/reconciles when response ID contains subpath slashes")
assert(!TestResourceOwnership.owned?(:user, 'user_extra'), "User with subpath never registered in ownership")

# 8. URI with userinfo: stops and raises reconciliation error
$faraday_custom_response = MockFaradayResponse.new(
  status: 201,
  body: JSON.dump({ 'id' => "http://user:pass@localhost:9393/users/user_userinfo" })
)
stopped_userinfo = false
begin
  harness.create_user(OpenStruct.new(username: 'user_userinfo', password: 'p', to_h: { username: 'user_userinfo', password: 'p' }), admin: true)
rescue StandardError => e
  stopped_userinfo = true if e.message.include?("missing created user identifier")
ensure
  $faraday_custom_response = nil
end
assert(stopped_userinfo, "Admin creator stops/reconciles when response ID contains userinfo")
assert(!TestResourceOwnership.owned?(:user, 'user_userinfo'), "User with userinfo never registered in ownership")

# 9. Counterexample 1 (%3F): turns into query in interpolated cleanup contract; must reject and stop
$faraday_custom_response = MockFaradayResponse.new(
  status: 201,
  body: JSON.dump({ 'id' => "http://localhost:9393/users/victim%3Fdetail" })
)
stopped_3F = false
begin
  harness.create_user(OpenStruct.new(username: 'victim_3F', password: 'p', to_h: { username: 'victim_3F', password: 'p' }), admin: true)
rescue StandardError => e
  stopped_3F = true if e.message.include?("missing created user identifier")
ensure
  $faraday_custom_response = nil
end
assert(stopped_3F, "Admin creator stops/reconciles when response ID contains %3F (query delimiter)")
assert(!TestResourceOwnership.owned?(:user, 'victim?detail'), "User with %3F never registered in ownership")
assert(!TestResourceOwnership.owned?(:user, 'victim'), "Truncated user from %3F never registered in ownership")

# 10. Counterexample 2 (%23): turns into fragment in interpolated cleanup contract; must reject and stop
$faraday_custom_response = MockFaradayResponse.new(
  status: 201,
  body: JSON.dump({ 'id' => "http://localhost:9393/users/victim%23fragment" })
)
stopped_23 = false
begin
  harness.create_user(OpenStruct.new(username: 'victim_23', password: 'p', to_h: { username: 'victim_23', password: 'p' }), admin: true)
rescue StandardError => e
  stopped_23 = true if e.message.include?("missing created user identifier")
ensure
  $faraday_custom_response = nil
end
assert(stopped_23, "Admin creator stops/reconciles when response ID contains %23 (fragment delimiter)")
assert(!TestResourceOwnership.owned?(:user, 'victim#fragment'), "User with %23 never registered in ownership")
assert(!TestResourceOwnership.owned?(:user, 'victim'), "Truncated user from %23 never registered in ownership")

# 11. Counterexample 3 (%2F): turns into subpath in interpolated cleanup contract; must reject and stop
$faraday_custom_response = MockFaradayResponse.new(
  status: 201,
  body: JSON.dump({ 'id' => "http://localhost:9393/users/a%2Fb" })
)
stopped_2F = false
begin
  harness.create_user(OpenStruct.new(username: 'subpath_2F', password: 'p', to_h: { username: 'subpath_2F', password: 'p' }), admin: true)
rescue StandardError => e
  stopped_2F = true if e.message.include?("missing created user identifier")
ensure
  $faraday_custom_response = nil
end
assert(stopped_2F, "Admin creator stops/reconciles when response ID contains %2F (path delimiter)")
assert(!TestResourceOwnership.owned?(:user, 'a/b'), "User with %2F never registered in ownership")

# 12. Counterexample 4 (%252F): retains ambiguous extra encoding; must reject and stop
$faraday_custom_response = MockFaradayResponse.new(
  status: 201,
  body: JSON.dump({ 'id' => "http://localhost:9393/users/a%252Fb" })
)
stopped_252F = false
begin
  harness.create_user(OpenStruct.new(username: 'extra_252F', password: 'p', to_h: { username: 'extra_252F', password: 'p' }), admin: true)
rescue StandardError => e
  stopped_252F = true if e.message.include?("missing created user identifier")
ensure
  $faraday_custom_response = nil
end
assert(stopped_252F, "Admin creator stops/reconciles when response ID contains ambiguous %252F encoding")
assert(!TestResourceOwnership.owned?(:user, 'a%2Fb'), "User with %252F never registered in ownership")

# 13. Dot / Double-dot paths: must reject and stop
$faraday_custom_response = MockFaradayResponse.new(
  status: 201,
  body: JSON.dump({ 'id' => "http://localhost:9393/users/." })
)
stopped_dot = false
begin
  harness.create_user(OpenStruct.new(username: 'dot_user', password: 'p', to_h: { username: 'dot_user', password: 'p' }), admin: true)
rescue StandardError => e
  stopped_dot = true if e.message.include?("missing created user identifier")
ensure
  $faraday_custom_response = nil
end
assert(stopped_dot, "Admin creator stops/reconciles when response ID is dot path")
assert(!TestResourceOwnership.owned?(:user, '.'), "Dot user never registered in ownership")

# 14. User URI with plus in username preserves exact target without double decoding
$faraday_custom_response = MockFaradayResponse.new(
  status: 201,
  body: JSON.dump({ 'id' => "http://localhost:9393/users/user+tag" })
)
$datastore.users['user+tag'] = { 'id' => "http://localhost:9393/users/user+tag", 'apikey' => 'key_plus' }
user_plus_model = OpenStruct.new(username: 'user+tag', password: 'p', to_h: { username: 'user+tag', password: 'p' })
created_plus = harness.create_user(user_plus_model, admin: true)
$faraday_custom_response = nil
assert(TestResourceOwnership.owned?(:user, 'user+tag'), "User with + in username preserves literal plus")
harness.delete_users
assert($datastore.deleted_log.include?([:user, 'user+tag']), "delete_users deleted user+tag preserving literal plus")

# 15. User URI with literal+plus preserving literal plus
$faraday_custom_response = MockFaradayResponse.new(
  status: 201,
  body: JSON.dump({ 'id' => "http://localhost:9393/users/literal+plus" })
)
$datastore.users['literal+plus'] = { 'id' => "http://localhost:9393/users/literal+plus", 'apikey' => 'key_literal_plus' }
user_literal_plus_model = OpenStruct.new(username: 'literal+plus', password: 'p', to_h: { username: 'literal+plus', password: 'p' })
created_literal_plus = harness.create_user(user_literal_plus_model, admin: true)
$faraday_custom_response = nil
assert(TestResourceOwnership.owned?(:user, 'literal+plus'), "User literal+plus preserves exact literal plus")
harness.delete_users
assert($datastore.deleted_log.include?([:user, 'literal+plus']), "delete_users deleted literal+plus preserving literal plus")

# 16. User URI with ordinary percent-escaped safe name (%2D is safe hyphen)
$faraday_custom_response = MockFaradayResponse.new(
  status: 201,
  body: JSON.dump({ 'id' => "http://localhost:9393/users/user%2Dtag" })
)
$datastore.users['user-tag'] = { 'id' => "http://localhost:9393/users/user-tag", 'apikey' => 'key_hyphen' }
user_hyphen_model = OpenStruct.new(username: 'user-tag', password: 'p', to_h: { username: 'user-tag', password: 'p' })
created_hyphen = harness.create_user(user_hyphen_model, admin: true)
$faraday_custom_response = nil
assert(TestResourceOwnership.owned?(:user, 'user-tag'), "User with safe %2D resolves to unescaped safe hyphen")
harness.delete_users
assert($datastore.deleted_log.include?([:user, 'user-tag']), "delete_users deleted safe hyphen user")

# 17. Absolute collection URI from metadata resolves correctly
assert(LinkedData::Client::Models::User.collection_path == "http://localhost:9393/users", "Collection.collection_path returns pinned absolute URI from API metadata")
meta_derived = ApplicationTestHelpers.derive_username_from_user_uri("http://localhost:9393/users/meta_test_user")
assert(meta_derived == "meta_test_user", "derive_username_from_user_uri resolves correctly against pinned absolute collection URI")

# 18. Basepath mismatch safely rejected
old_url = LinkedData::Client.settings.rest_url
begin
  LinkedData::Client.settings.rest_url = "http://localhost:9393/api"
  basepath_mismatch = ApplicationTestHelpers.derive_username_from_user_uri("http://localhost:9393/users/mismatch_user")
  assert(basepath_mismatch.nil?, "derive_username_from_user_uri safely rejects collection URI outside configured basepath")
ensure
  LinkedData::Client.settings.rest_url = old_url
end

# 19. Unavailable / error metadata safely rejected without guessing /users fallback
coll_method = LinkedData::Client::Models::User.method(:collection_path)
begin
  LinkedData::Client::Models::User.define_singleton_method(:collection_path) { raise StandardError, "API metadata down" }
  unavail_res = ApplicationTestHelpers.derive_username_from_user_uri("http://localhost:9393/users/unavail_user")
  assert(unavail_res.nil?, "derive_username_from_user_uri safely rejects unavailable metadata without guessing /users fallback")
ensure
  LinkedData::Client::Models::User.define_singleton_method(:collection_path, &coll_method)
end

# 20. Positive synthetic explicit username with @ (non-URI direct return): succeeds and cleans up without contact
$faraday_custom_response = MockFaradayResponse.new(
  status: 201,
  body: JSON.dump({ 'username' => "synthetic_test_user@example.org" })
)
$datastore.users['synthetic_test_user@example.org'] = { 'id' => "http://localhost:9393/users/synthetic_test_user@example.org", 'apikey' => 'key_synthetic_at' }
user_at_model = OpenStruct.new(username: 'synthetic_test_user@example.org', password: 'p', to_h: { username: 'synthetic_test_user@example.org', password: 'p' })
created_at_user = harness.create_user(user_at_model, admin: true)
$faraday_custom_response = nil
assert(TestResourceOwnership.owned?(:user, 'synthetic_test_user@example.org'), "Positive synthetic explicit username with @ is owned without restriction")
harness.delete_users
assert($datastore.deleted_log.include?([:user, 'synthetic_test_user@example.org']), "delete_users dispatched DELETE for synthetic username with @")
assert(!$datastore.users.key?('synthetic_test_user@example.org'), "synthetic_test_user@example.org removed from datastore")
assert(!TestResourceOwnership.owned?(:user, 'synthetic_test_user@example.org'), "synthetic_test_user@example.org unregistered after cleanup")

# -----------------------------------------------------------------------------
puts "\n=== Step 12: Final Teardown Preserves All Seeded Resources ==="
# -----------------------------------------------------------------------------
harness.cleanup_owned_resources!

assert($datastore.categories.key?('SEEDED_CAT_1'), "SEEDED_CAT_1 preserved after full cleanup")
assert($datastore.groups.key?('SEEDED_GRP_1'), "SEEDED_GRP_1 preserved after full cleanup")
assert($datastore.agents.key?('http://localhost:9393/agents/SEEDED_AGENT_1'), "SEEDED_AGENT_1 preserved after full cleanup")
assert($datastore.ontologies.key?('SEEDED_ONT_1'), "SEEDED_ONT_1 preserved after full cleanup")
assert($datastore.users.key?('admin'), "admin preserved after full cleanup")
assert($datastore.users.key?('SEEDED_USER_1'), "SEEDED_USER_1 preserved after full cleanup")
assert(TestResourceOwnership.empty?, "Ownership registry is completely empty after cleanup")

# -----------------------------------------------------------------------------
# Summary
# -----------------------------------------------------------------------------
puts "\n============================================================"
if $failures.empty?
  puts "ALL CHECKS PASSED: ONTO-T-Q06 acknowledged-create/cache ordering verified offline."
  exit 0
else
  puts "FAILED with #{$failures.size} failure(s):"
  $failures.each { |f| puts "  - #{f}" }
  exit 1
end
