# frozen_string_literal: true

begin
  require 'rails/test_help'
rescue LoadError
  # Support isolated/offline regression runs without Rails bundle
end
require_relative 'test_target_guard'
require_relative 'test_resource_ownership'

module ApplicationTestHelpers
  def self.verify_test_target!
    TestTargetGuard.enforce_isolated_test_target!
  end

  def self.included(base)
    verify_test_target! if defined?(TestTargetGuard)
  end

  def self.register_owned_resource(type, resource)
    TestResourceOwnership.register(type, resource)
  end

  def register_owned_resource(type, resource)
    TestResourceOwnership.register(type, resource)
  end

  def register_owned_ontology(ontology)
    TestResourceOwnership.register(:ontology, ontology)
  end

  def register_owned_agent(agent)
    TestResourceOwnership.register(:agent, agent)
  end

  def register_owned_user(user)
    TestResourceOwnership.register(:user, user)
  end

  def cleanup_owned_resources!
    ApplicationTestHelpers.verify_test_target!
    ApplicationTestHelpers.reset_cleanup_failures!
    failures = []
    failures.concat(delete_ontologies) if respond_to?(:delete_ontologies)
    failures.concat(delete_groups) if respond_to?(:delete_groups)
    failures.concat(delete_categories) if respond_to?(:delete_categories)
    failures.concat(delete_agents) if respond_to?(:delete_agents)
    failures.concat(delete_users) if respond_to?(:delete_users)
    ApplicationTestHelpers.record_cleanup_failures(failures)
    failures
  end

  def self.retire_linked_submissions(ontology)
    o_keys = TestResourceOwnership.extract_keys(:ontology, ontology)
    return if o_keys.empty?

    TestResourceOwnership.owned_resources(:submission).each do |s|
      parent = if s.respond_to?(:ontology) && s.ontology
        s.ontology
      elsif s.is_a?(Hash)
        s[:ontology] || s['ontology']
      end
      next if parent.nil? || parent.to_s.strip.empty?

      parent_keys = TestResourceOwnership.extract_keys(:ontology, parent)
      if (parent_keys & o_keys).any?
        TestResourceOwnership.unregister(:submission, s)
      end
    end
  end

  def self.sdk_retrieval_exception?(e)
    return false if e.is_a?(SignalException) || e.is_a?(SystemExit)
    e.is_a?(StandardError) || (e.class == Exception && e.message.to_s.include?('Problem retrieving:'))
  end

  def self.sdk_error_response?(obj)
    return false if obj.nil?
    if obj.respond_to?(:errors)
      errs = obj.errors
      return true if !errs.nil? && (!errs.respond_to?(:empty?) || !errs.empty?)
    end
    if obj.respond_to?(:error)
      err = obj.error
      return true if !err.nil? && (!err.respond_to?(:empty?) || !err.empty?)
    end
    if obj.is_a?(Hash)
      errs = obj[:errors] || obj['errors'] || obj[:error] || obj['error']
      return true if !errs.nil? && (!errs.respond_to?(:empty?) || !errs.empty?)
    end
    false
  end

  def self.sdk_error_message(obj)
    if obj.respond_to?(:errors) && obj.errors
      obj.errors
    elsif obj.respond_to?(:error) && obj.error
      obj.error
    elsif obj.is_a?(Hash)
      obj[:errors] || obj['errors'] || obj[:error] || obj['error']
    else
      "SDK error response"
    end
  end

  def self.reconcile_target(type, target, finder:)
    found = nil
    reconcile_err = nil
    begin
      found = finder.call
    rescue StandardError => e
      reconcile_err = e
    rescue Exception => e
      raise if e.is_a?(SignalException) || e.is_a?(SystemExit)
      raise unless sdk_retrieval_exception?(e)
      reconcile_err = e
    end

    if reconcile_err
      evaluate_deletion(type, target, error: reconcile_err)
    elsif found.nil?
      evaluate_deletion(type, target, absent: true)
    elsif sdk_error_response?(found)
      evaluate_deletion(type, target, error: sdk_error_message(found))
    elsif block_given?
      yield(found)
    else
      TestResourceOwnership.clear_outcome_unknown(type, target)
      resp = found.delete
      evaluate_deletion(type, target, response: resp, found: found)
    end
  end

  def self.record_confirmed_ontologies(confirmed)
    Thread.current[:application_test_helpers_confirmed_ontologies] = Array(confirmed)
  end

  def self.confirmed_ontologies
    Thread.current[:application_test_helpers_confirmed_ontologies] || []
  end

  def self.evaluate_deletion(type, target, response: nil, error: nil, absent: false, found: nil)
    if absent
      TestResourceOwnership.unregister(type, target)
      TestResourceOwnership.unregister(type, found) if found
      return { success: true, status: :absent, target: target, type: type }
    end

    if error
      TestResourceOwnership.mark_outcome_unknown(type, target)
      TestResourceOwnership.mark_outcome_unknown(type, found) if found
      return { success: false, error: error, target: target, type: type }
    end

    if response.respond_to?(:status)
      status_code = response.status.to_i
      if status_code >= 200 && status_code < 300
        TestResourceOwnership.unregister(type, target)
        TestResourceOwnership.unregister(type, found) if found
        return { success: true, status: status_code, target: target, type: type }
      elsif status_code == 404
        TestResourceOwnership.unregister(type, target)
        TestResourceOwnership.unregister(type, found) if found
        return { success: true, status: 404, target: target, type: type }
      elsif status_code >= 400
        TestResourceOwnership.clear_outcome_unknown(type, target)
        TestResourceOwnership.clear_outcome_unknown(type, found) if found
        return { success: false, status: status_code, response: response, error: "HTTP #{status_code}", target: target, type: type }
      else
        return { success: false, status: status_code, response: response, error: "Unexpected HTTP status #{status_code}", target: target, type: type }
      end
    end

    TestResourceOwnership.mark_outcome_unknown(type, target)
    TestResourceOwnership.mark_outcome_unknown(type, found) if found
    { success: false, error: "Non-response returned from delete: #{response.inspect}", target: target, type: type }
  end

  def self.record_cleanup_failures(failures)
    failures = Array(failures)
    if failures.empty?
      Thread.current[:application_test_helpers_last_cleanup_failures] ||= []
    else
      existing = Thread.current[:application_test_helpers_last_cleanup_failures] || []
      Thread.current[:application_test_helpers_last_cleanup_failures] = (existing + failures).uniq
    end
  end

  def self.reset_cleanup_failures!
    Thread.current[:application_test_helpers_last_cleanup_failures] = []
    Thread.current[:application_test_helpers_confirmed_ontologies] = []
  end

  def self.last_cleanup_failures
    Thread.current[:application_test_helpers_last_cleanup_failures] || []
  end

  def self.transform_models_to_ids(object)
    return object unless object.respond_to?(:each_pair)
    base_class = defined?(LinkedData::Client::Base) ? LinkedData::Client::Base : nil
    object.each_pair do |key, value|
      if base_class && value.is_a?(Array) && value.first.is_a?(base_class)
        object[key] = value.map(&:id)
      elsif base_class && value.is_a?(base_class)
        object[key] = value.id
      end
    end
    object
  end

  def self.acknowledged_has_errors?(resp)
    return false if resp.nil?

    if resp.respond_to?(:status) && resp.status
      is_typed_sub = defined?(LinkedData::Client::Models::OntologySubmission) &&
                     resp.is_a?(LinkedData::Client::Models::OntologySubmission)
      if is_typed_sub && !resp.status.to_s.match?(/\A\d+\z/)
        # Domain lifecycle status on typed submission (e.g. 'production'); not transport HTTP status
      else
        return true unless (200..299).cover?(resp.status.to_i)
      end
    end

    if resp.respond_to?(:errors) && resp.errors
      errs = resp.errors
      return true if errs && (!errs.respond_to?(:empty?) || !errs.empty?)
    end

    if resp.is_a?(Hash)
      errs = resp[:errors] || resp['errors'] || resp[:error] || resp['error']
      return true if errs && (!errs.respond_to?(:empty?) || !errs.empty?)
    end

    false
  end

  def self.derive_username_from_user_uri(raw_uri_str)
    str = raw_uri_str.to_s.strip
    return nil if str.empty?

    begin
      parsed = URI.parse(str)
    rescue URI::InvalidURIError, StandardError
      return nil
    end

    return nil unless parsed.is_a?(URI::HTTP) || parsed.is_a?(URI::HTTPS)
    return nil if parsed.user || parsed.password
    return nil if parsed.host.nil? || parsed.host.strip.empty?
    return nil if parsed.query && !parsed.query.empty?
    return nil if parsed.fragment && !parsed.fragment.empty?

    configured_url = LinkedData::Client.settings.rest_url rescue nil
    return nil if configured_url.nil? || configured_url.to_s.strip.empty?

    begin
      cfg_parsed = URI.parse(configured_url.to_s.strip)
    rescue URI::InvalidURIError, StandardError
      return nil
    end

    return nil unless cfg_parsed.is_a?(URI::HTTP) || cfg_parsed.is_a?(URI::HTTPS)
    return nil unless parsed.scheme.to_s.downcase == cfg_parsed.scheme.to_s.downcase
    return nil unless parsed.host.to_s.downcase == cfg_parsed.host.to_s.downcase
    parsed_port = parsed.port || (parsed.scheme == 'https' ? 443 : 80)
    cfg_port = cfg_parsed.port || (cfg_parsed.scheme == 'https' ? 443 : 80)
    return nil unless parsed_port == cfg_port

    coll_raw = begin
      if defined?(LinkedData::Client::Models::User) && LinkedData::Client::Models::User.respond_to?(:collection_path)
        LinkedData::Client::Models::User.collection_path
      end
    rescue StandardError
      nil
    end
    return nil if coll_raw.nil? || coll_raw.to_s.strip.empty?

    begin
      coll_parsed = URI.parse(coll_raw.to_s.strip)
    rescue URI::InvalidURIError, StandardError
      return nil
    end

    cfg_base_path = cfg_parsed.path.to_s.chomp('/')

    if coll_parsed.absolute?
      return nil unless coll_parsed.is_a?(URI::HTTP) || coll_parsed.is_a?(URI::HTTPS)
      return nil unless coll_parsed.scheme.to_s.downcase == cfg_parsed.scheme.to_s.downcase
      return nil unless coll_parsed.host.to_s.downcase == cfg_parsed.host.to_s.downcase
      coll_port = coll_parsed.port || (coll_parsed.scheme == 'https' ? 443 : 80)
      return nil unless coll_port == cfg_port

      coll_path_str = coll_parsed.path.to_s
      if !cfg_base_path.empty?
        return nil unless coll_path_str == cfg_base_path || coll_path_str.start_with?("#{cfg_base_path}/")
      end
    else
      coll_path_str = coll_parsed.path.to_s
      if coll_path_str.start_with?('/')
        if !cfg_base_path.empty?
          return nil unless coll_path_str == cfg_base_path || coll_path_str.start_with?("#{cfg_base_path}/")
        end
      else
        coll_path_str = "#{cfg_base_path}/#{coll_path_str}"
      end
    end

    expected_collection_prefix = "#{coll_path_str.chomp('/')}/"
    return nil unless parsed.path.start_with?(expected_collection_prefix)
    subpath = parsed.path[expected_collection_prefix.length..-1]
    return nil if subpath.nil? || subpath.empty?
    return nil if subpath.include?('/')

    candidate = if subpath.include?('%')
      return nil unless subpath =~ /\A(?:%[0-9a-fA-F]{2}|[^%])+\z/
      unescaped = URI::DEFAULT_PARSER.unescape(subpath)
      return nil if unescaped.include?('%')
      unescaped
    else
      subpath
    end

    return nil if candidate.strip.empty? || candidate == '.' || candidate == '..'
    return nil unless candidate =~ /\A[a-zA-Z0-9_\.\-+]+\z/

    candidate
  end

  def self.extract_user_identity(resp)
    return nil if resp.nil?

    raw_username = if resp.respond_to?(:username) && resp.username && !resp.username.to_s.strip.empty?
      resp.username.to_s.strip
    elsif resp.is_a?(Hash)
      val = resp[:username] || resp['username']
      val&.to_s&.strip
    end

    if raw_username && !raw_username.empty?
      if raw_username.include?('://') || raw_username.start_with?('/')
        return derive_username_from_user_uri(raw_username)
      end
      return raw_username
    end

    raw_id = if resp.respond_to?(:id) && resp.id && !resp.id.to_s.strip.empty?
      resp.id.to_s.strip
    elsif resp.is_a?(Hash)
      val = resp[:id] || resp['id']
      val&.to_s&.strip
    end

    return nil if raw_id.nil? || raw_id.empty?

    derive_username_from_user_uri(raw_id)
  end

  def self.extract_created_identity(resp, type = nil)
    return nil if resp.nil?

    if type == :user
      extract_user_identity(resp)
    elsif type == :submission
      if resp.respond_to?(:id) && resp.id && !resp.id.to_s.strip.empty?
        resp.id.to_s.strip
      elsif resp.is_a?(Hash)
        val = resp[:id] || resp['id']
        val&.to_s&.strip
      end
    elsif type
      if resp.respond_to?(:acronym) && resp.acronym && !resp.acronym.to_s.strip.empty?
        resp.acronym.to_s.strip
      elsif resp.respond_to?(:id) && resp.id && !resp.id.to_s.strip.empty?
        resp.id.to_s.strip
      elsif resp.is_a?(Hash)
        val = resp[:acronym] || resp['acronym'] || resp[:id] || resp['id']
        val&.to_s&.strip
      end
    else
      if resp.respond_to?(:acronym) && resp.acronym && !resp.acronym.to_s.strip.empty?
        resp.acronym.to_s.strip
      elsif (user_ident = extract_user_identity(resp))
        user_ident
      elsif resp.respond_to?(:id) && resp.id && !resp.id.to_s.strip.empty?
        resp.id.to_s.strip
      elsif resp.is_a?(Hash)
        val = resp[:acronym] || resp['acronym'] || resp[:id] || resp['id']
        val&.to_s&.strip
      end
    end
  end

  def self.acknowledged_success?(resp, type = nil)
    return false if resp.nil?
    return false if acknowledged_has_errors?(resp)

    ident = extract_created_identity(resp, type)
    !ident.nil? && !ident.empty?
  end

  def self.acknowledged_save(model, type, options = {})
    ApplicationTestHelpers.verify_test_target!
    return nil if model.nil?

    resp = LinkedData::Client::HTTP.post(model.class.collection_path, model.to_hash)

    if resp.nil?
      raise StandardError, "Unknown creation response: received nil response from #{model.class.collection_path}"
    end

    if acknowledged_has_errors?(resp)
      # Known error/duplicate response: preserve actual SDK cache sequence (ReadWrite.save invokes cache_refresh)
      model.send(:cache_refresh, options) if model.respond_to?(:cache_refresh, true)
      return resp
    end

    identity = extract_created_identity(resp, type)
    if identity.nil? || identity.empty?
      raise StandardError, "Unknown creation response: missing created identity from #{model.class.collection_path}"
    end

    target = if type == :user
      identity
    elsif type == :submission
      resp
    else
      resp
    end

    TestResourceOwnership.register(type, target)
    model.send(:cache_refresh, options) if model.respond_to?(:cache_refresh, true)
    resp
  end

  module Users
    def sign_in_as(username)
      ApplicationTestHelpers.verify_test_target!
      user = fixtures(:users)[username]
      logged_in_user = LinkedData::Client::Models::User.authenticate(user.username, user.password)
      logged_in_user = create_user(user) if logged_in_user && !logged_in_user.errors
      logged_in_user
    end

    def create_user(user, admin: false)
      ApplicationTestHelpers.verify_test_target!
      admin_user = LinkedData::Client::Models::User.authenticate('admin', 'password')
      existent_user = LinkedData::Client::Models::User.find_by_username(user.username).first

      conn = Faraday.new(url: LinkedData::Client.settings.rest_url) do |faraday|
        faraday.request :url_encoded
        faraday.response :logger
        faraday.adapter Faraday.default_adapter
        faraday.headers = {
          "Accept" => "application/json",
          "Authorization" => "apikey token=#{admin_user.apikey}",
          "User-Agent" => "NCBO API Ruby Client v0.1.0"
        }
      end

      # Only delete if previously owned by this test run; never delete seeded users or admin
      if existent_user && TestResourceOwnership.owned?(:user, user.username)
        conn.delete("/users/#{user.username}")
        TestResourceOwnership.unregister(:user, user.username)
      end

      values = user.to_h
      values[:role] = ["ADMINISTRATOR"] if admin
      user_model = LinkedData::Client::Models::User.new(values: values)

      if admin
        # Overwrite the normal ".save" to accept creating admin user
        path = user_model.class.respond_to?(:collection_path) ? user_model.class.collection_path : '/users'
        res = conn.post(path, user_model.to_hash.to_json, 'Content-Type' => 'application/json')

        if res.respond_to?(:status) && (200..299).cover?(res.status.to_i)
          raise StandardError, "Missing response body" if res.body.nil? || res.body.to_s.strip.empty?

          created_user = if defined?(LinkedData::Client::HTTP) && LinkedData::Client::HTTP.respond_to?(:object_from_json) && res.body.is_a?(String)
            LinkedData::Client::HTTP.object_from_json(res.body)
          elsif res.body.is_a?(Hash)
            LinkedData::Client::Models::User.new(values: res.body)
          elsif res.body.is_a?(String)
            parsed = JSON.parse(res.body)
            parsed.is_a?(Hash) ? LinkedData::Client::Models::User.new(values: parsed) : parsed
          else
            nil
          end

          has_errors = created_user.respond_to?(:errors) && created_user.errors && (!created_user.errors.respond_to?(:empty?) || !created_user.errors.empty?)
          created_id = ApplicationTestHelpers.extract_created_identity(created_user, :user)

          if has_errors
            created_user
          elsif created_id
            TestResourceOwnership.register(:user, created_id)
            created_user.password = user.password if created_user.respond_to?(:password=) && user.respond_to?(:password)
            created_user
          else
            raise StandardError, "Unknown admin response: 2xx response missing created user identifier"
          end
        else
          parsed = if defined?(LinkedData::Client::HTTP) && LinkedData::Client::HTTP.respond_to?(:load_json) && res.body.is_a?(String)
            begin
              LinkedData::Client::HTTP.load_json(res.body)
            rescue StandardError
              nil
            end
          elsif res.body.is_a?(Hash)
            res.body
          elsif res.body.is_a?(String) && !res.body.empty?
            begin
              JSON.parse(res.body)
            rescue StandardError
              nil
            end
          end

          errors = if parsed.respond_to?(:errors) && parsed.errors
            parsed.errors
          elsif parsed.is_a?(Hash)
            parsed['errors'] || parsed[:errors] || parsed['error'] || parsed[:error] || [res.body]
          else
            status_text = res.respond_to?(:status) && res.status ? "HTTP #{res.status}" : "Unknown response"
            [res.body.to_s.empty? ? status_text : res.body]
          end

          LinkedData::Client::Models::User.new(values: { errors: errors })
        end
      else
        created_user = ApplicationTestHelpers.acknowledged_save(user_model, :user)
        created_user.password = user.password if created_user.respond_to?(:password=) && user.respond_to?(:password)
        created_user
      end
    end

    def delete_users(users = nil)
      ApplicationTestHelpers.verify_test_target!
      targets = if users.nil?
        TestResourceOwnership.owned_resources(:user)
      else
        Array(users).select { |u| TestResourceOwnership.owned?(:user, u) }
      end

      failures = []
      targets.each do |u|
        result = delete_user(u)
        failures << result if result && !result[:success]
      end
      ApplicationTestHelpers.record_cleanup_failures(failures)
      failures
    end

    def delete_user(user)
      ApplicationTestHelpers.verify_test_target!
      return nil unless user

      username = if user.respond_to?(:username)
        user.username
      elsif user.is_a?(Hash)
        user[:username] || user['username']
      else
        user.to_s
      end

      return nil if username.nil? || username.empty?
      return nil if username.to_s.downcase == 'admin' || username.to_s.downcase == 'administrator' || username.to_s.downcase == 'admin@example.com'
      return nil unless TestResourceOwnership.owned?(:user, username)

      result = begin
        if TestResourceOwnership.outcome_unknown?(:user, username)
          ApplicationTestHelpers.reconcile_target(:user, username, finder: -> {
            if defined?(LinkedData::Client::Models::User) && LinkedData::Client::Models::User.respond_to?(:find_by_username)
              LinkedData::Client::Models::User.find_by_username(username, invalidate_cache: true)&.first
            elsif defined?(LinkedData::Client::Models::User) && LinkedData::Client::Models::User.respond_to?(:find)
              LinkedData::Client::Models::User.find(username, invalidate_cache: true)
            end
          }) do |existent_user|
            TestResourceOwnership.clear_outcome_unknown(:user, username)
            admin_user = LinkedData::Client::Models::User.authenticate('admin', 'password')
            if !admin_user
              ApplicationTestHelpers.evaluate_deletion(:user, username, error: "Admin authentication failed during user cleanup")
            else
              conn = Faraday.new(url: LinkedData::Client.settings.rest_url) do |faraday|
                faraday.request :url_encoded
                faraday.response :logger
                faraday.adapter Faraday.default_adapter
                faraday.headers = {
                  "Accept" => "application/json",
                  "Authorization" => "apikey token=#{admin_user.apikey}",
                  "User-Agent" => "NCBO API Ruby Client v0.1.0"
                }
              end

              resp = conn.delete("/users/#{username}")
              ApplicationTestHelpers.evaluate_deletion(:user, username, response: resp, found: existent_user)
            end
          end
        else
          admin_user = LinkedData::Client::Models::User.authenticate('admin', 'password')
          existent_user = LinkedData::Client::Models::User.find_by_username(username).first

          if existent_user.nil?
            ApplicationTestHelpers.evaluate_deletion(:user, username, absent: true)
          elsif ApplicationTestHelpers.sdk_error_response?(existent_user)
            ApplicationTestHelpers.evaluate_deletion(:user, username, error: ApplicationTestHelpers.sdk_error_message(existent_user))
          elsif !admin_user
            ApplicationTestHelpers.evaluate_deletion(:user, username, error: "Admin authentication failed during user cleanup")
          else
            conn = Faraday.new(url: LinkedData::Client.settings.rest_url) do |faraday|
              faraday.request :url_encoded
              faraday.response :logger
              faraday.adapter Faraday.default_adapter
              faraday.headers = {
                "Accept" => "application/json",
                "Authorization" => "apikey token=#{admin_user.apikey}",
                "User-Agent" => "NCBO API Ruby Client v0.1.0"
              }
            end

            resp = conn.delete("/users/#{username}")
            ApplicationTestHelpers.evaluate_deletion(:user, username, response: resp, found: existent_user)
          end
        end
      rescue StandardError => e
        ApplicationTestHelpers.evaluate_deletion(:user, username, error: e)
      rescue Exception => e
        raise if e.is_a?(SignalException) || e.is_a?(SystemExit)
        raise unless ApplicationTestHelpers.sdk_retrieval_exception?(e)
        ApplicationTestHelpers.evaluate_deletion(:user, username, error: e)
      end
      ApplicationTestHelpers.record_cleanup_failures([result]) if result && !result[:success]
      result
    end
  end

  module Ontologies
    def create_ontology(ontology, submission)
      ApplicationTestHelpers.verify_test_target!
      ontology_values = ApplicationTestHelpers.transform_models_to_ids(ontology).to_h
      ont = LinkedData::Client::Models::Ontology.new(values: ontology_values)
      ont_model = ApplicationTestHelpers.acknowledged_save(ont, :ontology)

      if !ApplicationTestHelpers.acknowledged_success?(ont_model, :ontology)
        return [ont_model, nil]
      end

      sub_model = nil
      if submission
        submission_values = ApplicationTestHelpers.transform_models_to_ids(submission).to_h
        submission_values[:ontology] = ont_model.id if ont_model.respond_to?(:id)
        submission_values.delete(:curatedOn)
        if submission_values[:naturalLanguage]
          submission_values[:naturalLanguage] = Array(submission_values[:naturalLanguage]).map { |x| x.gsub('iso639-1', 'iso639-3') }
        end
        sub = LinkedData::Client::Models::OntologySubmission.new(values: submission_values)
        sub_model = ApplicationTestHelpers.acknowledged_save(sub, :submission)
      end
      [ont_model, sub_model]
    end

    def delete_ontologies(ontologies = nil)
      ApplicationTestHelpers.verify_test_target!
      targets = if ontologies.nil?
        TestResourceOwnership.owned_resources(:ontology)
      else
        Array(ontologies).select { |o| TestResourceOwnership.owned?(:ontology, o) }
      end

      failures = []
      confirmed_ontologies = []
      targets.each do |o|
        acronym = if o.respond_to?(:acronym)
          o.acronym
        elsif o.is_a?(Hash)
          o[:acronym] || o['acronym']
        else
          o.to_s
        end
        next unless acronym && !acronym.empty?

        result = begin
          if TestResourceOwnership.outcome_unknown?(:ontology, o)
            ApplicationTestHelpers.reconcile_target(:ontology, o, finder: -> {
              found = LinkedData::Client::Models::Ontology.find_by_acronym(acronym, invalidate_cache: true)&.first if defined?(LinkedData::Client::Models::Ontology) && LinkedData::Client::Models::Ontology.respond_to?(:find_by_acronym)
              if found.nil? && defined?(LinkedData::Client::Models::Ontology) && LinkedData::Client::Models::Ontology.respond_to?(:find)
                id_val = (o.respond_to?(:id) && o.id) || (o.is_a?(Hash) ? (o[:id] || o['id']) : nil) || acronym
                found = LinkedData::Client::Models::Ontology.find(id_val, invalidate_cache: true)
              end
              found
            })
          elsif !o.is_a?(String) && !o.is_a?(Hash) && !o.is_a?(Symbol) && o.respond_to?(:delete)
            resp = o.delete
            ApplicationTestHelpers.evaluate_deletion(:ontology, o, response: resp)
          else
            found = LinkedData::Client::Models::Ontology.find_by_acronym(acronym).first if LinkedData::Client::Models::Ontology.respond_to?(:find_by_acronym)
            if found.nil? && LinkedData::Client::Models::Ontology.respond_to?(:find)
              id_val = o.is_a?(Hash) ? (o[:id] || o['id']) : acronym
              found = LinkedData::Client::Models::Ontology.find(id_val)
            end
            if found.nil?
              ApplicationTestHelpers.evaluate_deletion(:ontology, o, absent: true)
            elsif ApplicationTestHelpers.sdk_error_response?(found)
              ApplicationTestHelpers.evaluate_deletion(:ontology, o, error: ApplicationTestHelpers.sdk_error_message(found))
            else
              resp = found.delete
              ApplicationTestHelpers.evaluate_deletion(:ontology, o, response: resp, found: found)
            end
          end
        rescue StandardError => e
          ApplicationTestHelpers.evaluate_deletion(:ontology, o, error: e)
        rescue Exception => e
          raise if e.is_a?(SignalException) || e.is_a?(SystemExit)
          raise unless ApplicationTestHelpers.sdk_retrieval_exception?(e)
          ApplicationTestHelpers.evaluate_deletion(:ontology, o, error: e)
        end

        if result && result[:success]
          confirmed_ontologies << o
          ApplicationTestHelpers.retire_linked_submissions(o)
        else
          failures << result if result && !result[:success]
        end
      end
      ApplicationTestHelpers.record_confirmed_ontologies(confirmed_ontologies)
      ApplicationTestHelpers.record_cleanup_failures(failures)
      failures
    end
  end

  module Categories
    def create_category(category)
      ApplicationTestHelpers.verify_test_target!
      model = LinkedData::Client::Models::Category.new(values: category.to_h)
      ApplicationTestHelpers.acknowledged_save(model, :category)
    end

    def create_categories(categories_data = nil)
      ApplicationTestHelpers.verify_test_target!
      categories_data ||= fixtures(:categories)
      @categories = []
      categories_data.to_a.each do |name, category|
        cat = create_category(category)
        @categories << cat if cat && (!cat.respond_to?(:errors) || !cat.errors || (cat.errors.respond_to?(:empty?) && cat.errors.empty?))
      end
      @categories
    end

    def delete_categories(categories = nil)
      ApplicationTestHelpers.verify_test_target!
      targets = if categories.nil?
        TestResourceOwnership.owned_resources(:category)
      else
        Array(categories).select { |c| TestResourceOwnership.owned?(:category, c) }
      end

      failures = []
      targets.each do |c|
        acronym = if c.respond_to?(:acronym)
          c.acronym
        elsif c.is_a?(Hash)
          c[:acronym] || c['acronym']
        else
          c.to_s
        end
        next unless acronym && !acronym.empty?

        result = begin
          if TestResourceOwnership.outcome_unknown?(:category, c)
            ApplicationTestHelpers.reconcile_target(:category, c, finder: -> {
              found = LinkedData::Client::Models::Category.find_by_acronym(acronym, invalidate_cache: true)&.first if defined?(LinkedData::Client::Models::Category) && LinkedData::Client::Models::Category.respond_to?(:find_by_acronym)
              if found.nil? && defined?(LinkedData::Client::Models::Category) && LinkedData::Client::Models::Category.respond_to?(:find)
                id_val = (c.respond_to?(:id) && c.id) || (c.is_a?(Hash) ? (c[:id] || c['id']) : nil) || acronym
                found = LinkedData::Client::Models::Category.find(id_val, invalidate_cache: true)
              end
              found
            })
          elsif !c.is_a?(String) && !c.is_a?(Hash) && !c.is_a?(Symbol) && c.respond_to?(:delete)
            resp = c.delete
            ApplicationTestHelpers.evaluate_deletion(:category, c, response: resp)
          else
            found = LinkedData::Client::Models::Category.find_by_acronym(acronym).first if LinkedData::Client::Models::Category.respond_to?(:find_by_acronym)
            if found.nil? && LinkedData::Client::Models::Category.respond_to?(:find)
              id_val = c.is_a?(Hash) ? (c[:id] || c['id']) : acronym
              found = LinkedData::Client::Models::Category.find(id_val)
            end
            if found.nil?
              ApplicationTestHelpers.evaluate_deletion(:category, c, absent: true)
            elsif ApplicationTestHelpers.sdk_error_response?(found)
              ApplicationTestHelpers.evaluate_deletion(:category, c, error: ApplicationTestHelpers.sdk_error_message(found))
            else
              resp = found.delete
              ApplicationTestHelpers.evaluate_deletion(:category, c, response: resp, found: found)
            end
          end
        rescue StandardError => e
          ApplicationTestHelpers.evaluate_deletion(:category, c, error: e)
        rescue Exception => e
          raise if e.is_a?(SignalException) || e.is_a?(SystemExit)
          raise unless ApplicationTestHelpers.sdk_retrieval_exception?(e)
          ApplicationTestHelpers.evaluate_deletion(:category, c, error: e)
        end

        failures << result if result && !result[:success]
      end
      ApplicationTestHelpers.record_cleanup_failures(failures)
      failures
    end
  end

  module Groups
    def create_group(group)
      ApplicationTestHelpers.verify_test_target!
      model = LinkedData::Client::Models::Group.new(values: group.to_h)
      ApplicationTestHelpers.acknowledged_save(model, :group)
    end

    def create_groups(groups_data = nil)
      ApplicationTestHelpers.verify_test_target!
      groups_data ||= fixtures(:groups)
      @groups = []
      groups_data.to_a.each do |name, group|
        grp = create_group(group)
        @groups << grp if grp && (!grp.respond_to?(:errors) || !grp.errors || (grp.errors.respond_to?(:empty?) && grp.errors.empty?))
      end
      @groups
    end

    def delete_groups(groups = nil)
      ApplicationTestHelpers.verify_test_target!
      targets = if groups.nil?
        TestResourceOwnership.owned_resources(:group)
      else
        Array(groups).select { |g| TestResourceOwnership.owned?(:group, g) }
      end

      failures = []
      targets.each do |g|
        acronym = if g.respond_to?(:acronym)
          g.acronym
        elsif g.is_a?(Hash)
          g[:acronym] || g['acronym']
        else
          g.to_s
        end
        next unless acronym && !acronym.empty?

        result = begin
          if TestResourceOwnership.outcome_unknown?(:group, g)
            ApplicationTestHelpers.reconcile_target(:group, g, finder: -> {
              found = LinkedData::Client::Models::Group.find_by_acronym(acronym, invalidate_cache: true)&.first if defined?(LinkedData::Client::Models::Group) && LinkedData::Client::Models::Group.respond_to?(:find_by_acronym)
              if found.nil? && defined?(LinkedData::Client::Models::Group) && LinkedData::Client::Models::Group.respond_to?(:find)
                id_val = (g.respond_to?(:id) && g.id) || (g.is_a?(Hash) ? (g[:id] || g['id']) : nil) || acronym
                found = LinkedData::Client::Models::Group.find(id_val, invalidate_cache: true)
              end
              found
            })
          elsif !g.is_a?(String) && !g.is_a?(Hash) && !g.is_a?(Symbol) && g.respond_to?(:delete)
            resp = g.delete
            ApplicationTestHelpers.evaluate_deletion(:group, g, response: resp)
          else
            found = LinkedData::Client::Models::Group.find_by_acronym(acronym).first if LinkedData::Client::Models::Group.respond_to?(:find_by_acronym)
            if found.nil? && LinkedData::Client::Models::Group.respond_to?(:find)
              id_val = g.is_a?(Hash) ? (g[:id] || g['id']) : acronym
              found = LinkedData::Client::Models::Group.find(id_val)
            end
            if found.nil?
              ApplicationTestHelpers.evaluate_deletion(:group, g, absent: true)
            elsif ApplicationTestHelpers.sdk_error_response?(found)
              ApplicationTestHelpers.evaluate_deletion(:group, g, error: ApplicationTestHelpers.sdk_error_message(found))
            else
              resp = found.delete
              ApplicationTestHelpers.evaluate_deletion(:group, g, response: resp, found: found)
            end
          end
        rescue StandardError => e
          ApplicationTestHelpers.evaluate_deletion(:group, g, error: e)
        rescue Exception => e
          raise if e.is_a?(SignalException) || e.is_a?(SystemExit)
          raise unless ApplicationTestHelpers.sdk_retrieval_exception?(e)
          ApplicationTestHelpers.evaluate_deletion(:group, g, error: e)
        end

        failures << result if result && !result[:success]
      end
      ApplicationTestHelpers.record_cleanup_failures(failures)
      failures
    end
  end

  module Agents
    def delete_agents(agents = nil)
      ApplicationTestHelpers.verify_test_target!
      targets = if agents.nil?
        TestResourceOwnership.owned_resources(:agent)
      else
        (agents.is_a?(Array) ? agents : [agents]).select { |a| TestResourceOwnership.owned?(:agent, a) }
      end

      failures = []
      targets.each do |a|
        agent_id = if a.is_a?(Hash)
          (a[:id] || a['id'])&.to_s
        elsif a.respond_to?(:id) && a.id
          a.id.to_s
        else
          a.to_s
        end
        # Agent.find takes the bare id; affiliations are registered by full URI, which makes find raise.
        agent_id = agent_id&.split('/')&.last

        result = begin
          if TestResourceOwnership.outcome_unknown?(:agent, a)
            ApplicationTestHelpers.reconcile_target(:agent, a, finder: -> {
              if agent_id && !agent_id.to_s.empty? && defined?(LinkedData::Client::Models::Agent) && LinkedData::Client::Models::Agent.respond_to?(:find)
                LinkedData::Client::Models::Agent.find(agent_id, invalidate_cache: true)
              end
            })
          elsif a.is_a?(Hash) || a.is_a?(String) || a.is_a?(Symbol)
            if agent_id && !agent_id.to_s.empty? && defined?(LinkedData::Client::Models::Agent) && LinkedData::Client::Models::Agent.respond_to?(:find)
              found = LinkedData::Client::Models::Agent.find(agent_id)
              if found.nil?
                ApplicationTestHelpers.evaluate_deletion(:agent, a, absent: true)
              elsif ApplicationTestHelpers.sdk_error_response?(found)
                ApplicationTestHelpers.evaluate_deletion(:agent, a, error: ApplicationTestHelpers.sdk_error_message(found))
              else
                resp = found.delete
                ApplicationTestHelpers.evaluate_deletion(:agent, a, response: resp, found: found)
              end
            else
              ApplicationTestHelpers.evaluate_deletion(:agent, a, error: "Cannot resolve agent ID from #{a.inspect}")
            end
          elsif a.respond_to?(:delete)
            resp = a.delete
            ApplicationTestHelpers.evaluate_deletion(:agent, a, response: resp)
          elsif defined?(LinkedData::Client::Models::Agent) && LinkedData::Client::Models::Agent.respond_to?(:find)
            agent_id = a.respond_to?(:id) ? a.id : a.to_s
            found = LinkedData::Client::Models::Agent.find(agent_id) if agent_id && !agent_id.empty?
            if found.nil?
              ApplicationTestHelpers.evaluate_deletion(:agent, a, absent: true)
            elsif ApplicationTestHelpers.sdk_error_response?(found)
              ApplicationTestHelpers.evaluate_deletion(:agent, a, error: ApplicationTestHelpers.sdk_error_message(found))
            else
              resp = found.delete
              ApplicationTestHelpers.evaluate_deletion(:agent, a, response: resp, found: found)
            end
          else
            ApplicationTestHelpers.evaluate_deletion(:agent, a, error: "No delete method or client model available for #{a.inspect}")
          end
        rescue StandardError => e
          ApplicationTestHelpers.evaluate_deletion(:agent, a, error: e)
        rescue Exception => e
          raise if e.is_a?(SignalException) || e.is_a?(SystemExit)
          raise unless ApplicationTestHelpers.sdk_retrieval_exception?(e)
          ApplicationTestHelpers.evaluate_deletion(:agent, a, error: e)
        end

        failures << result if result && !result[:success]
      end
      ApplicationTestHelpers.record_cleanup_failures(failures)
      failures
    end
  end
end
