class AssistantController < ApplicationController
  wrap_parameters false
  include ActionController::Live

  STREAM_ERROR_MESSAGE = 'Assistant backend is unavailable.'
  PROMPT_LIMIT = 4_000

  layout :determine_layout
  before_action :require_assistant_user
  before_action :require_ai_assistant
  before_action :require_assistant_backend

  def index
  end

  def stream
    stream_started = false
    stream_completed = false
    payload = assistant_payload
    return render json: { error: 'Prompt is required.' }, status: :unprocessable_entity if payload.nil?
    context_requested = params.key?(:context) || params.key?('context')
    return head :not_found if context_requested && !contextual_assistant_enabled?

    response.headers['Cache-Control'] = 'no-cache'
    response.headers['X-Accel-Buffering'] = 'no'
    response.headers['Content-Type'] = 'text/event-stream'
    AssistantBackend.new.stream(payload) do |chunk|
      stream_started = true
      response.stream.write(chunk)
    end
    stream_completed = true
  rescue AssistantBackend::Error => error
    if response.committed?
      stream_started = true
      response.stream.write("event: error\ndata: #{JSON.generate(error: STREAM_ERROR_MESSAGE)}\n\n")
    else
      render json: { error: error.message }, status: error.status
    end
  rescue ActionController::Live::ClientDisconnected, IOError
    Rails.logger.info('Assistant stream client disconnected')
  ensure
    response.stream.close if stream_started || stream_completed
  end

  private

  def require_assistant_user
    return if session[:user]

    if request.get?
      redirect_to '/login'
    else
      render json: { error: 'Authentication required.' }, status: :unauthorized
    end
  end

  def require_ai_assistant
    actor = Flipper::Actor.new(session[:user].id.to_s)
    return if helpers.flipper_actor_enabled?(:ai_assistant, actor)

    if Flipper.enabled?(:ai_assistant)
      render json: { error: 'Assistant access is not enabled for this account.' }, status: :forbidden
    else
      head :not_found
    end
  rescue Flipper::Error, ArgumentError
    head :not_found
  end

  def require_assistant_backend
    AssistantBackend.validated_uri(ENV['AI_ASSISTANT_BACKEND_URL'])
  rescue AssistantBackend::Error => error
    render json: { error: error.message }, status: error.status
  end

  def assistant_payload
    unexpected = params.keys.map(&:to_s) - %w[controller action format prompt context]
    return if unexpected.any?

    prompt = params[:prompt].to_s.encode('UTF-8', invalid: :replace, undef: :replace).strip
    return if prompt.empty? || prompt.bytesize > PROMPT_LIMIT

    payload = { prompt: prompt }
    payload[:context] = sanitize_context(params[:context]) if params.key?(:context) || params.key?('context')
    payload
  end

  def contextual_assistant_enabled?
    actor = Flipper::Actor.new(session[:user].id.to_s)
    helpers.flipper_actor_enabled?(:contextual_assistant, actor)
  rescue Flipper::Error, ArgumentError
    false
  end

  def sanitize_context(raw_context)
    raw = raw_context.respond_to?(:to_unsafe_h) ? raw_context.to_unsafe_h : raw_context
    return {} unless raw.is_a?(Hash)

    limits = {
      'page_kind' => 40,
      'title' => 200,
      'search_query' => 200,
      'ontology_acronym' => 80,
      'ontology_name' => 200,
      'concept_id' => 300,
      'concept_label' => 200,
      'project_name' => 200,
      'project_description' => 500
    }
    limits.each_with_object({}) do |(key, limit), context|
      value = raw[key] || raw[key.to_sym]
      next if value.blank?

      context[key] = value.to_s.gsub(/<[^>]*>/, '').encode('UTF-8', invalid: :replace, undef: :replace).strip.first(limit).to_s
    end
  end
end
