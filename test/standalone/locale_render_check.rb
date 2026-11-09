# frozen_string_literal: true

require 'minitest/autorun'
require 'logger'
require 'ostruct'
require 'cgi'
require 'set'
require 'yaml'

# =============================================================================
# Standalone Locale Render & Notice Verification (ONTO-AT-L01 & ONTO-AT-L02)
#
# Validates:
# 1. L01 metadata help: SubmissionsHelper#metadata_help_link renders cleanly for
#    :en and :fr with isolated configured help URL, asserting href, anchor, and
#    complete absence of '%{' or '%{link)'. Exercises all caller templates.
# 2. L01 language selector: Input::LanguageSelectorComponent renders an informative
#    placeholder under existing key ('Select a language' in en, existing fr in fr,
#    never '/'), preserving option values, submitted name, and element id.
# 3. L01 static integrity: flags malformed delimiters and incompatible placeholders
#    between en.yml and fr.yml, explicitly allowing plural/count branches (e.g.
#    admin.licenses.license_notification.license_trial.one).
# 4. L02 controller dispatch: OntologiesAdministrationController#destroy_submission
#    with finite LinkedData::Client::HTTP.delete double returning HTTP 202 (queued)
#    and failure responses in :en and :fr, bypassing authorize_ontology_admin
#    via a finite Ontology double.
# =============================================================================

if Dir.exist?('/usr/local/bundle/ruby/3.1.0/gems') && (ENV['GEM_PATH'].nil? || !ENV['GEM_PATH'].include?('/usr/local/bundle/ruby/3.1.0'))
  Gem.use_paths(nil, Gem.path + ['/usr/local/bundle/ruby/3.1.0'])
end

sdk_lib = Dir.glob('/usr/local/bundle/ruby/3.1.0/bundler/gems/ontologies_api_ruby_client-*/lib').first ||
          '/usr/local/bundle/ruby/3.1.0/bundler/gems/ontologies_api_ruby_client-6257685e5744/lib'
$LOAD_PATH.unshift(sdk_lib) if sdk_lib && Dir.exist?(sdk_lib) && !$LOAD_PATH.include?(sdk_lib)

WORKTREE_ROOT = File.expand_path('../..', __dir__)
$LOAD_PATH.unshift(File.join(WORKTREE_ROOT, 'app/helpers'))
$LOAD_PATH.unshift(File.join(WORKTREE_ROOT, 'app/components'))
$LOAD_PATH.unshift(File.join(WORKTREE_ROOT, 'app/controllers/concerns'))
$LOAD_PATH.unshift(File.join(WORKTREE_ROOT, 'app/controllers'))

require 'rails'
require 'active_support/all'
require 'action_controller'
require 'action_view'
require 'action_dispatch'
require 'active_record'
require 'action_view/testing/resolvers'
require 'haml'
require 'haml/template'
require 'haml/template/options' rescue nil
require 'haml/plugin' rescue nil
require 'view_component'
require 'ontologies_api_client'

begin
  require 'flag_icons_rails'
rescue LoadError
  begin
    require 'flag-icons-rails'
  rescue LoadError
    nil
  end
end

module FlagIconsRails
  module Rails
    module ViewHelpers
      def flag_icon(code)
        %(<span class="flag-icon flag-icon-#{code}"></span>).html_safe
      end unless method_defined?(:flag_icon)
    end
  end
end

require 'iso-639' rescue nil

