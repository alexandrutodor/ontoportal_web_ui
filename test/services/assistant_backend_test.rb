require 'test_helper'

class AssistantBackendTest < ActiveSupport::TestCase
  test 'posts only the bounded prompt and accepts an event stream' do
    stub_request(:post, 'https://assistant.example.test/stream')
      .with(
        body: { prompt: 'Hello' }.to_json,
        headers: { 'Accept' => 'text/event-stream', 'Content-Type' => 'application/json' }
      )
      .to_return(status: 200, headers: { 'Content-Type' => 'text/event-stream' }, body: "data: hello\n\n")

    chunks = []
    AssistantBackend.new(url: 'https://assistant.example.test/stream').stream(prompt: 'Hello') { |chunk| chunks << chunk }

    assert_equal ["data: hello\n\n"], chunks
  end

  test 'maps non-success and unavailable responses to safe errors' do
    stub_request(:post, 'https://assistant.example.test/stream').to_return(status: 503, body: 'secret')
    error = assert_raises(AssistantBackend::Error) do
      AssistantBackend.new(url: 'https://assistant.example.test/stream').stream(prompt: 'Hello') { |_chunk| }
    end
    assert_equal :bad_gateway, error.status

    error = assert_raises(AssistantBackend::Error) { AssistantBackend.new(url: nil) }
    assert_equal :service_unavailable, error.status

    stub_request(:post, 'https://assistant.example.test/stream')
      .to_return(status: 200, headers: { 'Content-Type' => 'text/event-stream' }, body: 'x' * (AssistantBackend::MAX_RESPONSE_BYTES + 1))
    error = assert_raises(AssistantBackend::Error) do
      AssistantBackend.new(url: 'https://assistant.example.test/stream').stream(prompt: 'Hello') { |_chunk| }
    end
    assert_equal :bad_gateway, error.status

    stub_request(:post, 'https://assistant.example.test/stream').to_raise(Errno::ECONNRESET)
    error = assert_raises(AssistantBackend::Error) do
      AssistantBackend.new(url: 'https://assistant.example.test/stream').stream(prompt: 'Hello') { |_chunk| }
    end
    assert_equal :service_unavailable, error.status
  end
end
