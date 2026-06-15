# frozen_string_literal: true

require 'spec_helper'
require 'legion/extensions/llm/anthropic/provider'

RSpec.describe Legion::Extensions::Llm::Anthropic::Provider do
  it 'does not expose positional canonical provider arguments' do
    canonical_methods.each { |method_name| expect_keyword_compatible(method_name) }
  end

  def canonical_methods = %i[chat stream_chat embed image list_models discover_offerings health count_tokens]

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

  describe '#build_chunk bridge' do
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

    it 'converts real Anthropic content_block_delta text into a legacy Chunk' do
      data = {
        'type'  => 'content_block_delta',
        'index' => 0,
        'delta' => { 'type' => 'text_delta', 'text' => 'Hello' }
      }
      chunk = provider.send(:build_chunk, data)
      expect(chunk).to be_a(Legion::Extensions::Llm::Chunk)
      expect(chunk.content).to eq('Hello')
    end

    it 'converts real Anthropic content_block_delta thinking into a legacy Chunk' do
      data = {
        'type'  => 'content_block_delta',
        'index' => 0,
        'delta' => { 'type' => 'thinking_delta', 'thinking' => 'reasoning...' }
      }
      chunk = provider.send(:build_chunk, data)
      expect(chunk).to be_a(Legion::Extensions::Llm::Chunk)
      expect(chunk.thinking).not_to be_nil
      expect(chunk.thinking.text).to eq('reasoning...')
    end

    it 'converts real Anthropic message_delta into a legacy Chunk with usage' do
      data = {
        'type'  => 'message_delta',
        'delta' => { 'stop_reason' => 'end_turn' },
        'usage' => { 'output_tokens' => 15 }
      }
      chunk = provider.send(:build_chunk, data)
      expect(chunk).to be_a(Legion::Extensions::Llm::Chunk)
      expect(chunk.output_tokens).to eq(15)
    end

    it 'converts message_start into a legacy Chunk with model_id and input_tokens' do
      data = {
        'type'    => 'message_start',
        'message' => {
          'id'    => 'msg_123',
          'model' => 'claude-sonnet-4-20250514',
          'usage' => { 'input_tokens' => 100 }
        }
      }
      chunk = provider.send(:build_chunk, data)
      expect(chunk).to be_a(Legion::Extensions::Llm::Chunk)
      expect(chunk.model_id).to eq('claude-sonnet-4-20250514')
      expect(chunk.input_tokens).to eq(100)
    end

    it 'returns nil for ping and other non-content events' do
      data = { 'type' => 'ping' }
      chunk = provider.send(:build_chunk, data)
      expect(chunk).to be_nil
    end
  end
end
