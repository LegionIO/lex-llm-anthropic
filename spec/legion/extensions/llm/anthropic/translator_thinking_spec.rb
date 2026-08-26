# frozen_string_literal: true

require 'spec_helper'
require 'legion/extensions/llm/anthropic/translator'

RSpec.describe Legion::Extensions::Llm::Anthropic::Translator do
  let(:canonical) { Legion::Extensions::Llm::Canonical }
  let(:translator) { described_class.new(default_max_tokens: 4096) }

  describe '#render_request thinking reconciliation' do
    context 'effort-only Config (budget derived via resolved_budget)' do
      it 'derives budget from effort=high via resolved_budget' do
        thinking_config = canonical::Thinking::Config.build(enabled: true, effort: 'high')
        req = canonical::Request.build(
          messages: [canonical::Message.build(role: :user, content: 'hello')],
          thinking: thinking_config
        )

        wire = translator.render_request(req)
        expect(wire[:thinking]).to eq({ type: 'enabled', budget_tokens: 16_384 })
      end

      it 'derives budget from effort=low via resolved_budget' do
        thinking_config = canonical::Thinking::Config.build(enabled: true, effort: 'low')
        req = canonical::Request.build(
          messages: [canonical::Message.build(role: :user, content: 'hello')],
          thinking: thinking_config
        )

        wire = translator.render_request(req)
        expect(wire[:thinking]).to eq({ type: 'enabled', budget_tokens: 1024 })
      end

      it 'derives budget from effort=medium via resolved_budget' do
        thinking_config = canonical::Thinking::Config.build(enabled: true, effort: 'medium')
        req = canonical::Request.build(
          messages: [canonical::Message.build(role: :user, content: 'hello')],
          thinking: thinking_config
        )

        wire = translator.render_request(req)
        expect(wire[:thinking]).to eq({ type: 'enabled', budget_tokens: 8192 })
      end

      it 'derives budget from effort=max via resolved_budget' do
        thinking_config = canonical::Thinking::Config.build(enabled: true, effort: 'max')
        req = canonical::Request.build(
          messages: [canonical::Message.build(role: :user, content: 'hello')],
          thinking: thinking_config
        )

        wire = translator.render_request(req)
        expect(wire[:thinking]).to eq({ type: 'enabled', budget_tokens: 32_768 })
      end
    end

    context 'explicit budget Config (budget used directly)' do
      it 'uses the explicit budget when set' do
        thinking_config = canonical::Thinking::Config.build(enabled: true, budget: 4096)
        req = canonical::Request.build(
          messages: [canonical::Message.build(role: :user, content: 'hello')],
          thinking: thinking_config
        )

        wire = translator.render_request(req)
        expect(wire[:thinking]).to eq({ type: 'enabled', budget_tokens: 4096 })
      end
    end

    context 'budget >= max_tokens clamping' do
      it 'clamps budget to < max_tokens when budget equals max_tokens' do
        thinking_config = canonical::Thinking::Config.build(enabled: true, budget: 8192)
        req = canonical::Request.build(
          messages: [canonical::Message.build(role: :user, content: 'hello')],
          params:   canonical::Params.build(max_tokens: 8192),
          thinking: thinking_config
        )

        wire = translator.render_request(req)
        # budget clamped to max_tokens - OUTPUT_RESERVE = 8192 - 1024 = 7168
        expect(wire[:thinking][:budget_tokens]).to eq(7168)
        expect(wire[:thinking][:budget_tokens]).to be < wire[:max_tokens]
      end

      it 'clamps budget to < max_tokens when budget exceeds max_tokens' do
        thinking_config = canonical::Thinking::Config.build(enabled: true, budget: 20_000)
        req = canonical::Request.build(
          messages: [canonical::Message.build(role: :user, content: 'hello')],
          params:   canonical::Params.build(max_tokens: 10_000),
          thinking: thinking_config
        )

        wire = translator.render_request(req)
        # budget clamped to max_tokens - OUTPUT_RESERVE = 10000 - 1024 = 8976
        expect(wire[:thinking][:budget_tokens]).to eq(8976)
        expect(wire[:thinking][:budget_tokens]).to be < wire[:max_tokens]
      end

      it 'floors clamped budget at MINIMUM_BUDGET_TOKENS (1024)' do
        thinking_config = canonical::Thinking::Config.build(enabled: true, budget: 3000)
        req = canonical::Request.build(
          messages: [canonical::Message.build(role: :user, content: 'hello')],
          params:   canonical::Params.build(max_tokens: 3000),
          thinking: thinking_config
        )

        wire = translator.render_request(req)
        # max_tokens - OUTPUT_RESERVE = 3000 - 1024 = 1976, but budget (3000) >= max_tokens (3000)
        # so clamp to min(3000, 1976) = 1976, floor at max(1976, 1024) = 1976
        expect(wire[:thinking][:budget_tokens]).to eq(1976)
        expect(wire[:thinking][:budget_tokens]).to be >= 1024
      end

      it 'floors at 1024 when max_tokens is very small' do
        thinking_config = canonical::Thinking::Config.build(enabled: true, budget: 1500)
        req = canonical::Request.build(
          messages: [canonical::Message.build(role: :user, content: 'hello')],
          params:   canonical::Params.build(max_tokens: 1500),
          thinking: thinking_config
        )

        wire = translator.render_request(req)
        # budget (1500) >= max_tokens (1500), clamp to min(1500, 476) = 476, floor at max(476, 1024) = 1024
        expect(wire[:thinking][:budget_tokens]).to eq(1024)
      end

      it 'does not clamp when budget is safely below max_tokens' do
        thinking_config = canonical::Thinking::Config.build(enabled: true, budget: 4096)
        req = canonical::Request.build(
          messages: [canonical::Message.build(role: :user, content: 'hello')],
          params:   canonical::Params.build(max_tokens: 16_384),
          thinking: thinking_config
        )

        wire = translator.render_request(req)
        expect(wire[:thinking][:budget_tokens]).to eq(4096)
      end
    end

    context 'disabled/absent thinking' do
      it 'does not render thinking wire when thinking is nil' do
        req = canonical::Request.build(
          messages: [canonical::Message.build(role: :user, content: 'hello')]
        )

        wire = translator.render_request(req)
        expect(wire).not_to have_key(:thinking)
      end

      it 'does not render thinking wire when thinking is disabled' do
        thinking_config = canonical::Thinking::Config.build(enabled: false)
        req = canonical::Request.build(
          messages: [canonical::Message.build(role: :user, content: 'hello')],
          thinking: thinking_config
        )

        wire = translator.render_request(req)
        expect(wire).not_to have_key(:thinking)
      end
    end

    context 'contract: no max_thinking_tokens or default_thinking_budget referenced' do
      let(:translator_source) do
        gem_root = File.expand_path('../../../../..', __dir__)
        File.read(File.join(gem_root, 'lib/legion/extensions/llm/anthropic/translator.rb'))
      end

      it 'does not reference max_thinking_tokens on params' do
        expect(translator_source).not_to include('max_thinking_tokens')
      end

      it 'does not reference default_thinking_budget' do
        expect(translator_source).not_to include('default_thinking_budget')
      end
    end
  end
end
