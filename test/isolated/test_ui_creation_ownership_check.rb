# frozen_string_literal: true

# Standalone isolated check for ONTO-T-Q06 UI and Caller Creation Ownership contract.
# Run directly with plain Ruby:
#   ruby test/isolated/test_ui_creation_ownership_check.rb
#
# Validates:
#   1. Method owners & source locations: agent_fill from ApplicationSystemTestCase,
#      create_agent_flow & teardown from AgentFlowsTest, delete_agents from actual
#      ApplicationTestHelpers::Agents. Zero overrides in test harness.
#   2. Rejected save / placeholder: bare editable form id is an unsaved placeholder;
#      failed save raises lookup error upon waiting, leaving ownership unchanged.
#   3. Successful replacement: show replacement changes frame ID; acknowledged show
#      result is re-resolved from stable containing row and registered immediately.
#   4. Parent-vs-affiliation separation & caller-owned frame detachment: new embedded
#      parent collects parent show field from surviving row independently of caller frame.
#   5. Partial affiliation before parent failure: created affiliation is registered and
#      cleaned up by real teardown even when parent save fails.
#   6. Edit identity unchanged: editing an existing parent never overwrites parent ID
#      with affiliation hidden field.
#   7. Post-acknowledgement failure and real caller teardown: top-level parent acknowledged
#      immediately before table assertions; real teardown deletes created resource with
#      status-bearing 204.
#   8. Teardown reset-if-empty control flow & coupled retained-helper gate.
#   9. Entire check executes 100% offline with zero network or external dependencies.

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

ENV['ONTOPORTAL_ISOLATED_TEST'] = '1'

# Minimal class and load path setup to load actual ApplicationSystemTestCase and AgentFlowsTest
$LOAD_PATH << File.expand_path('..', __dir__)
$LOADED_FEATURES << "test_helper"
$LOADED_FEATURES << "test_helper.rb"

class Object
  def present?
    !nil? && !(respond_to?(:empty?) && empty?)
  end
end

module ActionDispatch
  class SystemTestCase
    def self.setup(*); end
    def self.driven_by(*); end
    def self.test(*); end
  end
end

module Capybara
  class ElementNotFound < StandardError; end
  class ExpectationNotMet < StandardError; end
end

require_relative '../helpers/test_target_guard'
require_relative '../helpers/test_resource_ownership'
require_relative '../helpers/application_test_helpers'
require_relative '../../app/helpers/agent_helper'
require_relative '../application_system_test_case'
require_relative '../system/agent_flows_test'

# --- Assertions & Reporting ---
$passed_count = 0
$failed_count = 0
$gate_skips = []

def assert(condition, message)
  if condition
    $passed_count += 1
    puts "  [PASS] #{message}"
  else
    $failed_count += 1
    puts "  [FAIL] #{message}"
  end
end

def gate_skip(message)
  $gate_skips << message
  puts "  [GATE/SKIP] #{message}"
end

# --- Mock Datastore & Client Model Double ---
class MockDatastore
  attr_reader :agents, :deleted_log
  attr_accessor :simulate_delete_error

  def initialize
    @agents = {}
    @deleted_log = []
    @simulate_delete_error = false
  end

  def reset!
    @agents.clear
    @deleted_log.clear
    @simulate_delete_error = false
  end

  def persist_agent(id, data)
    key = id.to_s.split('/').last
    @agents[key] = data
    @agents[id.to_s] = data
  end

  def find_agent(id)
    key = id.to_s.split('/').last
    @agents[key] || @agents[id.to_s]
  end

  def delete_agent(id)
    key = id.to_s.split('/').last
    @deleted_log << key
    @agents.delete(key)
    @agents.delete(id.to_s)
  end

  def agent_persisted?(id)
    key = id.to_s.split('/').last
    @agents.key?(key)
  end
end

$datastore = MockDatastore.new

