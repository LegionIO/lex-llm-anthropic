# frozen_string_literal: true

require 'spec_helper'
require 'faraday'
require 'json'

# The entry file intentionally does NOT require the runner (sibling parity —
# the daemon resolves the runner module from the actor's namespace), so the
# runner spec requires it explicitly.
require 'legion/extensions/llm/anthropic/runners/discovery'

RSpec.describe Legion::Extensions::Llm::Anthropic::Runners::Discovery do
  let(:registry) { Legion::Extensions::Llm::Inventory::Registry }
  let(:settings_root) { Legion::Settings[:extensions] }
  let(:discovery_actor) { Legion::Extensions::Llm::Anthropic::Actor::Discovery }

  # Pin the credential surfaces the pipeline's discover_instances reads beyond
  # the seeded settings: the ANTHROPIC_API_KEY env probe and the Claude config
  # probe must be empty or the claim set below is no longer exact.
  before do
    registry.reset!
    described_class.reset_state!
    @env_anthropic_key = ENV.delete('ANTHROPIC_API_KEY')
    allow(Legion::Extensions::Llm::CredentialSources).to receive(:claude_config_value).and_return(nil)
    stub_probe_http(ready: true)
  end

  after do
    ENV['ANTHROPIC_API_KEY'] = @env_anthropic_key if @env_anthropic_key
    # Module-level writer state (states / dormant tracker) — required or it
    # leaks across examples.
    described_class.reset_state!
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

  # The runner publishes the operator's config NAME as the instance identity;
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

  # The pipeline probes with its own raw Faraday connection (build_connection);
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

  def with_tier_weight(value)
    tier_weights = Legion::Settings.loader.settings.dig(:llm, :routing, :tier_weights)
    was_defined = tier_weights.is_a?(Hash) && tier_weights.key?(:frontier)
    previous = tier_weights[:frontier] if was_defined
    write_tier_weight(value)
    yield
  ensure
    tier_weights = Legion::Settings.loader.settings.dig(:llm, :routing, :tier_weights)
    tier_weights[:frontier] = previous if was_defined
    tier_weights.delete(:frontier) unless was_defined
  end

  def tracked_state(instance_id = 'primary')
    described_class.states.fetch(instance_id)
  end

  def authoritative_contract_variant(draft, field)
    replacement = case field
                  when :provider_native_key
                    'claude-native-revision-v2'
                  when :operation_evidence
                    draft.operation_evidence.merge(
                      chat: Legion::Extensions::Llm::Inventory::OperationEvidence.new(
                        operation: :chat, status: :supported, source: :provider_catalog,
                        observed_at: Time.now, metadata: { catalog_revision: 'v2' }
                      )
                    )
                  when :context_evidence
                    Legion::Extensions::Llm::Inventory::ValueEvidence.new(
                      status: :known, value: 200_000, source: :provider_catalog,
                      observed_at: Time.now, metadata: { catalog_revision: 'v2' }
                    )
                  when :quota_domains
                    { chat: 'anthropic-chat-v2' }
                  when :metadata
                    draft.metadata.merge(catalog_revision: 'v2')
                  when :publication_source
                    :provider_control_plane
                  end
    draft.with(field => replacement)
  end

  # ── actor time (base contract) ──────────────────────────────────────────

  describe 'Actor::Discovery#time' do
    it 'resolves the live nested instance default (never the top-level key)' do
      seed_anthropic_settings({ discovery_interval: 99, instances: { default: { discovery_interval: 7200 } } })
      expect(discovery_actor.new.time).to eq(7200)
    end

    it 'falls back to the registered base default when the live value is absent' do
      seed_anthropic_settings({})
      expect(discovery_actor.new.time).to eq(300)
    end
  end

  # ── initial discovery ───────────────────────────────────────────────────

  describe 'initial discovery' do
    it 'claims and activates a configured instance, and writes the settings display' do
      seed_instance(:primary, api_key: 'sk-ant-lifecycle-one')
      described_class.refresh

      key = instance_key_for(name: :primary, api_key: 'sk-ant-lifecycle-one')
      snapshot = registry.snapshot

      expect(snapshot.publication_status(instance_key: key).state).to eq(:complete)
      expect(snapshot.instance(instance_key: key).availability.state).to eq(:available)
      # One inference lane per chat model (chat + stream_chat collapse to the
      # :inference type in the 5-tuple).
      expect(snapshot.lanes_for(instance_key: key).map(&:model)).to contain_exactly('claude-sonnet-4-6', 'claude-haiku-4-5')

      # Identity is the config name; the derived host:port/ak rides as the
      # secondary physical_id on the committed key.
      committed = snapshot.publication_status(instance_key: key)
      expect(committed.instance_key.instance_id).to eq('primary')
      expect(committed.instance_key.physical_id)
        .to eq("api.anthropic.com:443/ak:#{Digest::SHA256.hexdigest('sk-ant-lifecycle-one')[0, 8]}")

      # The shared pipeline's display shape: state/reason/observed_at/
      # last_probe_outcome/source.
      health = health_for(:primary)
      expect(health[:state]).to eq(:available)
      expect(health[:reason]).to be_a(String)
      expect(health[:observed_at]).to be_a(String)
      expect(health[:last_probe_outcome]).to eq(:success)
      expect(health[:source]).to eq(:startup_readiness)
      expect(settings_root.dig(:llm, :anthropic, :instances, :primary, :capabilities))
        .to eq(%i[completion streaming tools vision])
    end

    it 'stays initializing while the catalog is unreachable at claim (readiness deferred)' do
      seed_instance(:primary, api_key: 'sk-ant-lifecycle-two')
      stub_probe_http(ready: false)

      described_class.refresh

      key = instance_key_for(name: :primary, api_key: 'sk-ant-lifecycle-two')
      expect(registry.snapshot.publication_status(instance_key: key).state).to eq(:initializing)
      expect(registry.snapshot.instance(instance_key: key)).to be_nil
      # Readiness is deferred while the catalog is unreachable — the display
      # is written post-commit, so nothing is displayed yet.
      expect(health_for(:primary)).to be_nil
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

        described_class.refresh

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
    it 're-activates an :initializing instance on a later passing pass' do
      seed_instance(:primary, api_key: 'sk-ant-lifecycle-recover')
      stub_probe_http(ready: false)

      described_class.refresh # catalog unreachable → :initializing
      key = instance_key_for(name: :primary, api_key: 'sk-ant-lifecycle-recover')
      expect(registry.snapshot.publication_status(instance_key: key).state).to eq(:initializing)

      stub_probe_http(ready: true)
      described_class.refresh # tick → build offerings → readiness → activate
      expect(registry.snapshot.publication_status(instance_key: key).state).to eq(:complete)
      expect(registry.snapshot.instance(instance_key: key).availability.state).to eq(:available)
      expect(health_for(:primary)[:state]).to eq(:available)
      expect(health_for(:primary)[:last_probe_outcome]).to eq(:success)
    end
  end

  # ── tick reconciliation (P2-7) ──────────────────────────────────────────

  describe 'tick reconciliation' do
    it 'claims instances added after boot and retires instances removed from config' do
      seed_instance(:alpha, api_key: 'sk-ant-alpha', endpoint: 'https://alpha.internal:8443')
      described_class.refresh

      alpha_key = instance_key_for(name: :alpha, api_key: 'sk-ant-alpha', endpoint: 'https://alpha.internal:8443')
      expect(registry.snapshot.publication_status(instance_key: alpha_key).state).to eq(:complete)

      seed_instance(:beta, api_key: 'sk-ant-beta', endpoint: 'https://beta.internal:8443')
      described_class.refresh # tick → reconcile: alpha gone, beta new

      beta_key = instance_key_for(name: :beta, api_key: 'sk-ant-beta', endpoint: 'https://beta.internal:8443')
      expect(registry.snapshot.publication_status(instance_key: beta_key).state).to eq(:complete)
      expect(registry.snapshot.instance(instance_key: alpha_key)).to be_nil
      expect(registry.snapshot.publication_status(instance_key: alpha_key)).to be_nil
      expect(health_for(:beta)[:state]).to eq(:available)
    end
  end

  # ── write-time lane weights (Task 03W) ──────────────────────────────────
  # The runner's draft is contractually weight-free ("NO weight — the
  # reconciler computes it at publish"); the shared WeightReconciler computes
  # the write-time weight from live settings at publish, so the assertions
  # land on the PUBLISHED lane, not the draft.

  describe 'write-time lane weights' do
    it 'publishes the live weight inputs and their product on the lanes, with identity-weighted drafts' do
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
      key = instance_key_for(name: :primary, api_key: 'sk-ant-weight-draft')
      instance_cfg = settings_root.dig(:llm, :anthropic, :instances, :primary)
      draft = described_class.build_offering_draft(
        model_id: 'claude-sonnet-4-6', model_data: { id: 'claude-sonnet-4-6' },
        instance_cfg: instance_cfg, instance_key: key
      )
      # The runner's draft carries the identity pair only — weight is NOT
      # computed at draft time.
      expect(draft.weight_inputs).to eq(tier: 100, provider: 100, instance: 100, model_or_offering: 100)
      expect(draft.base_weight).to eq(100_000_000)

      with_tier_weight(150) do
        described_class.refresh
      end

      lane = registry.snapshot.lanes_for(instance_key: key).find { |l| l.model == 'claude-sonnet-4-6' }
      expect(lane.weight_inputs).to eq(tier: 150, provider: 200, instance: 115, model_or_offering: 125)
      expect(lane.weight_inputs).to be_frozen
      expect(lane.base_weight).to eq(431_250_000)
    end

    it 'publishes one replacement on the next ordinary pass when only a weight changes' do
      calls = []
      stub_probe_http(calls: calls)
      seed_instance(:primary, api_key: 'sk-ant-weight-refresh')
      described_class.refresh
      key = instance_key_for(name: :primary, api_key: 'sk-ant-weight-refresh')
      before_calls = calls.length

      settings_root[:llm][:anthropic][:weight] = 175
      described_class.refresh

      status = registry.snapshot.publication_status(instance_key: key)
      lane = registry.snapshot.lanes_for(instance_key: key).find { |l| l.model == 'claude-sonnet-4-6' }
      expect(status.published_sequence).to eq(1)
      expect(lane.weight_inputs[:provider]).to eq(175)
      expect(lane.base_weight).to eq(175_000_000)
      expect(calls.length - before_calls).to eq(2)
    end

    it 'does not publish or advance sequence for a non-weight settings change' do
      seed_instance(:primary, api_key: 'sk-ant-weight-stable')
      described_class.refresh
      key = instance_key_for(name: :primary, api_key: 'sk-ant-weight-stable')

      settings_root[:llm][:anthropic][:request_timeout] = 91
      described_class.refresh

      expect(registry.snapshot.publication_status(instance_key: key).published_sequence).to eq(0)
      expect(tracked_state[:sequence]).to eq(0)
    end

    it 'does not publish or advance sequence across ten unchanged ordinary passes' do
      seed_instance(:primary, api_key: 'sk-ant-weight-ten-stable')
      described_class.refresh
      key = instance_key_for(name: :primary, api_key: 'sk-ant-weight-ten-stable')

      10.times { described_class.refresh }

      expect(registry.snapshot.publication_status(instance_key: key).published_sequence).to eq(0)
      expect(tracked_state[:sequence]).to eq(0)
    end

    %i[
      provider_native_key operation_evidence context_evidence quota_domains metadata publication_source
    ].each do |field|
      it "publishes a #{field} change once and ignores catalog reordering" do
        seed_instance(:primary, api_key: 'sk-ant-complete-contract')
        instance_cfg = settings_root.dig(:llm, :anthropic, :instances, :primary)
        key = instance_key_for(name: :primary, api_key: 'sk-ant-complete-contract')
        first = described_class.build_offering_draft(
          model_id: 'claude-sonnet-4-6', model_data: { id: 'claude-sonnet-4-6' },
          instance_cfg: instance_cfg, instance_key: key
        )
        second = described_class.build_offering_draft(
          model_id: 'claude-haiku-4-5', model_data: { id: 'claude-haiku-4-5' },
          instance_cfg: instance_cfg, instance_key: key
        )
        changed = authoritative_contract_variant(first, field)
        allow(described_class).to receive(:build_offerings)
          .and_return([first, second], [changed, second], [second, changed])
        writer = described_class.publisher
        allow(writer).to receive(:replace_instance_snapshot).and_call_original

        described_class.refresh
        described_class.refresh

        lane = registry.snapshot.lanes_for(instance_key: key).find { |l| l.model == first.model }
        expect(writer).to have_received(:replace_instance_snapshot).once
        expect(registry.snapshot.publication_status(instance_key: key).published_sequence).to eq(1)
        # Lanes retain the contract fields except provider_native_key and
        # operation_evidence (the lane identity is the 5 tuple; the fine
        # operation evidence stays on the draft) — those two are asserted on
        # the writer's published cache instead. quota_domains lands on the
        # lane's singular quota_domain for its representative operation.
        if %i[context_evidence metadata publication_source].include?(field)
          expect(lane.public_send(field)).to eq(changed.public_send(field))
        elsif field == :quota_domains
          expect(lane.quota_domain).to eq(changed.quota_domains.fetch(:chat))
        else
          cached = tracked_state[:offerings].find { |draft| draft.model == first.model }
          expect(cached.public_send(field)).to eq(changed.public_send(field))
        end

        described_class.refresh

        expect(writer).to have_received(:replace_instance_snapshot).once
        expect(registry.snapshot.publication_status(instance_key: key).published_sequence).to eq(1)
      end
    end

    it 'treats the offering catalog as an order-independent multiset without hiding duplicates' do
      seed_instance(:primary, api_key: 'sk-ant-complete-contract-multiset')
      instance_cfg = settings_root.dig(:llm, :anthropic, :instances, :primary)
      key = instance_key_for(name: :primary, api_key: 'sk-ant-complete-contract-multiset')
      first = described_class.build_offering_draft(
        model_id: 'claude-sonnet-4-6', model_data: { id: 'claude-sonnet-4-6' },
        instance_cfg: instance_cfg, instance_key: key
      )
      second = described_class.build_offering_draft(
        model_id: 'claude-haiku-4-5', model_data: { id: 'claude-haiku-4-5' },
        instance_cfg: instance_cfg, instance_key: key
      )

      expect(described_class.send(:offering_comparison_multiset, [first, first, second]))
        .to eq(described_class.send(:offering_comparison_multiset, [second, first, first]))
      expect(described_class.send(:offering_comparison_multiset, [first, first, second]))
        .not_to eq(described_class.send(:offering_comparison_multiset, [first, second]))
    end

    it 'publishes an explicit zero weight as base 0 and never publishes a malformed weight' do
      seed_instance(:primary, api_key: 'sk-ant-weight-values', weight: 0)
      described_class.refresh
      key = instance_key_for(name: :primary, api_key: 'sk-ant-weight-values')
      lane = registry.snapshot.lanes_for(instance_key: key).find { |l| l.model == 'claude-sonnet-4-6' }
      expect(lane.weight_inputs[:instance]).to eq(0)
      expect(lane.base_weight).to eq(0)

      # A malformed component (false) raises in the shared WeightSchema at the
      # publish path — it must stay unpublished and keep the last good
      # publication, never default the component.
      settings_root[:llm][:anthropic][:instances][:primary][:weight] = false
      described_class.refresh

      expect(registry.snapshot.publication_status(instance_key: key).published_sequence).to eq(0)
      expect(tracked_state[:sequence]).to eq(0)
      retained = registry.snapshot.lanes_for(instance_key: key).find { |l| l.model == 'claude-sonnet-4-6' }
      expect(retained.base_weight).to eq(0)
    end

    it 'never publishes a malformed startup weight and publishes once after correction' do
      seed_instance(:primary, api_key: 'sk-ant-malformed-startup', weight: false)
      key = instance_key_for(name: :primary, api_key: 'sk-ant-malformed-startup')

      described_class.refresh

      # The instance is claimed but the malformed weight blocks publication —
      # no lane, no :complete status, while the claim is retained for retry.
      expect(registry.snapshot.publication_status(instance_key: key).state).to eq(:initializing)
      expect(registry.snapshot.instance(instance_key: key)).to be_nil
      expect(registry.snapshot.lanes_for(instance_key: key)).to be_empty

      settings_root[:llm][:anthropic][:instances][:primary][:weight] = 115
      described_class.refresh

      expect(registry.snapshot.publication_status(instance_key: key).state).to eq(:complete)
      expect(registry.snapshot.lanes_for(instance_key: key)).not_to be_empty
      expect(tracked_state[:published]).to be(true)
    end
  end

  # ── shared pipeline mechanics (exercised through the real runner) ───────
  # NOTE: lex-llm 0.8.0 ships no spec for Discovery::Pipeline (only
  # weight_reconciler_spec), so these owner-agnostic mechanics are exercised
  # here through the Anthropic runner until the shared owner gains coverage.

  describe 'dormant weight observation' do
    it 'observes dormant configured weights once, clears on appearance, and logs on re-disappearance' do
      seed_anthropic_settings(
        models:    { ghost: { weight: 130 } },
        instances: {
          primary: {
            enabled: true, endpoint: 'https://api.anthropic.com', api_key: 'sk-ant-dormant', tier: :frontier
          }
        }
      )
      logger = spy('anthropic weight logger')
      allow(described_class).to receive(:log).and_return(logger)
      described_class.refresh
      described_class.refresh
      described_class.refresh

      stub_probe_http(models: [{ id: 'ghost' }])
      described_class.refresh
      stub_probe_http(models: [{ id: 'claude-sonnet-4-6' }])
      described_class.refresh

      expected = '[llm][anthropic] action=dormant_weight ' \
                 'weight_key=[:anthropic, :model, "ghost"] no_lane_published=true'
      expect(logger).to have_received(:info).with(expected).twice
      described_class.remove_all_instances
    end

    it 'updates an unpublished cache without replacing or counting it as a published dormant match' do
      seed_instance(:primary, api_key: 'sk-ant-unpublished', weight: 115)
      unavailable = Legion::Extensions::Llm::Inventory::ReadinessResult.new(
        ready: false, reason: 'not ready', metadata: {}
      )
      logger = spy('unpublished dormant logger')
      allow(described_class).to receive(:log).and_return(logger)
      allow(described_class).to receive(:check_health).and_return(unavailable)
      described_class.refresh
      state = tracked_state
      writer = described_class.publisher
      allow(writer).to receive(:replace_instance_snapshot).and_call_original

      # An unpublished instance with a configured weight IS a dormant match —
      # it is not suppressed by the published-keys accounting.
      expected = '[llm][anthropic] action=dormant_weight ' \
                 'weight_key=[:anthropic, :instance, "primary"] no_lane_published=true'
      expect(logger).to have_received(:info).with(expected)

      settings_root[:llm][:anthropic][:instances][:primary][:weight] = 125
      offerings = described_class.build_offerings(instance_cfg: state[:instance_cfg], instance_key: state[:instance_key])
      changed = described_class.reconcile_weight_snapshot(instance_id: 'primary', state: state, discovered_offerings: offerings)

      expect(changed).to be(true)
      expect(writer).not_to have_received(:replace_instance_snapshot)
      expect(state[:published]).to be(false)
      expect(state[:offerings].first.weight_inputs[:instance]).to eq(125)

      # Still unpublished → still dormant, but not NEWLY dormant — the log
      # fires once, not again.
      described_class.observe_dormant_weights
      expect(logger).to have_received(:info).with(expected).once
      described_class.remove_all_instances
    end
  end

  describe 'settings lifecycle isolation' do
    it 'never invokes Settings lifecycle APIs during cadence or shutdown' do
      seed_instance(:primary, api_key: 'sk-ant-no-settings-lifecycle')
      expect(Legion::Settings).not_to receive(:on_reload)
      expect(Legion::Settings).not_to receive(:reload!)
      expect(Legion::Settings).not_to receive(:reset!)

      described_class.refresh
      described_class.refresh
      described_class.remove_all_instances
    end
  end

  describe 'replace retry and serialization' do
    it 'leaves cached state unchanged on replacement failure and retries on the next pass' do
      seed_instance(:primary, api_key: 'sk-ant-replace-retry')
      described_class.refresh
      state = tracked_state
      original_offerings = state[:offerings]
      settings_root[:llm][:anthropic][:weight] = 175
      writer = described_class.publisher
      allow(writer).to receive(:replace_instance_snapshot).and_raise('replace failed')
      offerings = described_class.build_offerings(instance_cfg: state[:instance_cfg], instance_key: state[:instance_key])

      expect do
        described_class.reconcile_weight_snapshot(instance_id: 'primary', state: state, discovered_offerings: offerings)
      end.to raise_error(RuntimeError, 'replace failed')
      expect(state[:sequence]).to eq(0)
      expect(state[:offerings]).to equal(original_offerings)

      allow(writer).to receive(:replace_instance_snapshot).and_call_original
      described_class.reconcile_weight_snapshot(instance_id: 'primary', state: state, discovered_offerings: offerings)
      expect(state[:sequence]).to eq(1)
      expect(state[:offerings].first.weight_inputs[:provider]).to eq(175)
    end

    it 'serializes interleaved ordinary passes and leaves cache equal to the final publication' do
      seed_instance(:primary, api_key: 'sk-ant-interleaved')
      described_class.refresh
      state = tracked_state
      writer = described_class.publisher
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
      offerings = described_class.build_offerings(instance_cfg: state[:instance_cfg], instance_key: state[:instance_key])
      first = Thread.new { described_class.reconcile_weight_snapshot(instance_id: 'primary', state: state, discovered_offerings: offerings) }
      entered.pop
      settings_root[:llm][:anthropic][:weight] = 120
      second = Thread.new { described_class.reconcile_weight_snapshot(instance_id: 'primary', state: state, discovered_offerings: offerings) }
      release << true
      [first, second].each(&:join)

      published_sequences = Array.new(2) { sequences.pop }
      key = instance_key_for(name: :primary, api_key: 'sk-ant-interleaved')
      published = registry.snapshot.lanes_for(instance_key: key)
      expect(published_sequences).to eq([1, 2])
      expect(state[:sequence]).to eq(2)
      expect(state[:offerings].map(&:base_weight)).to eq(published.map(&:base_weight))
      expect(state[:offerings].first.weight_inputs[:provider]).to eq(120)
    end

    it 'rebuilds from current Settings after discovery and before initial activation' do
      seed_instance(:primary, api_key: 'sk-ant-initial-barrier')
      entered = Queue.new
      release = Queue.new
      allow(described_class).to receive(:check_health) do
        entered << true
        release.pop
        Legion::Extensions::Llm::Inventory::ReadinessResult.new(
          ready: true, reason: 'barrier released', metadata: {}
        )
      end

      activation = Thread.new { described_class.refresh }
      entered.pop
      settings_root[:llm][:anthropic][:weight] = 180
      release << true
      activation.value

      key = instance_key_for(name: :primary, api_key: 'sk-ant-initial-barrier')
      lane = registry.snapshot.lanes_for(instance_key: key).first
      state = tracked_state
      expect(lane.weight_inputs[:provider]).to eq(180)
      expect(state[:offerings].first.weight_inputs[:provider]).to eq(180)
      expect(state[:published]).to be(true)
    end

    it 'lets removal win a paused readiness race without resurrection or display writes' do
      seed_instance(:primary, api_key: 'sk-ant-remove-race')
      entered = Queue.new
      release = Queue.new
      allow(described_class).to receive(:check_health) do
        entered << true
        release.pop
        Legion::Extensions::Llm::Inventory::ReadinessResult.new(
          ready: true, reason: 'late readiness', metadata: {}
        )
      end

      activation = Thread.new { described_class.refresh }
      entered.pop
      state = tracked_state
      described_class.remove_instance_state('primary')
      release << true
      activation.value

      key = instance_key_for(name: :primary, api_key: 'sk-ant-remove-race')
      expect(registry.snapshot.publication_status(instance_key: key)).to be_nil
      expect(described_class.states.keys).to be_empty
      expect(health_for(:primary)).to be_nil
      expect(state[:published]).to be(false)
    end

    it 'keeps an activation failure unpublished and retries without mutating cached state' do
      seed_instance(:primary, api_key: 'sk-ant-activation-retry')
      writer = described_class.publisher
      allow(writer).to receive(:activate_instance_snapshot).and_raise('activation failed')

      described_class.refresh
      state = tracked_state
      original_offerings = state[:offerings]
      expect(state[:sequence]).to eq(0)
      expect(state[:offerings]).to equal(original_offerings)
      expect(state[:published]).to be(false)

      allow(writer).to receive(:activate_instance_snapshot).and_call_original
      described_class.refresh
      expect(state[:published]).to be(true)
      expect(state[:sequence]).to eq(0)
      expect(state[:offerings]).not_to be_empty
    end
  end

  # ── cadence probe on an available instance ──────────────────────────────

  describe 'cadence probe' do
    it 'marks an available instance unavailable after a failing cadence probe' do
      seed_instance(:primary, api_key: 'sk-ant-lifecycle-cadence')
      described_class.refresh # initial probe ready → available
      key = instance_key_for(name: :primary, api_key: 'sk-ant-lifecycle-cadence')
      expect(registry.snapshot.instance(instance_key: key).availability.state).to eq(:available)

      stub_probe_http(ready: false)
      described_class.refresh # tick → cadence probe fails → unavailable

      expect(registry.snapshot.instance(instance_key: key).availability.state).to eq(:unavailable)
      expect(health_for(:primary)[:state]).to eq(:unavailable)
      expect(health_for(:primary)[:last_probe_outcome]).to eq(:failure)
    end
  end

  # ── shutdown ────────────────────────────────────────────────────────────

  describe 'remove_all_instances' do
    it 'removes all instances from the registry and clears the display' do
      seed_instance(:primary, api_key: 'sk-ant-lifecycle-shutdown')
      described_class.refresh

      described_class.remove_all_instances

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

      # The unconfigured template has no resolved credential, while primary
      # remains claimable through the same normal validation path.
      claimable = described_class.discover_instances
      expect(claimable.keys).to eq([:primary])

      described_class.refresh

      statuses = registry.snapshot.each_publication_status.to_a
      expect(statuses.size).to eq(1)
      primary_key = instance_key_for(
        name: :primary, api_key: 'sk-ant-primary', endpoint: 'https://primary.internal:8443'
      )
      expect(statuses.first.instance_key).to eq(primary_key)
      expect(statuses.first.state).to eq(:complete)

      # The credential-less template is not claimed and gets no health display.
      expect(health_for(:default)).to be_nil
      expect(health_for(:primary)[:state]).to eq(:available)
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

      claimable = described_class.discover_instances

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
  # Lanes retain the capability evidence + representative operation; the fine
  # per-operation evidence is asserted on the runner's draft (the lane's
  # contract is the coarse type + capability evidence, per the 0.8.0 record).

  describe 'embedding model operation evidence' do
    def stub_catalog(models)
      allow(Faraday).to receive(:new) do |*_args, &_block|
        connection = instance_double(Faraday::Connection)
        allow(connection).to receive(:get) do |path|
          if path == '/v1/models'
            probe_response(200, ::JSON.dump(data: models))
          else
            probe_response(503, ::JSON.dump(type: 'error', error: { type: 'api_error', message: 'unavailable' }))
          end
        end
        connection
      end
    end

    it 'publishes chat: :unsupported and embed: :supported for an embedding model' do
      stub_catalog([{ id: 'claude-sonnet-4-6' }, { id: 'anthropic-embed-v1', type: 'embedding' }])
      seed_instance(:embedder, api_key: 'sk-ant-embedder')
      described_class.refresh

      key = instance_key_for(name: :embedder, api_key: 'sk-ant-embedder')
      lanes = registry.snapshot.lanes_for(instance_key: key)
      expect(lanes.map(&:model)).to contain_exactly('claude-sonnet-4-6', 'anthropic-embed-v1')

      instance_cfg = settings_root.dig(:llm, :anthropic, :instances, :embedder)
      chat_draft = described_class.build_offering_draft(
        model_id: 'claude-sonnet-4-6', model_data: { id: 'claude-sonnet-4-6' },
        instance_cfg: instance_cfg, instance_key: key
      )
      embed_draft = described_class.build_offering_draft(
        model_id: 'anthropic-embed-v1', model_data: { id: 'anthropic-embed-v1', type: 'embedding' },
        instance_cfg: instance_cfg, instance_key: key
      )

      expect(chat_draft.operation_evidence[:chat].status).to eq(:supported)
      expect(chat_draft.operation_evidence[:embed].status).to eq(:unsupported)

      expect(embed_draft.operation_evidence[:chat].status).to eq(:unsupported)
      expect(embed_draft.operation_evidence[:stream_chat].status).to eq(:unsupported)
      expect(embed_draft.operation_evidence[:embed].status).to eq(:supported)
      expect(embed_draft.operation_evidence[:embed].source).to eq(:provider_catalog)
      expect(embed_draft.operation_evidence[:count_tokens].status).to eq(:unsupported)

      chat_lane = lanes.find { |lane| lane.model == 'claude-sonnet-4-6' }
      expect(chat_lane.operation).to eq(:chat)
      embed_lane = lanes.find { |lane| lane.model == 'anthropic-embed-v1' }
      expect(embed_lane.operation).to eq(:embed)
      expect(embed_lane.capability_evidence[:embedding].status).to eq(:supported)
      # An embedding model serves embed and nothing else — no chat capabilities.
      expect(embed_lane.capability_evidence).not_to have_key(:completion)
      expect(embed_lane.capability_evidence).not_to have_key(:tools)
    end

    it 'publishes chat: :unsupported for an embedding-named model (id evidence)' do
      stub_catalog([{ id: 'custom-embedder-latest' }])
      seed_instance(:embedder, api_key: 'sk-ant-embedder-id')
      described_class.refresh

      key = instance_key_for(name: :embedder, api_key: 'sk-ant-embedder-id')
      instance_cfg = settings_root.dig(:llm, :anthropic, :instances, :embedder)
      draft = described_class.build_offering_draft(
        model_id: 'custom-embedder-latest', model_data: { id: 'custom-embedder-latest' },
        instance_cfg: instance_cfg, instance_key: key
      )
      expect(draft.operation_evidence[:chat].status).to eq(:unsupported)
      expect(draft.operation_evidence[:embed].status).to eq(:supported)

      lane = registry.snapshot.lanes_for(instance_key: key).first
      expect(lane.model).to eq('custom-embedder-latest')
      expect(lane.operation).to eq(:embed)
    end
  end
end
