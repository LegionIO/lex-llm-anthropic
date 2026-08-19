# frozen_string_literal: true

require 'spec_helper'
require 'faraday'
require 'json'
require 'legion/extensions/llm/inventory/weight_reconciler'

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

  # The actor publishes the operator's config NAME as the instance identity;
  # the derived host:port/ak:<digest> rides along as the secondary physical_id.
  def instance_key_for(name:, api_key:, endpoint: 'https://api.anthropic.com')
    host = URI.parse(endpoint).host
    port = URI.parse(endpoint).port
    fingerprint = Digest::SHA256.hexdigest(api_key)[0, 8]
    Legion::Extensions::Llm::Inventory::Identity::InstanceKey.new(
      provider_family: :anthropic,
      instance_id:     name.to_s,
      physical_id:     "#{host}:#{port}/ak:#{fingerprint}"
    )
  end

  # The actor probes with its own raw Faraday connection (build_api_connection);
  # GET /v1/models is the safe readiness + model-list endpoint.
  def stub_probe_http(ready: true, models: [{ id: 'claude-sonnet-4-6' }, { id: 'claude-haiku-4-5' }], calls: nil)
    allow(Faraday).to receive(:new) do |*_args, &_block|
      connection = instance_double(Faraday::Connection)
      allow(connection).to receive(:get) do |path|
        calls << path if calls
        if path == '/v1/models' && ready
          probe_response(200, ::JSON.dump(data: models))
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

  def write_tier_weight(value)
    root_settings = Legion::Settings.loader.settings
    root_settings[:llm] ||= {}
    root_settings[:llm][:routing] ||= {}
    root_settings[:llm][:routing][:tier_weights] ||= {}
    root_settings[:llm][:routing][:tier_weights][:frontier] = value
  end

  def tracked_state(actor, instance_id = 'primary')
    actor.send(:with_instance_states) { |states| states.fetch(instance_id) }
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
      seed_instance(:primary, api_key: 'sk-ant-lifecycle-one')
      actor = described_class.new
      actor.manual

      key = instance_key_for(name: :primary, api_key: 'sk-ant-lifecycle-one')
      snapshot = registry.snapshot

      expect(snapshot.publication_status(instance_key: key).state).to eq(:complete)
      expect(snapshot.instance(instance_key: key).availability.state).to eq(:available)
      expect(snapshot.offerings_for(instance_key: key).map(&:model)).to contain_exactly('claude-sonnet-4-6', 'claude-haiku-4-5')

      # Identity is the config name; the derived host:port/ak rides as the
      # secondary physical_id on the committed key.
      committed = snapshot.publication_status(instance_key: key)
      expect(committed.instance_key.instance_id).to eq('primary')
      expect(committed.instance_key.physical_id)
        .to eq("api.anthropic.com:443/ak:#{Digest::SHA256.hexdigest('sk-ant-lifecycle-one')[0, 8]}")

      health = health_for(:primary)
      expect(health[:circuit_state]).to eq(:closed)
      expect(health[:denied]).to eq(false)
      expect(health[:available]).to eq(true)
      expect(health[:adjustment]).to eq(0)
      expect(health[:last_probe_outcome]).to eq(:success)
      expect(health[:source]).to eq(:ssot_v3)
      expect(health[:observed_at]).to be_a(String)
      expect(settings_root.dig(:llm, :anthropic, :instances, :primary, :capabilities))
        .to eq(%i[completion streaming vision tools])
    end

    it 'stays initializing after an initial readiness failure and records unhealthy display' do
      seed_instance(:primary, api_key: 'sk-ant-lifecycle-two')
      stub_probe_http(ready: false)

      actor = described_class.new
      actor.manual

      key = instance_key_for(name: :primary, api_key: 'sk-ant-lifecycle-two')
      expect(registry.snapshot.publication_status(instance_key: key).state).to eq(:initializing)
      expect(registry.snapshot.instance(instance_key: key)).to be_nil

      health = health_for(:primary)
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

        proxy_key = instance_key_for(name: :proxy, api_key: 'sk-ant-proxy-real', endpoint: 'https://proxy.internal:8443')
        expect(statuses.first.instance_key).to eq(proxy_key)
        expect(statuses.first.state).to eq(:complete)

        # Skipped instances are never claimed and get no health display. The
        # credential-less :default is skipped for its unresolvable env://
        # credential (it is a modified entry, not the unmodified synthetic
        # template, so the synthetic-default skip does not apply to it).
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
      seed_instance(:primary, api_key: 'sk-ant-lifecycle-recover')
      stub_probe_http(ready: false)

      actor = described_class.new
      actor.manual # initial probe fails → :initializing
      key = instance_key_for(name: :primary, api_key: 'sk-ant-lifecycle-recover')
      expect(registry.snapshot.publication_status(instance_key: key).state).to eq(:initializing)

      stub_probe_http(ready: true)
      actor.manual # tick → retry_initial_activation → activate
      expect(registry.snapshot.publication_status(instance_key: key).state).to eq(:complete)
      expect(registry.snapshot.instance(instance_key: key).availability.state).to eq(:available)
      expect(health_for(:primary)[:available]).to eq(true)
      expect(health_for(:primary)[:last_probe_outcome]).to eq(:success)
    end
  end

  # ── tick reconciliation (P2-7) ──────────────────────────────────────────

  describe 'tick reconciliation' do
    it 'claims instances added after boot and retires instances removed from config' do
      seed_instance(:alpha, api_key: 'sk-ant-alpha', endpoint: 'https://alpha.internal:8443')
      actor = described_class.new
      actor.manual

      alpha_key = instance_key_for(name: :alpha, api_key: 'sk-ant-alpha', endpoint: 'https://alpha.internal:8443')
      expect(registry.snapshot.publication_status(instance_key: alpha_key).state).to eq(:complete)

      seed_instance(:beta, api_key: 'sk-ant-beta', endpoint: 'https://beta.internal:8443')
      actor.manual # tick → reconcile: alpha gone, beta new

      beta_key = instance_key_for(name: :beta, api_key: 'sk-ant-beta', endpoint: 'https://beta.internal:8443')
      expect(registry.snapshot.publication_status(instance_key: beta_key).state).to eq(:complete)
      expect(registry.snapshot.instance(instance_key: alpha_key)).to be_nil
      expect(registry.snapshot.publication_status(instance_key: alpha_key)).to be_nil
      expect(health_for(:beta)[:available]).to eq(true)
    end
  end

  # ── write-time lane weights (Task 03W) ──────────────────────────────────

  describe 'write-time lane weights' do
    before do
      tier_weights = Legion::Settings.loader.settings.dig(:llm, :routing, :tier_weights)
      @frontier_weight_was_defined = tier_weights.is_a?(Hash) && tier_weights.key?(:frontier)
      @previous_frontier_weight = tier_weights[:frontier] if @frontier_weight_was_defined
      write_tier_weight(150)
    end

    after do
      tier_weights = Legion::Settings.loader.settings.dig(:llm, :routing, :tier_weights)
      if @frontier_weight_was_defined
        tier_weights[:frontier] = @previous_frontier_weight
      else
        tier_weights.delete(:frontier)
      end
    end

    it 'stores the exact four weight inputs and their product on each draft' do
      seed_anthropic_settings(
        weight:    200,
        models:    { 'claude-sonnet-4-6' => { weight: 125 } },
        instances: {
          primary: {
            enabled: true, endpoint: 'https://api.anthropic.com', api_key: 'sk-ant-weight-draft',
            tier: :frontier, weight: 115
          }
        }
      )
      actor = described_class.new
      instance_key = instance_key_for(name: :primary, api_key: 'sk-ant-weight-draft')
      draft = actor.send(
        :build_offering_draft,
        model_id: 'claude-sonnet-4-6', model_data: { id: 'claude-sonnet-4-6' },
        instance_cfg: settings_root.dig(:llm, :anthropic, :instances, :primary), instance_key: instance_key
      )

      expect(draft.weight_inputs).to eq(tier: 150, provider: 200, instance: 115, model_or_offering: 125)
      expect(draft.weight_inputs).to be_frozen
      expect(draft.base_weight).to eq(431_250_000)
    end

    it 'publishes one replacement on the next ordinary pass when only a weight changes' do
      calls = []
      stub_probe_http(calls: calls)
      seed_instance(:primary, api_key: 'sk-ant-weight-refresh')
      actor = described_class.new
      actor.manual
      key = instance_key_for(name: :primary, api_key: 'sk-ant-weight-refresh')
      before_calls = calls.length

      settings_root[:llm][:anthropic][:weight] = 175
      actor.manual

      status = registry.snapshot.publication_status(instance_key: key)
      offering = registry.snapshot.offerings_for(instance_key: key).find { |item| item.model == 'claude-sonnet-4-6' }
      expect(status.published_sequence).to eq(1)
      expect(offering.weight_inputs[:provider]).to eq(175)
      expect(offering.base_weight).to eq(262_500_000)
      expect(calls.length - before_calls).to eq(2)
    end

    it 'does not publish or advance sequence for a non-weight settings change' do
      seed_instance(:primary, api_key: 'sk-ant-weight-stable')
      actor = described_class.new
      actor.manual
      key = instance_key_for(name: :primary, api_key: 'sk-ant-weight-stable')

      settings_root[:llm][:anthropic][:request_timeout] = 91
      actor.manual

      expect(registry.snapshot.publication_status(instance_key: key).published_sequence).to eq(0)
      expect(tracked_state(actor)[:sequence]).to eq(0)
    end

    it 'does not publish or advance sequence across ten unchanged ordinary passes' do
      seed_instance(:primary, api_key: 'sk-ant-weight-ten-stable')
      actor = described_class.new
      actor.manual
      key = instance_key_for(name: :primary, api_key: 'sk-ant-weight-ten-stable')

      10.times { actor.manual }

      expect(registry.snapshot.publication_status(instance_key: key).published_sequence).to eq(0)
      expect(tracked_state(actor)[:sequence]).to eq(0)
    end

    it 'preserves an explicit zero and rejects false instead of defaulting it' do
      seed_instance(:primary, api_key: 'sk-ant-weight-values', weight: 0)
      actor = described_class.new
      instance_key = instance_key_for(name: :primary, api_key: 'sk-ant-weight-values')
      instance_cfg = settings_root.dig(:llm, :anthropic, :instances, :primary)
      zero_draft = actor.send(
        :build_offering_draft,
        model_id: 'claude-sonnet-4-6', model_data: { id: 'claude-sonnet-4-6' },
        instance_cfg: instance_cfg, instance_key: instance_key
      )
      expect(zero_draft.weight_inputs[:instance]).to eq(0)
      expect(zero_draft.base_weight).to eq(0)

      instance_cfg[:weight] = false
      expect do
        actor.send(
          :build_offering_draft,
          model_id: 'claude-sonnet-4-6', model_data: { id: 'claude-sonnet-4-6' },
          instance_cfg: instance_cfg, instance_key: instance_key
        )
      end.to raise_error(ArgumentError, /weight component/)
    end

    it 'observes dormant configured weights once, clears on appearance, and logs on re-disappearance' do
      seed_anthropic_settings(
        models:    { ghost: { weight: 130 } },
        instances: {
          primary: {
            enabled: true, endpoint: 'https://api.anthropic.com', api_key: 'sk-ant-dormant', tier: :frontier
          }
        }
      )
      actor = described_class.new
      logger = spy('anthropic weight logger')
      allow(actor).to receive(:log).and_return(logger)
      actor.manual
      actor.manual
      actor.manual

      stub_probe_http(models: [{ id: 'ghost' }])
      actor.manual
      stub_probe_http(models: [{ id: 'claude-sonnet-4-6' }])
      actor.manual

      expected = '[llm][anthropic] action=dormant_weight ' \
                 'weight_key=[:anthropic, :model, "ghost"] no_lane_published=true'
      expect(logger).to have_received(:info).with(expected).twice
      actor.shutdown
    end

    it 'never invokes Settings lifecycle APIs during cadence or shutdown' do
      seed_instance(:primary, api_key: 'sk-ant-no-settings-lifecycle')
      actor = described_class.new
      expect(Legion::Settings).not_to receive(:on_reload)
      expect(Legion::Settings).not_to receive(:reload!)
      expect(Legion::Settings).not_to receive(:reset!)

      actor.manual
      actor.manual
      actor.shutdown
    end

    it 'leaves cached state unchanged on replacement failure and retries on the next pass' do
      seed_instance(:primary, api_key: 'sk-ant-replace-retry')
      actor = described_class.new
      actor.manual
      state = tracked_state(actor)
      original_offerings = state[:offerings]
      original_signature = state[:signature]
      settings_root[:llm][:anthropic][:weight] = 175
      writer = actor.send(:publisher)
      allow(writer).to receive(:replace_instance_snapshot).and_raise('replace failed')

      expect do
        actor.send(:replace_changed_offerings, instance_id: 'primary', state: state)
      end.to raise_error(RuntimeError, 'replace failed')
      expect(state.values_at(:sequence, :offerings, :signature)).to eq([0, original_offerings, original_signature])

      allow(writer).to receive(:replace_instance_snapshot).and_call_original
      actor.send(:replace_changed_offerings, instance_id: 'primary', state: state)
      expect(state[:sequence]).to eq(1)
      expect(state[:offerings].first.weight_inputs[:provider]).to eq(175)
    end

    it 'serializes interleaved ordinary passes and leaves cache equal to the final publication' do
      seed_instance(:primary, api_key: 'sk-ant-interleaved')
      actor = described_class.new
      actor.manual
      state = tracked_state(actor)
      writer = actor.send(:publisher)
      entered = Queue.new
      release = Queue.new
      sequences = Queue.new
      allow(writer).to receive(:replace_instance_snapshot).and_wrap_original do |original, **kwargs|
        sequences << kwargs[:sequence]
        if kwargs[:sequence] == 1
          entered << true
          release.pop
        end
        original.call(**kwargs)
      end

      settings_root[:llm][:anthropic][:weight] = 110
      first = Thread.new { actor.send(:replace_changed_offerings, instance_id: 'primary', state: state) }
      entered.pop
      settings_root[:llm][:anthropic][:weight] = 120
      second = Thread.new { actor.send(:replace_changed_offerings, instance_id: 'primary', state: state) }
      release << true
      [first, second].each(&:join)

      published_sequences = Array.new(2) { sequences.pop }
      key = instance_key_for(name: :primary, api_key: 'sk-ant-interleaved')
      published = registry.snapshot.offerings_for(instance_key: key)
      expect(published_sequences).to eq([1, 2])
      expect(state[:sequence]).to eq(2)
      expect(state[:offerings].map(&:base_weight)).to eq(published.map(&:base_weight))
      expect(state[:offerings].first.weight_inputs[:provider]).to eq(120)
    end

    it 'rebuilds from current Settings after discovery and before initial activation' do
      seed_instance(:primary, api_key: 'sk-ant-initial-barrier')
      actor = described_class.new
      entered = Queue.new
      release = Queue.new
      allow(actor).to receive(:check_readiness) do
        entered << true
        release.pop
        Legion::Extensions::Llm::Inventory::ReadinessResult.new(
          ready: true, reason: 'barrier released', metadata: {}
        )
      end

      activation = Thread.new { actor.manual }
      entered.pop
      settings_root[:llm][:anthropic][:weight] = 180
      release << true
      activation.value

      key = instance_key_for(name: :primary, api_key: 'sk-ant-initial-barrier')
      offering = registry.snapshot.offerings_for(instance_key: key).first
      state = tracked_state(actor)
      expect(offering.weight_inputs[:provider]).to eq(180)
      expect(state[:offerings].first.weight_inputs[:provider]).to eq(180)
      expect(state[:published]).to be(true)
    end

    it 'updates an unpublished cache without replacing or counting it as a published dormant match' do
      seed_instance(:primary, api_key: 'sk-ant-unpublished', weight: 115)
      actor = described_class.new
      unavailable = Legion::Extensions::Llm::Inventory::ReadinessResult.new(
        ready: false, reason: 'not ready', metadata: {}
      )
      allow(actor).to receive(:check_readiness).and_return(unavailable)
      actor.manual
      state = tracked_state(actor)
      writer = actor.send(:publisher)
      allow(writer).to receive(:replace_instance_snapshot).and_call_original

      settings_root[:llm][:anthropic][:instances][:primary][:weight] = 125
      changed = actor.send(:replace_changed_offerings, instance_id: 'primary', state: state)

      expect(changed).to be(true)
      expect(writer).not_to have_received(:replace_instance_snapshot)
      expect(state[:published]).to be(false)
      expect(state[:offerings].first.weight_inputs[:instance]).to eq(125)

      logger = spy('unpublished dormant logger')
      allow(actor).to receive(:log).and_return(logger)
      actor.send(:observe_dormant_weights)
      expected = '[llm][anthropic] action=dormant_weight ' \
                 'weight_key=[:anthropic, :instance, "primary"] no_lane_published=true'
      expect(logger).to have_received(:info).with(expected)
      actor.shutdown
    end

    it 'lets removal win a paused readiness race without resurrection or display writes' do
      seed_instance(:primary, api_key: 'sk-ant-remove-race')
      actor = described_class.new
      entered = Queue.new
      release = Queue.new
      allow(actor).to receive(:check_readiness) do
        entered << true
        release.pop
        Legion::Extensions::Llm::Inventory::ReadinessResult.new(
          ready: true, reason: 'late readiness', metadata: {}
        )
      end

      activation = Thread.new { actor.manual }
      entered.pop
      state = tracked_state(actor)
      actor.send(:retire_instance, state)
      release << true
      activation.value

      key = instance_key_for(name: :primary, api_key: 'sk-ant-remove-race')
      expect(registry.snapshot.publication_status(instance_key: key)).to be_nil
      expect(actor.send(:with_instance_states) { |states| states }).to be_empty
      expect(health_for(:primary)).to be_nil
      expect(state[:published]).to be(false)
    end

    it 'keeps an activation failure unpublished and retries without mutating cached state' do
      seed_instance(:primary, api_key: 'sk-ant-activation-retry')
      actor = described_class.new
      writer = actor.send(:publisher)
      allow(writer).to receive(:activate_instance_snapshot).and_raise('activation failed')

      actor.manual
      state = tracked_state(actor)
      original_offerings = state[:offerings]
      original_signature = state[:signature]
      expect(state.values_at(:sequence, :offerings, :signature, :published))
        .to eq([0, original_offerings, original_signature, false])

      allow(writer).to receive(:activate_instance_snapshot).and_call_original
      actor.manual
      expect(state[:published]).to be(true)
      expect(state[:sequence]).to eq(0)
      expect(state[:offerings]).not_to be_empty
    end
  end

  # ── cadence probe on an available instance ──────────────────────────────

  describe 'cadence probe' do
    it 'marks an available instance unavailable after a failing cadence probe' do
      seed_instance(:primary, api_key: 'sk-ant-lifecycle-cadence')
      actor = described_class.new
      actor.manual # initial probe ready → available
      key = instance_key_for(name: :primary, api_key: 'sk-ant-lifecycle-cadence')
      expect(registry.snapshot.instance(instance_key: key).availability.state).to eq(:available)

      stub_probe_http(ready: false)
      actor.manual # tick → cadence probe fails → unavailable

      expect(registry.snapshot.instance(instance_key: key).availability.state).to eq(:unavailable)
      expect(health_for(:primary)[:available]).to eq(false)
      expect(health_for(:primary)[:last_probe_outcome]).to eq(:failure)
    end
  end

  # ── shutdown ────────────────────────────────────────────────────────────

  describe '#shutdown' do
    it 'removes all instances from the registry and clears the display' do
      seed_instance(:primary, api_key: 'sk-ant-lifecycle-shutdown')
      actor = described_class.new
      actor.manual

      actor.shutdown

      expect(registry.snapshot.each_publication_status.to_a).to be_empty
      expect(health_for(:primary)).to be_nil
    end
  end

  # ── default instance (v2 parity) ──────────────────────────────────────────
  # A config name of `default` has no special claimability behavior. Normal
  # enabled and credential validation determines whether it is activated.

  let(:synthetic_default) do
    Legion::Extensions::Llm::Anthropic.default_settings.dig(:instances, :default)
  end

  describe 'default instance' do
    it 'uses normal credential validation for the unmodified template and claims configured instances' do
      seed_anthropic_settings({
                                instances: {
                                  default: synthetic_default,
                                  primary: {
                                    enabled:  true,
                                    endpoint: 'https://primary.internal:8443',
                                    api_key:  'sk-ant-primary'
                                  }
                                }
                              })

      actor = described_class.new

      # The unconfigured template has no resolved credential, while primary
      # remains claimable through the same normal validation path.
      claimable = actor.send(:configured_instances)
      expect(claimable.keys).to eq([:primary])

      actor.manual

      statuses = registry.snapshot.each_publication_status.to_a
      expect(statuses.size).to eq(1)
      primary_key = instance_key_for(
        name: :primary, api_key: 'sk-ant-primary', endpoint: 'https://primary.internal:8443'
      )
      expect(statuses.first.instance_key).to eq(primary_key)
      expect(statuses.first.state).to eq(:complete)

      # The credential-less template is not claimed and gets no health display.
      expect(health_for(:default)).to be_nil
      expect(health_for(:primary)[:available]).to eq(true)
    end

    it 'treats a configured default (real key) as claimable at the provider layer' do
      seed_anthropic_settings({
                                instances: {
                                  default: {
                                    enabled:  true,
                                    endpoint: 'https://api.anthropic.com',
                                    api_key:  'sk-ant-configured-default'
                                  }
                                }
                              })

      actor = described_class.new
      claimable = actor.send(:configured_instances)

      # Provider-layer decision: a modified default passes discovery and
      # reaches the claim path (v2 parity — 'default' is a plain instance
      # label). Whether the foundation's InstanceKey accepts the name is a
      # lex-llm contract, not a provider-layer decision — so this spec asserts
      # the claimable set, not an end-to-end claim.
      expect(claimable.keys).to eq([:default])
      expect(claimable[:default][:anthropic_api_key]).to eq('sk-ant-configured-default')
    end
  end

  # ── authoritative operation evidence: embedding models ───────────────────

  describe 'embedding model operation evidence' do
    it 'publishes chat: :unsupported and embed: :supported for an embedding model' do
      allow(Faraday).to receive(:new) do |*_args, &_block|
        connection = instance_double(Faraday::Connection)
        allow(connection).to receive(:get) do |path|
          if path == '/v1/models'
            probe_response(
              200,
              ::JSON.dump(data: [
                            { id: 'claude-sonnet-4-6' },
                            { id: 'anthropic-embed-v1', type: 'embedding' }
                          ])
            )
          else
            probe_response(503, ::JSON.dump(type: 'error', error: { type: 'api_error', message: 'unavailable' }))
          end
        end
        connection
      end

      seed_instance(:embedder, api_key: 'sk-ant-embedder')
      actor = described_class.new
      actor.manual

      key = instance_key_for(name: :embedder, api_key: 'sk-ant-embedder')
      offerings = registry.snapshot.offerings_for(instance_key: key)
      expect(offerings.map(&:model)).to contain_exactly('claude-sonnet-4-6', 'anthropic-embed-v1')

      chat_model = offerings.find { |o| o.model == 'claude-sonnet-4-6' }
      expect(chat_model.operation_evidence[:chat].status).to eq(:supported)
      expect(chat_model.operation_evidence[:embed].status).to eq(:unsupported)

      embedding_model = offerings.find { |o| o.model == 'anthropic-embed-v1' }
      expect(embedding_model.operation_evidence[:chat].status).to eq(:unsupported)
      expect(embedding_model.operation_evidence[:stream_chat].status).to eq(:unsupported)
      expect(embedding_model.operation_evidence[:embed].status).to eq(:supported)
      expect(embedding_model.operation_evidence[:embed].source).to eq(:provider_catalog)
      expect(embedding_model.operation_evidence[:count_tokens].status).to eq(:unsupported)
      expect(embedding_model.capability_evidence[:embedding].status).to eq(:supported)
      # An embedding model serves embed and nothing else — no chat capabilities.
      expect(embedding_model.capability_evidence).not_to have_key(:completion)
      expect(embedding_model.capability_evidence).not_to have_key(:tools)
    end

    it 'publishes chat: :unsupported for an embedding-named model (id evidence)' do
      allow(Faraday).to receive(:new) do |*_args, &_block|
        connection = instance_double(Faraday::Connection)
        allow(connection).to receive(:get) do |path|
          if path == '/v1/models'
            probe_response(200, ::JSON.dump(data: [{ id: 'custom-embedder-latest' }]))
          else
            probe_response(503, ::JSON.dump(type: 'error', error: { type: 'api_error', message: 'unavailable' }))
          end
        end
        connection
      end

      seed_instance(:embedder, api_key: 'sk-ant-embedder-id')
      actor = described_class.new
      actor.manual

      key = instance_key_for(name: :embedder, api_key: 'sk-ant-embedder-id')
      offering = registry.snapshot.offerings_for(instance_key: key).first
      expect(offering.model).to eq('custom-embedder-latest')
      expect(offering.operation_evidence[:chat].status).to eq(:unsupported)
      expect(offering.operation_evidence[:embed].status).to eq(:supported)
    end
  end
end