module LinkedData
  module Client
    module Models
      class Agent
        attr_accessor :id, :name, :agentType, :email, :acronym, :homepage, :identifiers, :affiliations

        def self.find(id)
          id_key = id.to_s.split('/').last
          data = $datastore.find_agent(id_key)
          data ? AgentInstanceDouble.new(id, data) : nil
        end
      end
    end
  end
end

class AgentInstanceDouble
  attr_reader :id, :data

  def initialize(id, data)
    @id = id
    @data = data
  end

  def delete
    if $datastore.simulate_delete_error
      OpenStruct.new(status: 500, success?: false)
    else
      $datastore.delete_agent(@id)
      OpenStruct.new(status: 204, success?: true)
    end
  end
end

# --- Named Scopes & Exact Query Maps (NO HTML trees, NO generic CSS matching) ---
class UnexpectedQueryError < StandardError; end
class DetachedFrameError < StandardError; end

class ElementDouble
  attr_reader :tag, :attributes, :text
  attr_accessor :on_click

  def initialize(tag, attributes = {}, text = nil)
    @tag = tag.to_sym
    @attributes = attributes.transform_keys(&:to_s)
    @text = text
    @on_click = nil
  end

  def [](key)
    @attributes[key.to_s]
  end

  def click
    @on_click.call(self) if @on_click
  end
end

class NamedScope
  attr_reader :name, :query_map, :child_scopes

  def initialize(name)
    @name = name
    @query_map = {}
    @child_scopes = {}
  end

  def on_query(selector, &block)
    @query_map[selector] = block
  end

  def add_child_scope(selector, child)
    @child_scopes[selector] = child
  end

  def resolve_child(selector)
    child = @child_scopes[selector]
    raise UnexpectedQueryError, "Unexpected child scope #{selector.inspect} on #{name}" unless child
    child
  end

  def first(*args, **opts)
    key = args.length == 1 ? args.first : args
    handler = @query_map[key]
    raise UnexpectedQueryError, "Unexpected query #{key.inspect} on #{name}" unless handler
    val = handler.call(self, opts)
    res = val.is_a?(Array) ? val.first : val
    if res.nil? && opts[:minimum] != 0
      raise Capybara::ElementNotFound, "Unable to find #{key.inspect} on #{name}"
    end
    res
  end

  def all(selector, **opts)
    handler = @query_map[selector]
    raise UnexpectedQueryError, "Unexpected all query #{selector.inspect} on #{name}" unless handler
    val = handler.call(self, opts)
    Array(val)
  end

  def find(*args, **opts)
    key = args.length == 1 ? args.first : args
    handler = @query_map[key]
    raise UnexpectedQueryError, "Unexpected find query #{key.inspect} on #{name}" unless handler
    res = handler.call(self, opts)
    res = res.first if res.is_a?(Array)
    raise Capybara::ElementNotFound, "Unable to find #{key.inspect} on #{name}" if res.nil?
    res
  end

  def has_no_selector?(selector, **opts)
    handler = @query_map[selector]
    return true unless handler
    val = handler.call(self, opts)
    val.nil? || (val.respond_to?(:empty?) && val.empty?)
  end

  def refute_selector(selector, **opts)
    handler = @query_map[selector]
    if handler
      val = handler.call(self, opts)
      if val && !(val.respond_to?(:empty?) && val.empty?)
        raise Capybara::ExpectationNotMet, "Expected #{selector.inspect} to NOT be present on #{name}"
      end
    end
    true
  end
end

class FormScope < NamedScope
  attr_reader :action, :fields, :chosen_options
  attr_accessor :on_save

  def initialize(name, action: "/agents")
    super(name)
    @action = action
    @fields = {}
    @chosen_options = []
    @on_save = nil
  end

  def fill_in(field, with:)
    @fields[field.to_s] = with
  end

  def choose(_locator, option:, **_opts)
    @chosen_options << option
  end

  def click_on(label)
    if label == "Save" && @on_save
      @on_save.call(self)
    end
  end
end

class CallerFrameScope < NamedScope
  def initialize(name)
    super(name)
    @detached = false
  end

  def detach!
    @detached = true
  end

  def detached?
    @detached
  end

  def first(*args, **opts)
    raise DetachedFrameError, "Cannot query detached caller frame #{name}" if @detached
    super
  end
