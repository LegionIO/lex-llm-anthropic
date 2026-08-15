# frozen_string_literal: true

require 'digest'
require 'time'
require 'uri'
require 'faraday'

require 'legion/logging/helper'
require 'legion/extensions/llm/anthropic/provider'
require 'legion/extensions/llm/inventory/publisher'
require 'legion/extensions/llm/inventory/identity'
require 'legion/extensions/llm/inventory/records'
require 'legion/extensions/llm/inventory/evidence'
require 'legion/extensions/llm/inventory/probe_coordinator'
require 'legion/extensions/llm/inventory/scoped_refresher'
require 'legion/extensions/llm/routing/provider_outcome'
require 'legion/extensions/llm/taxonomies'
require 'legion/extensions/llm/capabilities'

actor_load_logger = Object.new.extend(Legion::Logging::Helper)
actor_load_logger.define_singleton_method(:lex_filename) { 'llm_anthropic' }

begin
  require 'legion/extensions/actors/every'
rescue LoadError => e
  actor_load_logger.handle_exception(e, level: :warn, handled: true,
                                          operation: 'anthropic.actor.discovery_refresh.load')
end

return unless defined?(Legion::Extensions::Actors::Every)

module Legion
  module Extensions
    module Llm
      module Anthropic
        module Actor
          # SSOT v3 periodic discovery actor for Anthropic provider instances.
          # Claims instances, discovers models via GET /v1/models (safe — no inference),
          # probes readiness via GET /v1/models, and publishes complete OfferingDraft
          # snapshots through Inventory::Publisher. Supports coalesced reactive probes
          # after dispatch-triggered instance_unavailable transitions.
          #
          # Per-instance runtime state (publisher token, ProbeCoordinator, sequence,
          # last offerings) lives in process-local memory behind a mutex — never in
          # Legion::Settings. The only settings writes are the plain-data health
          # display hash and capabilities list written after each registry commit.
          class DiscoveryRefresh < Legion::Extensions::Actors::Every
            include Legion::Extensions::Helpers::Lex
            include Legion::Logging::Helper

            # Per-instance capabilities advertised in the settings health display,
            # mirroring the legacy discover_instances output.
            INSTANCE_CAPABILITIES = %i[completion streaming vision tools].freeze

            def runner_class    = self.class
            def runner_function = 'manual'
            def run_now?        = true
            def use_runner?     = false
            def check_subtask?  = false
            def generate_task?  = false

            # Registered per-instance discovery cadence (nested under
            # instances.default by provider_settings). Never nil: the live
            # setting is registered with a default, and the registered default
            # is the floor if an operator nulls the live value.
            def time
              settings.dig(:instances, :default, :discovery_interval) ||
                Legion::Extensions::Llm::Anthropic.default_settings.dig(:instances, :default, :discovery_interval)
            end

            def manual
              if @initialized
                tick_refresh
              else
                initial_discovery
                @initialized = true
              end
            rescue StandardError => e
              handle_exception(e, level: :warn, operation: 'anthropic.actor.discovery_refresh')
            end

            def shutdown
              remove_all_instances
            rescue StandardError => e
              handle_exception(e, level: :warn, operation: 'anthropic.actor.discovery_refresh.shutdown')
            end

            private

            # ── Publisher ──────────────────────────────────────────────────────

            # The compatibility adapter projects committed snapshots into the old
            # coordinator inventory store for the mixed-version window; it
            # degrades to :not_loaded when that coordinator is not loaded.
            def publisher
              @publisher ||= Legion::Extensions::Llm::Inventory::Publisher.new(
                provider_family:       :anthropic,
                compatibility_adapter:
                                       Legion::Extensions::Llm::Inventory::ScopedRefresher::LegacyCoordinatorAdapter.new(
                                         provider_family: :anthropic
                                       )
              )
            end

            # ── Instance state (process-local memory, mutex-guarded) ─────────

            def state_mutex
              @state_mutex ||= Mutex.new
            end

            def with_instance_states
              state_mutex.synchronize do
                @instance_states ||= {}
                yield @instance_states
              end
            end

            # ── Initial discovery ─────────────────────────────────────────────

            def initial_discovery
              with_instance_states { @instance_states = {} }
              configured_instances.each do |name, instance_cfg|
                claim_and_activate_instance(name:, instance_cfg:)
              rescue StandardError => e
                handle_exception(e, level: :warn, operation: 'anthropic.actor.claim_instance', instance_name: name.to_s)
              end
            end

            def claim_and_activate_instance(name:, instance_cfg:)
              instance_id = derive_instance_id(instance_cfg:)
              instance_key = Legion::Extensions::Llm::Inventory::Identity::InstanceKey.new(
                provider_family: :anthropic, instance_id: instance_id
              )

              callable = AnthropicCallable.new(instance_cfg: instance_cfg, logger: log)
              probe_coordinator = Legion::Extensions::Llm::Inventory::ProbeCoordinator.new(
                instance_key: instance_key,
                enqueue:      build_probe_enqueue(instance_id:)
              )

              publisher_token = publisher.claim_instance(
                instance_id:          instance_id,
                callable:             callable,
                probe_request_handle: probe_coordinator
              )

              offerings = discover_offerings_for_instance(instance_cfg:, instance_key:)

              probe_token = publisher.readiness_probe_started(
                instance_id:     instance_id,
                publisher_token: publisher_token
              )

              readiness = check_readiness(instance_cfg:)

              if readiness.ready?
                publisher.activate_instance_snapshot(
                  instance_id:     instance_id,
                  publisher_token: publisher_token,
                  offerings:       offerings,
                  sequence:        0,
                  probe_token:     probe_token
                )
                write_instance_display(name: name, ready: true, reason: readiness.reason)
              else
                publisher.readiness_failed(
                  instance_id: instance_id,
                  probe_token: probe_token,
                  reason:      readiness.reason
                )
                write_instance_display(name: name, ready: false, reason: readiness.reason)
              end

              with_instance_states do
                @instance_states[instance_id] = {
                  name:              name,
                  instance_key:      instance_key,
                  instance_cfg:      instance_cfg,
                  callable:          callable,
                  probe_coordinator: probe_coordinator,
                  publisher_token:   publisher_token,
                  sequence:          0,
                  offerings:         offerings,
                  signature:         offering_signature(offerings)
                }
              end
            end

            # ── Tick refresh ──────────────────────────────────────────────────

            def tick_refresh
              reconcile_instances
              refresh_tracked_instances
            end

            # Re-scan configured instances each tick so instances added or removed
            # after boot (late credentials, settings reload) are claimed or retired
            # without a process restart.
            def reconcile_instances
              configured = configured_instances
              current_names = configured.keys

              gone = with_instance_states do |states|
                states.reject { |_instance_id, state| current_names.include?(state[:name]) }
              end
              gone.each_value { |state| retire_instance(state) }

              to_claim = with_instance_states do |states|
                configured.reject { |name, _cfg| states.values.any? { |state| state[:name] == name } }
              end
              to_claim.each do |name, instance_cfg|
                claim_and_activate_instance(name:, instance_cfg:)
              rescue StandardError => e
                handle_exception(e, level: :warn, operation: 'anthropic.actor.claim_instance',
                                    instance_name: name.to_s)
              end
            rescue StandardError => e
              handle_exception(e, level: :warn, operation: 'anthropic.actor.reconcile_instances')
            end

            def refresh_tracked_instances
              tracked = with_instance_states { @instance_states.dup }
              tracked.each do |instance_id, state|
                refresh_instance(instance_id:, state:)
              rescue StandardError => e
                handle_exception(e, level: :warn, operation: 'anthropic.actor.refresh_instance',
                                    instance_id: instance_id)
              end
            end

            def refresh_instance(instance_id:, state:)
              status = publisher.snapshot.publication_status(instance_key: state[:instance_key])
              return if status.nil?

              if status.state == :initializing
                retry_initial_activation(instance_id:, state:)
              else
                replace_changed_offerings(instance_id:, state:)
                run_cadence_probe(instance_id:, state:)
              end
            end

            # Recovery for an instance that failed its initial readiness probe:
            # while the publication is still :initializing a passing probe
            # re-activates the snapshot (readiness_succeeded is illegal before
            # activation, so the activation path is used, not a probe success).
            def retry_initial_activation(instance_id:, state:)
              offerings = discover_offerings_for_instance(
                instance_cfg: state[:instance_cfg],
                instance_key: state[:instance_key]
              )
              probe_token = publisher.readiness_probe_started(
                instance_id:     instance_id,
                publisher_token: state[:publisher_token]
              )
              readiness = check_readiness(instance_cfg: state[:instance_cfg])

              if readiness.ready?
                publisher.activate_instance_snapshot(
                  instance_id:     instance_id,
                  publisher_token: state[:publisher_token],
                  offerings:       offerings,
                  sequence:        0,
                  probe_token:     probe_token
                )
                with_instance_states do
                  state[:offerings] = offerings
                  state[:signature] = offering_signature(offerings)
                end
                write_instance_display(name: state[:name], ready: true, reason: readiness.reason)
              else
                publisher.readiness_failed(
                  instance_id: instance_id,
                  probe_token: probe_token,
                  reason:      readiness.reason
                )
                write_instance_display(name: state[:name], ready: false, reason: readiness.reason)
              end
            end

            # Compare offering identity (model + tier), not Data#==: the evidence
            # observed_at timestamps change every scan and would otherwise force a
            # generation-bumping replace on every tick with no real change.
            def replace_changed_offerings(instance_id:, state:)
              new_offerings = discover_offerings_for_instance(
                instance_cfg: state[:instance_cfg],
                instance_key: state[:instance_key]
              )
              new_signature = offering_signature(new_offerings)
              return if new_signature == state[:signature]

              sequence = with_instance_states do
                state[:sequence] += 1
                state[:sequence]
              end
              publisher.replace_instance_snapshot(
                instance_id:     instance_id,
                publisher_token: state[:publisher_token],
                offerings:       new_offerings,
                sequence:        sequence
              )
              with_instance_states do
                state[:offerings] = new_offerings
                state[:signature] = new_signature
              end
              write_instance_display(name: state[:name], ready: true, reason: 'offerings refreshed')
            end

            def offering_signature(offerings)
              offerings.map { |offering| [offering.model, offering.tier] }.sort.freeze
            end

            # ── Readiness probing ─────────────────────────────────────────────

            def run_cadence_probe(instance_id:, state:)
              coordinator = state[:probe_coordinator]
              return unless coordinator.begin_probe

              probe_token = publisher.readiness_probe_started(
                instance_id:     instance_id,
                publisher_token: state[:publisher_token]
              )

              readiness = check_readiness(instance_cfg: state[:instance_cfg])
              coordinator.finish_probe

              report_probe_result(instance_id:, state:, probe_token:, readiness:)
            rescue StandardError => e
              begin
                coordinator&.finish_probe
              rescue StandardError => finish_e
                handle_exception(finish_e, level: :warn, operation: 'anthropic.actor.cadence_probe.finish_probe',
                                            instance_id: instance_id)
              end
              handle_exception(e, level: :warn, operation: 'anthropic.actor.cadence_probe',
                                  instance_id: instance_id)
            end

            def handle_reactive_probe(instance_id:, request:)
              state = with_instance_states { @instance_states[instance_id] }
              return unless state

              coordinator = state[:probe_coordinator]
              return unless coordinator.begin_probe(request: request)

              probe_token = publisher.readiness_probe_started(
                instance_id:     instance_id,
                publisher_token: state[:publisher_token]
              )

              readiness = check_readiness(instance_cfg: state[:instance_cfg])
              coordinator.finish_probe(request: request)

              report_probe_result(instance_id:, state:, probe_token:, readiness:)
            rescue StandardError => e
              begin
                coordinator&.finish_probe(request: request)
              rescue StandardError => finish_e
                handle_exception(finish_e, level: :warn, operation: 'anthropic.actor.reactive_probe.finish_probe',
                                            instance_id: instance_id)
              end
              handle_exception(e, level: :warn, operation: 'anthropic.actor.reactive_probe',
                                  instance_id: instance_id)
            end

            def report_probe_result(instance_id:, state:, probe_token:, readiness:)
              if readiness.ready?
                publisher.readiness_succeeded(instance_id: instance_id, probe_token: probe_token)
                write_instance_display(name: state[:name], ready: true, reason: readiness.reason)
              else
                publisher.readiness_failed(
                  instance_id: instance_id,
                  probe_token: probe_token,
                  reason:      readiness.reason
                )
                write_instance_display(name: state[:name], ready: false, reason: readiness.reason)
              end
            end

            def build_probe_enqueue(instance_id:)
              proc do |request:|
                handle_reactive_probe(instance_id: instance_id, request: request)
                true
              rescue StandardError => e
                handle_exception(e, level: :warn, operation: 'anthropic.actor.probe_enqueue',
                                    instance_id: instance_id)
                false
              end
            end

            # ── Readiness check (safe, no inference) ─────────────────────────

            def check_readiness(instance_cfg:)
              base_url = instance_cfg[:anthropic_api_base] || 'https://api.anthropic.com'
              conn = build_api_connection(base_url: base_url, instance_cfg: instance_cfg)
              response = conn.get('/v1/models')
              Legion::Extensions::Llm::Inventory::ReadinessResult.new(
                ready:    response.status == 200,
                reason:   "Anthropic /v1/models returned #{response.status}",
                metadata: { status: response.status, base_url: base_url }
              )
            rescue Faraday::ConnectionFailed => e
              readiness_failure(reason: "Anthropic /v1/models connection failed: #{e.message}", error: e)
            rescue StandardError => e
              readiness_failure(reason: "Anthropic /v1/models error: #{e.message}", error: e)
            end

            def readiness_failure(reason:, error:)
              Legion::Extensions::Llm::Inventory::ReadinessResult.new(
                ready:    false,
                reason:   reason,
                metadata: { error_class: error.class.name }
              )
            end

            # ── Model discovery ───────────────────────────────────────────────

            def discover_offerings_for_instance(instance_cfg:, instance_key:)
              models = fetch_models(instance_cfg: instance_cfg)

              models.filter_map do |model_data|
                model_id = model_data[:id].to_s
                next if model_id.empty?

                build_offering_draft(
                  model_id:     model_id,
                  model_data:   model_data,
                  instance_cfg: instance_cfg,
                  instance_key: instance_key
                )
              end
            rescue StandardError => e
              handle_exception(e, level: :warn, operation: 'anthropic.actor.discover_offerings')
              []
            end

            def fetch_models(instance_cfg:)
              base_url = instance_cfg[:anthropic_api_base] || 'https://api.anthropic.com'
              conn = build_api_connection(base_url: base_url, instance_cfg: instance_cfg)
              response = conn.get('/v1/models')
              Legion::JSON.load(response.body).fetch(:data, [])
            rescue StandardError => e
              handle_exception(e, level: :warn, operation: 'anthropic.actor.fetch_models')
              []
            end

            def build_offering_draft(model_id:, model_data:, instance_cfg:, instance_key:)
              tier = instance_cfg[:tier] || :frontier

              Legion::Extensions::Llm::Inventory::OfferingDraft.new(
                provider_native_key:           model_id,
                model:                         model_id,
                tier:                          tier,
                operation_evidence:            build_operation_evidence,
                capability_evidence:           build_capability_evidence(model_id: model_id, model_data: model_data),
                context_evidence:              absent_value_evidence,
                max_output_evidence:           absent_value_evidence,
                embedding_dimensions_evidence: absent_value_evidence,
                model_revision_evidence:       absent_value_evidence,
                tokenizer_evidence:            absent_value_evidence,
                quota_domains:                 {},
                metadata:                      { raw_model: model_id, instance_id: instance_key.instance_id }.freeze,
                publication_source:            :provider_catalog
              )
            end

            # ── Operation evidence ────────────────────────────────────────────

            def build_operation_evidence
              now = Time.now.freeze
              {
                chat:         op_evidence(operation: :chat,         status: :supported,   observed_at: now),
                stream_chat:  op_evidence(operation: :stream_chat,  status: :supported,   observed_at: now),
                embed:        op_evidence(operation: :embed,        status: :unsupported, observed_at: now),
                image:        op_evidence(operation: :image,        status: :unsupported, observed_at: now),
                transcribe:   op_evidence(operation: :transcribe,   status: :unsupported, observed_at: now),
                translate:    op_evidence(operation: :translate,    status: :unsupported, observed_at: now),
                speak:        op_evidence(operation: :speak,        status: :unsupported, observed_at: now),
                moderate:     op_evidence(operation: :moderate,     status: :unsupported, observed_at: now),
                count_tokens: op_evidence(operation: :count_tokens, status: :unknown,     observed_at: now)
              }
            end

            def op_evidence(operation:, status:, observed_at:)
              source = status == :unknown ? :default_false : :provider_implementation
              Legion::Extensions::Llm::Inventory::OperationEvidence.new(
                operation:   operation,
                status:      status,
                source:      source,
                observed_at: observed_at
              )
            end

            # ── Capability evidence ───────────────────────────────────────────

            def build_capability_evidence(model_id:, model_data:)
              {
                completion: cap_evidence(
                  capability: :completion, status: :supported, source: :provider_implementation
                ),
                streaming:  cap_evidence(
                  capability: :streaming, status: :supported, source: :provider_implementation
                ),
                tools:      cap_evidence(
                  capability: :tools, status: :supported, source: :provider_implementation
                ),
                thinking:   cap_evidence(
                  capability: :thinking,
                  status:     resolve_thinking_status(model_id: model_id, model_data: model_data),
                  source:     resolve_thinking_source(model_id: model_id, model_data: model_data)
                ),
                vision:     cap_evidence(
                  capability: :vision, status: :supported, source: :provider_implementation
                ),
                embedding:  cap_evidence(
                  capability: :embedding, status: :unsupported, source: :provider_implementation
                )
              }
            end

            def cap_evidence(capability:, status:, source:)
              Legion::Extensions::Llm::Inventory::CapabilityEvidence.new(
                capability:  capability,
                status:      status,
                source:      source,
                observed_at: Time.now.freeze
              )
            end

            def resolve_thinking_status(model_id:, model_data:)
              return :supported if model_data.is_a?(Hash) && model_data[:type].to_s == 'reasoning'
              return :supported if model_id.to_s.include?('-thinking')

              :unknown
            end

            def resolve_thinking_source(model_id:, model_data:)
              return :model_metadata if model_data.is_a?(Hash) && model_data[:type].to_s == 'reasoning'
              return :model_metadata if model_id.to_s.include?('-thinking')

              :default_false
            end

            # ── Value evidence ────────────────────────────────────────────────

            def absent_value_evidence
              Legion::Extensions::Llm::Inventory::ValueEvidence.new(
                status: :unknown, source: :absent
              )
            end

            # ── Instance ID derivation ────────────────────────────────────────

            def derive_instance_id(instance_cfg:)
              base_url = instance_cfg[:anthropic_api_base] || 'https://api.anthropic.com'
              host_port = extract_host_port(url: base_url)
              api_key = instance_cfg[:anthropic_api_key] || instance_cfg.dig(:credentials, :api_key)

              if api_key.is_a?(String) && !api_key.strip.empty?
                fingerprint = ::Digest::SHA256.hexdigest(api_key)[0, 8]
                "#{host_port}/ak:#{fingerprint}"
              else
                host_port
              end
            end

            def extract_host_port(url:)
              uri = URI.parse(url.to_s)
              host = uri.host || 'api.anthropic.com'
              port = uri.port
              "#{host}:#{port}"
            rescue URI::InvalidURIError
              'unknown:0'
            end

            # ── Graceful shutdown ─────────────────────────────────────────────

            def remove_all_instances
              tracked = with_instance_states { @instance_states.dup }
              tracked.each_value { |state| retire_instance(state) }
              with_instance_states { @instance_states.clear }
            end

            # Retire one instance: remove it from the registry, drop the local
            # state, clear its settings display, and close its callable.
            def retire_instance(state)
              instance_id = state[:instance_key].instance_id
              publisher.remove_instance(
                instance_id:     instance_id,
                publisher_token: state[:publisher_token]
              )
              with_instance_states { @instance_states.delete(instance_id) }
              clear_instance_display(name: state[:name])
              state[:callable]&.disconnect
            rescue StandardError => e
              handle_exception(e, level: :warn, operation: 'anthropic.actor.retire_instance',
                                  instance_id: instance_id)
            end

            # ── Configuration ─────────────────────────────────────────────────

            # Only instances the operator (or the merged provider defaults)
            # actually configured are claimable. Instances with enabled: false
            # or without a resolvable credential are skipped with a log —
            # claiming a credential-less instance would probe unauthenticated
            # and never activate.
            def configured_instances
              instances = {}
              cfg_instances = settings[:instances]
              return instances unless cfg_instances.is_a?(Hash)

              cfg_instances.each do |name, config|
                normalized = claimable_instance_config(config:)
                instances[name.to_sym] = normalized unless normalized.nil?
              rescue StandardError => e
                handle_exception(e, level: :warn, operation: 'anthropic.actor.normalize_instance',
                                    instance_name: name.to_s)
              end

              instances
            end

            def claimable_instance_config(config:)
              return nil unless config.is_a?(Hash)

              normalized = normalize_instance_config(config: config)
              return nil if normalized[:enabled] == false

              api_key = resolved_api_key(normalized[:anthropic_api_key])
              if api_key.nil?
                log.warn('[anthropic][actor] action=skip_instance reason=missing_credential')
                return nil
              end

              normalized[:anthropic_api_key] = api_key
              normalized
            end

            # env:// references resolve through the canonical credential source
            # helper; an unset variable resolves to nil (credential-less).
            def resolved_api_key(api_key)
              return nil unless api_key.is_a?(String) && !api_key.strip.empty?

              if api_key.start_with?('env://')
                Legion::Extensions::Llm::CredentialSources.env(api_key.delete_prefix('env://'))
              else
                api_key
              end
            end

            def normalize_instance_config(config:)
              normalized = config.to_h.transform_keys(&:to_sym)
              normalized[:anthropic_api_key] ||= normalized.delete(:api_key)
              normalized[:anthropic_api_base] ||= normalized.delete(:endpoint)
              normalized[:anthropic_api_base] ||= normalized.delete(:base_url)
              creds = normalized.delete(:credentials)
              if creds.is_a?(Hash)
                creds = creds.transform_keys(&:to_sym)
                normalized[:anthropic_api_key] ||= creds[:api_key]
              end
              normalized[:tier] ||= :frontier
              normalized[:anthropic_api_base] ||= 'https://api.anthropic.com'
              normalized
            end

            # ── Settings health display (plain data, display only) ──────────
            # Written after each registry commit (activate, replace, probe,
            # remove) so the API namespaces can render instance health. Routing
            # authority remains the in-memory Registry AvailabilityFact.

            def write_instance_display(name:, ready:, reason:)
              entry = settings.dig(:instances, name)
              return unless entry.is_a?(Hash)

              entry[:health] = {
                circuit_state:      ready ? :closed : :open,
                denied:             false,
                available:          ready,
                adjustment:         ready ? 0 : -50,
                reason:             reason.to_s,
                observed_at:        ::Time.now.utc.iso8601,
                last_probe_outcome: ready ? :success : :failure,
                source:             :ssot_v3
              }
              entry[:capabilities] = INSTANCE_CAPABILITIES
            end

            def clear_instance_display(name:)
              entry = settings.dig(:instances, name)
              return unless entry.is_a?(Hash)

              entry.delete(:health)
              entry.delete(:capabilities)
            end

            # ── HTTP connections ───────────────────────────────────────────────

            def build_api_connection(base_url:, instance_cfg:)
              Faraday.new(url: base_url) do |f|
                f.options.timeout = 15
                f.options.open_timeout = 5
                f.headers['Accept'] = 'application/json'
                apply_auth_header(faraday: f, instance_cfg: instance_cfg)
                f.adapter Faraday.default_adapter
              end
            end

            def apply_auth_header(faraday:, instance_cfg:)
              api_key = instance_cfg[:anthropic_api_key] || instance_cfg.dig(:credentials, :api_key)
              return unless api_key.is_a?(String) && !api_key.strip.empty?

              faraday.headers['x-api-key'] = api_key
              faraday.headers['anthropic-version'] =
                instance_cfg[:api_version] || instance_cfg[:anthropic_version] || '2023-10-16'
            end
          end

          # Callable wrapper for an Anthropic provider instance. Implements the
          # fleet dispatch operations (chat, stream_chat, embed, count_tokens) by
          # delegating to a per-instance Anthropic::Provider, plus the
          # `disconnect` and `normalize_dispatch_error(error:)` contracts required
          # by Inventory::CallableHandle and Routing::ProviderOutcome.
          #
          # Dispatch errors propagate unmodified so the coordinator can classify
          # them through normalize_dispatch_error.
          #
          # CRITICAL: Anthropic 529 overloaded_error is ALWAYS :overloaded.
          # It is NEVER :instance_unavailable. Only explicit connection failures
          # at the transport layer map to :connection_failure (which the actor's
          # harness may escalate to :instance_unavailable).
          class AnthropicCallable
            # Provider dispatch kwargs the base Provider accepts by name. Any
            # other fleet param is merged into the provider `params:` passthrough,
            # which the base Provider deep-merges into the rendered payload.
            CHAT_PROVIDER_KEYS = %i[tools temperature params headers schema thinking tool_prefs].freeze
            EMBED_PROVIDER_KEYS = %i[dimensions params headers].freeze

            def initialize(instance_cfg:, logger:)
              @instance_cfg = instance_cfg
              @logger = logger
              @provider_mutex = Mutex.new
              @disconnected = false
            end

            # The wrapped per-instance provider (built lazily on first dispatch).
            def provider
              @provider_mutex.synchronize do
                @provider ||= build_provider
              end
            end

            def disconnected?
              @disconnected
            end

            def chat(messages:, model:, **rest)
              provider.chat(messages: messages, model: normalize_model(model),
                                            **dispatch_kwargs(rest, known: CHAT_PROVIDER_KEYS))
            end

            def stream_chat(messages:, model:, **rest, &)
              provider.stream_chat(messages: messages, model: normalize_model(model),
                                              **dispatch_kwargs(rest, known: CHAT_PROVIDER_KEYS), &)
            end

            def embed(text:, model:, **rest)
              provider.embed(text: text, model: normalize_model(model),
                                       **dispatch_kwargs(rest, known: EMBED_PROVIDER_KEYS))
            end

            def count_tokens(messages:, model:, **rest)
              provider.count_tokens(messages: messages, model: normalize_model(model), params: rest)
            end

            def disconnect
              @provider_mutex.synchronize do
                @disconnected = true
                @provider&.disconnect
                @provider = nil
              end
              @logger.debug { '[anthropic][callable] disconnected' }
            end

            def normalize_dispatch_error(error:)
              reason = error.message.to_s[0, 512]

              kind = case error
                     when Faraday::ConnectionFailed
                       :connection_failure
                     when Faraday::TimeoutError
                       :timeout
                     when Faraday::ClientError
                       classify_client_error(error: error)
                     when Faraday::ServerError
                       classify_server_error(error: error)
                     when Legion::Extensions::Llm::OverloadedError
                       :overloaded
                     else
                       :provider_error
                     end

              Legion::Extensions::Llm::Routing::ProviderOutcome.new(
                kind:   kind,
                reason: reason.empty? ? 'unknown dispatch error' : reason
              )
            end

            private

            def build_provider
              Legion::Extensions::Llm::Anthropic::Provider.new(@instance_cfg)
            end

            # The fleet envelope carries the model as a String; the base
            # Provider renders against a Model::Info. Wrap at the boundary.
            def normalize_model(model)
              return model if model.respond_to?(:id)

              Legion::Extensions::Llm::Model::Info.new(id: model.to_s, provider: :anthropic)
            end

            def dispatch_kwargs(rest, known:)
              known_part = rest.slice(*known)
              extra = rest.except(*known)
              return known_part if extra.empty?

              base_params = known_part[:params]
              merged = base_params.is_a?(Hash) ? base_params.merge(extra) : extra
              known_part.merge(params: merged)
            end

            def classify_client_error(error:)
              status = error.respond_to?(:response_status) ? error.response_status : nil
              case status
              when 401 then :authentication
              when 403 then :authorization
              when 404 then :model_missing
              when 429 then :rate_limited
              else :invalid_request
              end
            end

            def classify_server_error(error:)
              # 529 is Anthropic's overloaded_error status — ALWAYS :overloaded, NEVER :instance_unavailable.
              # 503 from Anthropic also indicates transient overload, not instance loss.
              # Only explicit transport-layer connection failures (classified above as
              # Faraday::ConnectionFailed) can escalate to :instance_unavailable at the harness layer.
              status = error.respond_to?(:response_status) ? error.response_status : nil
              case status
              when 503, 529 then :overloaded
              else :provider_error
              end
            end
          end
        end
      end
    end
  end
end
