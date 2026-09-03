# frozen_string_literal: true

require 'minitest/autorun'

$LOAD_PATH.unshift File.expand_path('../app/models', __dir__)
$LOAD_PATH.unshift File.expand_path('../app/services', __dir__)
$LOAD_PATH.unshift File.expand_path('../app/controllers', __dir__)

# Explicit paths for rubyzip in test environment (avoid slow filesystem recursive globbing)
["/home/ranma/ontoportal/ontoportal_web_ui/vendor/bundle/ruby/#{RUBY_VERSION}/gems/rubyzip-2.4.1/lib",
 "/home/ranma/ontoportal/ontoportal_web_ui/vendor/bundle/ruby/3.3.0/gems/rubyzip-2.4.1/lib",
 "/home/ranma/ontoportal/ontoportal_web_ui/vendor/bundle/ruby/3.1.0/gems/rubyzip-2.4.1/lib"].each do |p|
  $LOAD_PATH.unshift(p) if File.directory?(p)
end

require 'semantic_capsule'
require 'capsules/lockfile_generator'
require 'capsules/lockfile_validator'
require 'capsules/ro_crate_exporter'
