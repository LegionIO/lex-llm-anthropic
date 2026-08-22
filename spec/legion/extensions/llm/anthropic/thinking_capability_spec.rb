# frozen_string_literal: true

require 'spec_helper'
require 'legion/extensions/llm/anthropic/runners/discovery'

# Regression: Claude models that support extended thinking advertise the
# :thinking capability during discovery, sourced from the provider catalog
# response (model_data[:type] == 'reasoning') or the model id — without it,
# legion-llm's router thinking filter cannot route thinking requests.
# Non-thinking Claude models must NOT advertise it.
#
# 0.8.0 semantic shift: a model no longer inherits :thinking from a shared
# model catalog — it is :unknown unless the provider catalog response or the
# model id evidences it.
RSpec.describe 'Anthropic thinking capability discovery' do
  let(:runner) { Legion::Extensions::Llm::Anthropic::Runners::Discovery }

  # A real /v1/models catalog entry as the discovery pipeline receives it.
  def catalog_entry(model_id, type: nil)
    data = { id: model_id, display_name: model_id }
    data[:type] = type if type
    data
  end

  describe 'a thinking-capable Claude model (extended thinking)' do
    it 'advertises :thinking for a reasoning-type catalog entry' do
      evidence = runner.send(
        :build_capability_evidence,
        model_id: 'claude-sonnet-4-20250514', model_data: catalog_entry('claude-sonnet-4-20250514', type: 'reasoning')
      )

      expect(evidence[:thinking].status).to eq(:supported)
      expect(evidence.values_at(:streaming, :tools, :completion).map(&:status)).to all(eq(:supported))
    end

    it 'reports :model_metadata as the source for thinking' do
      evidence = runner.send(
        :build_capability_evidence,
        model_id: 'claude-sonnet-4-20250514', model_data: catalog_entry('claude-sonnet-4-20250514', type: 'reasoning')
      )

      expect(evidence[:thinking].source).to eq(:model_metadata)
    end
  end

  describe 'a non-thinking Claude model' do
    it 'does NOT advertise :thinking for claude-3-haiku' do
      evidence = runner.send(
        :build_capability_evidence,
        model_id: 'claude-3-haiku-20240307', model_data: catalog_entry('claude-3-haiku-20240307')
      )

      expect(evidence.values_at(:completion, :streaming, :tools).map(&:status)).to all(eq(:supported))
      expect(evidence[:thinking].status).not_to eq(:supported)
    end
  end

  describe 'an unknown model absent from the catalog' do
    it 'defaults :thinking to :unknown / :default_false' do
      evidence = runner.send(
        :build_capability_evidence,
        model_id: 'claude-does-not-exist-99', model_data: catalog_entry('claude-does-not-exist-99')
      )

      expect(evidence[:thinking].status).to eq(:unknown)
      expect(evidence[:thinking].source).to eq(:default_false)
    end
  end
end