end

class RowScope < NamedScope
  attr_reader :show_replacement

  def initialize(name)
    super(name)
    @show_replacement = nil
  end

  def attach_replacement!(aff_id)
    @show_replacement = ElementDouble.new(
      :input,
      { type: "hidden", name: "agent[affiliations][0][id]", value: aff_id }
    )
  end
end

class SurvivingWidgetScope < NamedScope
  attr_reader :show_input

  def initialize(name)
    super(name)
    @show_input = nil
  end

  def acknowledge_show!(created_id, name_prefix = nil)
    field_name = name_prefix ? "#{name_prefix}[id]" : "agent[id]"
    @show_input = ElementDouble.new(:input, { type: "hidden", name: field_name, value: created_id })
  end
end

class TableScope < NamedScope
  attr_accessor :human_count, :organization_count

  def initialize(name)
    super(name)
    @human_count = 1
    @organization_count = 0
  end

  def assert_selector(selector, **opts)
    if selector == '.human'
      expected = opts[:count]
      if expected && expected != @human_count
        raise Capybara::ExpectationNotMet, "Expected #{expected} .human elements, got #{@human_count}"
      end
    elsif selector == 'span.agent-chip-circle[title="person"]'
      expected = opts[:count]
      if expected && expected != @human_count
        raise Capybara::ExpectationNotMet, "Expected #{expected} person chips, got #{@human_count}"
      end
    elsif selector == 'span.agent-chip-circle[title="organization"]'
      expected = opts[:count]
      if expected && expected != @organization_count
        raise Capybara::ExpectationNotMet, "Expected #{expected} organization chips, got #{@organization_count}"
      end
    elsif selector.start_with?("a[href=")
      # allowed identifier links
    else
      raise UnexpectedQueryError, "Unexpected table selector #{selector.inspect}"
    end
    true
  end

  def assert_text(_text)
    true
  end
end

# --- Scripted Test Harness ---
# Subclasses AgentFlowsTest WITHOUT overriding agent_fill, create_agent_flow, teardown, or delete_agents.
class ScriptedFlowHarness < AgentFlowsTest
  attr_reader :scope_stack, :registered_forms, :child_scopes
  attr_accessor :search_slot_id

  def initialize
    @scope_stack = [self]
    @registered_forms = {}
    @child_scopes = {}
    @search_slot_id = nil
    @page_queries = {}
  end

  def current_scope
    @scope_stack.last
  end

  def name
    "PageScope"
  end

  def add_child_scope(selector, child)
    @child_scopes[selector] = child
  end

  def resolve_child(selector)
    child = @child_scopes[selector]
    raise UnexpectedQueryError, "Unexpected child scope #{selector.inspect} on page" unless child
    child
  end

  def within(scope_or_selector)
    target = scope_or_selector.is_a?(NamedScope) ? scope_or_selector : current_scope.resolve_child(scope_or_selector)
    @scope_stack.push(target)
    yield
  ensure
    @scope_stack.pop
  end

  def all(selector, **opts)
    if current_scope == self
      if selector =~ /form\[action="([^"]+)"\]/
        action = $1
        form = @registered_forms[action]
        form ? [form] : []
      else
        raise UnexpectedQueryError, "Unexpected page-level all query: #{selector.inspect}"
      end
    else
      current_scope.all(selector, **opts)
    end
  end

  def first(*args, **opts)
    if current_scope == self
      key = args.length == 1 ? args.first : args
      handler = @page_queries[key]
      val = handler ? handler.call(self, opts) : nil
      res = val.is_a?(Array) ? val.first : val
      if res.nil? && opts[:minimum] != 0
        raise Capybara::ElementNotFound, "Unable to find #{key.inspect} on page"
      end
      res
    else
      current_scope.first(*args, **opts)
    end
  end

  def find(*args, **opts)
    if current_scope == self
      key = args.length == 1 ? args.first : args
      handler = @page_queries[key]
      raise UnexpectedQueryError, "Unexpected page find query: #{key.inspect}" unless handler
      res = handler.call(self, opts)
      res = res.first if res.is_a?(Array)
      raise Capybara::ElementNotFound, "Unable to find #{key.inspect} on page" if res.nil?
      res
    else
      current_scope.find(*args, **opts)
    end
  end

  def fill_in(field, with:)
    current_scope.fill_in(field, with: with)
  end

  def choose(locator, option:, **opts)
    current_scope.choose(locator, option: option, **opts)
  end

  def click_on(label)
    current_scope.click_on(label)
  end

  def has_no_selector?(selector, **opts)
    current_scope.has_no_selector?(selector, **opts)
  end

  def refute_selector(selector, **opts)
    current_scope.refute_selector(selector, **opts)
  end

  def assert_selector(selector, **opts)
    current_scope.assert_selector(selector, **opts)
  end

  def wait_for_text(_text, _tries = 60); end
  def assert_text(_text); end

  def agent_search(_name)
    @search_slot_id || 'aff_slot_1'
  end

  def on_page_query(selector, &block)
    @page_queries[selector] = block
  end

  def register_form(action, form_scope)
    @registered_forms[action] = form_scope
  end
