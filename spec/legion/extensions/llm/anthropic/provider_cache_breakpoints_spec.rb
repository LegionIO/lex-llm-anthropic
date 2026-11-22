# frozen_string_literal: true

require 'spec_helper'
require 'stringio'

RSpec.describe Legion::Extensions::Llm::Anthropic::Provider do
  conversation_lengths = [7, 20, 40].freeze
  explicit_counts = [1, 4, 5].freeze
  message_hint_positions = [0, 2, 4].freeze
  [false, true].each do |streaming|
    context "with streaming=#{streaming}" do
      conversation_lengths.each do |length|
        it "places bounded breakpoints at stable boundaries for #{length} chat messages" do
          messages = [system_message] + text_messages(length)
          original = Legion::JSON.dump(messages.map(&:to_h))

          wire = capture_request(messages: messages, streaming: streaming)

          expect(marked_blocks(wire).size).to eq(3)
          expect(wire[:tools].last[:cache_control]).to eq(type: 'ephemeral')
          expect(wire[:system].last[:cache_control]).to eq(type: 'ephemeral')
          expect(wire[:messages][length - 5][:content].last[:cache_control]).to eq(type: 'ephemeral')
          expect(marked_blocks({ messages: wire[:messages].last(4) })).to be_empty
          expect(Legion::JSON.dump(messages.map(&:to_h))).to eq(original)
        end
      end

      it 'marks only the outer stable tool result while preserving history and tool identities' do
        messages = tool_history
        original = Legion::JSON.dump(messages.map(&:to_h))
        cached = capture_request(messages: messages, streaming: streaming)
        uncached = capture_request(messages: messages, streaming: streaming, caching: false)

        expect(marked_blocks(cached).size).to eq(3)
        result = cached[:messages][3][:content].last
        expect(result).to include(type: 'tool_result', tool_use_id: 'call_b', cache_control: { type: 'ephemeral' })
        expect(marked_blocks({ messages: [{ content: result[:content] }] })).to be_empty
        expect(without_cache(cached)).to eq(uncached)
        expect(Legion::JSON.dump(messages.map(&:to_h))).to eq(original)
      end

      it 'adds only one automatic system marker across multiple system content blocks' do
        blocks = Array.new(6) { |index| Legion::Extensions::Llm::Canonical::ContentBlock.text("system #{index}") }
        messages = [Legion::Extensions::Llm::Canonical::Message.build(role: :system, content: blocks)] + text_messages(7)

        wire = capture_request(messages: messages, streaming: streaming)

        expect(wire[:system].size).to eq(6)
        expect(wire[:system].count { |block| block.key?(:cache_control) }).to eq(1)
        expect(wire[:system].last).to include(text: 'system 5', cache_control: { type: 'ephemeral' })
        expect(marked_blocks(wire).size).to eq(3)
      end

      it 'respects the configured excluded tail' do
        wire = capture_request(messages: [system_message] + text_messages(7), streaming: streaming, excluded_tail: 2)

        expect(wire[:messages][4][:content].last).to include(cache_control: { type: 'ephemeral' })
        expect(marked_blocks({ messages: wire[:messages].last(2) })).to be_empty
        expect(marked_blocks(wire).size).to eq(3)
      end

      it 'does not put automatic markers on thinking blocks' do
        messages = text_messages(7)
        thinking = Legion::Extensions::Llm::Canonical::ContentBlock.build(type: :thinking, text: 'prior reasoning', metadata: { signature: 'signature' })
        messages[2] = Legion::Extensions::Llm::Canonical::Message.build(role: :assistant, content: [
                                                                          Legion::Extensions::Llm::Canonical::ContentBlock.text('stable text'), thinking
                                                                        ])

        wire = capture_request(messages: messages, streaming: streaming, tools: {})

        expect(marked_blocks(wire)).to contain_exactly(type: 'text', text: 'stable text', cache_control: { type: 'ephemeral' })
        expect(wire[:messages][2][:content].last).to eq(type: 'thinking', thinking: 'prior reasoning', signature: 'signature')
      end

      explicit_counts.each do |count|
        it "preserves #{count} explicit markers and adds no competing automatic policy" do
          explicit = { type: 'ephemeral', ttl: '1h' }
          messages = [system_message] + text_messages(7)
          messages << Legion::Extensions::Llm::Canonical::Message.build(
            role: :user, content: Array.new(count) { |index| Legion::Extensions::Llm::Canonical::ContentBlock.text("explicit #{index}", cache_control: explicit) }
          )
          original = Legion::JSON.dump(messages.map(&:to_h))

          # An invalid caller-supplied count is preserved, not silently repaired.
          wire = capture_request(messages: messages, streaming: streaming)

          expect(marked_blocks(wire).size).to eq(count)
          expect(marked_blocks(wire).map { |block| block[:cache_control] }).to eq(Array.new(count, explicit))
          expect(wire[:system].none? { |block| block.key?(:cache_control) }).to be(true)
          expect(wire[:tools].none? { |block| block.key?(:cache_control) }).to be(true)
          expect(Legion::JSON.dump(messages.map(&:to_h))).to eq(original)
        end
      end

      it 'preserves explicit image/text TTLs with automatic caching disabled' do
        control = { type: 'ephemeral', ttl: '1h' }
        messages = [system_message, Legion::Extensions::Llm::Canonical::Message.build(role: :user, content: [
                                                                                        Legion::Extensions::Llm::Canonical::ContentBlock.text('look', cache_control: control),
                                                                                        Legion::Extensions::Llm::Canonical::ContentBlock.build(type: :image, source_type: :url,
                                                                                                                                               data: 'https://example.test/image.png',
                                                                                                                                               cache_control: control)
                                                                                      ])]
        wire = capture_request(messages: messages, streaming: streaming, caching: false)

        expect(marked_blocks(wire).size).to eq(2)
        expect(wire[:messages].last[:content]).to eq([
                                                       { type: 'text', text: 'look', cache_control: control },
                                                       { type: 'image', source: { type: 'url', url: 'https://example.test/image.png' }, cache_control: control }
                                                     ])
      end

      it 'does not add automatic markers when caching is disabled' do
        wire = capture_request(messages: [system_message] + text_messages(20), streaming: streaming, caching: false)
        expect(marked_blocks(wire)).to be_empty
      end

      it 'projects message cache controls onto system, tool-use, and outer tool-result boundaries' do
        control = { type: 'ephemeral', ttl: '1h' }
        messages = tool_history
        message_hint_positions.each { |index| messages[index] = messages[index].with(cache_control: control) }
        original = Legion::JSON.dump(messages.map(&:to_h))

        wire = capture_request(messages: messages, streaming: streaming)

        expect(marked_blocks(wire).size).to eq(3)
        expect(wire[:system].last[:cache_control]).to eq(control)
        expect(wire[:messages][1][:content].last).to include(type: 'tool_use', id: 'call_b', cache_control: control)
        expect(wire[:messages][3][:content].last).to include(type: 'tool_result', tool_use_id: 'call_b', cache_control: control)
        expect(wire[:tools].none? { |tool| tool.key?(:cache_control) }).to be(true)
        expect(Legion::JSON.dump(messages.map(&:to_h))).to eq(original)
      end

      it 'preserves an explicit message hint on the newest turn even when automatic caching is disabled' do
        control = { type: 'ephemeral', ttl: '1h' }
        messages = [system_message] + text_messages(7)
        messages[-1] = messages.last.with(cache_control: control)

        wire = capture_request(messages: messages, streaming: streaming, caching: false)

        expect(marked_blocks(wire)).to contain_exactly(type: 'text', text: 'turn 6', cache_control: control)
      end

      it 'preserves tool-definition cache controls folded into canonical metadata' do
        control = { type: 'ephemeral', ttl: '1h' }
        definitions = tools
        definitions['read_a'] = Legion::Extensions::Llm::Canonical::ToolDefinition.from_hash(
          definitions.fetch('read_a').to_h.merge(cache_control: control)
        )
        original = Legion::JSON.dump(definitions.transform_values(&:to_h))

        wire = capture_request(messages: [system_message] + text_messages(7), streaming: streaming, tools: definitions)

        expect(marked_blocks(wire).size).to eq(1)
        expect(wire[:tools].first).to include(name: 'read_a', cache_control: control)
        expect(Legion::JSON.dump(definitions.transform_values(&:to_h))).to eq(original)
      end

      it 'keeps block-specific controls instead of overwriting them with a broader message hint' do
        block_control = { type: 'ephemeral', ttl: '1h' }
        message = Legion::Extensions::Llm::Canonical::Message.build(
          role: :user, cache_control: { type: 'ephemeral' },
          content: [Legion::Extensions::Llm::Canonical::ContentBlock.text('explicit block', cache_control: block_control)]
        )

        wire = capture_request(messages: [system_message, message], streaming: streaming)

        expect(marked_blocks(wire)).to contain_exactly(type: 'text', text: 'explicit block', cache_control: block_control)
      end
    end
  end

  def system_message
    Legion::Extensions::Llm::Canonical::Message.build(role: :system, content: 'Stable instructions')
  end

  def text_messages(count)
    Array.new(count) { |index| Legion::Extensions::Llm::Canonical::Message.build(role: index.even? ? :user : :assistant, content: "turn #{index}") }
  end

  def tool_history
    calls = %w[a b].map { |name| Legion::Extensions::Llm::Canonical::ToolCall.build(id: "call_#{name}", name: "read_#{name}", arguments: { path: "#{name}.txt" }) }
    [system_message,
     Legion::Extensions::Llm::Canonical::Message.build(role: :user, content: 'Read both'),
     Legion::Extensions::Llm::Canonical::Message.build(role: :assistant, content: 'Reading', tool_calls: calls),
     Legion::Extensions::Llm::Canonical::Message.build(role: :tool, tool_call_id: 'call_a', content: 'first result'),
     Legion::Extensions::Llm::Canonical::Message.build(role: :tool, tool_call_id: 'call_b', content: 'second result'),
     *text_messages(4)]
  end

  def tools
    %w[a b].to_h do |name|
      ["read_#{name}", Legion::Extensions::Llm::Canonical::ToolDefinition.build(name: "read_#{name}", description: "Read #{name}",
                                                                                parameters: { type: 'object', properties: { path: { type: 'string' } } })]
    end
  end

  def capture_request(messages:, streaming:, caching: true, excluded_tail: 4, tools: self.tools)
    callable = Legion::Extensions::Llm::Anthropic::Helpers::Callable.new(
      instance_cfg: { anthropic_api_key: 'test-key', anthropic_api_base: 'https://anthropic.example', llm_cache_enabled: caching,
                      cache_control_prefix_tokens: excluded_tail }, logger: Logger.new(StringIO.new)
    )
    captured = nil
    stubs = Faraday::Adapter::Test::Stubs.new do |stub|
      stub.post('https://anthropic.example/v1/messages') do |env|
        captured = Legion::JSON.load(env.body)
        expect(env.request_headers['x-api-key']).to eq('test-key')
        streaming ? stream_response(env: env) : sync_response
      end
    end
    callable.provider.connection.connection.builder.adapter(:test, stubs)
    chunks = []
    response = if streaming
                 callable.stream_chat(messages, model: 'claude-sonnet-4-6', tools: tools) { |chunk| chunks << chunk }
               else
                 callable.chat(messages, model: 'claude-sonnet-4-6', tools: tools)
               end
    expect(response).to be_a(Legion::Extensions::Llm::Canonical::Response)
    expect(response.text).to eq('ok')
    expect(chunks.last.type).to eq(:done) if streaming
    stubs.verify_stubbed_calls
    captured
  end

  def sync_response
    body = { id: 'msg_test', type: 'message', role: 'assistant', model: 'claude-sonnet-4-6',
             content: [{ type: 'text', text: 'ok' }], stop_reason: 'end_turn', usage: { input_tokens: 10, output_tokens: 1 } }
    [200, { 'content-type' => 'application/json' }, Legion::JSON.dump(body)]
  end

  def stream_response(env:)
    env.status = 200
    env.response_headers = { 'content-type' => 'text/event-stream' }
    frames = [
      { type: 'content_block_delta', index: 0, delta: { type: 'text_delta', text: 'ok' } },
      { type: 'message_delta', delta: { stop_reason: 'end_turn' }, usage: { output_tokens: 1 } }
    ]
    frames.each do |frame|
      data = "data: #{Legion::JSON.dump(frame)}\n\n"
      env.request.on_data.call(data, data.bytesize, env)
    end
    [200, env.response_headers, '']
  end

  def marked_blocks(value)
    case value
    when Hash then (value.key?(:cache_control) ? [value] : []) + value.except(:cache_control).values.flat_map { |child| marked_blocks(child) }
    when Array then value.flat_map { |child| marked_blocks(child) }
    else []
    end
  end

  def without_cache(value)
    case value
    when Hash then value.except(:cache_control).transform_values { |child| without_cache(child) }
    when Array then value.map { |child| without_cache(child) }
    else value
    end
  end
end
