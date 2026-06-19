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

    context 'prompt cache-control injection (C5)' do
      let(:long_system) { 'A' * 1025 }
      let(:short_system) { 'A' * 512 }

      def req_with_system(system_str)
        canonical::Request.build(
          system:   system_str,
          messages: [canonical::Message.build(role: :user, content: 'hi')]
        )
      end

      it 'injects cache_control on last system block when caching enabled and content exceeds min_tokens' do
        t = described_class.new(prompt_caching: { enabled: true, min_tokens: 1024 })
        wire = t.render_request(req_with_system(long_system))
        last_system_block = wire[:system].last
        expect(last_system_block[:cache_control]).to eq({ type: 'ephemeral' })
      end

      it 'does not inject cache_control when content is below min_tokens' do
        t = described_class.new(prompt_caching: { enabled: true, min_tokens: 1024 })
        wire = t.render_request(req_with_system(short_system))
        last_system_block = wire[:system].last
        expect(last_system_block[:cache_control]).to be_nil
      end

      it 'does not inject cache_control when caching disabled' do
        t = described_class.new(prompt_caching: { enabled: false })
        wire = t.render_request(req_with_system(long_system))
        last_system_block = wire[:system].last
        expect(last_system_block[:cache_control]).to be_nil
      end

      it 'does not inject cache_control when system is absent' do
        t = described_class.new(prompt_caching: { enabled: true, min_tokens: 1024 })
        wire = t.render_request(req_with_system(nil))
        expect(wire[:system]).to be_nil
      end

      it 'passes through cache_control: nil for system Hash already carrying cache_control' do
        t = described_class.new(prompt_caching: { enabled: true, min_tokens: 1024 })
        req = canonical::Request.build(
          system:   { content: long_system, cache_control: { type: 'ephemeral' } },
          messages: [canonical::Message.build(role: :user, content: 'hi')]
        )
        wire = t.render_request(req)
        expect(wire[:system]).to eq({ content: long_system, cache_control: { type: 'ephemeral' } })
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

    context 'real Anthropic wire-format SSE events' do
      it 'parses content_block_delta with text_delta' do
        raw = {
          'type'  => 'content_block_delta',
          'index' => 0,
          'delta' => { 'type' => 'text_delta', 'text' => 'Hello world' }
        }
        chunk = translator.parse_chunk(raw)
        expect(chunk).not_to be_nil
        expect(chunk.type).to eq(:text_delta)
        expect(chunk.delta).to eq('Hello world')
        expect(chunk.block_index).to eq(0)
      end

      it 'parses content_block_delta with thinking_delta' do
        raw = {
          'type'  => 'content_block_delta',
          'index' => 0,
          'delta' => { 'type' => 'thinking_delta', 'thinking' => 'Let me reason...' }
        }
        chunk = translator.parse_chunk(raw)
        expect(chunk).not_to be_nil
        expect(chunk.type).to eq(:thinking_delta)
        expect(chunk.delta).to eq('Let me reason...')
      end

      it 'parses content_block_delta with signature_delta' do
        raw = {
          'type'  => 'content_block_delta',
          'index' => 0,
          'delta' => { 'type' => 'signature_delta', 'signature' => 'ErUB...' }
        }
        chunk = translator.parse_chunk(raw)
        expect(chunk).not_to be_nil
        expect(chunk.type).to eq(:thinking_delta)
        expect(chunk.signature).to eq('ErUB...')
      end

      it 'parses content_block_delta with input_json_delta for tool calls' do
        raw = {
          'type'  => 'content_block_delta',
          'index' => 1,
          'delta' => { 'type' => 'input_json_delta', 'partial_json' => '{"path":' }
        }
        chunk = translator.parse_chunk(raw)
        expect(chunk).not_to be_nil
        expect(chunk.type).to eq(:tool_call_delta)
      end

      it 'parses content_block_start with tool_use' do
        raw = {
          'type'          => 'content_block_start',
          'index'         => 1,
          'content_block' => { 'type' => 'tool_use', 'id' => 'toolu_123', 'name' => 'read_file' }
        }
        chunk = translator.parse_chunk(raw)
        expect(chunk).not_to be_nil
        expect(chunk.type).to eq(:tool_call_delta)
        expect(chunk.tool_call.id).to eq('toolu_123')
        expect(chunk.tool_call.name).to eq('read_file')
      end

      it 'parses message_delta with stop_reason and usage' do
        raw = {
          'type'  => 'message_delta',
          'delta' => { 'stop_reason' => 'end_turn' },
          'usage' => { 'output_tokens' => 42 }
        }
        chunk = translator.parse_chunk(raw)
        expect(chunk).not_to be_nil
        expect(chunk.type).to eq(:done)
        expect(chunk.stop_reason).to eq(:end_turn)
        expect(chunk.usage.output_tokens).to eq(42)
      end

      it 'parses message_stop' do
        raw = { 'type' => 'message_stop' }
        chunk = translator.parse_chunk(raw)
        expect(chunk).not_to be_nil
        expect(chunk.type).to eq(:done)
      end

      it 'ignores content_block_start for non-tool-use blocks' do
        raw = {
          'type'          => 'content_block_start',
          'index'         => 0,
          'content_block' => { 'type' => 'text', 'text' => '' }
        }
        chunk = translator.parse_chunk(raw)
        expect(chunk).to be_nil
      end

      it 'parses message_start with model and input_tokens' do
        raw = {
          'type'    => 'message_start',
          'message' => {
            'id'    => 'msg_abc',
            'model' => 'claude-sonnet-4-20250514',
            'usage' => { 'input_tokens' => 250 }
          }
        }
        chunk = translator.parse_chunk(raw)
        expect(chunk).not_to be_nil
        expect(chunk.type).to eq(:usage)
        expect(chunk.usage.input_tokens).to eq(250)
      end

      it 'produces nil-id tool_call for input_json_delta fragments' do
        raw = {
          'type'  => 'content_block_delta',
          'index' => 1,
          'delta' => { 'type' => 'input_json_delta', 'partial_json' => '{"path":"src/m' }
        }
        chunk = translator.parse_chunk(raw)
        expect(chunk).not_to be_nil
        expect(chunk.type).to eq(:tool_call_delta)
        expect(chunk.tool_call.id).to be_nil
        expect(chunk.tool_call.arguments).to eq('{"path":"src/m')
      end
    end

    context 'end-to-end tool call accumulation through provider bridge' do
      let(:provider) do
        Legion::Extensions::Llm::Anthropic::Provider.new({
                                                           anthropic_api_key: 'test-key', request_timeout: 30, max_retries: 0,
          retry_interval: 0, retry_backoff_factor: 0, retry_interval_randomness: 0
                                                         })
      end

      it 'accumulates content_block_start + input_json_delta fragments into one parsed tool call' do
        accumulator = Legion::Extensions::Llm::StreamAccumulator.new

        content_block_start_event = {
          'type' => 'content_block_start', 'index' => 1,
          'content_block' => { 'type' => 'tool_use', 'id' => 'toolu_abc', 'name' => 'read_file' }
        }
        first_json_delta = {
          'type' => 'content_block_delta', 'index' => 1,
          'delta' => { 'type' => 'input_json_delta', 'partial_json' => '{"path":"' }
        }
        second_json_delta = {
          'type' => 'content_block_delta', 'index' => 1,
          'delta' => { 'type' => 'input_json_delta', 'partial_json' => 'src/main.rb"}' }
        }

        accumulator.add(provider.send(:build_chunk, content_block_start_event))
        accumulator.add(provider.send(:build_chunk, first_json_delta))
        accumulator.add(provider.send(:build_chunk, second_json_delta))

        message = accumulator.to_message(nil)
        expect(message.tool_calls['toolu_abc'].arguments).to eq({ 'path' => 'src/main.rb' })
      end
    end

    context 'end-to-end message_start model/usage propagation through provider bridge' do
      let(:provider) do
        Legion::Extensions::Llm::Anthropic::Provider.new({
                                                           anthropic_api_key: 'test-key', request_timeout: 30, max_retries: 0,
          retry_interval: 0, retry_backoff_factor: 0, retry_interval_randomness: 0
                                                         })
      end

      it 'accumulator receives model_id and input_tokens from message_start' do
        accumulator = Legion::Extensions::Llm::StreamAccumulator.new

        message_start_event = {
          'type'    => 'message_start',
          'message' => {
            'model' => 'claude-sonnet-4-20250514',
            'usage' => { 'input_tokens' => 500 }
          }
        }

        accumulator.add(provider.send(:build_chunk, message_start_event))
        message = accumulator.to_message(nil)

        expect(message.model_id).to eq('claude-sonnet-4-20250514')
        expect(message.input_tokens).to eq(500)
      end
    end
  end
end
