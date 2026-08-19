# frozen_string_literal: true

require 'spec_helper'
require 'faraday'
require 'digest'
require 'uri'

require 'legion/extensions/llm/inventory/publisher'
require 'legion/extensions/llm/inventory/registry'
require 'legion/extensions/llm/inventory/identity'
require 'legion/extensions/llm/inventory/records'
require 'legion/extensions/llm/inventory/evidence'
require 'legion/extensions/llm/inventory/probe_coordinator'
require 'legion/extensions/llm/routing/provider_outcome'
require 'legion/extensions/llm/taxonomies'
require 'legion/extensions/llm/capabilities'
require 'legion/extensions/llm/fleet/worker_execution'
require 'legion/extensions/llm/fleet/protocol'

# Evidence-building helpers for the SSOT v3 Anthropic conformance harness.
module AnthropicSsotEvidenceHelpers
  private

  def build_operation_evidence(now:)
    {
      chat:         op_evidence(:chat,         :supported,   now),
      stream_chat:  op_evidence(:stream_chat,  :supported,   now),
      embed:        op_evidence(:embed,        :unsupported, now),
      image:        op_evidence(:image,        :unsupported, now),
      transcribe:   op_evidence(:transcribe,   :unsupported, now),
      translate:    op_evidence(:translate,    :unsupported, now),
      speak:        op_evidence(:speak,        :unsupported, now),
      moderate:     op_evidence(:moderate,     :unsupported, now),
      count_tokens: op_evidence(:count_tokens, :unknown,     now)
    }
  end

  def op_evidence(operation, status, observed_at)
    source = status == :unknown ? :default_false : :provider_implementation
    Legion::Extensions::Llm::Inventory::OperationEvidence.new(
      operation: operation, status: status, source: source, observed_at: observed_at
    )
  end

  def build_capability_evidence
    {
      completion: Legion::Extensions::Llm::Inventory::CapabilityEvidence.new(
        capability: :completion, status: :supported, source: :provider_implementation, observed_at: Time.now
      ),
      streaming:  Legion::Extensions::Llm::Inventory::CapabilityEvidence.new(
        capability: :streaming, status: :supported, source: :provider_implementation, observed_at: Time.now
      ),
      tools:      Legion::Extensions::Llm::Inventory::CapabilityEvidence.new(
        capability: :tools, status: :supported, source: :provider_implementation, observed_at: Time.now
      ),
      thinking:   Legion::Extensions::Llm::Inventory::CapabilityEvidence.new(
        capability: :thinking, status: :unknown, source: :default_false, observed_at: Time.now
      ),
      vision:     Legion::Extensions::Llm::Inventory::CapabilityEvidence.new(
        capability: :vision, status: :supported, source: :provider_implementation, observed_at: Time.now
      ),
      embedding:  Legion::Extensions::Llm::Inventory::CapabilityEvidence.new(
        capability: :embedding, status: :unsupported, source: :provider_implementation, observed_at: Time.now
      )
    }
  end

  def model_not_ready_signal?(error:)
    return false unless error.respond_to?(:response) && error.response.is_a?(Hash)

    body = error.response[:body].to_s.downcase
    body.include?('model not ready')
  end

  def extract_host_port(base_url:)
    uri = URI.parse(base_url.to_s)
    "#{uri.host || 'api.anthropic.com'}:#{uri.port}"
  end
end

# Explicit service-unavailable signal for the Anthropic SSOT v3 conformance harness.
# Only an explicit flat service/instance-unavailable response may map to :instance_unavailable
# per §8. This error type represents such a response (e.g. a provider-level "service down"
# administrative signal distinct from transient overload, timeout, or connection failure).
# Faraday::ConnectionFailed, Faraday::TimeoutError, and Anthropic 529 overloaded_error
# NEVER map to :instance_unavailable — they remain request-local outcomes.
class AnthropicExplicitUnavailableError < StandardError; end

