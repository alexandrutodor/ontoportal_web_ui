# frozen_string_literal: true

require_relative "../../test_helper_standalone"

test_files = Dir[File.expand_path("*_test.rb", __dir__)].sort
test_files.each do |file|
  require file
end
