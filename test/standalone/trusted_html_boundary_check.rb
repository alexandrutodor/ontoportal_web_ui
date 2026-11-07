# frozen_string_literal: true

# Set up gem paths for native docker image if present
if Dir.exist?('/usr/local/bundle/ruby/3.1.0/gems') && (ENV['GEM_PATH'].nil? || !ENV['GEM_PATH'].include?('/usr/local/bundle/ruby/3.1.0'))
  Gem.use_paths(nil, Gem.path + ['/usr/local/bundle/ruby/3.1.0'])
end

require 'minitest/autorun'
require 'active_support/all'
require 'rails'
require 'rails/version'
require 'action_controller'
require 'action_view'
require 'view_component'
require 'haml'
require 'haml/template'

module Turbo
  module Streams; end
  module FramesHelper; end
  module StreamsHelper; end
end
require '/usr/local/bundle/ruby/3.1.0/gems/turbo-rails-2.0.12/app/helpers/turbo/frames_helper.rb' rescue nil
require '/usr/local/bundle/ruby/3.1.0/gems/turbo-rails-2.0.12/app/helpers/turbo/streams_helper.rb' rescue nil

require 'ostruct'
require 'cgi'
require 'nokogiri'

# =============================================================================
# Standalone Trusted HTML Boundary Check (ONTO-T-U01)
#
# Validates proper HTML escaping and SafeBuffer boundary handling across:
# 1. NotesHelper#proposal_html & NoteDecorator#proposal_content
# 2. ComponentsHelper#properties_list_component (plain-value branch)
# 3. OntologiesHelper#display_contact & _ontology_description_section.html.haml
# 4. ontologies_metadata_curator/_attribute.html.haml & projects/index.html.haml
# 5. LinkTextComponent, PopupLinkTextComponent, and modal_helper#link_to_modal
# =============================================================================

WORKTREE_ROOT = File.expand_path('../..', __dir__)
$LOAD_PATH.unshift File.join(WORKTREE_ROOT, 'app/helpers')
$LOAD_PATH.unshift File.join(WORKTREE_ROOT, 'app/components')
$LOAD_PATH.unshift File.join(WORKTREE_ROOT, 'app/decorators')
$LOAD_PATH.unshift File.join(WORKTREE_ROOT, 'app/controllers/concerns')

$REST_URL = 'http://localhost:9393'
$API_KEY = 'test_key'
$SITE = 'MatPortal'
$READ_ONLY_PORTAL = false

class ApplicationController < ActionController::Base
  def self.skip_before_action(*); end
  def self.layout(*); end
end

require 'urls_helper'
require 'terms_reuses'
require 'components_helper'
require 'ontologies_helper'
require 'internationalisation_helper'
require 'multi_languages_helper'
require 'modal_helper'
require 'application_helper'
require 'notes_helper'
require 'submissions_helper'

require 'base_decorator'
require 'note_decorator'

module Display; end
module Layout; end
module FlagIconsRails; module Rails; module ViewHelpers; end; end; end

require 'display/header_component'
require 'display/alert_component'
require 'layout/card_component'
require 'layout/list_component'
require 'layout/horizontal_list_component'
require 'field_container_component'
require 'turbo_frame_component'
require 'loader_component'
require 'text_area_field_component'
require 'link_field_component'
require 'language_field_component'
require 'link_text_component'
require 'popup_link_text_component'
require 'external_link_text_component'
require 'internal_link_text_component'

class ViewComponent::Base
  def inline_svg(icon, options = {})
    %(<svg class="icon-test" data-icon="#{icon}" width="#{options[:width] || '14px'}" height="#{options[:height] || '14px'}"><path d="M0 0h24v24H0z"/></svg>).html_safe
  end

  def inline_svg_tag(icon, options = {})
    inline_svg(icon, options)
  end

  def t(key, options = {})
    options[:default] || key.to_s
  end
end

