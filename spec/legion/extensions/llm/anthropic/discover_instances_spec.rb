# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Legion::Extensions::Llm::Anthropic do
  let(:credential_sources) { Legion::Extensions::Llm::CredentialSources }

  describe '.discover_instances' do
    subject(:discover) { described_class.discover_instances }

    before do
      allow(credential_sources).to receive(:env).with('ANTHROPIC_API_KEY').and_return(nil)
      allow(credential_sources).to receive(:claude_config_value).with(:anthropicApiKey).and_return(nil)
      allow(credential_sources).to receive(:setting).with(:extensions, :llm, :anthropic).and_return(nil)
      hide_const('Legion::Identity::Broker')
    end

    it 'returns the :env instance when ANTHROPIC_API_KEY is set' do
      allow(credential_sources).to receive(:env).with('ANTHROPIC_API_KEY').and_return('sk-ant-env-key')

      expect(discover[:env]).to include(anthropic_api_key: 'sk-ant-env-key', tier: :frontier)
    end

    it 'returns the :claude instance when claude config has anthropicApiKey' do
      allow(credential_sources).to receive(:claude_config_value).with(:anthropicApiKey).and_return('sk-ant-claude-key')

      expect(discover[:claude]).to include(anthropic_api_key: 'sk-ant-claude-key', tier: :frontier)
    end

    it 'returns the :settings instance when extension settings have api_key' do
      stub_setting(api_key: 'sk-ant-settings-key', anthropic_version: '2023-06-01')

      expect(discover[:settings]).to include(anthropic_api_key: 'sk-ant-settings-key', tier: :frontier)
    end

    it 'preserves extra settings keys in the :settings instance' do
      stub_setting(api_key: 'sk-ant-settings-key', anthropic_version: '2023-06-01')

      expect(discover[:settings][:anthropic_version]).to eq('2023-06-01')
    end

    it 'normalizes generic settings keys to provider config keys' do
      stub_setting(api_key: 'sk-ant-settings-key', base_url: 'https://proxy.example', version: '2024-01-01')

      expect(discover[:settings]).to include(
        anthropic_api_key:  'sk-ant-settings-key',
        anthropic_api_base: 'https://proxy.example',
        anthropic_version:  '2024-01-01'
      )
      expect(discover[:settings]).not_to have_key(:base_url)
      expect(discover[:settings]).not_to have_key(:api_key)
    end

    it 'discovers named instances from extension settings' do
      stub_setting(instances: { west: { api_key: 'sk-ant-west', endpoint: 'https://west.example' } })

      expect(discover[:west]).to include(
        anthropic_api_key:  'sk-ant-west',
        anthropic_api_base: 'https://west.example',
        tier:               :frontier
      )
    end

    it 'omits the :settings instance when settings hash has no api_key' do
      stub_setting(anthropic_version: '2023-06-01')

      expect(discover).not_to have_key(:settings)
    end

    it 'returns the :broker instance when Legion::Identity::Broker provides a credential' do
      stub_broker('sk-ant-broker-key')

      expect(discover[:broker]).to include(anthropic_api_key: 'sk-ant-broker-key', tier: :frontier)
    end

    it 'omits the :broker instance when Broker returns nil' do
      stub_broker(nil)

      expect(discover).not_to have_key(:broker)
    end

    it 'returns multiple instances when all sources are available' do
      stub_all_sources

      expect(discover.keys).to include(:env, :claude, :settings)
    end

    it 'deduplicates when the same key appears from multiple sources' do
      stub_env_and_claude('sk-ant-shared-key', 'sk-ant-shared-key')

      expect(discover).to have_key(:env)
      expect(discover).not_to have_key(:claude)
    end

    it 'keeps both instances when keys differ' do
      stub_env_and_claude('sk-key-one', 'sk-key-two')

      expect(discover.keys).to contain_exactly(:env, :claude)
    end

    it 'returns an empty hash when no sources are available' do
      expect(discover).to eq({})
    end

    def stub_setting(hash)
      allow(credential_sources).to receive(:setting).with(:extensions, :llm, :anthropic).and_return(hash)
    end

    def stub_broker(value)
      broker = Module.new { define_singleton_method(:credential_for) { |_service| value } }
      stub_const('Legion::Identity::Broker', broker)
    end

    def stub_all_sources
      allow(credential_sources).to receive(:env).with('ANTHROPIC_API_KEY').and_return('sk-env')
      allow(credential_sources).to receive(:claude_config_value).with(:anthropicApiKey).and_return('sk-claude')
      stub_setting(api_key: 'sk-settings')
    end

    def stub_env_and_claude(env_key, claude_key)
      allow(credential_sources).to receive(:env).with('ANTHROPIC_API_KEY').and_return(env_key)
      allow(credential_sources).to receive(:claude_config_value).with(:anthropicApiKey).and_return(claude_key)
    end
  end

  describe '.provider_aliases' do
    it 'returns no aliases' do
      expect(described_class.provider_aliases).to eq([])
    end
  end

  describe '.resolve_default_model (policy-aware default)' do
    before { allow(credential_sources).to receive(:setting).with(:extensions, :llm, :anthropic).and_return(nil) }

    it 'keeps a configured default when no policy is set' do
      expect(described_class.resolve_default_model(default_model: 'claude-opus-4-8')).to eq('claude-opus-4-8')
    end

    it 'falls back to DEFAULT_MODEL when none is configured and no policy is set' do
      expect(described_class.resolve_default_model({})).to eq(described_class::DEFAULT_MODEL)
    end

    it 'keeps a configured default that the whitelist permits' do
      expect(described_class.resolve_default_model(default_model:   'claude-haiku-4-5-20251001',
                                                   model_whitelist: %w[haiku])).to eq('claude-haiku-4-5-20251001')
    end

    it 'drops a configured default the whitelist forbids rather than forcing it' do
      # The hardcoded DEFAULT_MODEL (sonnet) is also forbidden here, so the result is
      # nil — routing then resolves an allowed discovered model, not a forbidden default.
      expect(described_class.resolve_default_model(default_model:   'claude-sonnet-4-6',
                                                   model_whitelist: %w[haiku])).to be_nil
    end

    it 'does not fall back to a blacklisted DEFAULT_MODEL' do
      expect(described_class.resolve_default_model(model_blacklist: %w[sonnet])).to be_nil
    end

    it 'reads the provider-level whitelist when the instance config has none' do
      allow(credential_sources).to receive(:setting).with(:extensions, :llm, :anthropic)
                                                    .and_return({ model_whitelist: %w[haiku] })
      expect(described_class.resolve_default_model(default_model: 'claude-sonnet-4-6')).to be_nil
    end
  end
end
