# frozen_string_literal: true

# ONTO-T-U10: watcher counts come from one shared tally instead of a full user scan per
# rendered subscribe button; failures yield nil so the button can render without a count.
require 'minitest/autorun'
require 'ostruct'
require 'active_support/all'

module Rails
  def self.cache
    @cache ||= ActiveSupport::Cache::MemoryStore.new
  end
end
module LinkedData; module Client; module Models; class User
  class << self
    attr_accessor :calls, :users, :fail
    def all(*)
      self.calls += 1
      raise 'API down' if fail
      users
    end
  end
end; end; end; end
require_relative '../../app/helpers/ontologies_helper'

class SubscriptionCountCheck < Minitest::Test
  Host = Class.new { include OntologiesHelper }
  User = LinkedData::Client::Models::User

  def sub(ontology) = OpenStruct.new(ontology: ontology)

  def setup
    Rails.cache.clear
    User.calls = 0
    User.fail = false
    User.users = [
      OpenStruct.new(subscription: [sub('http://data.ex/ontologies/A'), sub('A')]), # same ontology twice
      OpenStruct.new(subscription: [sub('http://data.ex/ontologies/A'), sub('http://data.ex/ontologies/B')]),
      OpenStruct.new(subscription: [OpenStruct.new(ontology: nil)]),
      OpenStruct.new(subscription: nil)
    ]
  end

  def test_counts_match_the_previous_per_user_semantics
    h = Host.new
    assert_equal 2, h.count_subscriptions('http://data.ex/ontologies/A'), 'each user counted once'
    assert_equal 1, h.count_subscriptions('B')
    assert_equal 0, h.count_subscriptions('C')
  end

  def test_many_buttons_share_one_user_scan
    h = Host.new
    10.times { |i| h.count_subscriptions(i.even? ? 'A' : 'B') }
    assert_equal 1, User.calls
  end

  def test_invalidation_after_subscription_change_recounts
    h = Host.new
    assert_equal 1, h.count_subscriptions('B')
    User.users << OpenStruct.new(subscription: [sub('B')])
    Rails.cache.delete(OntologiesHelper::SUBSCRIPTION_COUNTS_CACHE_KEY) # as SubscriptionsController#create does
    assert_equal 2, h.count_subscriptions('B')
    assert_equal 2, User.calls
  end

  def test_failure_returns_nil_and_is_not_cached
    User.fail = true
    assert_nil Host.new.count_subscriptions('A')
    User.fail = false
    assert_equal 2, Host.new.count_subscriptions('A')
  end
end
