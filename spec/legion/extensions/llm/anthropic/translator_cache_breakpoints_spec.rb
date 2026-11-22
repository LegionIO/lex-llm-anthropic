# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Legion::Extensions::Llm::Anthropic::Translator do
  [1, 4, 5].each do |count|
    it "preserves #{count} explicit controls without adding an automatic system marker" do
      control = { type: 'ephemeral', ttl: '1h' }
      request = Legion::Extensions::Llm::Canonical::Request.build(
        system:   'S' * 1025,
        messages: [Legion::Extensions::Llm::Canonical::Message.build(role: :user, content: Array.new(count) do |index|
          Legion::Extensions::Llm::Canonical::ContentBlock.text("explicit #{index}", cache_control: control)
        end)]
      )
      original = Legion::JSON.dump(request.to_h)

      wire = described_class.new.render_request(request)

      expect(wire[:system]).to eq([{ type: 'text', text: 'S' * 1025 }])
      expect(wire[:messages].first[:content].map { |block| block[:cache_control] }).to eq(Array.new(count, control))
      expect(Legion::JSON.dump(request.to_h)).to eq(original)
    end
  end

  it 'preserves a single canonical system block and its explicit control' do
    control = { type: 'ephemeral', ttl: '1h' }
    block = Legion::Extensions::Llm::Canonical::ContentBlock.text('instructions', cache_control: control)
    request = Legion::Extensions::Llm::Canonical::Request.build(messages: [
                                                                  Legion::Extensions::Llm::Canonical::Message.build(role: :system, content: block),
                                                                  Legion::Extensions::Llm::Canonical::Message.build(role: :user, content: 'hello')
                                                                ])

    wire = described_class.new.render_request(request)

    expect(wire[:system]).to eq([{ type: 'text', text: 'instructions', cache_control: control }])
  end

  it 'retains the registered cache threshold with a partial enable override' do
    request = Legion::Extensions::Llm::Canonical::Request.build(system:   'S' * 1025,
                                                                messages: [Legion::Extensions::Llm::Canonical::Message.build(role: :user, content: 'hello')])
    wire = described_class.new(prompt_caching: { enabled: true }).render_request(request)
    expect(wire[:system].last[:cache_control]).to eq(type: 'ephemeral')
  end

  it 'respects a configured threshold and disabled automatic caching' do
    request = Legion::Extensions::Llm::Canonical::Request.build(system:   'S' * 1025,
                                                                messages: [Legion::Extensions::Llm::Canonical::Message.build(role: :user, content: 'hello')])
    [{ enabled: false }, { enabled: true, min_tokens: 2048 }].each do |config|
      wire = described_class.new(prompt_caching: config).render_request(request)
      expect(wire[:system].last).not_to have_key(:cache_control)
    end
  end

  it 'preserves canonical message and tool metadata hints before automatic placement' do
    control = { type: 'ephemeral', ttl: '1h' }
    tool = Legion::Extensions::Llm::Canonical::ToolDefinition.from_hash({ name: 'read', cache_control: control })
    request = Legion::Extensions::Llm::Canonical::Request.build(
      messages: [
        Legion::Extensions::Llm::Canonical::Message.build(role: :system, content: 'instructions', cache_control: control),
        Legion::Extensions::Llm::Canonical::Message.build(role: :user, content: 'hello', cache_control: control)
      ], tools: { 'read' => tool }
    )
    original = Legion::JSON.dump(request.to_h)

    wire = described_class.new.render_request(request)

    expect(wire[:system]).to eq([{ type: 'text', text: 'instructions', cache_control: control }])
    expect(wire[:messages].first[:content]).to eq([{ type: 'text', text: 'hello', cache_control: control }])
    expect(wire[:tools].first).to include(name: 'read', cache_control: control)
    expect(Legion::JSON.dump(request.to_h)).to eq(original)
  end

  it 'keeps the narrower block control when a message hint also exists' do
    control = { type: 'ephemeral', ttl: '1h' }
    message = Legion::Extensions::Llm::Canonical::Message.build(role: :user, cache_control: { type: 'ephemeral' },
                                                                content: [Legion::Extensions::Llm::Canonical::ContentBlock.text('block', cache_control: control)])
    wire = described_class.new.render_request(Legion::Extensions::Llm::Canonical::Request.build(system: 'S' * 1025, messages: [message]))
    expect(wire[:system]).to eq([{ type: 'text', text: 'S' * 1025 }])
    expect(wire[:messages].first[:content]).to eq([{ type: 'text', text: 'block', cache_control: control }])
  end
end
