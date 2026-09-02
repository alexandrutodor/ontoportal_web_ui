require 'test_helper'

class ContextualAssistantFeatureTest < ActionView::TestCase
  include ApplicationHelper

  setup do
    @original_url = ENV['AI_ASSISTANT_BACKEND_URL']
    ENV['AI_ASSISTANT_BACKEND_URL'] = 'https://assistant.example.test/stream'
    @user = Struct.new(:id, :apikey).new('user-1', 'test-apikey')
    define_singleton_method(:current_user) { @user }
    @actor = Flipper::Actor.new(@user.id.to_s)
    Flipper.disable(:ai_assistant)
    Flipper.disable(:contextual_assistant)
    Flipper.disable_actor(:ai_assistant, @actor)
    Flipper.disable_actor(:contextual_assistant, @actor)
  end

  teardown do
    Flipper.disable(:ai_assistant)
    Flipper.disable(:contextual_assistant)
    Flipper.disable_actor(:ai_assistant, @actor)
    Flipper.disable_actor(:contextual_assistant, @actor)
    ENV['AI_ASSISTANT_BACKEND_URL'] = @original_url
  end

  test 'anonymous users do not receive contextual markup access' do
    define_singleton_method(:current_user) { nil }

    assert_not contextual_assistant_enabled_for_current_user?
  end

  test 'global boolean gates do not grant contextual actor access' do
    Flipper.enable(:ai_assistant)
    Flipper.enable(:contextual_assistant)

    assert_not contextual_assistant_enabled_for_current_user?
  end

  test 'contextual access requires both actor-scoped flags and the backend URL' do
    Flipper.enable_actor(:ai_assistant, @actor)
    Flipper.enable_actor(:contextual_assistant, @actor)

    assert contextual_assistant_enabled_for_current_user?
  end
end
