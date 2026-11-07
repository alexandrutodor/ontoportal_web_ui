require "test_helper"
require_relative 'helpers/application_test_helpers'
require_relative 'helpers/browse_wait'

class ApplicationSystemTestCase < ActionDispatch::SystemTestCase
  include ApplicationTestHelpers::Ontologies
  include ApplicationTestHelpers::Users
  include ApplicationTestHelpers::Users
  include ApplicationTestHelpers::Categories
  include ApplicationTestHelpers::Groups
  include ApplicationTestHelpers::Agents
  include BrowseWait

  setup do
    TestTargetGuard.configure_webmock!
  end

  driven_by :selenium, using: ENV['CI'].present? ? :headless_chrome : :chrome, screen_size: [1400, 1400], options: {
    browser: :remote,
    url: "http://localhost:4444"
  }

  def wait_for(selector, tries = 60)
    assert page.has_selector?(selector, wait: tries), "Timed out after #{tries}s waiting for #{selector} at #{page.current_url}"
  end

  def wait_for_text(text, tries = 60)
    tries.times.each do
      sleep 1
      puts "waiting for #{text}"
      break if page.has_text?(text)
    end
    assert_text text
  end

  def login_in_as(user, admin: false)
    create_user(user, admin: admin)

    visit login_index_url

    # Fill in the login form
    fill_in 'user_username', with: user.username
    fill_in 'user_password', with: user.password

    # Click the login button
    click_button 'Login'
  end

  def assert_date(date)
    assert_text I18n.l(DateTime.parse(date), format: '%B %-d, %Y')
  end

  def search_input(selector, value)
    within "#{selector}" do
      find(".search-inputs .input-field-component").last.set(value)
      page.execute_script("document.querySelector('#{selector} > .search-inputs .input-field-component').dispatchEvent(new Event('input'))")
      sleep 1
      find(".search-inputs .search-content", text: value).click
      sleep 1
      find("input", text: 'Save').click
    end
  end

  def list_checks(selected_values, all_values = [])
    all_values.each do |val|
      uncheck val, allow_label_click: true
    end

    selected_values.each do |val|
      check val, allow_label_click: true
    end
  end

  def list_inputs(parent_selector, selector, values, &block)
    within parent_selector do
      all('.delete').each { |x| x.click }
      find('.add-another-object', text: 'Add another').click
      last_index = values.size - 1
      values.each_with_index do |value, index|
        if value.is_a?(Hash)
          value.each do |key, val|
            all("[name^='#{selector}'][name$='[#{key}]']").last.set(val)
          end
        else
          if block_given?
            block.call(selector, value, index)
          else
            all("[name^='#{selector}']").last.set(value)
          end
        end
        find('.add-another-object', text: 'Add another').click unless index.eql?(last_index)
      end
    end
  end

  def tom_select(selector, values, open_to_add: false)

    multiple = values.is_a?(Array)

    real_select = "[name='#{selector}']"

    ts_wrapper_selector = "#{real_select} + div.ts-wrapper"
    assert_selector ts_wrapper_selector

    # Click on the Tom Select input to open the dropdown
    element = find(ts_wrapper_selector)
    element.click

    return unless page.has_selector?("#{ts_wrapper_selector} > .ts-dropdown")

    if multiple
      # reset the input to empty
      all("#{ts_wrapper_selector} > .ts-control > .item .remove").each do |element|
        element.click
      end
    else
      values = Array(values)
    end

    values.each do |value|
      find("#{ts_wrapper_selector} input").set(value) if open_to_add
      within "#{ts_wrapper_selector} > .ts-dropdown" do
        if page.has_selector?('.option', text: value)
          find('.option', text: value).click
        elsif open_to_add
          find('.create').click
        end
      end
    end

    if multiple
      find("#{ts_wrapper_selector} input").click
    end
  end

  def date_picker_fill_in(selector, value, index = 0)
    page.execute_script("document.querySelectorAll(\"[name^='#{selector}']\")[#{index}].flatpickr().setDate('#{value}')")
  end

  def agent_search(name)
    sleep 2
    wait_for(".search-inputs:last-of-type")
    within(".search-inputs:last-of-type") do
      input = find("input[name^='agent']")
      agent_id = input[:name].split('agent').last
      input.set(name)
      sleep 2
      links = all('a', text: name)
      links_size = links.size
      sleep 1
      first(:link, name).click
      return links_size.eql?(1) ? agent_id : nil
    end

  end

  def agent_fill(agent, parent_id: nil, is_affiliation: false)
    is_editing = agent.respond_to?(:id) && agent.id && !agent.id.to_s.empty?
    id = is_editing ? "/#{agent.id}" : ''
    form = all("form[action=\"/agents#{id}\"]").first

    surviving_widget = nil
    submitted_name_prefix = nil
    if parent_id && !is_affiliation && !is_editing && form
      prefix_input = form.first("input[type='hidden'][name='name_prefix']", visible: false, minimum: 0)
      submitted_name_prefix = prefix_input[:value] if prefix_input

      surviving_widget = begin
        form.first(:xpath, "ancestor::*[contains(concat(' ', normalize-space(@class), ' '), ' nested-form-wrapper ') or contains(@id, '_from_group_input')][1]")
      rescue StandardError
        nil
      end

      if surviving_widget.nil? && submitted_name_prefix && (m = submitted_name_prefix.match(/submission\[([^\]]+)\]/))
        group_id = "submission#{m[1]}_from_group_input"
        surviving_widget = first("##{group_id}", minimum: 0) rescue nil
      end
    end

    within form do
      choose "", option: agent.agentType, allow_label_click: true unless is_affiliation
      fill_in 'name', with: agent.name

      if agent.agentType.eql?('organization')
        refute_selector('input[name="email"]')
        fill_in 'acronym', with: agent.acronym
        fill_in 'homepage', with: agent.homepage
      else
        refute_selector('input[name="acronym"]')
        refute_selector('input[name="homepage"]')
        fill_in 'email', with: agent.email
      end

      identifier = agent.identifiers.first

      if agent.agentType.eql?('organization')
        fill_in "_identifiers_0_notation", with: identifier['notation']
      else
        fill_in "_identifiers_1_notation", with: identifier['notation']
      end

      if is_affiliation || agent.agentType.eql?('organization')
        refute_selector ".agents-affiliations"
        click_on "Save" if agent.agentType.eql?('organization')
        return
      end

      within '.agents-affiliations' do
        all('.delete').each { |x| x.click }
        Array(agent.affiliations).each do |aff|
          aff_struct = aff.respond_to?(:agentType) ? aff : OpenStruct.new(aff)
          find('.add-another-object', text: 'Add another').click
          row = all('.nested-form-wrapper').last
          agent_id = nil
          within row do
            agent_id = agent_search(aff_struct.name)
            id = parent_id && !parent_id.eql?('NEW_RECORD') ? "#{parent_id}_#{agent_id}" : agent_id
            within "turbo-frame[id=\"#{id}\"]" do
              agent_fill(aff_struct, is_affiliation: true)
            end

            # Re-resolve acknowledged result from stable containing row after replacement.
            # Bare editable form id is an UNSAVED input-slot placeholder, never creation proof.
            # Successful show replacement changes frame ID and renders exact persisted show field.
            created_aff_id = nil
            show_hidden = first("turbo-frame:not([id=\"#{id}\"]) input[type='hidden'][name$='[id]']", visible: false) ||
                          first("input[type='hidden'][name$='[id]']:not([name='id'])", visible: false)
            if show_hidden && !show_hidden[:value].to_s.empty? && show_hidden[:value] != agent_id && show_hidden[:value] != 'NEW_RECORD'
              created_aff_id = show_hidden[:value]
            end

            if (created_aff_id.nil? || created_aff_id.empty?) && has_no_selector?("form")
              edit_link = first("a.agent-edit-icon") || first("a[href*='/agents/'][href*='/edit']")
              if edit_link && (match = edit_link[:href].match(%r{/agents/([^/?#]+)}))
                created_aff_id = match[1]
              end
            end

            if created_aff_id && !created_aff_id.empty?
              if aff.is_a?(Hash)
                aff['id'] = created_aff_id
                aff[:id] = created_aff_id
              elsif aff.respond_to?(:id=)
                aff.id = created_aff_id
              end
              aff_struct.id = created_aff_id if aff_struct.respond_to?(:id=)
              TestResourceOwnership.register(:agent, created_aff_id) if defined?(TestResourceOwnership)
            end
          end
        end
      end
      click_on "Save"
    end

    if parent_id && !is_affiliation && !is_editing
      target_scope = surviving_widget || self
      hidden_input = nil
      if submitted_name_prefix && !submitted_name_prefix.empty?
        expected_name = "#{submitted_name_prefix}[id]"
        hidden_input = target_scope.first("input[type='hidden'][name='#{expected_name}']", visible: false)
      else
        hidden_input = target_scope.first("input[type='hidden'][name$='[id]']:not([name*='affiliations']):not([name='id'])", visible: false)
      end

      created_id = hidden_input[:value] if hidden_input && !hidden_input[:value].to_s.empty? && hidden_input[:value] != parent_id

      if (created_id.nil? || created_id.empty?) && target_scope.has_no_selector?("form[action=\"/agents\"]")
        edit_link = target_scope.first("a.agent-edit-icon:not([href*='affiliations'])") ||
                    target_scope.first("a[href*='/agents/'][href*='/edit']:not([href*='affiliations'])")
        if edit_link && (match = edit_link[:href].match(%r{/agents/([^/?#]+)}))
          created_id = match[1]
        end
      end

      if created_id && !created_id.empty?
        if agent.respond_to?(:id=)
          agent.id = created_id
        elsif agent.is_a?(Hash)
          agent['id'] = created_id
          agent[:id] = created_id
        elsif agent.respond_to?(:[]=)
          agent[:id] = created_id
        end
        TestResourceOwnership.register(:agent, created_id) if defined?(TestResourceOwnership)
      end
    end
  end
end
