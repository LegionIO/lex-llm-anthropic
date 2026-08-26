# frozen_string_literal: true

require 'spec_helper'
require 'legion/extensions/llm/inventory/registry'

RSpec.describe Legion::Extensions::Llm::Anthropic do
  let(:provider_config) { { anthropic_api_key: 'test-anthropic-key', anthropic_version: '2023-06-01' } }
  let(:provider) { described_class::Provider.new(provider_config) }
  # 0.8.0 R1: the funnel takes the plain model string.
  let(:claude_model) { 'claude-sonnet-4-5-20250929' }

  it 'exposes provider defaults with inherited fleet settings' do
    settings = described_class.default_settings

    expect(settings[:provider_family]).to eq(:anthropic)
    expect(settings.dig(:fleet, :consumer, :enabled)).to be false
    expect(settings.dig(:instances, :default)).to include(
      endpoint: 'https://api.anthropic.com',
      fleet:    hash_including(respond_to_requests: false),
      usage:    hash_including(embedding: false)
    )
  end

  it 'extends AutoRegistration for multi-instance discovery and provider aliases' do
    expect(described_class).to respond_to(:discover_instances)
    expect(described_class.provider_aliases).to eq([])
    expect(described_class).not_to respond_to(:register_discovered_instances)
    expect(described_class).not_to respond_to(:rediscover!)
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

  it 'parses completion responses into a Canonical::Response with text, thinking, tool calls, and usage' do
    response = provider.send(:parse_completion_response, fake_response(completion_body))

    expect(response).to be_a(Legion::Extensions::Llm::Canonical::Response)
    expect_completion_text_and_thinking(response)
    expect_completion_tool_call(response)
    expect_completion_usage(response)
  end

  it 'serves discover_offerings from the registry snapshot without HTTP (0.8.0 D3: the actor is the sole writer)' do
    Legion::Extensions::Llm::Inventory::Registry.reset!
    allow(provider.connection).to receive(:get)

    offerings = provider.discover_offerings(live: true)

    expect(offerings).to be_empty
    expect(provider.connection).not_to have_received(:get)
  end

  def chat_payload(tools: {}, tool_prefs: nil)
    messages = [
      Legion::Extensions::Llm::Canonical::Message.build(role: :system, content: 'answer briefly'),
      Legion::Extensions::Llm::Canonical::Message.build(role: :user, content: 'hello')
    ]
    thinking = Legion::Extensions::Llm::Canonical::Thinking::Config.build(budget: 2048)
    params = Legion::Extensions::Llm::Canonical::Params.build(temperature: 0.2)
    provider.send(:render_payload, messages, tools: tools, model: claude_model, stream: false,
                                             schema: nil, thinking: thinking, params: params,
                                             tool_prefs: tool_prefs)
  end

  def expect_chat_envelope(payload)
    expect(payload.values_at(:model, :stream, :max_tokens)).to eq(['claude-sonnet-4-5-20250929', false, 4096])
    expect(payload[:thinking]).to eq({ type: 'enabled', budget_tokens: 2048 })
    expect(payload[:temperature]).to eq(0.2)
  end

  def expect_chat_content(payload)
    expect(payload[:system]).to eq([{ type: 'text', text: 'answer briefly' }])
    expect(payload[:messages]).to eq([{ role: 'user', content: [{ type: 'text', text: 'hello' }] }])
  end

  def lookup_tool_definition
    {
      name:         'lookup',
      description:  'look up a value',
      input_schema: { type: 'object', properties: {} }
    }
  end

  def lookup_tool_choice
    { type: 'tool', name: 'lookup', disable_parallel_tool_use: true }
  end

  def expect_completion_text_and_thinking(response)
    expect(response.text).to eq('done')
    expect(response.thinking).to be_a(Legion::Extensions::Llm::Canonical::Thinking)
    expect(response.thinking.content).to eq('reasoned')
    expect(response.thinking.signature).to eq('sig-1')
  end

  def expect_completion_tool_call(response)
    tool_call = response.tool_calls.find { |tc| tc.id == 'toolu_1' }
    expect(tool_call).to be_a(Legion::Extensions::Llm::Canonical::ToolCall)
    expect([tool_call.name, tool_call.arguments]).to eq(['lookup', { 'id' => 1 }])
  end

  def expect_completion_usage(response)
    expect([response.model, response.usage.input_tokens, response.usage.output_tokens]).to eq(
      ['claude-sonnet-4-5-20250929', 11, 7]
    )
  end

  def tool(name, description, params_schema)
    Struct.new(:name, :description, :params_schema).new(name, description, params_schema)
  end

  def completion_body
    {
      'model'   => 'claude-sonnet-4-5-20250929',
      'content' => [
        { 'type' => 'thinking', 'thinking' => 'reasoned', 'signature' => 'sig-1' },
        { 'type' => 'text', 'text' => 'done' },
        { 'type' => 'tool_use', 'id' => 'toolu_1', 'name' => 'lookup', 'input' => { 'id' => 1 } }
      ],
      'usage'   => { 'input_tokens' => 11, 'output_tokens' => 7 }
    }
  end

  def fake_response(body)
    Struct.new(:body).new(body)
  end
end
