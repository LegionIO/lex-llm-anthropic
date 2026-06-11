# frozen_string_literal: true

require 'spec_helper'
require 'legion/extensions/llm/anthropic/translator'

RSpec.describe Legion::Extensions::Llm::Anthropic::Translator do
  let(:canonical) { Legion::Extensions::Llm::Canonical }
  let(:translator) { described_class.new(default_thinking_budget: 1024, default_max_tokens: 4096) }

  it_behaves_like 'a canonical provider translator', described_class

  describe '#capabilities' do
    it 'declares Anthropic-specific quirks' do
      expect(translator.capabilities[:provider]).to eq('anthropic')
      expect(translator.capabilities[:thinking]).to eq(:signature_lifecycle)
      expect(translator.capabilities[:assistant_prefill]).to be true
      expect(translator.capabilities[:streaming]).to be true
      expect(translator.capabilities[:tool_calls]).to eq(:native)
      expect(translator.capabilities[:system_content_blocks]).to be true

      supported = translator.capabilities[:supported_params]
      expect(supported).to include(:max_tokens, :temperature, :stop_sequences, :seed, :response_format)
      expect(supported).not_to include(:top_p, :top_k, :frequency_penalty, :presence_penalty)
    end
  end

  describe '#render_request' do
    context 'param mapping (G18)' do
      it 'renders max_tokens as max_tokens (no rename needed for Anthropic)' do
        req = canonical::Request.build(
          messages: [canonical::Message.build(role: :user, content: [{ type: :text, text: 'hello' }])],
          params:   canonical::Params.new(max_tokens: 8192, temperature: nil, top_p: nil, top_k: nil,
                                          stop_sequences: nil, seed: nil, frequency_penalty: nil, presence_penalty: nil,
                                          response_format: nil, max_thinking_tokens: nil)
        )
        wire = translator.render_request(req)
        expect(wire[:max_tokens]).to eq(8192)
      end

      it 'renders temperature' do
        req = canonical::Request.build(
          messages: [canonical::Message.build(role: :user, content: 'hello')],
          params:   canonical::Params.new(max_tokens: nil, temperature: 0.7, top_p: nil, top_k: nil,
                                          stop_sequences: nil, seed: nil, frequency_penalty: nil, presence_penalty: nil,
                                          response_format: nil, max_thinking_tokens: nil)
        )
        wire = translator.render_request(req)
        expect(wire[:temperature]).to eq(0.7)
      end

      it 'renders stop_sequences' do
        req = canonical::Request.build(
          messages: [canonical::Message.build(role: :user, content: 'hi')],
          params:   canonical::Params.new(max_tokens: nil, temperature: nil, top_p: nil, top_k: nil,
                                          stop_sequences: ['[END]'], seed: nil, frequency_penalty: nil,
                                          presence_penalty: nil, response_format: nil, max_thinking_tokens: nil)
        )
        wire = translator.render_request(req)
        expect(wire[:stop_sequences]).to eq(['[END]'])
      end

      it 'renders seed' do
        req = canonical::Request.build(
          messages: [canonical::Message.build(role: :user, content: 'hi')],
          params:   canonical::Params.new(max_tokens: nil, temperature: nil, top_p: nil, top_k: nil,
                                          stop_sequences: nil, seed: 42, frequency_penalty: nil,
                                          presence_penalty: nil, response_format: nil, max_thinking_tokens: nil)
        )
        wire = translator.render_request(req)
        expect(wire[:seed]).to eq(42)
      end
    end
  end

  describe '#parse_response' do
    context 'stop_reason mapping' do
      it 'maps end_turn' do
        resp = translator.parse_response({ content: [{ type: 'text', text: 'ok' }], stop_reason: 'end_turn',
                                           model: 'claude-3', usage: { input_tokens: 5, output_tokens: 3 } })
        expect(resp.stop_reason).to eq(:end_turn)
      end

      it 'maps tool_use' do
        resp = translator.parse_response({ content: [], stop_reason: 'tool_use',
                                           model: 'claude-3', usage: { input_tokens: 5, output_tokens: 3 } })
        expect(resp.stop_reason).to eq(:tool_use)
      end

      it 'maps max_tokens' do
        resp = translator.parse_response({ content: [{ type: 'text', text: '' }], stop_reason: 'max_tokens',
                                           model: 'claude-3', usage: { input_tokens: 5, output_tokens: 3 } })
        expect(resp.stop_reason).to eq(:max_tokens)
      end

      it 'maps stop_sequence' do
        resp = translator.parse_response({ content: [{ type: 'text', text: '' }], stop_reason: 'stop_sequence',
                                           model: 'claude-3', usage: { input_tokens: 5, output_tokens: 3 } })
        expect(resp.stop_reason).to eq(:stop_sequence)
      end

      it 'maps content_filter' do
        resp = translator.parse_response({ content: [{ type: 'text', text: '' }], stop_reason: 'content_filter',
                                           model: 'claude-3', usage: { input_tokens: 5, output_tokens: 3 } })
        expect(resp.stop_reason).to eq(:content_filter)
      end
    end

    context 'Anthropic-specific response parsing' do
      it 'extracts thinking with content and signature' do
        wire = {
          content:     [
            { type: 'thinking', thinking: 'Let me reason', signature: 'sig-abc' },
            { type: 'text', text: 'Answer' }
          ],
          stop_reason: 'end_turn',
          model:       'claude-3',
          usage:       { input_tokens: 20, output_tokens: 10 }
        }
        resp = translator.parse_response(wire)
        expect(resp.text).to eq('Answer')
        expect(resp.thinking).to be_a(canonical::Thinking)
        expect(resp.thinking.content).to eq('Let me reason')
        expect(resp.thinking.signature).to eq('sig-abc')
      end

      it 'extracts redacted_thinking data as signature' do
        wire = {
          content:     [
            { type: 'redacted_thinking', data: 'redacted-sig' },
            { type: 'text', text: 'Answer' }
          ],
          stop_reason: 'end_turn',
          model:       'claude-3',
          usage:       { input_tokens: 20, output_tokens: 10 }
        }
        resp = translator.parse_response(wire)
        expect(resp.thinking.signature).to eq('redacted-sig')
      end

      it 'extracts thinking_tokens from output_tokens_details' do
        wire = {
          content:     [{ type: 'text', text: 'hi' }],
          stop_reason: 'end_turn',
          model:       'claude-3',
          usage:       { input_tokens: 5, output_tokens: 10,
                   output_tokens_details: { writing_tokens: 5, reasoning_tokens: 5 } }
        }
        resp = translator.parse_response(wire)
        expect(resp.usage.thinking_tokens).to eq(5)
      end

      it 'extracts cache_creation_input_tokens' do
        wire = {
          content:     [{ type: 'text', text: 'hi' }],
          stop_reason: 'end_turn',
          model:       'claude-3',
          usage:       { input_tokens: 100, output_tokens: 10,
                   cache_read_input_tokens: 50, cache_creation_input_tokens: 30 }
        }
        resp = translator.parse_response(wire)
        expect(resp.usage.cache_read_tokens).to eq(50)
        expect(resp.usage.cache_write_tokens).to eq(30)
      end
    end
  end

  describe '#parse_chunk' do
    context 'Anthropic SSE event types' do
      it 'parses text_delta from delta.text' do
        raw = { type: 'text_delta', delta: { type: 'text_delta', text: 'Hello' }, request_id: 'req-1' }
        chunk = translator.parse_chunk(raw)
        expect(chunk).to be_a(canonical::Chunk)
        expect(chunk.type).to eq(:text_delta)
        expect(chunk.delta).to eq('Hello')
      end

      it 'parses thinking_delta from delta.thinking' do
        raw = { type: 'thinking_delta', delta: { type: 'thinking_delta', thinking: 'hmm' }, request_id: 'req-1' }
        chunk = translator.parse_chunk(raw)
        expect(chunk.type).to eq(:thinking_delta)
        expect(chunk.delta).to eq('hmm')
      end

      it 'parses done chunk with stop_reason' do
        raw = { type: 'done', stop_reason: 'end_turn',
                request_id: 'req-1', usage: { input_tokens: 5, output_tokens: 3 } }
        chunk = translator.parse_chunk(raw)
        expect(chunk.type).to eq(:done)
        expect(chunk.stop_reason).to eq(:end_turn)
      end
    end
  end
end
