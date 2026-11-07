# frozen_string_literal: true

require 'minitest/autorun'
require 'logger'
require 'ostruct'
require 'cgi'
require 'faraday'

# =============================================================================
# Standalone Offline Note/Reply Create Result Inspection Check (ONTO-T-B15)
#
# Validates the B15 contract for NotesController#create result inspection:
# 1. Inspect nil/error/known status immediately after save and return actual error
#    stream BEFORE reading success-only fields (e.g. relatedOntology.first).
# 2. Confirmed API/validation error with no relatedOntology returns error stream
#    without NoMethodError, prepends zero rows, and emits zero success alerts.
# 3. Successful ontology/class comment and proposal prepend exactly one row with
#    correct locals and emit one success alert.
# 4. Reply error/success retain exact parent thread_replay_container and parent_reply
#    targets (preserving existing spelling) without false saved messages.
# 5. Unknown timeout-after-write, nil response, or malformed nominal response are
#    explicitly UNCERTAIN, do not claim write failed, suggest thread check, and
#    never repeat save automatically (exactly 1 save attempt).
# 6. Submitted values and form remain available on error; no arbitrary normalization changes.
# 7. Characterize pinned SDK Base and HTTP response conversion behavior.
# 8. Preserve programming errors and fatal exceptions without blanket swallowing.
# =============================================================================

# Ensure gem load paths in native container environment
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

# Require pinned SDK
require 'ontologies_api_client'

# Configure loggers and global app constants
ActionController::Base.logger = Logger.new(nil)
Rails.logger = Logger.new(nil)
$ENABLE_SLICES = false
$REST_URL = 'http://example.com'
$API_KEY = 'test'

# Load localization dictionaries
I18n.load_path = Dir[File.join(worktree_root, 'config/locales/*.yml')]
I18n.default_locale = :en
I18n.locale = :en

# Required helpers
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

# Finite presentation helpers for offline template rendering
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

