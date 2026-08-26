# frozen_string_literal: true

require 'spec_helper'
require 'legion/extensions/llm/anthropic/provider'

RSpec.describe Legion::Extensions::Llm::Anthropic::Provider do
  it 'exposes the 0.8.0 canonical funnel signatures' do
    # 0.8.0 08 F1/F3: chat/stream_chat are thin delegates to the base
    # complete funnel, which takes messages as its single required
    # positional. Every other canonical operation is kwargs-only.
    expect(described_class.instance_method(:chat).parameters).to include(%i[req messages])
    expect(described_class.instance_method(:stream_chat).parameters).to include(%i[req messages])

    canonical_methods.each { |method_name| expect_keyword_compatible(method_name) }
  end

  def canonical_methods = %i[embed image list_models discover_offerings health count_tokens]

  def expect_keyword_compatible(method_name)
    return unless described_class.method_defined?(method_name)

    params = described_class.instance_method(method_name).parameters
    expect(params).not_to include(%i[req messages]), "#{method_name} still has positional messages"
    expect(params).not_to include(%i[req text]), "#{method_name} still has positional text"
    expect(params).not_to include(%i[req prompt]), "#{method_name} still has positional prompt"
  end

  describe '#translator' do
    let(:provider) do
      described_class.new({
                            anthropic_api_key:         'test-key',
                            request_timeout:           30,
                            max_retries:               0,
                            retry_interval:            0,
                            retry_backoff_factor:      0,
                            retry_interval_randomness: 0
                          })
    end

    it 'exposes a public translator accessor' do
      expect(provider.translator).to respond_to(:capabilities)
      expect(provider.translator).to respond_to(:parse_response)
      expect(provider.translator).to respond_to(:parse_chunk)
    end

    it 'translator capabilities include tool_calls' do
      expect(provider.translator.capabilities[:tool_calls]).to eq(:native)
    end
  end

  describe '#render_payload' do
    let(:provider) do
      described_class.new({
                            anthropic_api_key:         'test-key',
                            request_timeout:           30,
                            max_retries:               0,
                            retry_interval:            0,
                            retry_backoff_factor:      0,
                            retry_interval_randomness: 0
                          })
    end

    # 0.8.0 R1: the funnel passes the plain model string to render_payload, and
    # the Messages API requires max_tokens on every request — the registered
    # instance default (4096) is the single source (per-model max_tokens is
    # inventory evidence, not a render input).
    def render_for(model)
      messages = [Legion::Extensions::Llm::Canonical::Message.build(role: :user, content: 'hello')]
      provider.send(:render_payload, messages, tools: {}, params: nil, model: model,
                                             stream: false, schema: nil, thinking: nil, tool_prefs: nil)
    end

    it 'renders the plain-string model and the registered default max_tokens' do
      payload = render_for('claude-sonnet-4-6')
      expect(payload[:model]).to eq('claude-sonnet-4-6')
      expect(payload[:max_tokens]).to eq(4096)
    end
  end

  # 0.8.0 08 R2 / kit B2: the streaming parse yields Canonical::Chunk objects
  # asserted BY TYPE. (Central enforcement of the message input is the base
  # funnel's job — 08 F2 — so the provider has no message-shape method of its
  # own anymore.)
  describe '#build_chunk' do
    let(:provider) do
      described_class.new({
                            anthropic_api_key:         'test-key',
                            request_timeout:           30,
                            max_retries:               0,
                            retry_interval:            0,
                            retry_backoff_factor:      0,
                            retry_interval_randomness: 0
                          })
    end

    it 'parses a real Anthropic content_block_delta text into a Canonical::Chunk text_delta' do
      data = {
        'type'  => 'content_block_delta',
        'index' => 0,
        'delta' => { 'type' => 'text_delta', 'text' => 'Hello' }
      }
      chunk = provider.send(:build_chunk, data)
      expect(chunk).to be_a(Legion::Extensions::Llm::Canonical::Chunk)
      expect(chunk.type).to eq(:text_delta)
      expect(chunk.delta).to eq('Hello')
    end

    it 'parses a real Anthropic content_block_delta thinking into a Canonical::Chunk thinking_delta' do
      data = {
        'type'  => 'content_block_delta',
        'index' => 0,
        'delta' => { 'type' => 'thinking_delta', 'thinking' => 'reasoning...' }
      }
      chunk = provider.send(:build_chunk, data)
      expect(chunk).to be_a(Legion::Extensions::Llm::Canonical::Chunk)
      expect(chunk.type).to eq(:thinking_delta)
      expect(chunk.delta).to eq('reasoning...')
    end

    it 'parses a real Anthropic message_delta into a done Canonical::Chunk with usage' do
      data = {
        'type'  => 'message_delta',
        'delta' => { 'stop_reason' => 'end_turn' },
        'usage' => { 'output_tokens' => 15 }
      }
      chunk = provider.send(:build_chunk, data)
      expect(chunk).to be_a(Legion::Extensions::Llm::Canonical::Chunk)
      expect(chunk.type).to eq(:done)
      expect(chunk.usage.output_tokens).to eq(15)
    end

    it 'parses message_start into a usage Canonical::Chunk with the wire model in metadata' do
      data = {
        'type'    => 'message_start',
        'message' => {
          'id'    => 'msg_123',
          'model' => 'claude-sonnet-4-20250514',
          'usage' => { 'input_tokens' => 100 }
        }
      }
      chunk = provider.send(:build_chunk, data)
      expect(chunk).to be_a(Legion::Extensions::Llm::Canonical::Chunk)
      expect(chunk.type).to eq(:usage)
      expect(chunk.usage.input_tokens).to eq(100)
      expect(chunk.metadata[:model]).to eq('claude-sonnet-4-20250514')
    end

    it 'returns nil for ping and other non-content events' do
      data = { 'type' => 'ping' }
      chunk = provider.send(:build_chunk, data)
      expect(chunk).to be_nil
    end
  end
end
