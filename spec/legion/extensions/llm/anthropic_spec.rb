# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Legion::Extensions::Llm::Anthropic do
  let(:provider_config) { { anthropic_api_key: 'test-anthropic-key', anthropic_version: '2023-06-01' } }
  let(:provider) { described_class::Provider.new(provider_config) }
  let(:claude_model) do
    Legion::Extensions::Llm::Model::Info.new(id: 'claude-sonnet-4-5-20250929', provider: :anthropic,
                                             metadata: { max_output_tokens: 8192 })
  end
  let(:registry_publisher) { instance_double(described_class::RegistryPublisher) }

  it 'exposes provider defaults with inherited fleet settings' do
    settings = described_class.default_settings

    expect(settings[:provider_family]).to eq(:anthropic)
    expect(settings[:fleet]).to include(:enabled)
    expect(settings.dig(:instances, :default, :endpoint)).to eq('https://api.anthropic.com')
    expect(settings.dig(:instances, :default, :usage, :embedding)).to be false
  end

  it 'extends AutoRegistration for multi-instance discovery' do
    expect(described_class).to respond_to(:discover_instances)
    expect(described_class).to respond_to(:register_discovered_instances)
    expect(described_class).to respond_to(:rediscover!)
  end

  it 'exposes Anthropic endpoint helpers and headers' do
    expect([provider.api_base, provider.completion_url, provider.models_url])
      .to eq(['https://api.anthropic.com', '/v1/messages', '/v1/models'])
    expect(provider.headers).to eq('x-api-key' => 'test-anthropic-key', 'anthropic-version' => '2023-06-01')
  end

  it 'advertises chat capabilities without embeddings' do
    capabilities = described_class::Provider.capabilities

    expect(capabilities.chat?(claude_model)).to be true
    expect(capabilities.streaming?(claude_model)).to be true
    expect(capabilities.functions?(claude_model)).to be true
    expect(capabilities.embeddings?(claude_model)).to be false
  end

  it 'renders chat payloads in the Anthropic Messages API shape' do
    payload = chat_payload

    expect_chat_envelope(payload)
    expect_chat_content(payload)
  end

  it 'renders Anthropic tool definitions and tool choices' do
    payload = chat_payload(tools: {
                             lookup: tool('lookup', 'look up a value', { type: 'object', properties: {} })
                           }, tool_prefs: { choice: :lookup, calls: :one })

    expect(payload[:tools]).to eq([lookup_tool_definition])
    expect(payload[:tool_choice]).to eq(lookup_tool_choice)
  end

  it 'parses completion responses with text, thinking, tool calls, and usage' do
    message = provider.send(:parse_completion_response, fake_response(completion_body))

    expect_completion_text_and_thinking(message)
    expect_completion_tool_call(message)
    expect_completion_usage(message)
  end

  it 'parses Anthropic model listing responses' do
    models = parsed_models

    expect(models.first.to_h).to include(expected_model_listing)
  end

  it 'publishes discovered models asynchronously through the registry publisher' do
    stub_registry_publisher
    stub_model_discovery

    models = provider.list_models

    expect_registry_publish(models)
  end

  it 'builds sanitized lex-llm registry events for Anthropic model availability' do
    events = capture_registry_events([claude_model], readiness: { ready: true })

    expect(events.first.to_h).to include(event_type: :offering_available)
    expect(events.first.to_h.dig(:offering, :provider_family)).to eq(:anthropic)
    expect(events.first.to_h.dig(:offering, :model)).to eq('claude-sonnet-4-5-20250929')
  end

  def chat_payload(tools: {}, tool_prefs: nil)
    messages = [
      Legion::Extensions::Llm::Message.new(role: :system, content: 'answer briefly'),
      Legion::Extensions::Llm::Message.new(role: :user, content: 'hello')
    ]
    thinking = Legion::Extensions::Llm::Thinking::Config.new(budget: 2048)
    provider.send(:render_payload, messages, tools: tools, temperature: 0.2, model: claude_model, stream: false,
                                             schema: nil, thinking: thinking, tool_prefs: tool_prefs)
  end

  def expect_chat_envelope(payload)
    expect(payload.values_at(:model, :stream, :max_tokens)).to eq(['claude-sonnet-4-5-20250929', false, 8192])
    expect(payload[:thinking]).to eq({ type: 'enabled', budget_tokens: 2048 })
    expect(payload[:temperature]).to eq(0.2)
  end

  def expect_chat_content(payload)
    expect(payload[:system]).to eq([{ type: 'text', text: 'answer briefly' }])
    expect(payload[:messages]).to eq([{ role: 'user', content: [{ type: 'text', text: 'hello' }] }])
  end

  def lookup_tool_definition
    {
      name: 'lookup',
      description: 'look up a value',
      input_schema: { type: 'object', properties: {} }
    }
  end

  def lookup_tool_choice
    { type: 'tool', name: 'lookup', disable_parallel_tool_use: true }
  end

  def expect_completion_text_and_thinking(message)
    expect(message.content).to eq('done')
    expect(message.thinking.text).to eq('reasoned')
    expect(message.thinking.signature).to eq('sig-1')
  end

  def expect_completion_tool_call(message)
    expect(message.tool_calls.fetch('toolu_1').to_h).to eq(
      { id: 'toolu_1', name: 'lookup', arguments: { 'id' => 1 } }
    )
  end

  def expect_completion_usage(message)
    expect([message.model_id, message.input_tokens, message.output_tokens]).to eq(
      ['claude-sonnet-4-5-20250929', 11, 7]
    )
  end

  def parsed_models
    provider.send(:parse_list_models_response, fake_response(models_body), :anthropic, nil)
  end

  def expected_model_listing
    {
      id: 'claude-opus-4-1-20250805',
      name: 'Claude Opus 4.1',
      provider: :anthropic
    }
  end

  def tool(name, description, params_schema)
    Struct.new(:name, :description, :params_schema).new(name, description, params_schema)
  end

  def completion_body
    {
      'model' => 'claude-sonnet-4-5-20250929',
      'content' => [
        { 'type' => 'thinking', 'thinking' => 'reasoned', 'signature' => 'sig-1' },
        { 'type' => 'text', 'text' => 'done' },
        { 'type' => 'tool_use', 'id' => 'toolu_1', 'name' => 'lookup', 'input' => { 'id' => 1 } }
      ],
      'usage' => { 'input_tokens' => 11, 'output_tokens' => 7 }
    }
  end

  def models_body
    {
      'data' => [
        {
          'id' => 'claude-opus-4-1-20250805',
          'display_name' => 'Claude Opus 4.1',
          'created_at' => '2025-08-05T00:00:00Z'
        }
      ]
    }
  end

  def fake_response(body)
    Struct.new(:body).new(body)
  end

  def stub_registry_publisher
    allow(described_class::Provider).to receive(:registry_publisher).and_return(registry_publisher)
    allow(registry_publisher).to receive(:publish_models_async)
  end

  def stub_model_discovery
    allow(provider.connection).to receive(:get).with('/v1/models').and_return(fake_response(models_body))
  end

  def expect_registry_publish(models)
    expect(registry_publisher).to have_received(:publish_models_async)
      .with(models, readiness: hash_including(provider: :anthropic, live: false))
  end

  def capture_registry_events(models, readiness:)
    publisher = described_class::RegistryPublisher.new
    events = []
    allow(publisher).to receive(:publishing_available?).and_return(true)
    allow(publisher).to receive(:publish_event) { |event| events << event }
    allow(Thread).to receive(:new).and_yield
    publisher.publish_models_async(models, readiness:)
    events
  end
end
