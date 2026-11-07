# frozen_string_literal: true

require 'minitest/autorun'
require 'logger'
require 'ostruct'
require 'cgi'

# =============================================================================
# Standalone Offline Note Author Identity Binding Check (ONTO-T-B04)
#
# Validates the B04 author-identity binding contract for NotesController#create:
# 1. Note/Proposal/Reply creator must come ONLY from effective authenticated
#    session actor.id, never from request/hidden creator parameters.
# 2. Spoofed creator parameters in requests are ignored for ontology comments,
#    class comments, proposals, and replies.
# 3. Missing creator parameters in requests default safely to authenticated actor.id.
# 4. Administrators cannot choose another author through the creator field;
#    admin requests still bind creator strictly to the admin's session actor.id.
# 5. Session object identity and sensitive attributes (e.g., apikey) remain unchanged.
# 6. Anonymous requests (session[:user] == nil) are stopped before constructor/save,
#    redirecting to home with zero Note/Reply constructor or save invocations.
# 7. Unusable or missing actor IDs (session[:user].id is nil, empty, or whitespace)
#    are stopped before constructor/save, redirecting to home with zero invocations.
# 8. No duplicate string+symbol creator keys exist in SDK payloads.
# 9. Actual Rails callback chain retains :authorize_and_redirect and :verify_note_creator.
# =============================================================================

if Dir.exist?('/usr/local/bundle/ruby/3.1.0/gems') && (ENV['GEM_PATH'].nil? || !ENV['GEM_PATH'].include?('/usr/local/bundle/ruby/3.1.0'))
  Gem.use_paths(nil, Gem.path + ['/usr/local/bundle/ruby/3.1.0'])
end

sdk_lib = '/usr/local/bundle/ruby/3.1.0/bundler/gems/ontologies_api_ruby_client-6257685e5744/lib'
$LOAD_PATH.unshift(sdk_lib) if Dir.exist?(sdk_lib) && !$LOAD_PATH.include?(sdk_lib)

worktree_root = File.expand_path('../..', __dir__)
$LOAD_PATH.unshift(File.join(worktree_root, 'app/helpers'))
$LOAD_PATH.unshift(File.join(worktree_root, 'app/controllers/concerns'))
$LOAD_PATH.unshift(File.join(worktree_root, 'app/controllers'))
$LOAD_PATH.unshift(File.join(worktree_root, 'app/decorators'))

require 'rails'
require 'action_controller'
require 'action_view'
require 'action_dispatch'
require 'active_record'
require 'haml'
require 'haml/template/options'
require 'haml/plugin'

module Turbo
  module Streams
  end
end

require '/usr/local/bundle/ruby/3.1.0/gems/turbo-rails-2.0.12/app/helpers/turbo/streams/action_helper.rb' rescue nil
require '/usr/local/bundle/ruby/3.1.0/gems/turbo-rails-2.0.12/app/models/turbo/streams/tag_builder.rb' rescue nil
require '/usr/local/bundle/ruby/3.1.0/gems/turbo-rails-2.0.12/app/helpers/turbo/streams_helper.rb' rescue nil
require '/usr/local/bundle/ruby/3.1.0/gems/turbo-rails-2.0.12/app/controllers/turbo/streams/turbo_streams_tag_builder.rb' rescue nil
require '/usr/local/bundle/ruby/3.1.0/gems/turbo-rails-2.0.12/app/helpers/turbo/frames_helper.rb' rescue nil

ActionView::Base.include Turbo::StreamsHelper if defined?(Turbo::StreamsHelper)
ActionView::Base.include Turbo::FramesHelper if defined?(Turbo::FramesHelper)
ActionController::Base.include Turbo::Streams::TurboStreamsTagBuilder if defined?(Turbo::Streams::TurboStreamsTagBuilder)

ActionController::Renderers.add :turbo_stream do |html, _options|
  self.content_type ||= 'text/vnd.turbo-stream.html; charset=utf-8'
  self.response_body = html.is_a?(Array) ? html.join : html.to_s