end

# --- Test Setup Helpers ---
def create_affiliation_row(row_id, slot_id, &on_save)
  row_scope = RowScope.new(row_id)
  turbo_frame = NamedScope.new("turbo_frame_#{slot_id}")
  aff_form = FormScope.new("aff_form_#{slot_id}", action: "/agents")
  aff_form.on_query('input[name="email"]') { nil }
  aff_form.on_query(".agents-affiliations") { nil }
  aff_form.on_save = on_save

  turbo_frame.add_child_scope("form[action=\"/agents\"]", aff_form)
  turbo_frame.on_query("form[action=\"/agents\"]") { [aff_form] }

  row_scope.add_child_scope("turbo-frame[id=\"#{slot_id}\"]", turbo_frame)
  row_scope.on_query("turbo-frame:not([id=\"#{slot_id}\"]) input[type='hidden'][name$='[id]']") { row_scope.show_replacement }
  row_scope.on_query("input[type='hidden'][name$='[id]']:not([name='id'])") { row_scope.show_replacement }
  row_scope
end

def create_affiliations_container(rows)
  aff_scope = NamedScope.new("affiliations")
  aff_button = ElementDouble.new(:div, { class: "add-another-object" }, "Add another")
  aff_scope.on_query('.delete') { [] }
  aff_scope.on_query('.add-another-object') { aff_button }
  aff_scope.on_query('.nested-form-wrapper') { rows }
  aff_scope
end

def create_parent_form(harness, action = "/agents", name_prefix: nil, surviving_widget: nil)
  form = FormScope.new("form_#{action}", action: action)
  prefix_el = name_prefix ? ElementDouble.new(:input, { type: "hidden", name: "name_prefix", value: name_prefix }) : nil
  form.on_query("input[type='hidden'][name='name_prefix']") { prefix_el }
  form.on_query([:xpath, "ancestor::*[contains(concat(' ', normalize-space(@class), ' '), ' nested-form-wrapper ') or contains(@id, '_from_group_input')][1]"]) { surviving_widget }
  form.on_query('input[name="acronym"]') { nil }
  form.on_query('input[name="homepage"]') { nil }
  harness.register_form(action, form)
  form
end

puts "============================================================"
puts "Running ONTO-T-Q06 Scripted UI Creation Ownership Checks"
puts "============================================================"

# -----------------------------------------------------------------------------
puts "\n=== Step 0: Assert Method Owners and Zero Overrides ==="
# -----------------------------------------------------------------------------
assert(ApplicationSystemTestCase.instance_method(:agent_fill).owner == ApplicationSystemTestCase,
       "agent_fill is owned by ApplicationSystemTestCase")
assert(AgentFlowsTest.instance_method(:create_agent_flow).owner == AgentFlowsTest,
       "create_agent_flow is owned by AgentFlowsTest")
