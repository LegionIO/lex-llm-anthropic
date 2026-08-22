# frozen_string_literal: true

require 'spec_helper'
require 'legion/extensions/llm/anthropic/runners/discovery'

# 0.8.0: capability evidence for discovered Anthropic models is owned by
# Runners::Discovery.build_capability_evidence — sourced from the provider
# catalog response (model_data[:type]) and the model id. The legacy
# CapabilityPolicy cascade (provider-root / instance / model overrides) is no
# longer wired in this gem; the cascade logic itself remains tested at its
# shared owner (lex-llm capability_policy_spec).
RSpec.describe 'Anthropic capability evidence' do
  let(:runner) { Legion::Extensions::Llm::Anthropic::Runners::Discovery }

  describe 'build_capability_evidence default capabilities' do
    it 'advertises :thinking for a reasoning-type catalog entry, sourced from model metadata' do
      evidence = runner.send(
        :build_capability_evidence,
        model_id: 'claude-sonnet-4-6', model_data: { id: 'claude-sonnet-4-6', type: 'reasoning' }
      )

      expect(evidence[:thinking].status).to eq(:supported)
      expect(evidence[:thinking].source).to eq(:model_metadata)
    end

    it 'advertises :thinking for a -thinking model id' do
      evidence = runner.send(
        :build_capability_evidence,
        model_id: 'claude-sonnet-4-6-thinking', model_data: { id: 'claude-sonnet-4-6-thinking' }
      )

      expect(evidence[:thinking].status).to eq(:supported)
    end

    it 'defaults a plain chat model to :unknown / :default_false' do
      evidence = runner.send(
        :build_capability_evidence,
        model_id: 'claude-3-haiku-20240307', model_data: { id: 'claude-3-haiku-20240307' }
      )

      expect(evidence[:thinking].status).to eq(:unknown)
      expect(evidence[:thinking].source).to eq(:default_false)
    end
  end
end