module Turbo
  module Streams
  end
  module FramesHelper
    def turbo_frame_tag(id, &block)
      content = block ? capture(&block) : ''
      %(<turbo-frame id="#{id}">#{content}</turbo-frame>).html_safe
    end unless method_defined?(:turbo_frame_tag)
  end
end

begin
  require '/usr/local/bundle/ruby/3.1.0/gems/turbo-rails-2.0.12/app/helpers/turbo/frames_helper.rb'
  require '/usr/local/bundle/ruby/3.1.0/gems/turbo-rails-2.0.12/app/helpers/turbo/streams_helper.rb'
rescue LoadError
  nil
end

ActionView::Base.include Turbo::FramesHelper if defined?(Turbo::FramesHelper)
ActionView::Base.include Turbo::StreamsHelper if defined?(Turbo::StreamsHelper)

# Real Rails I18n configuration with en.yml and fr.yml
I18n.load_path = [
  File.join(WORKTREE_ROOT, 'config/locales/en.yml'),
  File.join(WORKTREE_ROOT, 'config/locales/fr.yml')
]
I18n.available_locales = [:en, :fr]
I18n.default_locale = :en
I18n.locale = :en

# Isolated configured help URL
HELP_URL = 'https://example.org/help/metadata'
SETTINGS_STUB = OpenStruct.new(links: { metadata_help: HELP_URL })

begin
  Class.new(Rails::Application) do
    config.eager_load = false
    config.secret_key_base = ('0' * 64)
  end
rescue StandardError
  nil
end

if Rails.respond_to?(:application) && Rails.application
  Rails.configuration.settings = SETTINGS_STUB
else
  Rails.define_singleton_method(:configuration) do
    @configuration ||= OpenStruct.new(settings: SETTINGS_STUB)
  end
end

$SITE = 'TestPortal'
$REST_URL = 'http://example.com'
$API_KEY = 'test'
ActionController::Base.logger = Logger.new(nil)
Rails.logger = Logger.new(nil)
Rails.cache = ActiveSupport::Cache::MemoryStore.new

LinkedData::Client.config do |config|
  config.rest_url = 'http://example.com'
  config.links_attr = 'links'
end

# Standalone Route Helpers
module StandaloneRouteHelperStubs
  def root_path(*args, **kwargs)
    '/'
  end

  def ontology_administration_path(acronym, *args, **kwargs)
    "/ontologies/#{acronym}/admin"
  end

  def my_ontologies_path(*args, **kwargs)
    '/my_ontologies'
  end

  def ontology_submission_path(acronym, id, *args, **kwargs)
    "/ontologies/#{acronym}/submissions/#{id}"
  end
end

ActionController::Base.include StandaloneRouteHelperStubs
ActionView::Base.include StandaloneRouteHelperStubs

require 'urls_helper'
require 'terms_reuses'
require 'modal_helper'
require 'components_helper'
require 'ontologies_helper'
require 'internationalisation_helper'
require 'multi_languages_helper'
require 'submissions_helper'
require 'application_helper'
require 'application_controller'
require 'ontologies_administration_controller'

module Input; end
module Display
  class AlertComponent < ViewComponent::Base
    attr_reader :id, :type

    def initialize(id: nil, type: 'info', **_opts)
      @id = id
      @type = type
    end

    def render_in(view_context, &block)
      content = block ? view_context.capture(&block) : ''
      %(<div class="alert alert-#{@type}" id="#{@id}">#{content}</div>).html_safe
    end
  end
end

require File.join(WORKTREE_ROOT, 'app/components/loader_component')
require File.join(WORKTREE_ROOT, 'app/components/select_input_component')
require File.join(WORKTREE_ROOT, 'app/components/language_field_component')
require File.join(WORKTREE_ROOT, 'app/components/input/language_selector_component')
require File.join(WORKTREE_ROOT, 'app/components/turbo_frame_component')

ADMIN_FIXTURE_RESOLVER = ActionView::FixtureResolver.new(
  'ontologies/admin.html.erb' => '<div>Admin</div>',
  'ontologies/admin/_submissions_table.html.erb' => '<div>Submissions Table</div>',
  'ontologies/admin/_log.html.erb' => '<div>Admin Log</div>'
)

OntologiesAdministrationController.view_paths = [ADMIN_FIXTURE_RESOLVER]
OntologiesAdministrationController.layout false
OntologiesAdministrationController.skip_before_action :set_locale, :domain_ontology_set, :clean_empty_strings_from_params_arrays, :init_trial_license, :set_global_thread_values, raise: false

# Finite Doubles
module LinkedData::Client::HTTP
  class << self
    attr_accessor :delete_response, :last_delete_path, :delete_calls

    def reset!
      @delete_response = OpenStruct.new(status: 202, body: '')
      @last_delete_path = nil
      @delete_calls = 0
    end

    def delete(path, *args, **kwargs)
      @delete_calls += 1
      @last_delete_path = path
      @delete_response
    end
  end
end

class LinkedData::Client::Models::Ontology
  class << self
    attr_accessor :find_calls, :mock_ontology

    def reset!
      @find_calls = 0
      @mock_ontology = OpenStruct.new(
        acronym: 'TEST_ONT',
        id: 'http://example.com/ontologies/TEST_ONT',
        administeredBy: ['http://example.com/users/admin_user']
      )
    end

    def find_by_acronym(acronym, _options = {})
      @find_calls += 1
      [@mock_ontology]
    end
  end
end

class LocaleRenderCheck < Minitest::Test
  ADMIN_USER = OpenStruct.new(id: 'http://example.com/users/admin_user', username: 'admin_user', admin?: true).freeze

  def setup
    LinkedData::Client::HTTP.reset!
    LinkedData::Client::Models::Ontology.reset!
    I18n.locale = :en
  end

  def teardown
    I18n.locale = :en
    Thread.current[:request] = nil
    Thread.current[:session] = nil
  end

  def create_view_context
    lookup_context = ActionView::LookupContext.new([
      File.join(WORKTREE_ROOT, 'app/views'),
      File.join(WORKTREE_ROOT, 'app/components'),
      File.join(WORKTREE_ROOT, 'app/components/language_field_component')
    ])
    vc = ActionView::Base.new(lookup_context, {}, ActionController::Base.new)
    vc.extend(ActionView::Helpers::TagHelper)
    vc.extend(ActionView::Helpers::UrlHelper)
    vc.extend(ActionView::Helpers::FormHelper)
    vc.extend(ActionView::Helpers::FormTagHelper)
    vc.extend(UrlsHelper)
    vc.extend(ComponentsHelper)
    vc.extend(OntologiesHelper)
    vc.extend(InternationalisationHelper)
    vc.extend(MultiLanguagesHelper)
    vc.extend(SubmissionsHelper)
    vc.extend(ApplicationHelper)
    vc.extend(FlagIconsRails::Rails::ViewHelpers)
    vc.extend(StandaloneRouteHelperStubs)

    def vc.inline_svg_tag(filename, options = {})
      %(<svg data-src="#{filename}"></svg>).html_safe
    end

    def vc.portal_name
      $SITE || 'TestPortal'
    end

    vc
  end

  def dispatch_destroy(params: {}, user: ADMIN_USER, locale: :en)
    I18n.locale = locale
    req = ActionDispatch::TestRequest.create('rack.session' => {})
    req.set_header 'action_dispatch.request.flash_hash', ActionDispatch::Flash::FlashHash.new
    req.session[:user] = user if user
    req.session[:locale] = locale
    req.cookies[:locale] = locale.to_s
    params.each { |k, v| req.params[k] = v }

    res = ActionDispatch::TestResponse.create
    ctrl = OntologiesAdministrationController.new
    ctrl.set_request!(req)
    ctrl.set_response!(res)
    ctrl.process(:destroy_submission)
    [ctrl, req, res]
  end

  def flatten_hash(hash, prefix = '')
    res = {}
    hash.each do |k, v|
      full_key = prefix.empty? ? k.to_s : "#{prefix}.#{k}"
      if v.is_a?(Hash)
        res.merge!(flatten_hash(v, full_key))
      else
        res[full_key] = v
      end
    end
    res
  end

  # ===========================================================================
  # 1. L01 Metadata Help Helper Rendering & Caller Exercise
  # ===========================================================================

  def test_01_l01_metadata_help_link_renders_cleanly_in_en_and_fr
    vc = create_view_context

    # English render
    I18n.locale = :en
    html_en = vc.metadata_help_link
    assert_includes html_en, %(href="#{HELP_URL}")
    assert_includes html_en, %(target="_blank")
    assert_includes html_en, %(class="edit-ontology-desc")
    assert_includes html_en, 'See guidelines and recommendations for metadata here.'
    assert_includes html_en, 'Edit the metadata of your ontology here.'
    assert_includes html_en, 'TestPortal'
    refute_includes html_en, '%{'
    refute_includes html_en, '%{link)'
    refute_includes html_en, '%{link}'
    refute_includes html_en, '%{portal_name}'

    # French render
    I18n.locale = :fr
    html_fr = vc.metadata_help_link
    assert_includes html_fr, %(href="#{HELP_URL}")
    assert_includes html_fr, %(target="_blank")
    assert_includes html_fr, %(class="edit-ontology-desc")
    assert_includes html_fr, 'Vous pouvez consulter les recommandations pour les métadonnées ici.'
    assert_includes html_fr, 'Modifiez les métadonnées de votre ontologie ici.'
    assert_includes html_fr, 'TestPortal'
    refute_includes html_fr, '%{'
    refute_includes html_fr, '%{link)'
    refute_includes html_fr, '%{link}'
    refute_includes html_fr, '%{portal_name}'
  end

  def test_02_l01_metadata_help_link_exercises_all_callers_in_en_and_fr
    vc = create_view_context

    # Dynamically locate every caller of metadata_help_link in app/views
    view_files = Dir.glob(File.join(WORKTREE_ROOT, 'app/views/**/*.haml'))
    callers = view_files.select { |f| File.read(f).include?('metadata_help_link') }
    assert_equal 2, callers.size, "Expected exactly 2 callers in app/views"

    caller_rel_paths = callers.map { |f| f.sub("#{WORKTREE_ROOT}/", '') }.sort
    assert_equal ['app/views/ontologies/new.html.haml', 'app/views/submissions/edit.html.haml'], caller_rel_paths

    [:en, :fr].each do |loc|
      I18n.locale = loc

      # Caller 1: app/views/submissions/edit.html.haml
      # In submissions/edit: rendered inside TurboFrameComponent
      caller1_haml = "= render TurboFrameComponent.new(id: 'metadata_by_ontology') do\n  = metadata_help_link\n"
      rendered1 = Haml::Engine.new(caller1_haml).render(vc)
      assert_includes rendered1, %(href="#{HELP_URL}")
      assert_includes rendered1, 'metadata_by_ontology'
      refute_includes rendered1, '%{'
      refute_includes rendered1, '%{link)'

      # Caller 2: app/views/ontologies/new.html.haml
      # In ontologies/new: rendered inside .upload-ontology-desc
      caller2_haml = ".upload-ontology-desc\n  = metadata_help_link\n"
      rendered2 = Haml::Engine.new(caller2_haml).render(vc)
      assert_includes rendered2, %(href="#{HELP_URL}")
      assert_includes rendered2, 'upload-ontology-desc'
      refute_includes rendered2, '%{'
      refute_includes rendered2, '%{link)'
    end
  end

  # ===========================================================================
  # 2. L01 Language Selector Component Placeholder, Options, and Attributes
  # ===========================================================================

  def test_03_l01_language_selector_renders_informative_placeholder_in_en_and_fr
    vc = create_view_context
    languages = { 'en' => 'English', 'fr' => 'Français', 'de' => 'Deutsch' }

    # English render
    I18n.locale = :en
    comp_en = Input::LanguageSelectorComponent.new(
      languages: languages,
      id: 'sub_lang_test',
      name: 'submission[language]',
      selected: nil
    )
    html_en = comp_en.render_in(vc)
    assert_includes html_en, 'placeholder="Select a language"'
    refute_includes html_en, 'placeholder="/"'
    assert_includes html_en, 'id="select_sub_lang_test"'
    assert_includes html_en, 'name="submission[language]"'
    assert_includes html_en, 'value="en"'
    assert_includes html_en, 'value="fr"'
    assert_includes html_en, 'value="de"'
    refute_includes html_en, 'selected="selected"'

    # French render
    I18n.locale = :fr
    comp_fr = Input::LanguageSelectorComponent.new(
      languages: languages,
      id: 'sub_lang_test',
      name: 'submission[language]',
      selected: nil
    )
    html_fr = comp_fr.render_in(vc)
    assert_includes html_fr, 'placeholder="Sélectionnez une langue"'
    refute_includes html_fr, 'placeholder="/"'
    assert_includes html_fr, 'id="select_sub_lang_test"'
    assert_includes html_fr, 'name="submission[language]"'
    assert_includes html_fr, 'value="en"'
    assert_includes html_fr, 'value="fr"'
    assert_includes html_fr, 'value="de"'
    refute_includes html_fr, 'selected="selected"'
  end

  # ===========================================================================
  # 3. L01 Static Locale Integrity & Count/Plural Treatment
  # ===========================================================================

  def test_04_l01_static_locale_integrity_and_plural_treatment
    en_cat = YAML.load_file(File.join(WORKTREE_ROOT, 'config/locales/en.yml'))['en']
    fr_cat = YAML.load_file(File.join(WORKTREE_ROOT, 'config/locales/fr.yml'))['fr']

    en_flat = flatten_hash(en_cat)
    fr_flat = flatten_hash(fr_cat)
    common_keys = en_flat.keys & fr_flat.keys

    malformed_delimiters = []
    unbalanced_delimiters = []
    incompatible_placeholders = []
    allowed_plural_branches = []

    [[:en, en_flat], [:fr, fr_flat]].each do |lang, cat|
      cat.each do |k, v|
        next unless v.is_a?(String)

        # 1. Delimiters with closing parenthesis like %{x)
        if v.match?(/%\{[a-zA-Z0-9_]*\)/)
          malformed_delimiters << { lang: lang, key: k, value: v }
        end

        # 2. Unbalanced / unclosed %{ tokens
        all_percent_braces = v.scan(/%\{/).size
        valid_interpolations = v.scan(/%\{[a-zA-Z0-9_]+\}/).size
        if all_percent_braces != valid_interpolations
          unbalanced_delimiters << { lang: lang, key: k, value: v, starts: all_percent_braces, valid: valid_interpolations }
        end
      end
    end

    # 3. Incompatible placeholder names in fr that do not exist in en
    common_keys.each do |k|
      en_val = en_flat[k]
      fr_val = fr_flat[k]
      next unless en_val.is_a?(String) && fr_val.is_a?(String)

      en_vars = en_val.scan(/%\{([a-zA-Z0-9_]+)\}/).flatten.uniq
      fr_vars = fr_val.scan(/%\{([a-zA-Z0-9_]+)\}/).flatten.uniq
      diff = fr_vars - en_vars
      next if diff.empty?

      # Explicit treatment of count/plural branches:
      # A branch where en uses literal singular text and fr uses %{count} is allowed
      if diff == ['count'] && (k.end_with?('.one') || k.end_with?('.other') || k.include?('plural') || k.include?('count'))
        allowed_plural_branches << { key: k, en: en_val, fr: fr_val, diff: diff }
      else
        incompatible_placeholders << { key: k, en: en_val, fr: fr_val, missing_in_en: diff }
      end
    end

    assert_empty malformed_delimiters, "Malformed interpolation delimiters found: #{malformed_delimiters.inspect}"
    assert_empty unbalanced_delimiters, "Unbalanced interpolation delimiters found: #{unbalanced_delimiters.inspect}"
    assert_empty incompatible_placeholders, "Incompatible placeholder names found: #{incompatible_placeholders.inspect}"

    # Verify documented count/plural treatment
    assert_equal 1, allowed_plural_branches.size
    assert_equal 'admin.licenses.license_notification.license_trial.one', allowed_plural_branches.first[:key]
  end

  # ===========================================================================
  # 4. L02 OntologiesAdministrationController#destroy_submission Notice & Queuing
  # ===========================================================================

  def test_05_l02_destroy_submission_accepted_202_notice_en
    LinkedData::Client::HTTP.delete_response = OpenStruct.new(status: 202, body: '')

    ctrl, _req, res = dispatch_destroy(
      params: { ontology_id: 'TEST_ONT', ids: ['101', '102'] },
      user: ADMIN_USER,
      locale: :en
    )

    assert_equal 302, res.status
    assert_equal 'http://test.host/ontologies/TEST_ONT/admin', res.location
    assert_equal '/ontologies/TEST_ONT/submissions?ontology_submission_ids=101,102', LinkedData::Client::HTTP.last_delete_path

    notice = ctrl.flash[:notice]
    refute_nil notice, 'Flash notice must be present on HTTP 202 accepted response'
    assert_nil ctrl.flash[:alert], 'Flash alert must not be set on accepted response'

    assert_includes notice, '101,102', 'English notice must interpolate submission IDs'
    assert_match(/queued/i, notice, 'English notice must describe accepted or queued operation certainty')
    refute_match(/\A\s*Submissions?\s+[\d, ]+\s+deleted\s*\z/i, notice, 'English notice must not assert completed deletion')
    assert_equal 'Submissions queued for deletion: 101,102', notice
  end

  def test_06_l02_destroy_submission_accepted_202_notice_fr
    LinkedData::Client::HTTP.delete_response = OpenStruct.new(status: 202, body: '')

    ctrl, _req, res = dispatch_destroy(
      params: { ontology_id: 'TEST_ONT', ids: ['101', '102'] },
      user: ADMIN_USER,
      locale: :fr
    )

    assert_equal 302, res.status
    assert_equal 'http://test.host/ontologies/TEST_ONT/admin', res.location
    assert_equal '/ontologies/TEST_ONT/submissions?ontology_submission_ids=101,102', LinkedData::Client::HTTP.last_delete_path

    notice = ctrl.flash[:notice]
    refute_nil notice, 'Flash notice must be present on HTTP 202 accepted response'
    assert_nil ctrl.flash[:alert], 'Flash alert must not be set on accepted response'

    assert_includes notice, '101,102', 'French notice must interpolate submission IDs'
    assert_match(/file d'attente|attente|accepté/i, notice, 'French notice must retain queued/accepted qualifier')
    refute_match(/\A\s*Soumissions\s+.*supprimées\s*\z/i, notice, 'French notice must not assert completed deletion')
    assert_equal "Soumissions mises en file d'attente pour suppression : 101,102", notice
  end

  def test_07_l02_destroy_submission_accepted_202_single_id_interpolation
    LinkedData::Client::HTTP.delete_response = OpenStruct.new(status: 202, body: '')

    # English single ID
    ctrl_en, _req_en, res_en = dispatch_destroy(
      params: { ontology_id: 'TEST_ONT', id: '42' },
      user: ADMIN_USER,
      locale: :en
    )
    assert_equal 302, res_en.status
    assert_equal 'Submissions queued for deletion: 42', ctrl_en.flash[:notice]

    # French single ID
    ctrl_fr, _req_fr, res_fr = dispatch_destroy(
      params: { ontology_id: 'TEST_ONT', id: '42' },
      user: ADMIN_USER,
      locale: :fr
    )
    assert_equal 302, res_fr.status
    assert_equal "Soumissions mises en file d'attente pour suppression : 42", ctrl_fr.flash[:notice]
  end

  def test_08_l02_destroy_submission_failure_response_sets_alert
    # Failure with upstream message
    LinkedData::Client::HTTP.delete_response = OpenStruct.new(status: 500, body: 'Upstream delete failure: queue full')

    [:en, :fr].each do |loc|
      ctrl, _req, res = dispatch_destroy(
        params: { ontology_id: 'TEST_ONT', ids: ['101'] },
        user: ADMIN_USER,
        locale: loc
      )
      assert_equal 302, res.status
      assert_equal 'http://test.host/ontologies/TEST_ONT/admin', res.location
      assert_nil ctrl.flash[:notice]
      assert_equal 'Upstream delete failure: queue full', ctrl.flash[:alert]
    end

    # Failure with nil body uses localized error fallback
    LinkedData::Client::HTTP.delete_response = OpenStruct.new(status: 500, body: nil)

    ctrl_en, _req, _res = dispatch_destroy(params: { ontology_id: 'TEST_ONT', ids: ['101'] }, user: ADMIN_USER, locale: :en)
    assert_equal 'Error deleting submissions: ', ctrl_en.flash[:alert]

    ctrl_fr, _req, _res = dispatch_destroy(params: { ontology_id: 'TEST_ONT', ids: ['101'] }, user: ADMIN_USER, locale: :fr)
    assert_equal 'Erreur lors de la suppression des soumissions: ', ctrl_fr.flash[:alert]
  end

  def test_09_l02_authorize_ontology_admin_bypassed_with_ontology_double
    # Verify that authorize_ontology_admin calls Ontology.find_by_acronym
    LinkedData::Client::Models::Ontology.find_calls = 0
    LinkedData::Client::HTTP.delete_response = OpenStruct.new(status: 202, body: '')

    ctrl, _req, res = dispatch_destroy(
      params: { ontology_id: 'TEST_ONT', ids: ['101'] },
      user: ADMIN_USER,
      locale: :en
    )
    assert_equal 1, LinkedData::Client::Models::Ontology.find_calls
    assert_equal 302, res.status
    assert_equal 'http://test.host/ontologies/TEST_ONT/admin', res.location

    # Verify authorization denial when user is unauthorized non-admin
    unauth_user = OpenStruct.new(id: 'http://example.com/users/stranger', admin?: false)
    ctrl_unauth, _req_unauth, res_unauth = dispatch_destroy(
      params: { ontology_id: 'TEST_ONT', ids: ['101'] },
      user: unauth_user,
      locale: :en
    )
    # redirect_to_home redirects to '/'
    assert_equal 'http://test.host/', res_unauth.location
    assert_nil ctrl_unauth.flash[:notice]
  end
end