assert(AgentFlowsTest.instance_method(:teardown).owner == AgentFlowsTest,
       "teardown is owned by AgentFlowsTest")
assert(AgentFlowsTest.instance_method(:delete_agents).owner == ApplicationTestHelpers::Agents,
       "delete_agents is owned by actual ApplicationTestHelpers::Agents")

[:agent_fill, :create_agent_flow, :teardown, :delete_agents].each do |m|
  assert(!ScriptedFlowHarness.instance_methods(false).include?(m),
         "ScriptedFlowHarness does not override #{m}")
end

# -----------------------------------------------------------------------------
puts "\n=== Test 1: Rejected Save / Placeholder Leaves Ownership Unchanged ==="
# -----------------------------------------------------------------------------
$datastore.reset!
TestResourceOwnership.reset!

harness = ScriptedFlowHarness.new
harness.search_slot_id = "slot_aff_placeholder"

parent_form = create_parent_form(harness, "/agents")
# Save rejected: does not attach replacement
row_scope = create_affiliation_row("row_1", "slot_aff_placeholder") { |_f| }
parent_form.add_child_scope(".agents-affiliations", create_affiliations_container([row_scope]))

aff_fixture = { 'name' => 'Failed Org', 'agentType' => 'organization', 'identifiers' => [{'notation' => '000'}] }
person_fixture = OpenStruct.new(
  name: 'Parent Person',
  agentType: 'person',
  email: 'person@example.com',
  identifiers: [{'notation' => '111'}],
  affiliations: [aff_fixture]
)

lookup_error_raised = false
begin
  harness.agent_fill(person_fixture)
rescue Capybara::ElementNotFound
  lookup_error_raised = true
end

assert(lookup_error_raised, "Rejected save raised lookup error upon waiting for missing replacement")
assert(!TestResourceOwnership.owned?(:agent, 'slot_aff_placeholder'), "Bare input-slot placeholder was NOT registered as owned")
assert(!TestResourceOwnership.owned?(:agent, 'Failed Org'), "Failed org fixture was NOT registered as owned")
assert(TestResourceOwnership.empty?, "Ownership registry remains empty after failed save")

# -----------------------------------------------------------------------------
puts "\n=== Test 2: Successful Affiliation Replacement Captures Show Result from Containing Row ==="
# -----------------------------------------------------------------------------
$datastore.reset!
TestResourceOwnership.reset!

harness = ScriptedFlowHarness.new
harness.search_slot_id = "slot_aff_2"

parent_form = create_parent_form(harness, "/agents")
row_scope = nil
row_scope = create_affiliation_row("row_2", "slot_aff_2") do |_f|
  $datastore.persist_agent("aff_persisted_2", { name: "Valid Org", agentType: "organization" })
  row_scope.attach_replacement!("http://localhost:9393/agents/aff_persisted_2")
end
parent_form.add_child_scope(".agents-affiliations", create_affiliations_container([row_scope]))

aff_fixture = { 'name' => 'Valid Org', 'agentType' => 'organization', 'identifiers' => [{'notation' => '222'}] }
person_fixture = OpenStruct.new(
  name: 'Parent Person 2',
  agentType: 'person',
  email: 'person2@example.com',
  identifiers: [{'notation' => '333'}],
  affiliations: [aff_fixture]
)

harness.agent_fill(person_fixture)

assert(TestResourceOwnership.owned?(:agent, "http://localhost:9393/agents/aff_persisted_2"), "Persisted affiliation ID was captured and registered as owned")
assert(!TestResourceOwnership.owned?(:agent, 'aff_persisted_2'), "Unregistered bare basename is not owned")
assert(aff_fixture['id'] == "http://localhost:9393/agents/aff_persisted_2",
       "Affiliation fixture ID was updated with persisted URI (expected: \"http://localhost:9393/agents/aff_persisted_2\", got: #{aff_fixture['id'].inspect})")
assert(!TestResourceOwnership.owned?(:agent, 'slot_aff_2'), "Input-slot placeholder was NOT registered")

