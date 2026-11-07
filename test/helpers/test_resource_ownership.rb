# frozen_string_literal: true

module TestResourceOwnership
  RESOURCE_TYPES = [:category, :group, :agent, :user, :ontology, :submission].freeze

  class Registry
    def initialize
      @resources = Hash.new { |h, k| h[k] = {} }
      @unknown_outcomes = Hash.new { |h, k| h[k] = {} }
    end

    def register(type, resource)
      return nil if resource.nil?
      type = type.to_sym
      keys = extract_keys(type, resource)
      return nil if keys.empty?

      # Seeded admin protection: never register admin user as owned
      if type == :user && keys.any? { |k| admin_user?(k) }
        return nil
      end

      keys.each do |k|
        @resources[type][k] = resource
      end
      keys.first
    end

    def expand_aliases(type, keys)
      matched_resources = keys.map { |k| @resources[type][k] }.compact.uniq
      all_keys = keys.dup
      matched_resources.each do |matched|
        all_keys.concat(extract_keys(type, matched))
      end
      all_keys.uniq
    end

    def unregister(type, resource)
      return nil if resource.nil?
      type = type.to_sym
      keys = extract_keys(type, resource)
      return nil if keys.empty?

      expand_aliases(type, keys).each do |k|
        @resources[type].delete(k)
        @unknown_outcomes[type].delete(k)
      end
    end

    def mark_outcome_unknown(type, resource)
      return nil if resource.nil?
      type = type.to_sym
      keys = extract_keys(type, resource)
      return nil if keys.empty?

      expand_aliases(type, keys).each do |k|
        @unknown_outcomes[type][k] = true
      end
      true
    end

    def clear_outcome_unknown(type, resource)
      return nil if resource.nil?
      type = type.to_sym
      keys = extract_keys(type, resource)
      return nil if keys.empty?

      expand_aliases(type, keys).each do |k|
        @unknown_outcomes[type].delete(k)
      end
      true
    end

    def outcome_unknown?(type, resource)
      return false if resource.nil?
      type = type.to_sym
      keys = extract_keys(type, resource)
      return false if keys.empty?

      expand_aliases(type, keys).any? { |k| @unknown_outcomes[type][k] }
    end

    def owned?(type, resource)
      return false if resource.nil?
      type = type.to_sym
      keys = extract_keys(type, resource)
      return false if keys.empty?
      return false if type == :user && keys.any? { |k| admin_user?(k) }

      expand_aliases(type, keys).any? { |k| @resources[type].key?(k) }
    end

    def owned_resources(type)
      type = type.to_sym
      @resources[type].values.uniq
    end

    def owned_keys(type)
      type = type.to_sym
      @resources[type].keys
    end

    def empty?(type = nil)
      if type
        @resources[type.to_sym].empty?
      else
        @resources.values.all?(&:empty?)
      end
    end

    def clear!
      @resources.clear
      @unknown_outcomes.clear
    end

    def extract_keys(type, resource)
      return [] if resource.nil?
      type = type.to_sym if type.respond_to?(:to_sym)

      if type == :agent
        id_val = if resource.is_a?(String) || resource.is_a?(Symbol)
          resource.to_s.strip
        elsif resource.is_a?(Hash)
          (resource[:id] || resource['id'])&.to_s&.strip
        elsif resource.respond_to?(:id) && resource.id
          resource.id.to_s.strip
        end
        return (id_val && !id_val.empty?) ? [id_val] : []
      end

      if type == :submission
        id_val = if resource.is_a?(String) || resource.is_a?(Symbol)
          resource.to_s.strip
        elsif resource.is_a?(Hash)
          (resource[:id] || resource['id'])&.to_s&.strip
        elsif resource.respond_to?(:id) && resource.id
          resource.id.to_s.strip
        end
        return (id_val && !id_val.empty?) ? [id_val] : []
      end

      keys = []

      if resource.is_a?(String) || resource.is_a?(Symbol)
        val = resource.to_s.strip
        keys << val unless val.empty?
        if val.include?('/')
          last = val.split('/').last.to_s.strip
          keys << last unless last.empty?
        end
        return keys.uniq
      end

      if resource.respond_to?(:acronym) && resource.acronym
        keys << resource.acronym.to_s.strip
      end

      if resource.respond_to?(:username) && resource.username
        keys << resource.username.to_s.strip
      end

      if resource.respond_to?(:id) && resource.id
        id_str = resource.id.to_s.strip
        keys << id_str unless id_str.empty?
        if id_str.include?('/')
          last = id_str.split('/').last.to_s.strip
          keys << last unless last.empty?
        end
      end

      if resource.is_a?(Hash)
        [:acronym, 'acronym', :username, 'username', :id, 'id', :name, 'name'].each do |k|
          if resource.key?(k) && resource[k]
            v = resource[k].to_s.strip
            keys << v unless v.empty?
            if v.include?('/')
              last = v.split('/').last.to_s.strip
              keys << last unless last.empty?
            end
          end
        end
      end

      keys.reject(&:empty?).uniq
    end

    private

    def admin_user?(key)
      norm = key.to_s.strip.downcase
      norm == 'admin' || norm == 'administrator' || norm == 'admin@example.com'
    end
  end

  def self.registry
    Thread.current[:test_resource_ownership_registry] ||= Registry.new
  end

  def self.register(type, resource)
    registry.register(type, resource)
  end

  def self.unregister(type, resource)
    registry.unregister(type, resource)
  end

  def self.owned?(type, resource)
    registry.owned?(type, resource)
  end

  def self.owned_resources(type)
    registry.owned_resources(type)
  end

  def self.owned_keys(type)
    registry.owned_keys(type)
  end

  def self.empty?(type = nil)
    registry.empty?(type)
  end

  def self.mark_outcome_unknown(type, resource)
    registry.mark_outcome_unknown(type, resource)
  end

  def self.clear_outcome_unknown(type, resource)
    registry.clear_outcome_unknown(type, resource)
  end

  def self.outcome_unknown?(type, resource)
    registry.outcome_unknown?(type, resource)
  end

  def self.extract_keys(type, resource)
    registry.extract_keys(type, resource)
  end

  def self.reset!
    registry.clear!
    ApplicationTestHelpers.reset_cleanup_failures! if defined?(ApplicationTestHelpers) && ApplicationTestHelpers.respond_to?(:reset_cleanup_failures!)
  end

  def self.namespace_suffix
    @namespace_suffix ||= "_t#{Time.now.to_i % 100000}#{rand(1000..9999)}"
  end

  def self.namespaced(identifier)
    return identifier if identifier.nil?
    str = identifier.to_s
    return str if str.downcase == 'admin' || str.downcase == 'administrator' || str.downcase == 'admin@example.com'
    "#{str}#{namespace_suffix}"
  end
end
