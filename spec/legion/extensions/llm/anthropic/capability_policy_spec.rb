# frozen_string_literal: true

require 'spec_helper'
require 'legion/extensions/llm/anthropic/provider'

RSpec.describe 'Anthropic CapabilityPolicy integration' do
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

  let(:models_response_body) do
    {
      'data' => [
        { 'id' => 'claude-sonnet-4-20250514', 'display_name' => 'Claude Sonnet 4', 'created_at' => '2025-05-14' }
      ]
    }
  end

  let(:http_response) { double('response', body: models_response_body) }

  before do
    allow(credential_sources).to receive(:setting).with(:extensions, :llm, :anthropic).and_return(nil)
  end

  describe 'default capabilities from provider_envelope' do
    it 'includes streaming and tools but not vision or thinking' do
      models = provider.send(:parse_list_models_response, http_response, :anthropic, nil)
      model = models.first

      expect(model.capabilities).to include(:streaming, :tools, :completion)
      expect(model.capabilities).not_to include(:vision)
      expect(model.capabilities).not_to include(:thinking)
    end
  end

  describe 'provider-root override' do
    before do
      allow(credential_sources).to receive(:setting).with(:extensions, :llm, :anthropic).and_return(
        capabilities: { vision: false, thinking: false },
        tools_flag:   true
      )
    end

    it 'applies provider-level capability overrides' do
      models = provider.send(:parse_list_models_response, http_response, :anthropic, nil)
      model = models.first

      expect(model.capabilities).to include(:streaming, :tools, :completion)
      expect(model.capabilities).not_to include(:vision)
      expect(model.capabilities).not_to include(:thinking)
    end
  end

  describe 'instance override' do
    let(:provider) do
      Legion::Extensions::Llm::Anthropic::Provider.new({
                                                         anthropic_api_key:         'test-key',
                                                         request_timeout:           30,
                                                         max_retries:               0,
                                                         retry_interval:            0,
                                                         retry_backoff_factor:      0,
                                                         retry_interval_randomness: 0,
                                                         capabilities:              { streaming: true, thinking: false }
                                                       })
    end

    it 'applies instance-level capability overrides' do
      models = provider.send(:parse_list_models_response, http_response, :anthropic, nil)
      model = models.first

      expect(model.capabilities).to include(:streaming, :completion)
      expect(model.capabilities).not_to include(:thinking)
    end
  end

  describe 'model override' do
    before do
      allow(credential_sources).to receive(:setting).with(:extensions, :llm, :anthropic).and_return(
        models: {
          'claude-sonnet-4-20250514': { thinking_flag: true }
        }
      )
    end

    it 'enables thinking for a specific model via model config' do
      models = provider.send(:parse_list_models_response, http_response, :anthropic, nil)
      model = models.first

      expect(model.capabilities).to include(:thinking)
    end

    it 'reports :model_override as the source for thinking' do
      resolved = provider.send(:resolve_model_capabilities, 'claude-sonnet-4-20250514')

      thinking_source = resolved[:sources][:thinking]
      expect(thinking_source[:value]).to be true
      expect(thinking_source[:source]).to eq(:model_override)
    end
  end
end