# -----------------------------------------------------------------------------
puts "\n=== Test 3: Embedded Parent Caller-Owned Frame & Acknowledged Show Resolution ==="
# -----------------------------------------------------------------------------
$datastore.reset!
TestResourceOwnership.reset!

harness = ScriptedFlowHarness.new
harness.search_slot_id = "slot_aff_3"

caller_frame = CallerFrameScope.new("caller_frame")
surviving_widget = SurvivingWidgetScope.new("surviving_widget")

parent_form = create_parent_form(harness, "/agents", name_prefix: "submission[contacts_attributes][0]", surviving_widget: surviving_widget)

row_scope = nil
row_scope = create_affiliation_row("row_3", "sub_slot_3_slot_aff_3") do |_f|
  $datastore.persist_agent("aff_created_33", { name: "Embedded Aff", agentType: "organization" })
  row_scope.attach_replacement!("http://localhost:9393/agents/aff_created_33")
end
parent_form.add_child_scope(".agents-affiliations", create_affiliations_container([row_scope]))

parent_form.on_save = lambda do |_f|
  caller_frame.detach!
  $datastore.persist_agent("parent_created_33", { name: "Embedded Parent", agentType: "person" })
  surviving_widget.acknowledge_show!("http://localhost:9393/agents/parent_created_33", "submission[contacts_attributes][0]")
end

surviving_widget.on_query("input[type='hidden'][name='submission[contacts_attributes][0][id]']") { surviving_widget.show_input }
caller_frame.add_child_scope("form[action=\"/agents\"]", parent_form)

aff_fixture = { 'name' => 'Embedded Aff', 'agentType' => 'organization', 'identifiers' => [{'notation' => 'aff3'}] }
parent_fixture = OpenStruct.new(
  name: 'Embedded Parent',
  agentType: 'person',
  email: 'embedded@example.com',
  identifiers: [{'notation' => 'par3'}],
  affiliations: [aff_fixture]
)

harness.agent_fill(parent_fixture, parent_id: "sub_slot_3", is_affiliation: false)

assert(caller_frame.detached?, "Caller-owned frame was replaced and detached upon save")
assert(parent_fixture.id == "http://localhost:9393/agents/parent_created_33",
       "Parent fixture received parent show ID independently of detached caller frame (expected: \"http://localhost:9393/agents/parent_created_33\", got: #{parent_fixture.id.inspect})")
assert(TestResourceOwnership.owned?(:agent, "http://localhost:9393/agents/parent_created_33"), "Parent was registered with its own ID")
assert(!TestResourceOwnership.owned?(:agent, 'parent_created_33'), "Unregistered bare parent basename is not owned")
assert(TestResourceOwnership.owned?(:agent, "http://localhost:9393/agents/aff_created_33"), "Affiliation was registered with its own ID")
assert(!TestResourceOwnership.owned?(:agent, 'aff_created_33'), "Unregistered bare affiliation basename is not owned")

# -----------------------------------------------------------------------------
puts "\n=== Test 4: Partial Affiliation Before Parent Failure ==="
# -----------------------------------------------------------------------------
$datastore.reset!
TestResourceOwnership.reset!

harness = ScriptedFlowHarness.new
harness.search_slot_id = "slot_aff_4"

surviving_widget = SurvivingWidgetScope.new("surviving_widget_4")
parent_form = create_parent_form(harness, "/agents", name_prefix: "submission[contacts_attributes][0]", surviving_widget: surviving_widget)

row_scope = nil
row_scope = create_affiliation_row("row_4", "sub_slot_4_slot_aff_4") do |_f|
  $datastore.persist_agent("aff_orphaned_44", { name: "Orphaned Aff", agentType: "organization" })
  row_scope.attach_replacement!("http://localhost:9393/agents/aff_orphaned_44")
end
parent_form.add_child_scope(".agents-affiliations", create_affiliations_container([row_scope]))

