require 'test_helper'

class ContextualAssistantTest < ActionController::TestCase
  tests AssistantController

  setup do
    @user = Struct.new(:id, :admin?).new('user-1', false)
    @request.session[:user] = @user
    @actor = Flipper::Actor.new(@user.id.to_s)
    @original_url = ENV['AI_ASSISTANT_BACKEND_URL']
    ENV['AI_ASSISTANT_BACKEND_URL'] = 'https://assistant.example.test/stream'
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

  test 'context payload is allowlisted, bounded, and sanitized before streaming' do
    stub_request(:post, 'https://assistant.example.test/stream')
      .with(body: { prompt: 'Hello', context: { 'page_kind' => 'ontology', 'title' => 'Ontology', 'project_description' => 'alert(1)' } }.to_json)
      .to_return(status: 200, headers: { 'Content-Type' => 'text/event-stream' }, body: "data: hello\n\n")
    Flipper.enable_actor(:ai_assistant, @actor)
    Flipper.enable_actor(:contextual_assistant, @actor)

    post :stream, params: {
      prompt: 'Hello',
      context: {
        page_kind: 'ontology',
        title: 'Ontology',
        project_description: '<script>alert(1)</script>',
        private_token: 'do-not-forward'
      }
    }, as: :json

    assert_response :success
    assert_requested :post, 'https://assistant.example.test/stream'
  end

  test 'context is rejected unless the separate contextual actor flag is enabled' do
    Flipper.enable_actor(:ai_assistant, @actor)

    post :stream, params: { prompt: 'Hello', context: { page_kind: 'ontology' } }, as: :json

    assert_response :not_found
  end
end
