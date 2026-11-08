require "application_system_test_case"

class AgentFlowsTest < ApplicationSystemTestCase
  include AgentHelper

  setup do
    TestTargetGuard.configure_webmock!
    teardown
    @logged_user = fixtures(:users)[:john]
    @new_person = fixtures(:agents)[:agent1]
    @new_organization = fixtures(:agents)[:organization1]
    login_in_as(@logged_user, admin: true)
  end

  def teardown
    delete_agents
    delete_user(@logged_user) if @logged_user
    TestResourceOwnership.reset! if defined?(TestResourceOwnership) && TestResourceOwnership.empty?
  end

  test "go agents page and create an agent person and edit it" do
    visit root_url
    click_on "Explore"
    click_link(href: '/agents')

    wait_for_text "Create agent"
    # The shared test API may hold unrelated agents; the helpers assert what this test adds on top.
    assert_selector 'table#agents-table'
    @base = %w[.human span.agent-chip-circle[title="person"] span.agent-chip-circle[title="organization"]]
              .to_h { |css| [css, all("table#agents-table #{css}").size] }

    # Creation test
    create_agent_flow(@new_person, person_count: 1, organization_count: 2)

    # Edition test
    @new_person2 = fixtures(:agents)[:agent2]
    wait_for_text  @new_person.name
    edit_link = find("a[data-show-modal-title-value=\"Edit agent #{@new_person.name}\"]")
    @new_person2.id = edit_link['href'].split('/')[-2]
    TestResourceOwnership.register(:agent, @new_person2.id) if defined?(TestResourceOwnership)
    edit_link.click

    edit_agent_flow(@new_person2, person_count: 1, organization_count: 3)

  end

  private
  def create_agent_flow(new_agent, person_count: , organization_count:)
    wait_for_text "Create agent"

    # Creation test

    find("a", text: "Create agent", match: :first).click

    wait_for_text "TYPE"
    agent_fill(new_agent, is_affiliation: false)
    assert_text "New agent added successfully"

    edit_link = find("a[data-show-modal-title-value=\"Edit agent #{new_agent.name}\"]")
    created_id = if edit_link && (match = edit_link['href'].match(%r{/agents/([^/?#]+)}))
      match[1]
    else
      edit_link['href'].split('/')[-2]
    end
    new_agent.id = created_id
    TestResourceOwnership.register(:agent, created_id) if defined?(TestResourceOwnership)

    find('.close').click
    within "table#agents-table" do
      puts "Person count: #{person_count}, Organization count: #{organization_count}"
      assert_selector '.human',  count: @base['.human'] + person_count + organization_count #  all created  agents
      assert_text new_agent.name
      new_agent.identifiers.map{|x| "https://#{new_agent.agentType.eql?('organization') ? 'ror' : 'orcid'}.org/#{x["notation"]}"}.each do |orcid|
        assert_selector "a[href='#{orcid}']"
      end

      assert_selector 'span.agent-chip-circle[title="person"]', count: @base['span.agent-chip-circle[title="person"]'] + person_count
      assert_selector 'span.agent-chip-circle[title="organization"]', count: @base['span.agent-chip-circle[title="organization"]'] + organization_count

      Array(new_agent.affiliations).map do |aff|
        aff["identifiers"] = aff["identifiers"].each{|x| x["schemaAgency"] = 'ORCID'}
        assert_text aff['name']
      end
    end
  end

  def edit_agent_flow(agent, person_count: , organization_count: )
    wait_for_text "TYPE"
    agent_fill(agent, parent_id: agent.id)
    # assert_text "New agent added successfully"
    find('.close').click
    sleep 1
    within "table#agents-table" do
      assert_selector '.human',  count: @base['.human'] + person_count + organization_count # all created  agents
      assert_text agent.name
      agent.identifiers.map{|x| "https://#{agent.agentType.eql?('organization') ? 'ror' : 'orcid'}.org/#{x["notation"]}"}.each do |orcid|
        assert_selector "a[href='#{orcid}']"
      end

      assert_selector 'span.agent-chip-circle[title="person"]', count: @base['span.agent-chip-circle[title="person"]'] + person_count
      assert_selector 'span.agent-chip-circle[title="organization"]', count: @base['span.agent-chip-circle[title="organization"]'] + organization_count

      Array(agent.affiliations).map do |aff|
        aff["identifiers"] = aff["identifiers"].each{|x| x["schemaAgency"] = 'ORCID'}
        assert_text aff['name']
      end
    end
  end
end