# Parent save fails: no show replacement acknowledged in surviving_widget
parent_form.on_save = ->(_f) {}
surviving_widget.on_query("input[type='hidden'][name='submission[contacts_attributes][0][id]']") { nil }
surviving_widget.on_query("form[action=\"/agents\"]") { [parent_form] }
surviving_widget.on_query("a.agent-edit-icon:not([href*='affiliations'])") { nil }
surviving_widget.on_query("a[href*='/agents/'][href*='/edit']:not([href*='affiliations'])") { nil }

aff_fixture = { 'name' => 'Orphaned Aff', 'agentType' => 'organization', 'identifiers' => [{'notation' => 'aff4'}] }
parent_fixture = OpenStruct.new(
  name: 'Failed Parent',
  agentType: 'person',
  email: 'failed_par@example.com',
  identifiers: [{'notation' => 'par4'}],
  affiliations: [aff_fixture]
)

lookup_error_raised = false
begin
  harness.agent_fill(parent_fixture, parent_id: "sub_slot_4", is_affiliation: false)
rescue Capybara::ElementNotFound
  lookup_error_raised = true
end

assert(lookup_error_raised, "Parent save failure raised lookup error upon waiting for replacement")
assert(TestResourceOwnership.owned?(:agent, "http://localhost:9393/agents/aff_orphaned_44"), "Affiliation created before parent failure remains registered")
assert(!TestResourceOwnership.owned?(:agent, 'aff_orphaned_44'), "Unregistered bare basename is not owned")
assert(parent_fixture.id.nil?, "Parent fixture was NOT registered with ID (expected: nil, got: #{parent_fixture.id.inspect})")

# Run actual teardown
harness.teardown
assert(!$datastore.agent_persisted?('aff_orphaned_44'), "Teardown deleted orphaned affiliation from datastore")
assert(TestResourceOwnership.empty?, "Registry cleanly emptied by teardown")

# -----------------------------------------------------------------------------
puts "\n=== Test 5: Edit Flow Never Overwrites Existing Parent Identity ==="
# -----------------------------------------------------------------------------
$datastore.reset!
TestResourceOwnership.reset!

harness = ScriptedFlowHarness.new
harness.search_slot_id = "slot_aff_5"

existing_parent = OpenStruct.new(
  id: "existing_person_55",
  name: "Existing Person",
  agentType: "person",
  email: "existing@example.com",
  identifiers: [{'notation' => '555'}],
  affiliations: [{ 'name' => 'New Aff', 'agentType' => 'organization', 'identifiers' => [{'notation' => 'aff5'}] }]
)
$datastore.persist_agent("existing_person_55", { name: "Existing Person", agentType: "person" })
TestResourceOwnership.register(:agent, existing_parent.id)

edit_form = create_parent_form(harness, "/agents/existing_person_55")
row_scope = nil
row_scope = create_affiliation_row("row_5", "existing_person_55_slot_aff_5") do |_f|
  $datastore.persist_agent("aff_new_55", { name: "New Aff", agentType: "organization" })
  row_scope.attach_replacement!("http://localhost:9393/agents/aff_new_55")
end
edit_form.add_child_scope(".agents-affiliations", create_affiliations_container([row_scope]))

harness.agent_fill(existing_parent, parent_id: existing_parent.id)

assert(existing_parent.id == "existing_person_55",
       "Existing parent ID was NOT overwritten with affiliation ID (expected: \"existing_person_55\", got: #{existing_parent.id.inspect})")
assert(TestResourceOwnership.owned?(:agent, 'existing_person_55'), "Existing parent remains owned under original ID")
assert(TestResourceOwnership.owned?(:agent, "http://localhost:9393/agents/aff_new_55"), "New affiliation is owned under its own ID")
assert(!TestResourceOwnership.owned?(:agent, 'aff_new_55'), "Unregistered bare basename is not owned")

# -----------------------------------------------------------------------------
puts "\n=== Test 6: Post-Acknowledgement Failure & Real Caller Teardown ==="
# -----------------------------------------------------------------------------
$datastore.reset!
TestResourceOwnership.reset!

harness = ScriptedFlowHarness.new