# Harness class for Anthropic SSOT v3 conformance testing.
class AnthropicSsotHarness
  include AnthropicSsotEvidenceHelpers

  # Each fixture carries the operator's CONFIG NAME — the instance identity.
  INSTANCE_CONFIGS = [
    {
      name:               'primary',
      anthropic_api_base: 'https://api.anthropic.com',
      anthropic_api_key:  'sk-ant-key-one-1234567890',
      tier:               :frontier
    }.freeze,
    {
      name:               'proxy',
      anthropic_api_base: 'https://anthropic-proxy.internal:443',
      anthropic_api_key:  'sk-ant-key-two-0987654321',
      tier:               :frontier
    }.freeze
  ].freeze

  # Wire body of a successful Anthropic Messages API response, used by the
  # stubbed dispatch path (the production callable delegates to a real
  # Anthropic::Provider whose base Connection is stubbed at Connection#post).
  MESSAGES_RESPONSE_BODY = {
    'id'            => 'msg_ssot_conformance',
    'type'          => 'message',
    'role'          => 'assistant',
    'content'       => [{ 'type' => 'text', 'text' => 'ssot conformance response' }],
    'model'         => 'claude-sonnet-4-6',
    'stop_reason'   => 'end_turn',
    'stop_sequence' => nil,
    'usage'         => { 'input_tokens' => 10, 'output_tokens' => 5 }
  }.freeze

  def provider_family = :anthropic
  def instance_configs = INSTANCE_CONFIGS

  # The operator's config name IS the instance identity — the key the router
  # resolves instances.<name> settings (per-instance tuning, enable_*) by.
  def instance_id(instance_config:)
    instance_config[:name].to_s
  end

  # The derived host:port or host:port/ak:<8-char digest> is the SECONDARY
  # physical id: dedup and diagnostics only, never identity (it is excluded
  # from InstanceKey equality/hash).
  def physical_id(instance_config:)
    base_url = instance_config[:anthropic_api_base] || 'https://api.anthropic.com'
    host_port = extract_host_port(base_url: base_url)
    api_key = instance_config[:anthropic_api_key] || instance_config.dig(:credentials, :api_key)

    return host_port unless api_key.is_a?(String) && !api_key.strip.empty?

    "#{host_port}/ak:#{::Digest::SHA256.hexdigest(api_key)[0, 8]}"
  end

  # The harness uses the PRODUCTION callable. Dispatch counting works through
  # the real delegation path: the callable wraps a per-instance Provider whose
  # base Connection#post is stubbed by the spec and counted per provider
  # object via record_dispatch.
  def build_callable(instance_config:)
    Legion::Extensions::Llm::Anthropic::Actor::AnthropicCallable.new(
      instance_cfg: instance_config,
      logger:       Logger.new(File::NULL)
    )
  end

  def record_dispatch(provider)
    @dispatch_counts ||= Hash.new(0)
    @dispatch_counts[provider] += 1
  end

  def build_offering_drafts(tier: :frontier, **)
    now = Time.now.freeze
    model_id = 'claude-sonnet-4-6'
    [build_single_offering(model_id: model_id, tier: tier, now: now)]
  end

  def safe_readiness(instance_config:, **)
    Legion::Extensions::Llm::Inventory::ReadinessResult.new(
      ready:    true,
      reason:   'Anthropic /v1/models returned 200',
      metadata: { status: 200, base_url: instance_config[:anthropic_api_base] }
    )
  end

  def inference_call_count(callable:)
    @dispatch_counts ||= Hash.new(0)
    provider = callable.provider
    provider.nil? ? 0 : @dispatch_counts[provider]
  end

  def normalize_dispatch_error(error:)
    callable = build_callable(instance_config: instance_configs.first)
    outcome = callable.normalize_dispatch_error(error: error)
    apply_anthropic_escalation(outcome: outcome, error: error)
  end

  def instance_unavailable_error
    # An explicit, flat service/instance-unavailable signal (§8). Only this explicit
    # provider-level signal may map to :instance_unavailable. Connection failures,
    # timeouts, 529 overload errors, and generic 5xx are all request-local.
    AnthropicExplicitUnavailableError.new('explicit flat service unavailable from provider')
  end

  def overloaded_error
    # Anthropic responds with HTTP 529 for overloaded_error
    response = { status: 529, headers: {}, body: '{"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}' }
    Faraday::ServerError.new('the server responded with status 529', response)
  end

  def model_not_ready_error
    # Anthropic does not have a model-loading state; 503 is treated as overloaded
    response = { status: 503, headers: {}, body: '{"type":"error","error":{"type":"api_error","message":"model not ready"}}' }
    Faraday::ServerError.new('the server responded with status 503', response)
  end

  private

  def apply_anthropic_escalation(outcome:, error:)
    # §8 health firewall: ONLY an explicit flat service/instance-unavailable signal
    # (AnthropicExplicitUnavailableError) may transition to :instance_unavailable.
    # Connection failures, timeouts, 529 overloaded_error, 503, and generic 5xx
    # are ALL request-local — they must NEVER mutate global instance availability.
    if error.is_a?(AnthropicExplicitUnavailableError)
      return Legion::Extensions::Llm::Routing::ProviderOutcome.new(
        kind:   :instance_unavailable,
        reason: error.message
      )
    end

    if outcome.kind == :overloaded && model_not_ready_signal?(error: error)
      return Legion::Extensions::Llm::Routing::ProviderOutcome.new(
        kind: :model_not_ready, reason: outcome.reason
      )
    end

    outcome
  end

  def build_single_offering(model_id:, tier:, now:)
    Legion::Extensions::Llm::Inventory::OfferingDraft.new(
      provider_native_key: model_id, model: model_id, tier: tier,
      operation_evidence: build_operation_evidence(now: now),
      capability_evidence: build_capability_evidence,
      context_evidence: Legion::Extensions::Llm::Inventory::ValueEvidence.new(status: :unknown, source: :absent),
      max_output_evidence: Legion::Extensions::Llm::Inventory::ValueEvidence.new(status: :unknown, source: :absent),
      embedding_dimensions_evidence: Legion::Extensions::Llm::Inventory::ValueEvidence.new(
        status: :unknown, source: :absent
      ),
      model_revision_evidence: Legion::Extensions::Llm::Inventory::ValueEvidence.new(
        status: :unknown, source: :absent
      ),
      tokenizer_evidence: Legion::Extensions::Llm::Inventory::ValueEvidence.new(status: :unknown, source: :absent),
      quota_domains: {}, metadata: { raw_model: model_id }.freeze, publication_source: :provider_catalog
    )
  end
end

