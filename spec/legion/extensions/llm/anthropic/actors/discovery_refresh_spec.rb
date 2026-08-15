# frozen_string_literal: true

require 'spec_helper'
require 'faraday'
require 'json'

RSpec.describe Legion::Extensions::Llm::Anthropic::Actor::DiscoveryRefresh do
  let(:registry) { Legion::Extensions::Llm::Inventory::Registry }
  let(:settings_root) { Legion::Settings[:extensions] }

  before do
    registry.reset!
    stub_probe_http(ready: true)
  end

  after do
    settings_root[:llm]&.delete(:anthropic)
  end

  # ── helpers ─────────────────────────────────────────────────────────────

  def seed_anthropic_settings(config)
    settings_root[:llm] ||= {}
    settings_root[:llm][:anthropic] = config
  end

  def seed_instance(name, api_key:, endpoint: 'https://api.anthropic.com', **extra)
    seed_anthropic_settings({
                              instances: {
                                name => {
                                  enabled:  true,
                                  endpoint: endpoint,
                                  api_key:  api_key,
                                  tier:     :frontier
                                }.merge(extra)
                              }
                            })
  end

  def instance_key_for(api_key:, endpoint: 'https://api.anthropic.com')
    host = URI.parse(endpoint).host
    port = URI.parse(endpoint).port
    fingerprint = Digest::SHA256.hexdigest(api_key)[0, 8]
    Legion::Extensions::Llm::Inventory::Identity::InstanceKey.new(
      provider_family: :anthropic, instance_id: "#{host}:#{port}/ak:#{fingerprint}"
    )
  end

  # The actor probes with its own raw Faraday connection (build_api_connection);
  # GET /v1/models is the safe readiness + model-list endpoint.
  def stub_probe_http(ready: true)
    allow(Faraday).to receive(:new) do |*_args, &_block|
      connection = instance_double(Faraday::Connection)
      allow(connection).to receive(:get) do |path|
        if path == '/v1/models' && ready
          probe_response(200, ::JSON.dump(data: [{ id: 'claude-sonnet-4-6' }, { id: 'claude-haiku-4-5' }]))
        else
          probe_response(503, ::JSON.dump(type: 'error', error: { type: 'api_error', message: 'unavailable' }))
        end
      end
      connection
    end
  end

  def probe_response(status, body)
    env = Faraday::Env.new
    env.status = status
    env.response = { headers: {} }
    env.body = body
    Faraday::Response.new(env)
  end

  def health_for(name)
    settings_root.dig(:llm, :anthropic, :instances, name, :health)
  end

  # ── time (D9) ───────────────────────────────────────────────────────────

  describe '#time' do
    it 'resolves the live nested instance default (never the top-level key)' do
      seed_anthropic_settings({ discovery_interval: 99, instances: { default: { discovery_interval: 7200 } } })
      expect(described_class.new.time).to eq(7200)
    end

    it 'falls back to the registered default when the live value is absent' do
      seed_anthropic_settings({})
      expect(described_class.new.time).to eq(3600)
    end
  end

  # ── initial discovery ───────────────────────────────────────────────────

  describe 'initial discovery' do
    it 'claims and activates a configured instance, and writes the settings display' do
      seed_instance(:default, api_key: 'sk-ant-lifecycle-one')
      actor = described_class.new
      actor.manual

      key = instance_key_for(api_key: 'sk-ant-lifecycle-one')
      snapshot = registry.snapshot

      expect(snapshot.publication_status(instance_key: key).state).to eq(:complete)
      expect(snapshot.instance(instance_key: key).availability.state).to eq(:available)
      expect(snapshot.offerings_for(instance_key: key).map(&:model)).to contain_exactly('claude-sonnet-4-6', 'claude-haiku-4-5')

      health = health_for(:default)
      expect(health[:circuit_state]).to eq(:closed)
      expect(health[:denied]).to eq(false)
      expect(health[:available]).to eq(true)
      expect(health[:adjustment]).to eq(0)
      expect(health[:last_probe_outcome]).to eq(:success)
      expect(health[:source]).to eq(:ssot_v3)
      expect(health[:observed_at]).to be_a(String)
      expect(settings_root.dig(:llm, :anthropic, :instances, :default, :capabilities))
        .to eq(%i[completion streaming vision tools])
    end

    it 'stays initializing after an initial readiness failure and records unhealthy display' do
      seed_instance(:default, api_key: 'sk-ant-lifecycle-two')
      stub_probe_http(ready: false)

      actor = described_class.new
      actor.manual

      key = instance_key_for(api_key: 'sk-ant-lifecycle-two')
      expect(registry.snapshot.publication_status(instance_key: key).state).to eq(:initializing)
      expect(registry.snapshot.instance(instance_key: key)).to be_nil

      health = health_for(:default)
      expect(health[:circuit_state]).to eq(:open)
      expect(health[:available]).to eq(false)
      expect(health[:adjustment]).to eq(-50)
      expect(health[:last_probe_outcome]).to eq(:failure)
    end
  end

  # ── phantom exclusion (D3) ──────────────────────────────────────────────

  describe 'phantom exclusion' do
    it 'skips credential-less and disabled instances, and only claims real ones' do
      env_name = 'ANTHROPIC_LIFECYCLE_UNSET'
      saved = ENV.delete(env_name)

      begin
        seed_anthropic_settings({
                                  instances: {
                                    default:  {
                                      enabled:     true,
                                      endpoint:    'https://api.anthropic.com',
                                      credentials: { api_key: "env://#{env_name}" }
                                    },
                                    disabled: {
                                      enabled:  false,
                                      endpoint: 'https://disabled.internal:8443',
                                      api_key:  'sk-ant-disabled'
                                    },
                                    proxy:    {
                                      enabled:  true,
                                      endpoint: 'https://proxy.internal:8443',
                                      api_key:  'sk-ant-proxy-real'
                                    }
                                  }
                                })

        actor = described_class.new
        actor.manual

        statuses = registry.snapshot.each_publication_status.to_a
        expect(statuses.size).to eq(1)

        proxy_key = instance_key_for(api_key: 'sk-ant-proxy-real', endpoint: 'https://proxy.internal:8443')
        expect(statuses.first.instance_key).to eq(proxy_key)
        expect(statuses.first.state).to eq(:complete)

        # Skipped instances are never claimed and get no health display.
        expect(health_for(:default)).to be_nil
        expect(health_for(:disabled)).to be_nil
      ensure
        ENV[env_name] = saved if saved
      end
    end
  end

  # ── recovery after initial failure (D4) ─────────────────────────────────

  describe 'recovery after initial readiness failure' do
    it 're-activates an :initializing instance on a later passing probe' do
      seed_instance(:default, api_key: 'sk-ant-lifecycle-recover')
      stub_probe_http(ready: false)

      actor = described_class.new
      actor.manual # initial probe fails → :initializing
      key = instance_key_for(api_key: 'sk-ant-lifecycle-recover')
      expect(registry.snapshot.publication_status(instance_key: key).state).to eq(:initializing)

      stub_probe_http(ready: true)
      actor.manual # tick → retry_initial_activation → activate
      expect(registry.snapshot.publication_status(instance_key: key).state).to eq(:complete)
      expect(registry.snapshot.instance(instance_key: key).availability.state).to eq(:available)
      expect(health_for(:default)[:available]).to eq(true)
      expect(health_for(:default)[:last_probe_outcome]).to eq(:success)
    end
  end

  # ── tick reconciliation (P2-7) ──────────────────────────────────────────

  describe 'tick reconciliation' do
    it 'claims instances added after boot and retires instances removed from config' do
      seed_instance(:alpha, api_key: 'sk-ant-alpha', endpoint: 'https://alpha.internal:8443')
      actor = described_class.new
      actor.manual

      alpha_key = instance_key_for(api_key: 'sk-ant-alpha', endpoint: 'https://alpha.internal:8443')
      expect(registry.snapshot.publication_status(instance_key: alpha_key).state).to eq(:complete)

      seed_instance(:beta, api_key: 'sk-ant-beta', endpoint: 'https://beta.internal:8443')
      actor.manual # tick → reconcile: alpha gone, beta new

      beta_key = instance_key_for(api_key: 'sk-ant-beta', endpoint: 'https://beta.internal:8443')
      expect(registry.snapshot.publication_status(instance_key: beta_key).state).to eq(:complete)
      expect(registry.snapshot.instance(instance_key: alpha_key)).to be_nil
      expect(registry.snapshot.publication_status(instance_key: alpha_key)).to be_nil
      expect(health_for(:beta)[:available]).to eq(true)
    end
  end

  # ── cadence probe on an available instance ──────────────────────────────

  describe 'cadence probe' do
    it 'marks an available instance unavailable after a failing cadence probe' do
      seed_instance(:default, api_key: 'sk-ant-lifecycle-cadence')
      actor = described_class.new
      actor.manual # initial probe ready → available
      key = instance_key_for(api_key: 'sk-ant-lifecycle-cadence')
      expect(registry.snapshot.instance(instance_key: key).availability.state).to eq(:available)

      stub_probe_http(ready: false)
      actor.manual # tick → cadence probe fails → unavailable

      expect(registry.snapshot.instance(instance_key: key).availability.state).to eq(:unavailable)
      expect(health_for(:default)[:available]).to eq(false)
      expect(health_for(:default)[:last_probe_outcome]).to eq(:failure)
    end
  end

  # ── shutdown ────────────────────────────────────────────────────────────

  describe '#shutdown' do
    it 'removes all instances from the registry and clears the display' do
      seed_instance(:default, api_key: 'sk-ant-lifecycle-shutdown')
      actor = described_class.new
      actor.manual

      actor.shutdown

      expect(registry.snapshot.each_publication_status.to_a).to be_empty
      expect(health_for(:default)).to be_nil
    end
  end
end
