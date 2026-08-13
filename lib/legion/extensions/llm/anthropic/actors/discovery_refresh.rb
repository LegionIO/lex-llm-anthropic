# frozen_string_literal: true

require 'digest'
require 'uri'

begin
  require 'legion/extensions/actors/every'
rescue LoadError => e
  warn(e.message) if $VERBOSE
end

require 'legion/extensions/llm/inventory/publisher'
require 'legion/extensions/llm/inventory/identity'
require 'legion/extensions/llm/inventory/records'
require 'legion/extensions/llm/inventory/evidence'
require 'legion/extensions/llm/inventory/probe_coordinator'
require 'legion/extensions/llm/routing/provider_outcome'
require 'legion/extensions/llm/taxonomies'
require 'legion/extensions/llm/capabilities'

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
          class DiscoveryRefresh < Legion::Extensions::Actors::Every
            include Legion::Extensions::Helpers::Lex
            include Legion::Logging::Helper

            def self.every_seconds = 3600

            def runner_class    = self.class
            def runner_function = 'manual'
            def run_now?        = true
            def use_runner?     = false
            def check_subtask?  = false
            def generate_task?  = false

            def time
              settings[:discovery_interval] || self.class.every_seconds
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

            def publisher
              @publisher ||= Legion::Extensions::Llm::Inventory::Publisher.new(provider_family: :anthropic)
            end

            # ── Initial discovery ─────────────────────────────────────────────

            def initial_discovery
              @instance_states = {}
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
              else
                publisher.readiness_failed(
                  instance_id: instance_id,
                  probe_token: probe_token,
                  reason:      readiness.reason
                )
              end

              @instance_states[instance_id] = {
                name:              name,
                instance_key:      instance_key,
                instance_cfg:      instance_cfg,
                callable:          callable,
                probe_coordinator: probe_coordinator,
                publisher_token:   publisher_token,
                sequence:          0,
                offerings:         offerings
              }
            end

            # ── Tick refresh ──────────────────────────────────────────────────

            def tick_refresh
              @instance_states.each do |instance_id, state|
                refresh_instance(instance_id:, state:)
              rescue StandardError => e
                handle_exception(e, level: :warn, operation: 'anthropic.actor.refresh_instance',
                                    instance_id: instance_id)
              end
            end

            def refresh_instance(instance_id:, state:)
              new_offerings = discover_offerings_for_instance(
                instance_cfg: state[:instance_cfg],
                instance_key: state[:instance_key]
              )

              if new_offerings != state[:offerings]
                state[:sequence] += 1
                publisher.replace_instance_snapshot(
                  instance_id:     instance_id,
                  publisher_token: state[:publisher_token],
                  offerings:       new_offerings,
                  sequence:        state[:sequence]
                )
                state[:offerings] = new_offerings
              end

              run_cadence_probe(instance_id:, state:)
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

              report_probe_result(instance_id:, probe_token:, readiness:)
            rescue StandardError => e
              coordinator&.finish_probe rescue nil # rubocop:disable Style/RescueModifier
              handle_exception(e, level: :warn, operation: 'anthropic.actor.cadence_probe',
                                  instance_id: instance_id)
            end

            def handle_reactive_probe(instance_id:, request:)
              state = @instance_states[instance_id]
              return unless state

              coordinator = state[:probe_coordinator]
              return unless coordinator.begin_probe(request: request)

              probe_token = publisher.readiness_probe_started(
                instance_id:     instance_id,
                publisher_token: state[:publisher_token]
              )

              readiness = check_readiness(instance_cfg: state[:instance_cfg])
              coordinator.finish_probe(request: request)

              report_probe_result(instance_id:, probe_token:, readiness:)
            rescue StandardError => e
              coordinator&.finish_probe(request: request) rescue nil # rubocop:disable Style/RescueModifier
              handle_exception(e, level: :warn, operation: 'anthropic.actor.reactive_probe',
                                  instance_id: instance_id)
            end

            def report_probe_result(instance_id:, probe_token:, readiness:)
              if readiness.ready?
                publisher.readiness_succeeded(instance_id: instance_id, probe_token: probe_token)
              else
                publisher.readiness_failed(
                  instance_id: instance_id,
                  probe_token: probe_token,
                  reason:      readiness.reason
                )
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
              return unless @instance_states

              @instance_states.each do |instance_id, state|
                publisher.remove_instance(
                  instance_id:     instance_id,
                  publisher_token: state[:publisher_token]
                )
              rescue StandardError => e
                handle_exception(e, level: :warn, operation: 'anthropic.actor.remove_instance',
                                    instance_id: instance_id)
              end
              @instance_states.clear
            end

            # ── Configuration ─────────────────────────────────────────────────

            def configured_instances
              instances = {}

              cfg_instances = settings[:instances]
              if cfg_instances.is_a?(Hash)
                cfg_instances.each do |name, config|
                  instances[name.to_sym] = normalize_instance_config(config: config)
                rescue StandardError => e
                  handle_exception(e, level: :warn, operation: 'anthropic.actor.normalize_instance',
                                      instance_name: name.to_s)
                end
              end

              if instances.empty?
                api_key = settings[:anthropic_api_key] ||
                          settings.dig(:credentials, :api_key) ||
                          settings[:api_key]
                endpoint = settings[:endpoint] ||
                           settings[:anthropic_api_base] ||
                           'https://api.anthropic.com'
                instances[:primary] = {
                  anthropic_api_key:  api_key,
                  anthropic_api_base: endpoint,
                  tier:               settings[:tier] || :frontier
                }.compact
              end

              instances
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

            # ── HTTP connections ───────────────────────────────────────────────

            def build_api_connection(base_url:, instance_cfg:)
              require 'faraday'
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
              faraday.headers['anthropic-version'] = instance_cfg[:anthropic_version] || '2023-10-16'
            end
          end

          # Callable wrapper for an Anthropic provider instance. Implements the
          # `disconnect` and `normalize_dispatch_error(error:)` contracts required
          # by Inventory::CallableHandle and Routing::ProviderOutcome.
          #
          # CRITICAL: Anthropic 529 overloaded_error is ALWAYS :overloaded.
          # It is NEVER :instance_unavailable. Only explicit connection failures
          # at the transport layer map to :connection_failure (which the actor's
          # harness may escalate to :instance_unavailable).
          class AnthropicCallable
            def initialize(instance_cfg:, logger:)
              @instance_cfg = instance_cfg
              @logger = logger
              @disconnected = false
            end

            def disconnected?
              @disconnected
            end

            def disconnect
              @disconnected = true
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