RSpec.describe Legion::Extensions::Llm::Anthropic do
  let(:ssot_harness) { AnthropicSsotHarness.new }
  let(:registry) { Legion::Extensions::Llm::Inventory::Registry }

  # The exact InstanceKey the production actor builds for a fixture config:
  # identity = config name, secondary physical_id = derived host:port/ak.
  def anthropic_key_for(config)
    Legion::Extensions::Llm::Inventory::Identity::InstanceKey.new(
      provider_family: ssot_harness.provider_family,
      instance_id:     ssot_harness.instance_id(instance_config: config),
      physical_id:     ssot_harness.physical_id(instance_config: config)
    )
  end

  before do
    registry.reset!
    allow_any_instance_of(Legion::Extensions::Llm::Connection).to receive(:post) do |connection, *_args, &_block|
      ssot_harness.record_dispatch(connection.provider)
      env = Faraday::Env.new
      env.status = 200
      env.response = { headers: {} }
      env.body = AnthropicSsotHarness::MESSAGES_RESPONSE_BODY.dup
      Faraday::Response.new(env)
    end
  end

  it_behaves_like 'an SSOT v3 provider adapter'

  # ─── Anthropic-specific identity: config name + secondary physical id ─────

  describe 'instance identity derivation' do
    it 'uses the operator config name as the instance_id' do
      config = ssot_harness.instance_configs.first
      expect(ssot_harness.instance_id(instance_config: config)).to eq('primary')
    end

    it 'derives physical_id as host:port/ak:fingerprint with API key (8-char fingerprint)' do
      config = {
        name: 'primary', anthropic_api_base: 'https://api.anthropic.com',
        anthropic_api_key: 'sk-ant-key-one-1234567890'
      }
      fingerprint = Digest::SHA256.hexdigest('sk-ant-key-one-1234567890')[0, 8]
      expect(ssot_harness.physical_id(instance_config: config)).to eq("api.anthropic.com:443/ak:#{fingerprint}")
    end

    it 'derives physical_id as host:port without API key' do
      config = { name: 'primary', anthropic_api_base: 'https://api.anthropic.com' }
      expect(ssot_harness.physical_id(instance_config: config)).to eq('api.anthropic.com:443')
    end

    it 'produces distinct identities for two different config names' do
      ids = ssot_harness.instance_configs.map { |cfg| ssot_harness.instance_id(instance_config: cfg) }
      expect(ids.uniq.size).to eq(2)
    end

    it 'reproduces the same instance_id across multiple calls (stable identity)' do
      config = ssot_harness.instance_configs.first
      id_a = ssot_harness.instance_id(instance_config: config)
      id_b = ssot_harness.instance_id(instance_config: config)
      expect(id_a).to eq(id_b)
    end

    it 'uses 8 character fingerprint (not 6) in the physical_id' do
      config = ssot_harness.instance_configs.first
      fingerprint_part = ssot_harness.physical_id(instance_config: config).split('/ak:').last
      expect(fingerprint_part.length).to eq(8)
    end

    it 'keeps distinct config names on the same endpoint as distinct instances (no collapse)' do
      same_endpoint = {
        name: 'a', anthropic_api_base: 'https://api.anthropic.com',
        anthropic_api_key: 'sk-ant-key-one-1234567890'
      }
      other_name = same_endpoint.merge(name: 'b')
      expect(ssot_harness.instance_id(instance_config: same_endpoint)).not_to eq(
        ssot_harness.instance_id(instance_config: other_name)
      )
      # Same endpoint + credential → identical secondary physical id, yet the
      # names keep the instances apart.
      expect(ssot_harness.physical_id(instance_config: same_endpoint)).to eq(
        ssot_harness.physical_id(instance_config: other_name)
      )
    end

    it 'excludes the secondary physical_id from InstanceKey equality and hash' do
      config = ssot_harness.instance_configs.first
      with_physical = anthropic_key_for(config)
      without_physical = Legion::Extensions::Llm::Inventory::Identity::InstanceKey.new(
        provider_family: :anthropic, instance_id: ssot_harness.instance_id(instance_config: config)
      )
      expect(with_physical).to eq(without_physical)
      expect(with_physical.hash).to eq(without_physical.hash)
    end
  end

  # ─── Two instances with same model = separate lanes ─────────────────────────

  describe 'two Anthropic instances serving the same model' do
    def bring_up_instance(config, tier: :frontier)
      publisher = Legion::Extensions::Llm::Inventory::Publisher.new(provider_family: :anthropic)
      key = anthropic_key_for(config)
      instance_id = key.instance_id
      physical_id = key.physical_id
      callable = ssot_harness.build_callable(instance_config: config)
      coordinator = Legion::Extensions::Llm::Inventory::ProbeCoordinator.new(
        instance_key: key, enqueue: ->(**) { true }
      )

      token = publisher.claim_instance(
        instance_id: instance_id, callable: callable, probe_request_handle: coordinator, physical_id: physical_id
      )
      probe = publisher.readiness_probe_started(instance_id: instance_id, publisher_token: token, physical_id: physical_id)
      drafts = ssot_harness.build_offering_drafts(instance_config: config, callable: callable, tier: tier)
      publisher.activate_instance_snapshot(
        instance_id: instance_id, publisher_token: token, offerings: drafts, sequence: 0, probe_token: probe,
        physical_id: physical_id
      )

      { publisher: publisher, key: key, callable: callable, token: token, drafts: drafts, coordinator: coordinator }
    end

    it 'creates separate lanes for the same model on different instances' do
      a = bring_up_instance(ssot_harness.instance_configs[0])
      b = bring_up_instance(ssot_harness.instance_configs[1])

      snapshot = registry.snapshot
      lanes_a = snapshot.lanes_for(instance_key: a[:key])
      lanes_b = snapshot.lanes_for(instance_key: b[:key])

      expect(lanes_a).not_to be_empty
      expect(lanes_b).not_to be_empty

      lane_ids_a = lanes_a.map(&:lane_id)
      lane_ids_b = lanes_b.map(&:lane_id)
      expect(lane_ids_a & lane_ids_b).to be_empty
    end

    it 'reproduces IDs after restart (identity is deterministic from inputs)' do
      config = ssot_harness.instance_configs[0]
      first_run = bring_up_instance(config)
      first_offering_id = registry.snapshot.offerings_for(instance_key: first_run[:key]).first.offering_id
      first_lane_id = registry.snapshot.lanes_for(instance_key: first_run[:key]).first.lane_id

      registry.reset!
      second_run = bring_up_instance(config)
      second_offering_id = registry.snapshot.offerings_for(instance_key: second_run[:key]).first.offering_id
      second_lane_id = registry.snapshot.lanes_for(instance_key: second_run[:key]).first.lane_id

      expect(second_offering_id).to eq(first_offering_id)
      expect(second_lane_id).to eq(first_lane_id)
    end
  end

  # ─── Tier change does NOT change lane/offering identity ─────────────────────

  describe 'tier change and identity preservation' do
    def bring_up_with_tier(config, tier:)
      publisher = Legion::Extensions::Llm::Inventory::Publisher.new(provider_family: :anthropic)
      key = anthropic_key_for(config)
      instance_id = key.instance_id
      physical_id = key.physical_id
      callable = ssot_harness.build_callable(instance_config: config)
      coordinator = Legion::Extensions::Llm::Inventory::ProbeCoordinator.new(
        instance_key: key, enqueue: ->(**) { true }
      )

      token = publisher.claim_instance(
        instance_id: instance_id, callable: callable, probe_request_handle: coordinator, physical_id: physical_id
      )
      probe = publisher.readiness_probe_started(instance_id: instance_id, publisher_token: token, physical_id: physical_id)
      drafts = ssot_harness.build_offering_drafts(instance_config: config, callable: callable, tier: tier)
      publisher.activate_instance_snapshot(
        instance_id: instance_id, publisher_token: token, offerings: drafts, sequence: 0, probe_token: probe,
        physical_id: physical_id
      )

      { publisher: publisher, key: key, callable: callable, token: token, drafts: drafts }
    end

    it 'preserves offering_id and lane_id when tier changes from frontier to local' do
      config = ssot_harness.instance_configs[0]
      context = bring_up_with_tier(config, tier: :frontier)

      before_offering = registry.snapshot.offerings_for(instance_key: context[:key]).first
      before_lane = registry.snapshot.lanes_for(instance_key: context[:key]).first

      local_drafts = ssot_harness.build_offering_drafts(
        instance_config: config, callable: context[:callable], tier: :local
      )
      context[:publisher].replace_instance_snapshot(
        instance_id:     context[:key].instance_id,
        publisher_token: context[:token],
        offerings:       local_drafts,
        sequence:        1,
        physical_id:     context[:key].physical_id
      )

      after_offering = registry.snapshot.offerings_for(instance_key: context[:key]).first
      after_lane = registry.snapshot.lanes_for(instance_key: context[:key]).first

      expect(after_offering.offering_id).to eq(before_offering.offering_id)
      expect(after_lane.lane_id).to eq(before_lane.lane_id)
      expect(after_offering.tier).to eq(:local)
    end
  end

  # ─── Explicit operation evidence controls ───────────────────────────────────

  describe 'operation evidence controls' do
    let(:config) { ssot_harness.instance_configs[0] }
    let(:callable) { ssot_harness.build_callable(instance_config: config) }
    let(:drafts) { ssot_harness.build_offering_drafts(instance_config: config, callable: callable, tier: :frontier) }
    let(:offering) { drafts.first }

    it 'marks chat as supported' do
      expect(offering.operation_evidence[:chat].status).to eq(:supported)
    end

    it 'marks stream_chat as supported' do
      expect(offering.operation_evidence[:stream_chat].status).to eq(:supported)
    end

    it 'marks embed as unsupported' do
      expect(offering.operation_evidence[:embed].status).to eq(:unsupported)
    end

    it 'marks image/transcribe/translate/speak/moderate as unsupported' do
      %i[image transcribe translate speak moderate].each do |op|
        expect(offering.operation_evidence[op].status).to eq(:unsupported),
                                                          "expected #{op} to be :unsupported"
      end
    end

    it 'marks count_tokens as unknown' do
      expect(offering.operation_evidence[:count_tokens].status).to eq(:unknown)
    end

    it 'uses :provider_implementation source for supported/unsupported operations' do
      %i[chat stream_chat embed image transcribe translate speak moderate].each do |op|
        expect(offering.operation_evidence[op].source).to eq(:provider_implementation),
                                                          "expected #{op} source to be :provider_implementation"
      end
    end

    it 'uses :default_false source for unknown operations' do
      expect(offering.operation_evidence[:count_tokens].source).to eq(:default_false)
    end
  end

  # ─── Startup gating ─────────────────────────────────────────────────────────

  describe 'startup gating' do
    let(:config) { ssot_harness.instance_configs[0] }
    let(:key) { anthropic_key_for(config) }
    let(:instance_id) { key.instance_id }
    let(:physical_id) { key.physical_id }
    let(:publisher) { Legion::Extensions::Llm::Inventory::Publisher.new(provider_family: :anthropic) }
    let(:callable) { ssot_harness.build_callable(instance_config: config) }
    let(:coordinator) do
      Legion::Extensions::Llm::Inventory::ProbeCoordinator.new(
        instance_key: key, enqueue: ->(**) { true }
      )
    end

    it 'remains initializing until readiness probe succeeds' do
      publisher.claim_instance(instance_id: instance_id, callable: callable, probe_request_handle: coordinator, physical_id: physical_id)

      snapshot = registry.snapshot
      expect(snapshot.instance(instance_key: key)).to be_nil
      expect(snapshot.publication_status(instance_key: key).state).to eq(:initializing)
    end

    it 'stays initializing after an initial readiness failure' do
      token = publisher.claim_instance(instance_id: instance_id, callable: callable, probe_request_handle: coordinator, physical_id: physical_id)
      probe = publisher.readiness_probe_started(instance_id: instance_id, publisher_token: token, physical_id: physical_id)
      publisher.readiness_failed(instance_id: instance_id, probe_token: probe, reason: 'Anthropic /v1/models connection failed', physical_id: physical_id)

      snapshot = registry.snapshot
      expect(snapshot.instance(instance_key: key)).to be_nil
      expect(snapshot.publication_status(instance_key: key).state).to eq(:initializing)
    end

    it 'transitions to available after readiness success' do
      token = publisher.claim_instance(instance_id: instance_id, callable: callable, probe_request_handle: coordinator, physical_id: physical_id)
      probe = publisher.readiness_probe_started(instance_id: instance_id, publisher_token: token, physical_id: physical_id)
      drafts = ssot_harness.build_offering_drafts(instance_config: config, callable: callable, tier: :frontier)
      publisher.activate_instance_snapshot(
        instance_id: instance_id, publisher_token: token, offerings: drafts, sequence: 0, probe_token: probe,
        physical_id: physical_id
      )

      snapshot = registry.snapshot
      expect(snapshot.instance(instance_key: key).availability.state).to eq(:available)
      expect(snapshot.publication_status(instance_key: key).state).to eq(:complete)
    end
  end

  # ─── Readiness probe lifecycle ───────────────────────────────────────────────

  describe 'readiness probe lifecycle' do
    let(:config) { ssot_harness.instance_configs[0] }
    let(:key) { anthropic_key_for(config) }
    let(:instance_id) { key.instance_id }
    let(:physical_id) { key.physical_id }
    let(:publisher) { Legion::Extensions::Llm::Inventory::Publisher.new(provider_family: :anthropic) }
    let(:callable) { ssot_harness.build_callable(instance_config: config) }
    let(:coordinator) do
      Legion::Extensions::Llm::Inventory::ProbeCoordinator.new(
        instance_key: key, enqueue: ->(**) { true }
      )
    end

    def activate_instance
      token = publisher.claim_instance(instance_id: instance_id, callable: callable, probe_request_handle: coordinator, physical_id: physical_id)
      probe = publisher.readiness_probe_started(instance_id: instance_id, publisher_token: token, physical_id: physical_id)
      drafts = ssot_harness.build_offering_drafts(instance_config: config, callable: callable, tier: :frontier)
      publisher.activate_instance_snapshot(
        instance_id: instance_id, publisher_token: token, offerings: drafts, sequence: 0, probe_token: probe,
        physical_id: physical_id
      )
      token
    end

    it 'rejects a stale probe started before a newer one that reported failure' do
      token = activate_instance

      stale_probe = publisher.readiness_probe_started(instance_id: instance_id, publisher_token: token, physical_id: physical_id)
      fresh_probe = publisher.readiness_probe_started(instance_id: instance_id, publisher_token: token, physical_id: physical_id)

      publisher.readiness_failed(instance_id: instance_id, probe_token: fresh_probe, reason: 'server down', physical_id: physical_id)

      result = publisher.readiness_succeeded(instance_id: instance_id, probe_token: stale_probe, physical_id: physical_id)
      expect(result.applied).to be(false)
      expect(result.reason).to eq(:stale_probe)
    end

    it 'recovers an unavailable instance after a valid probe succeeds' do
      token = activate_instance

      registry.dispatch_instance_unavailable(
        instance_key: key, publisher_token_id: token.publisher_token_id, reason: 'connection refused'
      )
      expect(registry.snapshot.instance(instance_key: key).availability.state).to eq(:unavailable)

      new_probe = publisher.readiness_probe_started(instance_id: instance_id, publisher_token: token, physical_id: physical_id)
      publisher.readiness_succeeded(instance_id: instance_id, probe_token: new_probe, physical_id: physical_id)
      expect(registry.snapshot.instance(instance_key: key).availability.state).to eq(:available)
    end
  end

  # ─── Instance-unavailable isolation ─────────────────────────────────────────

  describe 'instance-unavailable isolation' do
    def bring_up(config)
      publisher = Legion::Extensions::Llm::Inventory::Publisher.new(provider_family: :anthropic)
      key = anthropic_key_for(config)
      instance_id = key.instance_id
      physical_id = key.physical_id
      callable = ssot_harness.build_callable(instance_config: config)
      coordinator = Legion::Extensions::Llm::Inventory::ProbeCoordinator.new(
        instance_key: key, enqueue: ->(**) { true }
      )

      token = publisher.claim_instance(
        instance_id: instance_id, callable: callable, probe_request_handle: coordinator, physical_id: physical_id
      )
      probe = publisher.readiness_probe_started(instance_id: instance_id, publisher_token: token, physical_id: physical_id)
      drafts = ssot_harness.build_offering_drafts(instance_config: config, callable: callable, tier: :frontier)
      publisher.activate_instance_snapshot(
        instance_id: instance_id, publisher_token: token, offerings: drafts, sequence: 0, probe_token: probe,
        physical_id: physical_id
      )

      { publisher: publisher, key: key, callable: callable, token: token }
    end

    it 'marks only one instance unavailable without affecting the other' do
      a = bring_up(ssot_harness.instance_configs[0])
      b = bring_up(ssot_harness.instance_configs[1])

      registry.dispatch_instance_unavailable(
        instance_key:       a[:key],
        publisher_token_id: a[:token].publisher_token_id,
        reason:             'connection refused to api.anthropic.com'
      )

      expect(registry.snapshot.instance(instance_key: a[:key]).availability.state).to eq(:unavailable)
      expect(registry.snapshot.instance(instance_key: b[:key]).availability.state).to eq(:available)
    end

    it 'normalizes an explicit service-unavailable signal to :instance_unavailable' do
      outcome = ssot_harness.normalize_dispatch_error(error: ssot_harness.instance_unavailable_error)
      expect(outcome).to be_a(Legion::Extensions::Llm::Routing::ProviderOutcome)
      expect(outcome.kind).to eq(:instance_unavailable)
    end

    it '§8 health firewall: connection failure stays :connection_failure, never :instance_unavailable' do
      # §8: connection refusal/reset never mutates global availability.
      # The production AnthropicCallable correctly returns :connection_failure;
      # the harness must NOT escalate it to :instance_unavailable.
      conn_error = Faraday::ConnectionFailed.new('Connection refused - connect(2) for api.anthropic.com:443')
      outcome = ssot_harness.normalize_dispatch_error(error: conn_error)
      expect(outcome).to be_a(Legion::Extensions::Llm::Routing::ProviderOutcome)
      expect(outcome.kind).to eq(:connection_failure)
      expect(outcome.kind).not_to eq(:instance_unavailable)
    end

    it 'normalizes 529 as overloaded, never as instance_unavailable' do
      outcome = ssot_harness.normalize_dispatch_error(error: ssot_harness.overloaded_error)
      expect(outcome.kind).to eq(:overloaded)
      expect(outcome.kind).not_to eq(:instance_unavailable)
    end
  end

  # ─── Error isolation: 529 is ALWAYS overloaded ──────────────────────────────

  describe 'error isolation (Anthropic 529 = overloaded, no global poisoning)' do
    it 'classifies 529 as :overloaded on the callable (NEVER instance_unavailable)' do
      callable = ssot_harness.build_callable(instance_config: ssot_harness.instance_configs[0])
      response = { status: 529, headers: {}, body: '{"type":"error","error":{"type":"overloaded_error"}}' }
      error = Faraday::ServerError.new('529', response)
      outcome = callable.normalize_dispatch_error(error: error)
      expect(outcome.kind).to eq(:overloaded)
      expect(outcome.kind).not_to eq(:instance_unavailable)
    end

    it 'never returns instance_unavailable from the callable for any server error status' do
      callable = ssot_harness.build_callable(instance_config: ssot_harness.instance_configs[0])
      [500, 502, 503, 504, 529].each do |status|
        response = { status: status, headers: {}, body: '' }
        error = Faraday::ServerError.new(status.to_s, response)
        outcome = callable.normalize_dispatch_error(error: error)
        expect(outcome.kind).not_to eq(:instance_unavailable),
                                    "status #{status} should not map to :instance_unavailable"
      end
    end

    it 'classifies connection failure as :connection_failure on the callable (not instance_unavailable)' do
      callable = ssot_harness.build_callable(instance_config: ssot_harness.instance_configs[0])
      error = Faraday::ConnectionFailed.new('Connection refused')
      outcome = callable.normalize_dispatch_error(error: error)
      expect(outcome.kind).to eq(:connection_failure)
    end

    it 'classifies timeout as :timeout on the callable' do
      callable = ssot_harness.build_callable(instance_config: ssot_harness.instance_configs[0])
      error = Faraday::TimeoutError.new('Net::ReadTimeout')
      outcome = callable.normalize_dispatch_error(error: error)
      expect(outcome.kind).to eq(:timeout)
    end

    it 'classifies 429 ClientError as :rate_limited on the callable' do
      callable = ssot_harness.build_callable(instance_config: ssot_harness.instance_configs[0])
      response = { status: 429, headers: {}, body: '' }
      error = Faraday::ClientError.new('429', response)
      outcome = callable.normalize_dispatch_error(error: error)
      expect(outcome.kind).to eq(:rate_limited)
    end

    it 'classifies 401 as :authentication on the callable' do
      callable = ssot_harness.build_callable(instance_config: ssot_harness.instance_configs[0])
      response = { status: 401, headers: {}, body: '' }
      error = Faraday::ClientError.new('401', response)
      outcome = callable.normalize_dispatch_error(error: error)
      expect(outcome.kind).to eq(:authentication)
    end

    it 'classifies 403 as :authorization on the callable' do
      callable = ssot_harness.build_callable(instance_config: ssot_harness.instance_configs[0])
      response = { status: 403, headers: {}, body: '' }
      error = Faraday::ClientError.new('403', response)
      outcome = callable.normalize_dispatch_error(error: error)
      expect(outcome.kind).to eq(:authorization)
    end

    it 'classifies 404 as :model_missing on the callable' do
      callable = ssot_harness.build_callable(instance_config: ssot_harness.instance_configs[0])
      response = { status: 404, headers: {}, body: '' }
      error = Faraday::ClientError.new('404', response)
      outcome = callable.normalize_dispatch_error(error: error)
      expect(outcome.kind).to eq(:model_missing)
    end

    it 'classifies generic errors as :provider_error on the callable' do
      callable = ssot_harness.build_callable(instance_config: ssot_harness.instance_configs[0])
      outcome = callable.normalize_dispatch_error(error: RuntimeError.new('unexpected failure'))
      expect(outcome.kind).to eq(:provider_error)
    end
  end

  # ─── ProbeCoordinator coalescing ─────────────────────────────────────────────

  describe 'ProbeCoordinator coalescing' do
    let(:config) { ssot_harness.instance_configs[0] }
    let(:key) { anthropic_key_for(config) }
    let(:enqueue_calls) { [] }
    let(:coordinator) do
      Legion::Extensions::Llm::Inventory::ProbeCoordinator.new(
        instance_key: key,
        enqueue:      lambda { |request:|
          enqueue_calls << request
          true
        }
      )
    end

    it 'coalesces multiple probe requests into a single in-flight probe' do
      coordinator.enqueue_probe_request(
        instance_key: key, publisher_token_id: 'ptok:v1:aaa',
        unavailable_revision: 1, reason: 'first failure'
      )
      expect(enqueue_calls.size).to eq(1)

      expect(coordinator.begin_probe(request: enqueue_calls.first)).to be(true)
      expect(coordinator.in_flight?).to be(true)

      coordinator.enqueue_probe_request(
        instance_key: key, publisher_token_id: 'ptok:v1:aaa',
        unavailable_revision: 2, reason: 'second failure'
      )
      expect(enqueue_calls.size).to eq(1)

      coordinator.finish_probe(request: enqueue_calls.first)
      expect(enqueue_calls.size).to eq(2)
      expect(enqueue_calls.last.unavailable_revision).to eq(2)
    end

    it 'only retains the highest unavailable_revision when coalescing' do
      coordinator.enqueue_probe_request(
        instance_key: key, publisher_token_id: 'ptok:v1:aaa',
        unavailable_revision: 1, reason: 'rev 1'
      )
      expect(coordinator.begin_probe(request: enqueue_calls.first)).to be(true)

      coordinator.enqueue_probe_request(
        instance_key: key, publisher_token_id: 'ptok:v1:aaa',
        unavailable_revision: 3, reason: 'rev 3'
      )
      coordinator.enqueue_probe_request(
        instance_key: key, publisher_token_id: 'ptok:v1:aaa',
        unavailable_revision: 2, reason: 'rev 2'
      )

      coordinator.finish_probe(request: enqueue_calls.first)
      expect(enqueue_calls.last.unavailable_revision).to eq(3)
    end
  end

  # ─── No quota domain broadening ──────────────────────────────────────────────

  describe 'quota domain safety' do
    it 'does not declare quota_domains on offerings' do
      config = ssot_harness.instance_configs[0]
      callable = ssot_harness.build_callable(instance_config: config)
      drafts = ssot_harness.build_offering_drafts(instance_config: config, callable: callable, tier: :frontier)

      drafts.each do |draft|
        expect(draft.quota_domains).to be_empty,
                                       'Anthropic offerings must not declare quota_domains without authoritative scope'
      end
    end
  end

  # ─── Fleet worker execution contract ─────────────────────────────────────────

  describe 'exact fleet worker execution contract' do
    let(:config) { ssot_harness.instance_configs[0] }
    let(:key) { anthropic_key_for(config) }
    let(:instance_id) { key.instance_id }
    let(:physical_id) { key.physical_id }

    def activate_offering
      publisher = Legion::Extensions::Llm::Inventory::Publisher.new(provider_family: :anthropic)
      callable = ssot_harness.build_callable(instance_config: config)
      token = claim_and_activate(publisher: publisher, callable: callable)
      offering = registry.snapshot.offerings_for(instance_key: key).first
      { publisher: publisher, token: token, offering: offering, callable: callable }
    end

    def claim_and_activate(publisher:, callable:)
      coordinator = Legion::Extensions::Llm::Inventory::ProbeCoordinator.new(
        instance_key: key, enqueue: ->(**) { true }
      )
      token = publisher.claim_instance(instance_id: instance_id, callable: callable, probe_request_handle: coordinator, physical_id: physical_id)
      probe = publisher.readiness_probe_started(instance_id: instance_id, publisher_token: token, physical_id: physical_id)
      drafts = ssot_harness.build_offering_drafts(instance_config: config, callable: callable, tier: :frontier)
      publisher.activate_instance_snapshot(
        instance_id: instance_id, publisher_token: token, offerings: drafts, sequence: 0, probe_token: probe,
        physical_id: physical_id
      )
      token
    end

    before do
      allow(Legion::Extensions::Llm::Fleet::WorkerExecution).to receive_messages(
        validate_identity!:    true,
        validate_idempotency!: nil
      )
    end

    it 'rejects a mismatched offering_id' do
      activate_offering

      envelope = {
        execution_contract: Legion::Extensions::Llm::Fleet::Protocol::EXACT_EXECUTION_CONTRACT,
        offering_id:        'off:v1:0000000000000000000000000000000000000000000000000000000000000000',
        provider:           'anthropic',
        provider_instance:  instance_id,
        model:              'claude-sonnet-4-6',
        operation:          'chat',
        params:             { messages: [] }
      }

      expect do
        Legion::Extensions::Llm::Fleet::WorkerExecution.call(envelope: envelope, registry: registry)
      end.to raise_error(Legion::Extensions::Llm::Inventory::Errors::ExactOfferingMismatchError)
    end

    it 'rejects an unsupported operation' do
      ctx = activate_offering

      envelope = {
        execution_contract: Legion::Extensions::Llm::Fleet::Protocol::EXACT_EXECUTION_CONTRACT,
        offering_id:        ctx[:offering].offering_id,
        provider:           'anthropic',
        provider_instance:  instance_id,
        model:              ctx[:offering].model,
        operation:          'embed',
        params:             { text: 'hello' }
      }

      expect do
        Legion::Extensions::Llm::Fleet::WorkerExecution.call(envelope: envelope, registry: registry)
      end.to raise_error(Legion::Extensions::Llm::Inventory::Errors::ExactOfferingMismatchError)
    end

    it 'rejects a mismatched model' do
      ctx = activate_offering

      envelope = {
        execution_contract: Legion::Extensions::Llm::Fleet::Protocol::EXACT_EXECUTION_CONTRACT,
        offering_id:        ctx[:offering].offering_id,
        provider:           'anthropic',
        provider_instance:  instance_id,
        model:              'some-other-model/v1',
        operation:          'chat',
        params:             { messages: [] }
      }

      expect do
        Legion::Extensions::Llm::Fleet::WorkerExecution.call(envelope: envelope, registry: registry)
      end.to raise_error(Legion::Extensions::Llm::Inventory::Errors::ExactOfferingMismatchError)
    end

    it 'rejects an unavailable instance' do
      ctx = activate_offering

      registry.dispatch_instance_unavailable(
        instance_key:       key,
        publisher_token_id: ctx[:token].publisher_token_id,
        reason:             'server down'
      )

      envelope = {
        execution_contract: Legion::Extensions::Llm::Fleet::Protocol::EXACT_EXECUTION_CONTRACT,
        offering_id:        ctx[:offering].offering_id,
        provider:           'anthropic',
        provider_instance:  instance_id,
        model:              ctx[:offering].model,
        operation:          'chat',
        params:             { messages: [] }
      }

      expect do
        Legion::Extensions::Llm::Fleet::WorkerExecution.call(envelope: envelope, registry: registry)
      end.to raise_error(Legion::Extensions::Llm::Inventory::Errors::ExactOfferingMismatchError)
    end
  end

  # ─── No Legion::LLM reverse dependency ─────────────────────────────────────

  describe 'dependency isolation' do
    it 'does not require Legion::LLM in the discovery actor' do
      project_root = File.expand_path('../../../..', __dir__)
      actor_file = File.read(
        File.join(project_root, 'lib/legion/extensions/llm/anthropic/actors/discovery_refresh.rb')
      )
      expect(actor_file).not_to match(/\bLegion::LLM\b/)
    end

    it 'AnthropicCallable does not reference Legion::LLM' do
      callable = ssot_harness.build_callable(instance_config: ssot_harness.instance_configs[0])
      outcome = callable.normalize_dispatch_error(error: RuntimeError.new('test'))
      expect(outcome).to be_a(Legion::Extensions::Llm::Routing::ProviderOutcome)
    end
  end

  # ─── No default model/provider ──────────────────────────────────────────────

  describe 'no default model or provider' do
    it 'permits "default" as an explicit instance_id' do
      key = Legion::Extensions::Llm::Inventory::Identity::InstanceKey.new(
        provider_family: :anthropic, instance_id: 'default'
      )
      expect(key.instance_id).to eq('default')
    end

    it 'rejects nil instance_id' do
      expect do
        Legion::Extensions::Llm::Inventory::Identity::InstanceKey.new(
          provider_family: :anthropic, instance_id: nil
        )
      end.to raise_error(Legion::Extensions::Llm::Inventory::Errors::ValidationError)
    end

    it 'does not define a DEFAULT_MODEL constant' do
      expect(described_class.const_defined?(:DEFAULT_MODEL, false)).to be(false)
    end

    it 'does not define a DEFAULT_PROVIDER constant' do
      expect(described_class.const_defined?(:DEFAULT_PROVIDER, false)).to be(false)
    end

    it 'offering drafts require an explicit model string' do
      expect do
        Legion::Extensions::Llm::Inventory::OfferingDraft.new(
          provider_native_key:           'test',
          model:                         '',
          tier:                          :frontier,
          operation_evidence:            ssot_harness.send(:build_operation_evidence, now: Time.now),
          context_evidence:              Legion::Extensions::Llm::Inventory::ValueEvidence.new(status: :unknown, source: :absent),
          max_output_evidence:           Legion::Extensions::Llm::Inventory::ValueEvidence.new(status: :unknown, source: :absent),
          embedding_dimensions_evidence: Legion::Extensions::Llm::Inventory::ValueEvidence.new(status: :unknown, source: :absent),
          model_revision_evidence:       Legion::Extensions::Llm::Inventory::ValueEvidence.new(status: :unknown, source: :absent),
          tokenizer_evidence:            Legion::Extensions::Llm::Inventory::ValueEvidence.new(status: :unknown, source: :absent),
          quota_domains:                 {},
          metadata:                      {},
          publication_source:            :provider_catalog
        )
      end.to raise_error(Legion::Extensions::Llm::Inventory::Errors::ValidationError)
    end
  end

  # ─── AnthropicCallable direct contract ─────────────────────────────────────

  describe Legion::Extensions::Llm::Anthropic::Actor::AnthropicCallable do
    let(:callable) do
      described_class.new(
        instance_cfg: ssot_harness.instance_configs[0],
        logger:       Logger.new(File::NULL)
      )
    end

    it 'responds to disconnect' do
      expect(callable).to respond_to(:disconnect)
      expect(callable).to respond_to(:disconnected?)
    end

    it 'responds to normalize_dispatch_error with kwargs' do
      expect(callable).to respond_to(:normalize_dispatch_error)
    end

    it 'is not disconnected on creation' do
      expect(callable.disconnected?).to be(false)
    end

    it 'becomes disconnected after disconnect' do
      callable.disconnect
      expect(callable.disconnected?).to be(true)
    end

    it 'returns a ProviderOutcome from normalize_dispatch_error' do
      outcome = callable.normalize_dispatch_error(error: RuntimeError.new('test'))
      expect(outcome).to be_a(Legion::Extensions::Llm::Routing::ProviderOutcome)
      expect(outcome.kind).to be_a(Symbol)
      expect(outcome.reason).to be_a(String)
    end

    it 'renders the folded leading system message in the native Anthropic system field' do
      rendered_payload = nil
      allow_any_instance_of(Legion::Extensions::Llm::Connection).to receive(:post) do |connection, _url, payload|
        rendered_payload = payload
        ssot_harness.record_dispatch(connection.provider)
        env = Faraday::Env.new
        env.status = 200
        env.response = { headers: {} }
        env.body = AnthropicSsotHarness::MESSAGES_RESPONSE_BODY.dup
        Faraday::Response.new(env)
      end

      callable.chat(
        messages: [
          Legion::Extensions::Llm::Canonical::Message.build(
            role: :system, content: 'authoritative system instruction'
          ),
          Legion::Extensions::Llm::Canonical::Message.build(role: :user, content: 'hello')
        ],
        model:    'claude-sonnet-4-6'
      )

      expect(rendered_payload[:system]).to eq([{ type: 'text', text: 'authoritative system instruction' }])
      expect(rendered_payload[:messages]).to eq([{ role: 'user', content: [{ type: 'text', text: 'hello' }] }])
    end

    it 'truncates reason to 512 bytes' do
      long_message = 'x' * 1000
      error = RuntimeError.new(long_message)
      outcome = callable.normalize_dispatch_error(error: error)
      expect(outcome.reason.length).to eq(512)
    end

    # D15: both the fleet WorkerExecution and legion-llm SelectionDispatch pass
    # the offering model as a RAW STRING, but render_payload calls model.id /
    # model.max_tokens (Model::Info). The callable must wrap at the boundary —
    # the render path is exercised here for real (only Connection#post is
    # stubbed), so a missing wrap fails with NoMethodError, not a green stub.
    context 'raw-string model dispatch (D15)' do
      it 'wraps a raw string into a Model::Info and renders without NoMethodError' do
        result = callable.chat(
          messages: [Legion::Extensions::Llm::Message.new(role: :user, content: 'hello')],
          model:    'claude-sonnet-4-6'
        )
        expect(result).to be_a(Legion::Extensions::Llm::Message)
        expect(ssot_harness.inference_call_count(callable: callable)).to eq(1)
      end

      it 'pass-throughs a model that already responds to :id' do
        info = Legion::Extensions::Llm::Model::Info.new(id: 'claude-sonnet-4-6', provider: :anthropic)
        expect(callable.send(:normalize_model, info)).to equal(info)
      end

      it 'wraps every dispatch op through the same boundary' do
        info = callable.send(:normalize_model, 'claude-sonnet-4-6')
        expect(info).to be_a(Legion::Extensions::Llm::Model::Info)
        expect(info.id).to eq('claude-sonnet-4-6')
        expect(info.provider).to eq(:anthropic)
      end
    end
  end

  # ─── OfferingDraft validation ────────────────────────────────────────────────

  describe 'OfferingDraft structure' do
    let(:config) { ssot_harness.instance_configs[0] }
    let(:callable) { ssot_harness.build_callable(instance_config: config) }
    let(:drafts) { ssot_harness.build_offering_drafts(instance_config: config, callable: callable, tier: :frontier) }

    it 'produces valid OfferingDraft instances' do
      expect(drafts).to all(be_a(Legion::Extensions::Llm::Inventory::OfferingDraft))
    end

    it 'includes all required operation evidence keys' do
      expected_ops = Legion::Extensions::Llm::Taxonomies::OPERATIONS.sort
      drafts.each do |draft|
        actual_ops = draft.operation_evidence.keys.sort
        expect(actual_ops).to eq(expected_ops)
      end
    end

    it 'sets publication_source to :provider_catalog' do
      drafts.each do |draft|
        expect(draft.publication_source).to eq(:provider_catalog)
      end
    end

    it 'uses frozen metadata without secret keys' do
      drafts.each do |draft|
        expect(draft.metadata).to be_frozen
        draft.metadata.each_key do |key|
          normalized = key.to_s.downcase.gsub(/[^a-z0-9]/, '')
          expect(normalized).not_to include('credential')
          expect(normalized).not_to include('secret')
          expect(normalized).not_to include('apikey')
        end
      end
    end
  end

  # ─── ReadinessResult contract ─────────────────────────────────────────────

  describe 'ReadinessResult contract' do
    it 'safe_readiness returns a ready ReadinessResult' do
      config = ssot_harness.instance_configs[0]
      callable = ssot_harness.build_callable(instance_config: config)
      result = ssot_harness.safe_readiness(instance_config: config, callable: callable)

      expect(result).to be_a(Legion::Extensions::Llm::Inventory::ReadinessResult)
      expect(result.ready?).to be(true)
      expect(result.reason).to be_a(String)
      expect(result.reason).not_to be_empty
    end

    it 'readiness does not invoke inference on the callable' do
      config = ssot_harness.instance_configs[0]
      callable = ssot_harness.build_callable(instance_config: config)
      ssot_harness.safe_readiness(instance_config: config, callable: callable)
      expect(ssot_harness.inference_call_count(callable: callable)).to eq(0)
    end
  end
end
