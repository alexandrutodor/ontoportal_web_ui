require 'test_helper'

class AssistantControllerTest < ActionController::TestCase
  tests AssistantController

  setup do
    @user = Struct.new(:id, :admin?, :apikey).new('user-1', false, 'test-apikey')
    @request.session[:user] = @user
    @actor = Flipper::Actor.new(@user.id.to_s)
    @original_url = ENV['AI_ASSISTANT_BACKEND_URL']
    ENV['AI_ASSISTANT_BACKEND_URL'] = 'https://assistant.example.test/stream'
    Flipper.disable(:ai_assistant)
    Flipper.disable_actor(:ai_assistant, @actor)
  end

  teardown do
    Thread.current[:session] = nil
    Thread.current[:request] = nil
    Flipper.disable(:ai_assistant)
    Flipper.disable_actor(:ai_assistant, @actor)
    ENV['AI_ASSISTANT_BACKEND_URL'] = @original_url
  end

  test 'feature off returns 404 without a backend request' do
    stub_request(:post, %r{assistant\.example\.test}).to_raise('must not call backend')
    post :stream, params: { prompt: 'Hello' }, as: :json
    assert_response :not_found
    assert_not_requested :post, %r{assistant\.example\.test}
  end

  test 'anonymous stream returns 401' do
    @request.session.delete(:user)
    post :stream, params: { prompt: 'Hello' }, as: :json
    assert_response :unauthorized
  end

  test 'globally enabled feature denies an actor without an actor gate' do
    Flipper.enable(:ai_assistant)
    post :stream, params: { prompt: 'Hello' }, as: :json
    assert_response :forbidden
  end

  test 'enabled actor can proxy a bounded event stream' do
    stub_request(:post, 'https://assistant.example.test/stream')
      .with(body: { prompt: 'Hello' }.to_json)
      .to_return(status: 200, headers: { 'Content-Type' => 'text/event-stream' }, body: "data: hello\n\n")
    Flipper.enable_actor(:ai_assistant, @actor)

    post :stream, params: { prompt: 'Hello' }, as: :json

    assert_response :success
    assert_equal 'text/event-stream', response.media_type
    assert_includes response.body, 'hello'
  end

  test 'unknown payload keys and oversized prompts are rejected' do
    Flipper.enable_actor(:ai_assistant, @actor)
    post :stream, params: { prompt: 'Hello', backend_url: 'https://evil.example.test' }, as: :json
    assert_response :unprocessable_entity
    post :stream, params: { prompt: 'x' * (AssistantController::PROMPT_LIMIT + 1) }, as: :json
    assert_response :unprocessable_entity
  end

  test 'missing backend configuration returns 503 after authorization' do
    ENV.delete('AI_ASSISTANT_BACKEND_URL')
    Flipper.enable_actor(:ai_assistant, @actor)
    get :index
    assert_response :service_unavailable
  end
end