end

require 'ontologies_api_client'

ActionController::Base.logger = Logger.new(nil)
Rails.logger = Logger.new(nil)
$ENABLE_SLICES = false
$REST_URL = 'http://example.com'
$API_KEY = 'test'

I18n.load_path = Dir[File.join(worktree_root, 'config/locales/*.yml')]
I18n.default_locale = :en
I18n.locale = :en

require 'urls_helper'
require 'terms_reuses'
require 'components_helper'
require 'ontologies_helper'
require 'internationalisation_helper'
require 'multi_languages_helper'
require 'modal_helper'
require 'application_helper'
require 'notes_helper'
require 'turbo_helper'
require 'application_controller'
require 'notes_controller'
require 'base_decorator'
require 'note_decorator'

module TestViewHelpers
  def current_user_admin?
    false
  end

  def link_to_modal(text, link, **opts)
    "<a href=\"#{link}\">#{text}</a>".html_safe
  end

  def get_note_type_text(type)
    type.to_s
  end

  def get_link_for_cls_ajax(cls, _ont, _target)
    "<a href=\"#{cls}\">#{cls}</a>".html_safe
  end

  def render_alerts_container(id = nil)
    "<div id=\"#{id}\"></div>".html_safe
  end

  def add_reply_button(_id)
    "<button>Reply</button>".html_safe
  end

  def notes_path(**_opts)
    '/notes'
  end

  def login_index_path
    '/login'
  end

  def get_username(user_uri)
    user_uri.to_s.split('/').last
  end

  def session
    {}
  end
end

class TableRowComponent
  def initialize(id: '', class_css: '', **_opts)
    @id = id
    @class_css = class_css
    @cells = []
  end

  def td(**_opts, &block)
    content = block ? block.call : ''
    @cells << "<td>#{content}</td>"
  end

  def render_in(_view_context, &block)
    block.call(self) if block
    "<tr id=\"#{@id}\" class=\"#{@class_css}\">#{@cells.join}</tr>".html_safe
  end
end

class TurboFrameComponent
  def initialize(id: '', **_opts)
    @id = id
  end

  def render_in(_view_context)
    "<turbo-frame id=\"#{@id}\"></turbo-frame>".html_safe
  end
end

class PopupLinkTextComponent
  def initialize(text: '', **_opts)
    @text = text
  end

  def call
    @text.to_s
  end
end

module Display
  class AlertComponent
    attr_reader :id, :type

    def initialize(id: nil, type: 'info', **_opts)
      @id = id
      @type = type
    end

    def render_in(view_context, &block)
      content = block ? view_context.capture(&block) : ''
      "<div class=\"alert alert-#{@type}\" id=\"#{@id}\">#{content}</div>".html_safe
    end
  end
end

ActionView::Base.include TestViewHelpers
NotesController.prepend_view_path(File.join(worktree_root, 'app/views'))
NotesController.layout false
NotesController.skip_before_action :set_locale, :domain_ontology_set, :init_trial_license, raise: false

