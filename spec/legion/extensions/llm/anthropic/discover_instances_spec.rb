# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Legion::Extensions::Llm::Anthropic do # rubocop:disable RSpec/SpecFilePathFormat
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

      expect(discover[:env]).to eq(api_key: 'sk-ant-env-key', anthropic_api_key: 'sk-ant-env-key', tier: :frontier)
    end

    it 'returns the :claude instance when claude config has anthropicApiKey' do
      allow(credential_sources).to receive(:claude_config_value).with(:anthropicApiKey).and_return('sk-ant-claude-key')

      expect(discover[:claude]).to eq(api_key: 'sk-ant-claude-key', anthropic_api_key: 'sk-ant-claude-key',
                                      tier: :frontier)
    end

    it 'returns the :settings instance when extension settings have api_key' do
      stub_setting(api_key: 'sk-ant-settings-key', anthropic_version: '2023-06-01')

      expect(discover[:settings]).to include(anthropic_api_key: 'sk-ant-settings-key', tier: :frontier)
    end

    it 'preserves extra settings keys in the :settings instance' do
      stub_setting(api_key: 'sk-ant-settings-key', anthropic_version: '2023-06-01')

      expect(discover[:settings][:anthropic_version]).to eq('2023-06-01')
    end

    it 'omits the :settings instance when settings hash has no api_key' do
      stub_setting(anthropic_version: '2023-06-01')

      expect(discover).not_to have_key(:settings)
    end

    it 'returns the :broker instance when Legion::Identity::Broker provides a credential' do
      stub_broker('sk-ant-broker-key')

      expect(discover[:broker]).to eq(api_key: 'sk-ant-broker-key', anthropic_api_key: 'sk-ant-broker-key',
                                      tier: :frontier)
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

  describe '.register_discovered_instances' do
    let(:registry) do
      Module.new do
        def self.register(*args, **kwargs); end

        def self.instances_for(_name)
          {}
        end
      end
    end
    let(:adapter_class) { Class.new { def initialize(*args, **kwargs); end } }

    before do
      stub_const('Legion::LLM::Call::Registry', registry)
      stub_const('Legion::LLM::Call::LexLLMAdapter', adapter_class)
      allow(credential_sources).to receive(:env).with('ANTHROPIC_API_KEY').and_return(nil)
      allow(credential_sources).to receive(:claude_config_value).with(:anthropicApiKey).and_return(nil)
      allow(credential_sources).to receive(:setting).with(:extensions, :llm, :anthropic).and_return(nil)
      hide_const('Legion::Identity::Broker')
    end

    it 'registers discovered instances under :claude alias' do
      stub_env_with_adapter

      expect(registry).to have_received(:register).with(:anthropic, an_instance_of(adapter_class), instance: :env)
      expect(registry).to have_received(:register).with(:claude, anything, instance: :env)
    end

    it 'registers all anthropic instances under :claude' do
      stub_multi_instance_adapters

      expect(registry).to have_received(:register).with(:claude, anything, instance: :env)
      expect(registry).to have_received(:register).with(:claude, anything, instance: :claude)
    end

    it 'is a no-op when Call::Registry is not defined' do
      hide_const('Legion::LLM::Call::Registry')
      hide_const('Legion::LLM::Call::LexLLMAdapter')

      expect { described_class.register_discovered_instances }.not_to raise_error
    end

    def stub_registry_methods(adapter_instances)
      allow(registry).to receive(:register)
      allow(registry).to receive(:instances_for).with(:anthropic).and_return(adapter_instances)
    end

    def stub_env_with_adapter
      allow(credential_sources).to receive(:env).with('ANTHROPIC_API_KEY').and_return('sk-test-key')
      stub_registry_methods(env: adapter_class.new)
      described_class.register_discovered_instances
    end

    def stub_credential_sources_for_multi
      allow(credential_sources).to receive(:env).with('ANTHROPIC_API_KEY').and_return('sk-key-1')
      allow(credential_sources).to receive(:claude_config_value).with(:anthropicApiKey).and_return('sk-key-2')
    end

    def stub_multi_instance_adapters
      stub_credential_sources_for_multi
      stub_registry_methods(env: adapter_class.new, claude: adapter_class.new)
      described_class.register_discovered_instances
    end
  end
end