class NoteCreateResultCheck < Minitest::Test
  def setup
    @note_save_calls = 0
    @reply_save_calls = 0
    @last_note_values = nil
    @last_reply_values = nil
  end

  AUTHENTICATED_ACTOR_ID = 'http://example.com/users/authenticated_b15_actor'
  AUTHENTICATED_USER = OpenStruct.new(id: AUTHENTICATED_ACTOR_ID, username: 'authenticated_b15_actor')

  # Dispatch helper that invokes actual NotesController#create
  def dispatch_create(params = {}, user = AUTHENTICATED_USER)
    req = ActionDispatch::TestRequest.create('rack.session' => {})
    req.session[:user] = user if user
    params.each { |k, v| req.params[k] = v }
    res = ActionDispatch::TestResponse.create
    ctrl = NotesController.new
    ctrl.set_request!(req)
    ctrl.set_response!(res)
    ctrl.process(:create)
    [ctrl, res]
  end

  # Helper for temporarily stubbing Note.save
  def stub_note_save(callable_or_val)
    old_method = LinkedData::Client::Models::Note.instance_method(:save) rescue nil
    counter = -> { @note_save_calls += 1 }
    record_values = ->(vals) { @last_note_values = vals }
    LinkedData::Client::Models::Note.define_method(:save) do |*args, **kwargs|
      counter.call
      record_values.call(to_hash)
      if callable_or_val.is_a?(Proc) || callable_or_val.is_a?(Method)
        callable_or_val.call
      else
        callable_or_val
      end
    end
    yield
  ensure
    if old_method
      LinkedData::Client::Models::Note.define_method(:save, old_method)
    else
      LinkedData::Client::Models::Note.remove_method(:save) rescue nil
    end
  end

  # Helper for temporarily stubbing Reply.save
  def stub_reply_save(callable_or_val)
    old_method = LinkedData::Client::Models::Reply.instance_method(:save) rescue nil
    counter = -> { @reply_save_calls += 1 }
    record_values = ->(vals) { @last_reply_values = vals }
    LinkedData::Client::Models::Reply.define_method(:save) do |*args, **kwargs|
      counter.call
      record_values.call(to_hash)
      if callable_or_val.is_a?(Proc) || callable_or_val.is_a?(Method)
        callable_or_val.call
      else
        callable_or_val
      end
    end
    yield
  ensure
    if old_method
      LinkedData::Client::Models::Reply.define_method(:save, old_method)
    else
      LinkedData::Client::Models::Reply.remove_method(:save) rescue nil
    end
  end

  # ---------------------------------------------------------------------------
  # 1. Pinned SDK Characterization
  # ---------------------------------------------------------------------------
  def test_sdk_base_respond_to_and_missing_readers
    base_inst = LinkedData::Client::Models::Note.new

    # Pinned SDK behavior: LinkedData::Client::Base#respond_to? returns true for arbitrary readers
    assert_equal true, base_inst.respond_to?(:non_existent_field)
    assert_nil base_inst.non_existent_field
    assert_nil base_inst.errors

    # Setting attributes defines accessors
    base_inst.subject = 'Custom Subject'
    assert_equal 'Custom Subject', base_inst.subject
  end

  def test_sdk_object_from_json_conversions
    # Successful note shape
    json_note = %q{{"@id": "http://data.bioontology.org/ontologies/TEST/notes/100", "@type": "http://data.bioontology.org/metadata/Note", "relatedOntology": ["http://data.bioontology.org/ontologies/TEST"], "subject": "Note Title"}}
    note_obj = LinkedData::Client::HTTP.object_from_json(json_note)
    assert_instance_of LinkedData::Client::Models::Note, note_obj
    assert_equal 'http://data.bioontology.org/ontologies/TEST/notes/100', note_obj.id
    assert_equal ['http://data.bioontology.org/ontologies/TEST'], note_obj.relatedOntology
    assert_nil note_obj.errors

    # Successful reply shape
    json_reply = %q{{"@id": "http://data.bioontology.org/ontologies/TEST/notes/100/replies/200", "@type": "http://data.bioontology.org/metadata/Reply", "parent": "http://data.bioontology.org/ontologies/TEST/notes/100", "body": "Reply Body"}}
    reply_obj = LinkedData::Client::HTTP.object_from_json(json_reply)
    assert_instance_of LinkedData::Client::Models::Reply, reply_obj
    assert_equal 'http://data.bioontology.org/ontologies/TEST/notes/100/replies/200', reply_obj.id
    assert_nil reply_obj.errors

    # Ordinary API error response shape
    json_err = %q{{"errors": ["Subject cannot be blank"]}}
    err_obj = LinkedData::Client::HTTP.object_from_json(json_err)
    assert_instance_of OpenStruct, err_obj
    assert_equal ['Subject cannot be blank'], err_obj.errors
    assert_nil err_obj.relatedOntology
    refute err_obj.respond_to?(:relatedOntology)
  end

  # ---------------------------------------------------------------------------
  # 2. Confirmed Rejection / Error Handling (ONTO-B15 Core Bug)
  # ---------------------------------------------------------------------------
  def test_error_response_produces_error_stream_and_no_nomethoderror_and_no_row
    # In unpatched code, new_note.relatedOntology.first was accessed BEFORE new_note.errors check,
    # raising NoMethodError on error OpenStruct without relatedOntology.
    stub_note_save(OpenStruct.new(errors: ['Subject cannot be blank'])) do
      ctrl, res = dispatch_create(
        type: 'ontology',
        parent: 'TEST_ONTO',
        creator: 'http://example.com/users/tester',
        subject: '',
        body: 'Body text'
      )

      assert_equal 200, res.status
      assert_equal 1, @note_save_calls

      # Prepend target is alerts container, NOT notes table body
      assert_includes res.body, 'action="prepend" target="notes_alerts_container"'
      assert_includes res.body, 'Subject cannot be blank'

      # No row prepended and no success alert emitted
      refute_includes res.body, 'ontology_notes_table_body'
      refute_includes res.body, 'alert-success'
      refute_includes res.body, I18n.t('notes.new_comment_added')

      # Submitted inputs remain available in params on error (not stripped)
      assert_equal 'TEST_ONTO', ctrl.params[:parent]
      assert_equal 'ontology', ctrl.params[:type]
      assert_equal 'Body text', ctrl.params[:body]
    end
  end

  def test_http_4xx_status_response_produces_error_stream
    stub_note_save(OpenStruct.new(status: 422, errors: ['Invalid note property'])) do
      ctrl, res = dispatch_create(
        type: 'class',
        parent: 'http://example.com/class/1',
        ontology_id: 'TEST_ONTO',
        creator: 'http://example.com/users/tester',
        subject: 'Bad property note',
        body: 'Body text'
      )

      assert_equal 200, res.status
      assert_equal 1, @note_save_calls
      assert_includes res.body, 'action="prepend" target="notes_alerts_container"'
      assert_includes res.body, 'Invalid note property'
      refute_includes res.body, 'class_notes_table_body'
      refute_includes res.body, 'alert-success'

      # Preserved submitted inputs
      assert_equal 'http://example.com/class/1', ctrl.params[:parent]
      assert_equal 'TEST_ONTO', ctrl.params[:ontology_id]
    end
  end

  # ---------------------------------------------------------------------------
  # 3. Successful Note / Proposal Creation
  # ---------------------------------------------------------------------------
  def test_successful_ontology_comment_prepends_exactly_one_row_with_correct_locals
    success_dto = LinkedData::Client::Models::Note.new(values: {
      id: 'http://example.com/ontologies/TEST_ONTO/notes/101',
      relatedOntology: ['http://example.com/ontologies/TEST_ONTO'],
      subject: 'Ontology discussion',
      creator: 'http://example.com/users/alice',
      created: '2026-11-07T00:00:00Z'
    })

    stub_note_save(success_dto) do
      ctrl, res = dispatch_create(
        type: 'ontology',
        parent: 'TEST_ONTO',
        creator: 'http://example.com/users/alice',
        subject: 'Ontology discussion',
        body: 'Discussion body'
      )

      assert_equal 200, res.status
      assert_equal 1, @note_save_calls

      # Exactly one success alert and exactly one note row prepended
      assert_equal 1, res.body.scan('action="prepend" target="notes_alerts_container"').length
      assert_equal 1, res.body.scan('action="prepend" target="ontology_notes_table_body"').length

      assert_includes res.body, I18n.t('notes.new_comment_added')
      assert_includes res.body, 'http://example.com/ontologies/TEST_ONTO/notes/101_tr_ontology'
      assert_includes res.body, 'Ontology discussion'

      # Note values passed to SDK save had parent stripped from API payload and creator bound to authenticated actor
      assert_nil @last_note_values[:parent]
      assert_equal ['TEST_ONTO'], @last_note_values[:relatedOntology]
      assert_equal AUTHENTICATED_ACTOR_ID, @last_note_values[:creator]
    end
  end

  def test_successful_class_comment_prepends_exactly_one_row_with_correct_locals
    success_dto = LinkedData::Client::Models::Note.new(values: {
      id: 'http://example.com/ontologies/TEST_ONTO/notes/102',
      relatedOntology: ['http://example.com/ontologies/TEST_ONTO'],
      relatedClass: [{ ontology: 'TEST_ONTO', class: 'http://example.com/class/42' }],
      subject: 'Class specific comment',
      creator: 'http://example.com/users/bob',
      created: '2026-11-07T00:00:00Z'
    })

    stub_note_save(success_dto) do
      ctrl, res = dispatch_create(
        type: 'class',
        parent: 'http://example.com/class/42',
        ontology_id: 'TEST_ONTO',
        creator: 'http://example.com/users/bob',
        subject: 'Class specific comment',
        body: 'Class comment body'
      )

      assert_equal 200, res.status
      assert_equal 1, @note_save_calls

      assert_equal 1, res.body.scan('action="prepend" target="notes_alerts_container"').length
      assert_equal 1, res.body.scan('action="prepend" target="class_notes_table_body"').length

      assert_includes res.body, I18n.t('notes.new_comment_added')
      assert_includes res.body, 'http://example.com/ontologies/TEST_ONTO/notes/102_tr_class'
      assert_includes res.body, 'Class specific comment'

      # Correctly mapped relatedClass and relatedOntology, and creator bound to authenticated actor
      assert_equal ['TEST_ONTO'], @last_note_values[:relatedOntology]
      mapped_class = @last_note_values[:relatedClass].first
      assert_equal 'TEST_ONTO', (mapped_class[:ontology] || mapped_class['ontology'])
      assert_equal 'http://example.com/class/42', (mapped_class[:class] || mapped_class['class'])
      assert_nil @last_note_values[:parent]
      assert_equal AUTHENTICATED_ACTOR_ID, @last_note_values[:creator]
    end
  end

  def test_successful_proposal_prepends_exactly_one_row_with_generated_subject_and_cast_lists
    proposal_type_label = NotesController::NOTES_PROPOSAL_TYPES[:ProposalNewClass]
    expected_subject = "#{proposal_type_label}: New term needed"

    success_dto = LinkedData::Client::Models::Note.new(values: {
      id: 'http://example.com/ontologies/TEST_ONTO/notes/103',
      relatedOntology: ['http://example.com/ontologies/TEST_ONTO'],
      subject: expected_subject,
      creator: 'http://example.com/users/carol',
      created: '2026-11-07T00:00:00Z',
      proposal: OpenStruct.new(type: 'ProposalNewClass')
    })

    stub_note_save(success_dto) do
      ctrl, res = dispatch_create(
        type: 'ontology',
        parent: 'TEST_ONTO',
        creator: 'http://example.com/users/carol',
        proposal: {
          type: 'ProposalNewClass',
          reasonForChange: 'New term needed',
          classId: 'http://example.com/class/NewTerm',
          label: 'New Term',
          synonym: 'synonymA,synonymB',
          definition: 'Definition 1,Definition 2',
          newRelationshipType: 'isA,partOf'
        }
      )

      assert_equal 200, res.status
      assert_equal 1, @note_save_calls

      assert_equal 1, res.body.scan('action="prepend" target="ontology_notes_table_body"').length
      assert_includes res.body, expected_subject

      # Verified proposal values passed to SDK had comma-separated lists cast to arrays and creator bound to authenticated actor
      assert_equal ['synonymA', 'synonymB'], @last_note_values[:proposal][:synonym]
      assert_equal ['Definition 1', 'Definition 2'], @last_note_values[:proposal][:definition]
      assert_equal ['isA', 'partOf'], @last_note_values[:proposal][:newRelationshipType]
      assert_equal expected_subject, @last_note_values[:subject]
      assert_equal AUTHENTICATED_ACTOR_ID, @last_note_values[:creator]

      # Original submitted values remain available in params
      assert_equal 'synonymA,synonymB', ctrl.params[:proposal][:synonym]
      assert_equal 'TEST_ONTO', ctrl.params[:parent]
    end
  end

  # ---------------------------------------------------------------------------
  # 4. Reply Error and Success Routing
  # ---------------------------------------------------------------------------
  def test_successful_reply_prepends_to_exact_thread_replay_container_without_success_alert
    success_reply = LinkedData::Client::Models::Reply.new(values: {
      id: 'http://example.com/notes/parent_123/replies/555',
      parent: 'http://example.com/notes/parent_123',
      creator: 'http://example.com/users/dave',
      body: 'Clear affirmative reply',
      created: '2026-11-07T00:00:00Z'
    })

    stub_reply_save(success_reply) do
      ctrl, res = dispatch_create(
        type: 'reply',
        parent: 'http://example.com/notes/parent_123',
        creator: 'http://example.com/users/dave',
        body: 'Clear affirmative reply'
      )

      assert_equal 200, res.status
      assert_equal 1, @reply_save_calls

      # Exact target: parent + _thread_replay_container (retaining existing spelling)
      assert_includes res.body, 'action="prepend" target="http://example.com/notes/parent_123_thread_replay_container"'
      assert_includes res.body, 'Clear affirmative reply'
      assert_equal AUTHENTICATED_ACTOR_ID, @last_reply_values[:creator]

      # No false saved message or success alert for replies
      refute_includes res.body, 'alert-success'
      refute_includes res.body, I18n.t('notes.new_comment_added')
    end
  end

  def test_rejected_reply_targets_parent_reply_frame_without_success
    stub_reply_save(OpenStruct.new(errors: ['Reply body cannot be blank'])) do
      ctrl, res = dispatch_create(
        type: 'reply',
        parent: 'http://example.com/notes/parent_123',
        creator: 'http://example.com/users/dave',
        body: ''
      )

      assert_equal 200, res.status
      assert_equal 1, @reply_save_calls

      # Exact target: parent + _reply
      assert_includes res.body, 'action="prepend" target="http://example.com/notes/parent_123_reply"'
      assert_includes res.body, 'Reply body cannot be blank'

      refute_includes res.body, 'thread_replay_container'
      refute_includes res.body, 'alert-success'

      # Preserved input params
      assert_equal 'http://example.com/notes/parent_123', ctrl.params[:parent]
      assert_equal 'reply', ctrl.params[:type]
    end
  end

  # ---------------------------------------------------------------------------
  # 5. Ambiguous / Uncertain Write Outcomes
  # ---------------------------------------------------------------------------
  def test_timeout_after_write_produces_uncertain_message_and_no_repeat_save
    stub_note_save(-> { raise Faraday::TimeoutError, 'Net read timeout after post' }) do
      ctrl, res = dispatch_create(
        type: 'ontology',
        parent: 'TEST_ONTO',
        creator: 'http://example.com/users/eve',
        subject: 'Timeout check',
        body: 'Timeout body'
      )

      assert_equal 200, res.status
      assert_equal 1, @note_save_calls # NO automatic retry

      assert_includes res.body, 'action="prepend" target="notes_alerts_container"'
      assert_includes res.body, I18n.t('notes.save_uncertain')

      # Must not claim write failed/wasn't saved, and suggests checking thread
      refute_includes res.body, 'failed'
      assert_includes res.body, 'uncertain'
      assert_includes res.body, 'check the thread'

      refute_includes res.body, 'ontology_notes_table_body'
      refute_includes res.body, 'alert-success'

      # Preserves submitted inputs
      assert_equal 'TEST_ONTO', ctrl.params[:parent]
      assert_equal 'Timeout check', ctrl.params[:subject]
    end
  end

  def test_nil_save_result_produces_uncertain_message
    stub_note_save(nil) do
      ctrl, res = dispatch_create(
        type: 'ontology',
        parent: 'TEST_ONTO',
        creator: 'http://example.com/users/eve',
        subject: 'Nil result check',
        body: 'Nil body'
      )

      assert_equal 200, res.status
      assert_equal 1, @note_save_calls
      assert_includes res.body, 'action="prepend" target="notes_alerts_container"'
      assert_includes res.body, I18n.t('notes.save_uncertain')
      refute_includes res.body, 'ontology_notes_table_body'
      refute_includes res.body, 'alert-success'
    end
  end

  def test_malformed_nominal_response_produces_uncertain_message
    # Empty OpenStruct without id and without errors
    stub_note_save(OpenStruct.new(randomField: 'unexpected')) do
      ctrl, res = dispatch_create(
        type: 'ontology',
        parent: 'TEST_ONTO',
        creator: 'http://example.com/users/eve',
        subject: 'Malformed body check',
        body: 'Malformed body'
      )

      assert_equal 200, res.status
      assert_equal 1, @note_save_calls
      assert_includes res.body, 'action="prepend" target="notes_alerts_container"'
      assert_includes res.body, I18n.t('notes.save_uncertain')
      refute_includes res.body, 'ontology_notes_table_body'
      refute_includes res.body, 'alert-success'
    end
  end

  def test_note_missing_related_ontology_without_errors_produces_uncertain_message
    # Note with id but empty relatedOntology and no errors
    nominal_but_missing_ont = LinkedData::Client::Models::Note.new(values: {
      id: 'http://example.com/notes/orphan',
      relatedOntology: []
    })

    stub_note_save(nominal_but_missing_ont) do
      ctrl, res = dispatch_create(
        type: 'ontology',
        parent: 'TEST_ONTO',
        creator: 'http://example.com/users/eve',
        subject: 'Orphan note',
        body: 'Body'
      )

      assert_equal 200, res.status
      assert_equal 1, @note_save_calls
      assert_includes res.body, 'action="prepend" target="notes_alerts_container"'
      assert_includes res.body, I18n.t('notes.save_uncertain')
      refute_includes res.body, 'ontology_notes_table_body'
      refute_includes res.body, 'alert-success'
    end
  end

  # ---------------------------------------------------------------------------
  # 6. Exception Preservation (No Blanket Swallowing)
  # ---------------------------------------------------------------------------
  def test_programming_errors_and_fatal_exceptions_are_preserved
    stub_note_save(-> { raise ArgumentError, 'Unexpected argument error' }) do
      assert_raises(ArgumentError) do
        dispatch_create(
          type: 'ontology',
          parent: 'TEST_ONTO',
          creator: 'http://example.com/users/eve',
          subject: 'Fatal test',
          body: 'Body'
        )
      end
      assert_equal 1, @note_save_calls
    end
  end
end