class NoteAuthorBindingCheck < Minitest::Test
  ACTOR_ID = 'http://example.com/users/real_author_42'
  ACTOR_USER = OpenStruct.new(id: ACTOR_ID, username: 'real_author_42', apikey: 'key-author-42')

  ADMIN_ACTOR_ID = 'http://example.com/users/admin_boss_99'
  ADMIN_USER = OpenStruct.new(id: ADMIN_ACTOR_ID, username: 'admin_boss_99', admin: true, apikey: 'key-admin-secret-99')

  def setup
    @note_init_calls = 0
    @reply_init_calls = 0
    @note_save_calls = 0
    @reply_save_calls = 0
    @last_note_values = nil
    @last_reply_values = nil
    @last_note_payload = nil
    @last_reply_payload = nil
  end

  def dispatch_create(params = {}, user = ACTOR_USER)
    req = ActionDispatch::TestRequest.create('rack.session' => {})
    req.session[:user] = user if user
    params.each { |k, v| req.params[k] = v }
    res = ActionDispatch::TestResponse.create
    ctrl = NotesController.new
    ctrl.set_request!(req)
    ctrl.set_response!(res)
    ctrl.process(:create)
    [ctrl, req, res]
  end

  def stub_note_lifecycle(return_dto)
    old_init = LinkedData::Client::Models::Note.instance_method(:initialize) rescue nil
    old_save = LinkedData::Client::Models::Note.instance_method(:save) rescue nil
    init_counter = -> { @note_init_calls += 1 }
    save_counter = -> { @note_save_calls += 1 }
    record_values = ->(vals) { @last_note_values = vals }
    record_payload = ->(vals) { @last_note_payload = vals }

    LinkedData::Client::Models::Note.define_method(:initialize) do |options = {}|
      init_counter.call
      record_values.call(options[:values])
      super(options)
    end

    LinkedData::Client::Models::Note.define_method(:save) do |*args, **kwargs|
      save_counter.call
      record_payload.call(to_hash)
      return_dto
    end

    yield
  ensure
    LinkedData::Client::Models::Note.define_method(:initialize, old_init) if old_init
    LinkedData::Client::Models::Note.define_method(:save, old_save) if old_save
  end

  def stub_reply_lifecycle(return_dto)
    old_init = LinkedData::Client::Models::Reply.instance_method(:initialize) rescue nil
    old_save = LinkedData::Client::Models::Reply.instance_method(:save) rescue nil
    init_counter = -> { @reply_init_calls += 1 }
    save_counter = -> { @reply_save_calls += 1 }
    record_values = ->(vals) { @last_reply_values = vals }
    record_payload = ->(vals) { @last_reply_payload = vals }

    LinkedData::Client::Models::Reply.define_method(:initialize) do |options = {}|
      init_counter.call
      record_values.call(options[:values])
      super(options)
    end

    LinkedData::Client::Models::Reply.define_method(:save) do |*args, **kwargs|
      save_counter.call
      record_payload.call(to_hash)
      return_dto
    end

    yield
  ensure
    LinkedData::Client::Models::Reply.define_method(:initialize, old_init) if old_init
    LinkedData::Client::Models::Reply.define_method(:save, old_save) if old_save
  end

  # ===========================================================================
  # 1. Callback Chain Registration
  # ===========================================================================
  def test_callback_chain_includes_actual_guards_without_replacement
    callbacks = NotesController._process_action_callbacks.map(&:filter)
    auth_idx = callbacks.index(:authorize_and_redirect)
    verify_idx = callbacks.index(:verify_note_creator)

    refute_nil auth_idx, 'NotesController must declare :authorize_and_redirect callback'
    refute_nil verify_idx, 'NotesController must declare :verify_note_creator callback'
    assert_operator auth_idx, :<, verify_idx, ':authorize_and_redirect must precede :verify_note_creator'
  end

  # ===========================================================================
  # 2. Anonymous & Unusable Actor Guarding
  # ===========================================================================
  def test_anonymous_request_stopped_before_constructor_and_save_with_redirect
    dummy_dto = LinkedData::Client::Models::Note.new(values: { id: 'x', relatedOntology: ['TEST'] })
    stub_note_lifecycle(dummy_dto) do
      ctrl, req, res = dispatch_create({
        type: 'ontology',
        parent: 'TEST_ONTO',
        creator: 'http://example.com/users/spoofed_attacker',
        subject: 'Anon attempt',
        body: 'Body text'
      }, nil)

      assert_equal 302, res.status
      assert_equal 'http://test.host/', res.location
      assert_equal 0, @note_init_calls, 'Note constructor must NOT be called for anonymous request'
      assert_equal 0, @note_save_calls, 'Note save must NOT be called for anonymous request'
      assert_nil @last_note_values
      refute_includes res.body, 'alert-success'
    end
  end

  def test_missing_actor_id_stopped_before_constructor_and_save_with_redirect
    dummy_reply = LinkedData::Client::Models::Reply.new(values: { id: 'r1', parent: 'p1' })
    user_without_id = OpenStruct.new(id: nil, username: 'blank_id_user')

    stub_reply_lifecycle(dummy_reply) do
      ctrl, req, res = dispatch_create({
        type: 'reply',
        parent: 'http://example.com/notes/parent_1',
        creator: 'http://example.com/users/spoofed_attacker',
        body: 'Reply without actor id'
      }, user_without_id)

      assert_equal 302, res.status
      assert_equal 'http://test.host/', res.location
      assert_equal 0, @reply_init_calls, 'Reply constructor must NOT be called when actor id is nil'
      assert_equal 0, @reply_save_calls, 'Reply save must NOT be called when actor id is nil'
      assert_nil @last_reply_values
      refute_includes res.body, 'alert-success'
    end
  end

  def test_empty_or_whitespace_actor_id_stopped_before_constructor_and_save
    dummy_dto = LinkedData::Client::Models::Note.new(values: { id: 'x', relatedOntology: ['TEST'] })
    user_empty_id = OpenStruct.new(id: '   ', username: 'empty_id_user')

    stub_note_lifecycle(dummy_dto) do
      ctrl, req, res = dispatch_create({
        type: 'class',
        parent: 'http://example.com/class/1',
        ontology_id: 'TEST_ONTO',
        creator: 'http://example.com/users/spoofed_attacker',
        subject: 'Whitespace id attempt',
        body: 'Body text'
      }, user_empty_id)

      assert_equal 302, res.status
      assert_equal 'http://test.host/', res.location
      assert_equal 0, @note_init_calls, 'Note constructor must NOT be called when actor id is whitespace'
      assert_equal 0, @note_save_calls, 'Note save must NOT be called when actor id is whitespace'
      assert_nil @last_note_values
    end
  end

  # ===========================================================================
  # 3. Creator Binding: Ontology Comment
  # ===========================================================================
  def test_ontology_comment_binds_actor_and_ignores_spoofed_creator
    success_dto = LinkedData::Client::Models::Note.new(values: {
      id: 'http://example.com/notes/ont_1',
      relatedOntology: ['http://example.com/ontologies/TEST_ONTO'],
      subject: 'Ontology discussion',
      creator: ACTOR_ID,
      created: '2026-11-07T00:00:00Z'
    })

    stub_note_lifecycle(success_dto) do
      ctrl, req, res = dispatch_create(
        type: 'ontology',
        parent: 'TEST_ONTO',
        creator: 'http://example.com/users/spoofed_attacker',
        subject: 'Ontology discussion',
        body: 'Discussion body'
      )

      assert_equal 200, res.status
      assert_equal 1, @note_init_calls
      assert_equal 1, @note_save_calls

      # Payload creator strictly matches session actor id, ignoring spoofed creator
      assert_equal ACTOR_ID, @last_note_values[:creator]
      refute_equal 'http://example.com/users/spoofed_attacker', @last_note_values[:creator]

      # String and symbol uniqueness: exactly 1 creator key
      assert_equal 1, @last_note_values.keys.map(&:to_s).count('creator')
      assert_equal ACTOR_ID, @last_note_payload[:creator]
      assert_equal 1, @last_note_payload.keys.map(&:to_s).count('creator')
      assert_equal true, @last_note_payload.key?(:creator)
      assert_equal false, @last_note_payload.key?('creator')

      # Parent deleted from note values
      assert_nil @last_note_values[:parent]
      assert_equal ['TEST_ONTO'], @last_note_values[:relatedOntology]
    end
  end

  def test_ontology_comment_binds_actor_when_creator_omitted
    success_dto = LinkedData::Client::Models::Note.new(values: {
      id: 'http://example.com/notes/ont_2',
      relatedOntology: ['http://example.com/ontologies/TEST_ONTO'],
      subject: 'Omitted creator discussion',
      creator: ACTOR_ID,
      created: '2026-11-07T00:00:00Z'
    })

    stub_note_lifecycle(success_dto) do
      ctrl, req, res = dispatch_create(
        type: 'ontology',
        parent: 'TEST_ONTO',
        subject: 'Omitted creator discussion',
        body: 'Discussion body'
      )

      assert_equal 200, res.status
      assert_equal 1, @note_save_calls
      assert_equal ACTOR_ID, @last_note_values[:creator]
    end
  end

  # ===========================================================================
  # 4. Creator Binding: Class Comment
  # ===========================================================================
  def test_class_comment_binds_actor_and_ignores_spoofed_creator
    success_dto = LinkedData::Client::Models::Note.new(values: {
      id: 'http://example.com/notes/cls_1',
      relatedOntology: ['http://example.com/ontologies/TEST_ONTO'],
      relatedClass: [{ ontology: 'TEST_ONTO', class: 'http://example.com/class/99' }],
      subject: 'Class comment',
      creator: ACTOR_ID,
      created: '2026-11-07T00:00:00Z'
    })

    stub_note_lifecycle(success_dto) do
      ctrl, req, res = dispatch_create(
        type: 'class',
        parent: 'http://example.com/class/99',
        ontology_id: 'TEST_ONTO',
        creator: 'http://example.com/users/spoofed_attacker',
        subject: 'Class comment',
        body: 'Class comment body'
      )

      assert_equal 200, res.status
      assert_equal 1, @note_save_calls

      assert_equal ACTOR_ID, @last_note_values[:creator]
      refute_equal 'http://example.com/users/spoofed_attacker', @last_note_values[:creator]
      assert_equal 1, @last_note_values.keys.map(&:to_s).count('creator')
      assert_equal ACTOR_ID, @last_note_payload[:creator]
      assert_equal 1, @last_note_payload.keys.map(&:to_s).count('creator')
      assert_equal true, @last_note_payload.key?(:creator)
      assert_equal false, @last_note_payload.key?('creator')
    end
  end

  # ===========================================================================
  # 5. Creator Binding: Proposal
  # ===========================================================================
  def test_proposal_binds_actor_and_ignores_spoofed_creator
    expected_subject = "#{NotesController::NOTES_PROPOSAL_TYPES[:ProposalNewClass]}: Proposal reason"
    success_dto = LinkedData::Client::Models::Note.new(values: {
      id: 'http://example.com/notes/prop_1',
      relatedOntology: ['http://example.com/ontologies/TEST_ONTO'],
      subject: expected_subject,
      creator: ACTOR_ID,
      created: '2026-11-07T00:00:00Z',
      proposal: OpenStruct.new(type: 'ProposalNewClass')
    })

    stub_note_lifecycle(success_dto) do
      ctrl, req, res = dispatch_create(
        type: 'ontology',
        parent: 'TEST_ONTO',
        creator: 'http://example.com/users/spoofed_attacker',
        proposal: {
          type: 'ProposalNewClass',
          reasonForChange: 'Proposal reason',
          classId: 'http://example.com/class/NewTerm',
          label: 'New Term'
        }
      )

      assert_equal 200, res.status
      assert_equal 1, @note_save_calls

      assert_equal ACTOR_ID, @last_note_values[:creator]
      refute_equal 'http://example.com/users/spoofed_attacker', @last_note_values[:creator]
      assert_equal 1, @last_note_values.keys.map(&:to_s).count('creator')
      assert_equal ACTOR_ID, @last_note_payload[:creator]
      assert_equal 1, @last_note_payload.keys.map(&:to_s).count('creator')
      assert_equal true, @last_note_payload.key?(:creator)
      assert_equal false, @last_note_payload.key?('creator')
      assert_equal expected_subject, @last_note_values[:subject]
    end
  end

  # ===========================================================================
  # 6. Creator Binding: Reply
  # ===========================================================================
  def test_reply_binds_actor_and_ignores_spoofed_creator
    success_reply = LinkedData::Client::Models::Reply.new(values: {
      id: 'http://example.com/notes/p1/replies/r1',
      parent: 'http://example.com/notes/p1',
      creator: ACTOR_ID,
      body: 'Reply message',
      created: '2026-11-07T00:00:00Z'
    })

    stub_reply_lifecycle(success_reply) do
      ctrl, req, res = dispatch_create(
        type: 'reply',
        parent: 'http://example.com/notes/p1',
        creator: 'http://example.com/users/spoofed_attacker',
        body: 'Reply message'
      )

      assert_equal 200, res.status
      assert_equal 1, @reply_init_calls
      assert_equal 1, @reply_save_calls

      assert_equal ACTOR_ID, @last_reply_values[:creator]
      refute_equal 'http://example.com/users/spoofed_attacker', @last_reply_values[:creator]
      assert_equal 1, @last_reply_values.keys.map(&:to_s).count('creator')
      assert_equal ACTOR_ID, @last_reply_payload[:creator]
      assert_equal 1, @last_reply_payload.keys.map(&:to_s).count('creator')
      assert_equal true, @last_reply_payload.key?(:creator)
      assert_equal false, @last_reply_payload.key?('creator')
    end
  end

  # ===========================================================================
  # 7. Admin Spoof Defense & Credential Preservation
  # ===========================================================================
  def test_admin_spoof_still_uses_actor_id_and_preserves_session_credentials
    initial_user_object_id = ADMIN_USER.object_id
    initial_apikey = ADMIN_USER.apikey

    success_dto = LinkedData::Client::Models::Note.new(values: {
      id: 'http://example.com/notes/admin_note_1',
      relatedOntology: ['http://example.com/ontologies/TEST_ONTO'],
      subject: 'Admin note',
      creator: ADMIN_ACTOR_ID,
      created: '2026-11-07T00:00:00Z'
    })

    stub_note_lifecycle(success_dto) do
      ctrl, req, res = dispatch_create({
        type: 'ontology',
        parent: 'TEST_ONTO',
        creator: 'http://example.com/users/subordinate_user',
        subject: 'Admin note',
        body: 'Admin created note'
      }, ADMIN_USER)

      assert_equal 200, res.status
      assert_equal 1, @note_save_calls

      # Admin cannot choose another author through the hidden field
      assert_equal ADMIN_ACTOR_ID, @last_note_values[:creator]
      refute_equal 'http://example.com/users/subordinate_user', @last_note_values[:creator]

      # Session credentials and identity completely preserved
      assert_equal initial_user_object_id, req.session[:user].object_id, 'Session user object identity must not change'
      assert_equal initial_apikey, req.session[:user].apikey, 'Admin apikey must not change'
      assert_equal 'key-admin-secret-99', req.session[:user].apikey
      assert_equal true, req.session[:user].admin
    end
  end

  # ===========================================================================
  # 8. Hash-backed Session User Support
  # ===========================================================================
  def test_hash_backed_session_user_actor_binding
    hash_user = { id: 'http://example.com/users/hash_actor_77', username: 'hash_actor' }
    success_dto = LinkedData::Client::Models::Note.new(values: {
      id: 'http://example.com/notes/hash_note_1',
      relatedOntology: ['http://example.com/ontologies/TEST_ONTO'],
      subject: 'Hash user note',
      creator: 'http://example.com/users/hash_actor_77',
      created: '2026-11-07T00:00:00Z'
    })

    stub_note_lifecycle(success_dto) do
      ctrl, req, res = dispatch_create({
        type: 'ontology',
        parent: 'TEST_ONTO',
        creator: 'http://example.com/users/spoofed_attacker',
        subject: 'Hash user note',
        body: 'Body text'
      }, hash_user)

      assert_equal 200, res.status
      assert_equal 1, @note_save_calls
      assert_equal 'http://example.com/users/hash_actor_77', @last_note_values[:creator]
    end
  end
end
