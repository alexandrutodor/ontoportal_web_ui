# frozen_string_literal: true

require 'minitest/autorun'

$LOAD_PATH.unshift File.expand_path('../app/models', __dir__)
$LOAD_PATH.unshift File.expand_path('../app/services', __dir__)
$LOAD_PATH.unshift File.expand_path('../app/controllers', __dir__)

# Fallback path for rubyzip in test environment
gem_paths = Dir.glob('/home/ranma/ontoportal/**/rubyzip-*/lib') + Dir.glob('/home/ranma/**/rubyzip-*/lib')
gem_paths.uniq.each { |p| $LOAD_PATH.unshift(p) }

require 'semantic_capsule'
require 'capsules/lockfile_generator'
require 'capsules/lockfile_validator'
require 'capsules/ro_crate_exporter'