class TrustedHtmlBoundaryCheck < Minitest::Test
  XSS_PAYLOAD = %(<script>alert("xss")</script><img src=x onerror=alert('xss')>"double"&'single')

  def setup
    lookup_context = ActionView::LookupContext.new([
      File.join(WORKTREE_ROOT, 'app/views'),
      File.join(WORKTREE_ROOT, 'app/components')
    ])
    @view = ActionView::Base.with_empty_template_cache.new(lookup_context, {}, ActionController::Base.new)
    @view.extend(ActionView::Helpers::TagHelper)
    @view.extend(ActionView::Helpers::OutputSafetyHelper)
    @view.extend(ActionView::Helpers::UrlHelper)
    @view.extend(UrlsHelper)
    @view.extend(TermsReuses)
    @view.extend(ComponentsHelper)
    @view.extend(OntologiesHelper)
    @view.extend(InternationalisationHelper)
    @view.extend(MultiLanguagesHelper)
    @view.extend(ModalHelper)
    @view.extend(NotesHelper)
    @view.extend(SubmissionsHelper)

    @view.define_singleton_method(:session) { @session ||= {} }
    @view.define_singleton_method(:inline_svg) do |icon, options = {}|
      %(<svg class="icon-test" data-icon="#{icon}" width="#{options[:width] || '14px'}" height="#{options[:height] || '14px'}"><path d="M0 0h24v24H0z"/></svg>).html_safe
    end
    @view.define_singleton_method(:inline_svg_tag) { |icon, options = {}| inline_svg(icon, options) }
    @view.define_singleton_method(:t) { |key, options = {}| options[:default] || key.to_s }
    @view.define_singleton_method(:l) { |date, options = {}| date.to_s }
    @view.define_singleton_method(:attr_label) { |k, label = nil, **opts| label || k.to_s }
    @view.define_singleton_method(:attr_metadata) { |_k| {} }
    @view.define_singleton_method(:link?) { |v| v.to_s.start_with?('http://', 'https://') }
    @view.define_singleton_method(:current_user_admin?) { false }
    @view.define_singleton_method(:help_path) { |*| '/help' }
    @view.define_singleton_method(:project_path) { |acronym| "/projects/#{acronym}" }
    @view.define_singleton_method(:new_project_path) { '/projects/new' }
    @view.define_singleton_method(:edit_project_path) { |acronym| "/projects/#{acronym}/edit" }
    @view.define_singleton_method(:error_message_alert) { ''.html_safe }
    @view.define_singleton_method(:equivalent_properties) { |attr_labels| [attr_labels.to_s] }
    @view.define_singleton_method(:equivalent_ontology_properties) { |_attr| [] }
    @view.define_singleton_method(:attribute_input_frame_id) { |*| 'frame_1' }
    @view.define_singleton_method(:metadata_export_index_path) { |*| '/export' }
    @view.define_singleton_method(:metadata_filled_count) { '0' }
    @view.define_singleton_method(:admin_block) { |**_opts, &block| block.call }
    @view.define_singleton_method(:show_ontology_domains) { |domains| Array(domains) }
    @view.define_singleton_method(:category_chip) { |domain| %(<span class="chip">#{domain}</span>).html_safe }
    @view.define_singleton_method(:subject_chip) { |domain, _tax| %(<span class="chip">#{domain}</span>).html_safe }
    @view.define_singleton_method(:get_theme_taxonomy_ontologies) { [] }
    @view.define_singleton_method(:smart_truncate) { |text, **_opts| text.to_s[0..20] }
    @view.define_singleton_method(:get_username) { |_user| 'Test User' }

    original_render = @view.method(:render)
    @view.define_singleton_method(:render) do |options = {}, locals = {}, &block|
      if options.is_a?(ViewComponent::Base)
        options.render_in(self, &block)
      else
        original_render.call(options, locals, &block)
      end
    end
  end

  # ===========================================================================
  # 1. NotesHelper#proposal_html & NoteDecorator#proposal_content
  # ===========================================================================

  def test_proposal_html_proposal_new_class_escapes_markup
    prop = OpenStruct.new(
      type: 'ProposalNewClass',
      reasonForChange: XSS_PAYLOAD,
      contactInfo: XSS_PAYLOAD,
      label: XSS_PAYLOAD,
      classId: XSS_PAYLOAD,
      parent: XSS_PAYLOAD,
      synonym: [XSS_PAYLOAD, 'regular synonym'],
      definition: [XSS_PAYLOAD, 'regular definition']
    )
    note = OpenStruct.new(proposal: prop)
    html = @view.proposal_html(note)

    assert_instance_of ActiveSupport::SafeBuffer, html
    refute_includes html, '<script>'
    refute_includes html, '<img'
    assert_includes html, '&lt;script&gt;alert(&quot;xss&quot;)&lt;/script&gt;'
    assert_includes html, '&lt;img src=x onerror=alert(&#39;xss&#39;)&gt;'
    assert_includes html, '&quot;double&quot;'
    assert_includes html, '&amp;&#39;single&#39;'
    assert_includes html, '<table class="proposal">'
  end

  def test_proposal_html_proposal_change_hierarchy_escapes_markup
    prop = OpenStruct.new(
      type: 'ProposalChangeHierarchy',
      newRelationshipType: [XSS_PAYLOAD],
      newTarget: XSS_PAYLOAD,
      oldTarget: XSS_PAYLOAD,
      reasonForChange: XSS_PAYLOAD,
      contactInfo: XSS_PAYLOAD
    )
    note = OpenStruct.new(proposal: prop)
    html = @view.proposal_html(note)

    assert_instance_of ActiveSupport::SafeBuffer, html
    refute_includes html, '<script>'
    refute_includes html, '<img'
    assert_includes html, '&lt;script&gt;alert(&quot;xss&quot;)&lt;/script&gt;'
    assert_includes html, '<td colspan="3">&lt;script&gt;'
    assert_includes html, '<table class="proposal">'
  end

  def test_proposal_html_proposal_change_property_escapes_markup
    prop = OpenStruct.new(
      type: 'ProposalChangeProperty',
      propertyId: XSS_PAYLOAD,
      newValue: XSS_PAYLOAD,
      oldValue: XSS_PAYLOAD,
      reasonForChange: XSS_PAYLOAD,
      contactInfo: XSS_PAYLOAD
    )
    note = OpenStruct.new(proposal: prop)
    html = @view.proposal_html(note)

    assert_instance_of ActiveSupport::SafeBuffer, html
    refute_includes html, '<script>'
    refute_includes html, '<img'
    assert_includes html, '&lt;script&gt;alert(&quot;xss&quot;)&lt;/script&gt;'
    assert_includes html, '<td colspan="3">&lt;script&gt;'
    assert_includes html, '<table class="proposal">'
  end

  def test_proposal_html_preserves_safebuffers_without_double_escaping
    safe_label = %(<strong class="trusted-prop">Safe Label</strong>).html_safe
    safe_syn = %(<em class="trusted-syn">Safe Syn</em>).html_safe
    prop = OpenStruct.new(
      type: 'ProposalNewClass',
      reasonForChange: 'Normal text',
      contactInfo: 'user@example.com',
      label: safe_label,
      classId: 'http://example.org/prop1',
      parent: 'http://example.org/Parent',
      synonym: [safe_syn],
      definition: ['Plain definition']
    )
    note = OpenStruct.new(proposal: prop)
    html = @view.proposal_html(note)

    assert_includes html, '<strong class="trusted-prop">Safe Label</strong>'
    assert_includes html, '<em class="trusted-syn">Safe Syn</em>'
    refute_includes html, '&lt;strong'
    refute_includes html, '&lt;em'
  end

  def test_proposal_html_plain_text_unchanged
    prop = OpenStruct.new(
      type: 'ProposalNewClass',
      reasonForChange: 'Update material classification',
      contactInfo: 'curator@example.com',
      label: 'Tensile Strength',
      classId: 'http://example.org/ts',
      parent: 'http://example.org/MechanicalProperty',
      synonym: ['Resistance to tension', 'Ultimate tensile stress'],
      definition: ['Maximum stress a material withstands before fracture']
    )
    note = OpenStruct.new(proposal: prop)
    html = @view.proposal_html(note)

    assert_includes html, '<td>Update material classification</td>'
    assert_includes html, '<td>curator@example.com</td>'
    assert_includes html, '<td>Tensile Strength</td>'
    assert_includes html, '<td>Resistance to tension, Ultimate tensile stress</td>'
  end

  def test_note_decorator_proposal_content_escapes_and_renders_div
    prop = OpenStruct.new(
      type: 'ProposalNewClass',
      reasonForChange: XSS_PAYLOAD,
      contactInfo: 'admin@example.org',
      label: 'Class Label',
      classId: 'http://example.org/c1',
      parent: 'http://example.org/Root',
      synonym: [],
      definition: []
    )
    note = OpenStruct.new(proposal: prop)
    decorator = NoteDecorator.new(note, @view)
    rendered = decorator.proposal_content

    assert_instance_of ActiveSupport::SafeBuffer, rendered
    assert_includes rendered, '<div class="proposal">'
    assert_includes rendered, '<table class="proposal">'
    refute_includes rendered, '<script>'
    assert_includes rendered, '&lt;script&gt;alert(&quot;xss&quot;)&lt;/script&gt;'
  end

  # ===========================================================================
  # 2. ComponentsHelper#properties_list_component (plain-value branch)
  # ===========================================================================

  def test_properties_list_component_plain_values_escaped
    container = Layout::ListComponent.new
    props = {
      description: [[XSS_PAYLOAD], 'Description'],
      status: [XSS_PAYLOAD, 'Status']
    }
    @view.properties_list_component(container, props)
    rendered = @view.render(container)

    refute_includes rendered, '<script>'
    refute_includes rendered, '<img'
    assert_includes rendered, '&lt;script&gt;alert(&quot;xss&quot;)&lt;/script&gt;'
    assert_includes rendered, '&quot;double&quot;'
    assert_includes rendered, '&amp;&#39;single&#39;'
  end

  def test_properties_list_component_plain_values_preserves_safebuffers
    container = Layout::ListComponent.new
    safe_markup = %(<span class="badge badge-success">Approved</span>).html_safe
    props = {
      badge: [safe_markup, 'Approval Status'],
      mixed: [[safe_markup, XSS_PAYLOAD], 'Mixed Content']
    }
    @view.properties_list_component(container, props)
    rendered = @view.render(container)

    assert_includes rendered, '<span class="badge badge-success">Approved</span>'
    refute_includes rendered, '&lt;span class=&quot;badge'
    assert_includes rendered, '&lt;script&gt;alert(&quot;xss&quot;)&lt;/script&gt;'
  end

  def test_properties_list_component_plain_values_unchanged
    container = Layout::ListComponent.new
    props = {
      label: ['Standard Label', 'Label'],
      aliases: [['Alias One', 'Alias Two'], 'Aliases']
    }
    @view.properties_list_component(container, props)
    rendered = @view.render(container)

    assert_includes rendered, 'Standard Label'
    assert_includes rendered, 'Alias One, Alias Two'
  end

  # ===========================================================================
  # 3. OntologiesHelper#display_contact & _ontology_description_section
  # ===========================================================================

  def test_display_contact_escapes_markup
    contacts = [
      { name: XSS_PAYLOAD, email: XSS_PAYLOAD },
      { name: 'Alice Smith', email: 'alice@example.com' }
    ]
    formatted = @view.display_contact(contacts)

    assert_instance_of ActiveSupport::SafeBuffer, formatted
    refute_includes formatted, '<script>'
    refute_includes formatted, '<img'
    assert_includes formatted, '&lt;script&gt;'
    assert_includes formatted, '<span class="date_creation_text">'
    assert_includes formatted, ' and <span class="date_creation_text">Alice Smith</span> (alice@example.com)'
  end

  def test_display_contact_preserves_safebuffers
    safe_name = %(<b class="author-tag">Dr. Safe</b>).html_safe
    contacts = [{ name: safe_name, email: 'safe@example.org' }]
    formatted = @view.display_contact(contacts)

    assert_includes formatted, '<b class="author-tag">Dr. Safe</b>'
    refute_includes formatted, '&lt;b class='
  end

  def test_display_contact_plain_text_unchanged
    contacts = [{ name: 'Jane Doe', email: 'jane.doe@example.com' }]
    formatted = @view.display_contact(contacts)

    assert_equal %(<span class="date_creation_text">Jane Doe</span> (jane.doe@example.com)), formatted
  end

  def test_ontology_description_section_haml_renders_escaped_contact
    submission = OpenStruct.new(
      abstract: nil,
      description: 'Test description',
      logo: nil,
      released: '2026-01-15',
      contact: [{ name: XSS_PAYLOAD, email: XSS_PAYLOAD }],
      naturalLanguage: [],
      hasDomain: [],
      keywords: [],
      keyClasses: []
    )
    ontology = OpenStruct.new(acronym: 'TEST', hasDomain: [])
    @view.assign(submission_latest: submission, ontology: ontology, ontology_icon_links: [])
    rendered = @view.render(partial: 'ontologies/sections/metadata/ontology_description_section')

    refute_includes rendered, '<script>'
    refute_includes rendered, '<img'
    assert_includes rendered, '&lt;script&gt;'
    assert_includes rendered, '<span class="date_creation_text">'
    assert_match(/#{Regexp.escape('.')}\s*<\/span>/, rendered)
  end

  # ===========================================================================
  # 4. ontologies_metadata_curator/_attribute.html.haml & projects/index.html.haml
  # ===========================================================================

  def test_attribute_haml_contact_escapes_markup_and_preserves_br
    submission = OpenStruct.new(
      submissionId: 1,
      contact: [
        { name: XSS_PAYLOAD, email: XSS_PAYLOAD },
        { name: 'Curator Jane', email: 'jane@curator.org' }
      ]
    )
    ontology = OpenStruct.new(acronym: 'TEST')
    rendered = @view.render(
      partial: 'ontologies_metadata_curator/attribute',
      locals: { attribute: 'contact', submission: submission, ontology: ontology }
    )

    refute_includes rendered, '<script>'
    refute_includes rendered, '<img'
    assert_includes rendered, '&lt;script&gt;'
    assert_includes rendered, '<br>'
    assert_includes rendered, 'Curator Jane, jane@curator.org'
  end

  def test_attribute_haml_contact_preserves_safebuffers
    safe_name = %(<b class="curator">Dr. Valid</b>).html_safe
    submission = OpenStruct.new(submissionId: 1, contact: [{ name: safe_name, email: 'valid@curator.org' }])
    ontology = OpenStruct.new(acronym: 'TEST')
    rendered = @view.render(
      partial: 'ontologies_metadata_curator/attribute',
      locals: { attribute: 'contact', submission: submission, ontology: ontology }
    )

    assert_includes rendered, '<b class="curator">Dr. Valid</b>'
    refute_includes rendered, '&lt;b class='
  end

  def test_projects_index_haml_escapes_contacts_and_institution
    project = OpenStruct.new(
      name: 'Test Project',
      acronym: 'TP',
      homePage: 'https://example.org/project',
      description: 'A test project for verification',
      contacts: XSS_PAYLOAD,
      institution: XSS_PAYLOAD,
      ontologyUsed: [],
      creator: ['http://example.org/users/u1'],
      created: '2026-02-01'
    )
    @view.assign(projects: [project], ontologies_hash: {})
    rendered = @view.render(template: 'projects/index')

    refute_includes rendered, '<script>'
    refute_includes rendered, '<img src=x onerror'
    assert_includes rendered, '&lt;script&gt;alert(&quot;xss&quot;)&lt;/script&gt;'
    assert_includes rendered, '&quot;double&quot;'
    assert_includes rendered, '&amp;&#39;single&#39;'
  end

  def test_projects_index_haml_preserves_safebuffers
    safe_contact = %(<a href="mailto:admin@ex.org" class="trusted-mail">admin@ex.org</a>).html_safe
    safe_inst = %(<span class="trusted-inst">Fraunhofer IWM</span>).html_safe
    project = OpenStruct.new(
      name: 'Safe Project',
      acronym: 'SP',
      homePage: 'https://example.org/safe',
      description: 'Valid safe description',
      contacts: safe_contact,
      institution: safe_inst,
      ontologyUsed: [],
      creator: ['http://example.org/users/u1'],
      created: '2026-02-01'
    )
    @view.assign(projects: [project], ontologies_hash: {})
    rendered = @view.render(template: 'projects/index')

    assert_includes rendered, '<a href="mailto:admin@ex.org" class="trusted-mail">admin@ex.org</a>'
    assert_includes rendered, '<span class="trusted-inst">Fraunhofer IWM</span>'
    refute_includes rendered, '&lt;a href='
    refute_includes rendered, '&lt;span class='
  end

  def test_projects_index_haml_plain_text_unchanged
    project = OpenStruct.new(
      name: 'Plain Project',
      acronym: 'PP',
      homePage: 'https://example.org/plain',
      description: 'Simple plain project',
      contacts: 'Dr. John Doe (john@example.com)',
      institution: 'Materials Research Institute',
      ontologyUsed: [],
      creator: ['http://example.org/users/u1'],
      created: '2026-02-01'
    )
    @view.assign(projects: [project], ontologies_hash: {})
    rendered = @view.render(template: 'projects/index')

    assert_includes rendered, 'Dr. John Doe (john@example.com)'
    assert_includes rendered, 'Materials Research Institute'
  end

  # ===========================================================================
  # 5. LinkTextComponent & modal_helper#link_to_modal
  # ===========================================================================

  def test_link_text_component_escapes_text_and_preserves_svg
    comp = LinkTextComponent.new(text: XSS_PAYLOAD, icon: 'icons/popup-link.svg')
    rendered = @view.render(comp)

    assert_instance_of ActiveSupport::SafeBuffer, rendered
    refute_includes rendered, '<script>'
    refute_includes rendered, '<img'
    assert_includes rendered, '&lt;script&gt;alert(&quot;xss&quot;)&lt;/script&gt;'
    assert_includes rendered, '<svg class="icon-test" data-icon="icons/popup-link.svg"'
    assert_includes rendered, '<span class="mx-1">'
  end

  def test_popup_link_text_component_escapes_text_and_preserves_svg
    comp = PopupLinkTextComponent.new(text: XSS_PAYLOAD)
    rendered = @view.render(comp)

    assert_instance_of ActiveSupport::SafeBuffer, rendered
    refute_includes rendered, '<script>'
    assert_includes rendered, '&lt;script&gt;'
    assert_includes rendered, '<svg class="icon-test" data-icon="icons/popup-link.svg"'
  end

  def test_link_to_modal_escapes_name_and_preserves_svg
    link = @view.link_to_modal(XSS_PAYLOAD, '/ontologies/TEST/notes/1')

    assert_instance_of ActiveSupport::SafeBuffer, link
    refute_includes link, '<script>'
    assert_includes link, '&lt;script&gt;'
    assert_includes link, '<a '
    assert_includes link, '<svg class="icon-test" data-icon="icons/popup-link.svg"'
    assert_includes link, 'data-controller="show-modal"'
  end

  def test_link_text_component_preserves_safebuffers
    safe_text = %(<span class="badge-label">Ontology 1.0</span>).html_safe
    comp = LinkTextComponent.new(text: safe_text, icon: 'icons/external-link.svg')
    rendered = @view.render(comp)

    assert_includes rendered, '<span class="badge-label">Ontology 1.0</span>'
    refute_includes rendered, '&lt;span class='
    assert_includes rendered, '<svg class="icon-test" data-icon="icons/external-link.svg"'
  end

  def test_link_text_component_plain_text_unchanged
    comp = LinkTextComponent.new(text: 'Explore Classes', icon: 'icons/internal-link.svg')
    rendered = @view.render(comp)

    assert_includes rendered, 'Explore Classes<span class="mx-1"><svg class="icon-test" data-icon="icons/internal-link.svg"'
  end
end
