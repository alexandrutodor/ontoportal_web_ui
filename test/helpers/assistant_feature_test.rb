require 'test_helper'

class AssistantFeatureTest < ActionView::TestCase
  include ApplicationHelper

  setup do
    @original_url = ENV['AI_ASSISTANT_BACKEND_URL']
    ENV['AI_ASSISTANT_BACKEND_URL'] = 'https://assistant.example.test/stream'
    @user = Struct.new(:id, :apikey).new('user-1', 'test-apikey')
    define_singleton_method(:current_user) { @user }
    @actor = Flipper::Actor.new(@user.id.to_s)
    Flipper.disable(:ai_assistant)
    Flipper.disable_actor(:ai_assistant, @actor)
  end

  teardown do
    Flipper.disable(:ai_assistant)
    Flipper.disable_actor(:ai_assistant, @actor)
    ENV['AI_ASSISTANT_BACKEND_URL'] = @original_url
  end

  test 'assistant flag is registered but disabled by default' do
    assert_not Flipper.enabled?(:ai_assistant)
  end

  test 'global boolean access does not show the assistant navigation link' do
    Flipper.enable(:ai_assistant)
    assert_not assistant_enabled_for_current_user?
  end

  test 'explicit actor access shows the assistant navigation link' do
    Flipper.enable_actor(:ai_assistant, @actor)
    assert assistant_enabled_for_current_user?
  end
end
