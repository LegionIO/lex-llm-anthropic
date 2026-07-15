# frozen_string_literal: true

require 'spec_helper'
require 'legion/extensions/llm/anthropic/provider'

# Regression: Claude 4+ models advertise the :thinking capability (extended
# thinking) during discovery, sourced from the shared lex-llm model catalog.
# Without it, legion-llm's router thinking filter cannot route thinking
# requests. Non-thinking Claude models (3.x haiku) must NOT advertise it.
RSpec.describe 'Anthropic thinking capability discovery' do
  let(:credential_sources) { Legion::Extensions::Llm::CredentialSources }
  let(:provider) do
    Legion::Extensions::Llm::Anthropic::Provider.new({
                                                       anthropic_api_key:         'test-key',
                                                       request_timeout:           30,
                                                       max_retries:               0,
                                                       retry_interval:            0,
                                                       retry_backoff_factor:      0,
                                                       retry_interval_randomness: 0
                                                     })
  end

  def response_for(model_id, display_name)
    body = { 'data' => [{ 'id' => model_id, 'display_name' => display_name, 'created_at' => '2025-05-14' }] }
    double('response', body: body)
  end

  before do
    allow(credential_sources).to receive(:setting).with(:extensions, :llm, :anthropic).and_return(nil)
  end

  describe 'a thinking-capable Claude model (extended thinking)' do
    it 'advertises :thinking for claude-sonnet-4 from the shared catalog' do
      response = response_for('claude-sonnet-4-20250514', 'Claude Sonnet 4')
      model = provider.send(:parse_list_models_response, response, :anthropic, nil).first

      expect(model.capabilities).to include(:thinking, :streaming, :tools, :completion)
    end

    it 'reports :provider_catalog as the source for thinking' do
      resolved = provider.send(:resolve_model_capabilities, 'claude-sonnet-4-20250514')

      thinking_source = resolved[:sources][:thinking]
      expect(thinking_source[:value]).to be true
      expect(thinking_source[:source]).to eq(:provider_catalog)
    end
  end

  describe 'a non-thinking Claude model' do
    it 'does NOT advertise :thinking for claude-3-haiku' do
      response = response_for('claude-3-haiku-20240307', 'Claude 3 Haiku')
      model = provider.send(:parse_list_models_response, response, :anthropic, nil).first

      expect(model.capabilities).to include(:completion, :streaming, :tools)
      expect(model.capabilities).not_to include(:thinking)
    end
  end

  describe 'an unknown model absent from the catalog' do
    it 'falls back to the provider envelope without :thinking' do
      response = response_for('claude-does-not-exist-99', 'Nonexistent')
      model = provider.send(:parse_list_models_response, response, :anthropic, nil).first

      expect(model.capabilities).to include(:completion, :streaming, :tools)
      expect(model.capabilities).not_to include(:thinking)
    end
  end
end