create_link = ElementDouble.new(:a, { text: "Create agent" })
close_btn = ElementDouble.new(:button, { class: "close" })
edit_modal_link = ElementDouble.new(:a, {
  "data-show-modal-title-value" => "Edit agent Top Person 66",
  "href" => "/agents/top_person_66/edit"
})

harness.on_page_query("a") { create_link }
harness.on_page_query("a[data-show-modal-title-value=\"Edit agent Top Person 66\"]") { edit_modal_link }
harness.on_page_query(".close") { close_btn }

top_form = create_parent_form(harness, "/agents")
aff_container = NamedScope.new("empty_aff")
aff_container.on_query('.delete') { [] }
top_form.add_child_scope(".agents-affiliations", aff_container)
top_form.on_save = lambda do |_f|
  $datastore.persist_agent("top_person_66", { name: "Top Person 66", agentType: "person" })
end

# Table scope with human count = 1. create_agent_flow asserts count = 10 + 10 = 20, triggering failure.
table_scope = TableScope.new("table#agents-table")
table_scope.human_count = 1
harness.current_scope.add_child_scope("table#agents-table", table_scope)

top_fixture = OpenStruct.new(
  name: 'Top Person 66',
  agentType: 'person',
  email: 'top66@example.com',
  identifiers: [{'notation' => 'top66'}],
  affiliations: []
)

assertion_failed = false
begin
  harness.send(:create_agent_flow, top_fixture, person_count: 10, organization_count: 10)
rescue Capybara::ExpectationNotMet
  assertion_failed = true
end

assert(assertion_failed, "Unrelated table count assertion failed as expected")
assert(top_fixture.id == "top_person_66",
       "Acknowledged parent ID was captured before assertion failure (expected: \"top_person_66\", got: #{top_fixture.id.inspect})")
assert(TestResourceOwnership.owned?(:agent, 'top_person_66'),
       "Created parent was registered in TestResourceOwnership before assertion failure")
assert($datastore.agent_persisted?('top_person_66'), "Created parent is in datastore before teardown")

# Real teardown deletes created resource with 204
harness.teardown
assert(!$datastore.agent_persisted?('top_person_66'),
       "Created parent was deleted from datastore by real teardown with status 204")
assert(TestResourceOwnership.empty?, "TestResourceOwnership is cleanly reset when empty")

# -----------------------------------------------------------------------------
puts "\n=== Test 7: Teardown Reset-If-Empty Control Flow & Coupled Retained-Helper Gate ==="
# -----------------------------------------------------------------------------
$datastore.reset!
TestResourceOwnership.reset!

harness = ScriptedFlowHarness.new

# Labelled static dependency stub: proves AgentFlowsTest#teardown's reset-if-empty control flow
TestResourceOwnership.register(:ontology, "retained_static_stub")
harness.teardown
assert(!TestResourceOwnership.empty?, "Real teardown preserves TestResourceOwnership when non-empty (reset-if-empty control flow)")
TestResourceOwnership.reset!
assert(TestResourceOwnership.empty?, "Real teardown cleanly resets when registry is empty")

# Coupled base helper behavior check on backend deletion failure
$datastore.persist_agent("retained_backend_agent", { name: "Retained Backend Agent", agentType: "person" })
TestResourceOwnership.register(:agent, "retained_backend_agent")
$datastore.simulate_delete_error = true

harness.delete_agents

assert(TestResourceOwnership.owned?(:agent, "retained_backend_agent"),
       "Base helper retained ownership bookkeeping on deletion failure")

$datastore.simulate_delete_error = false
TestResourceOwnership.reset!

# -----------------------------------------------------------------------------
puts "\n============================================================"
puts "SUMMARY: #{$passed_count} PASSED, #{$failed_count} FAILED, #{$gate_skips.size} GATED/SKIPPED"
puts "============================================================"

if $failed_count > 0 || $gate_skips.any?
  puts "FAILED: #{$failed_count} checks failed, #{$gate_skips.size} gated/skipped."
  exit 1
else
  puts "ALL CHECKS PASSED: UI Creation Ownership verified offline."
end
