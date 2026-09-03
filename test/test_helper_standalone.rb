# frozen_string_literal: true

require "minitest/autorun"
require "json"
require_relative "../app/services/application_service"
require_relative "../app/services/annotator/confidence_calibrator"
require_relative "../app/services/annotator/nil_detector"
require_relative "../app/services/annotator/w3c_serializer"
require_relative "../app/services/annotator/lexical_service"
require_relative "../app/services/annotator/contextual_service"
require_relative "../app/services/annotator/high_assurance_service"
require_relative "../app/services/annotator/tier_dispatcher"

module ActiveSupport
  class TestCase < Minitest::Test
    def self.test(name, &block)
      test_name = "test_#{name.gsub(/\s+/, '_')}".to_sym
      defined = method_defined?(test_name)
      raise "#{test_name} is already defined in #{self}" if defined

      if block_given?
        define_method(test_name, &block)
      else
        define_method(test_name) do
          flunk "No implementation provided for #{name}"
        end
      end
    end
  end
end
