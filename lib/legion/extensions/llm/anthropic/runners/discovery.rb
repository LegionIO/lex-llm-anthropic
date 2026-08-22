# frozen_string_literal: true

require 'digest'
require 'time'
require 'uri'
require 'faraday'

require 'legion/extensions/llm/discovery/pipeline'
require 'legion/extensions/llm/anthropic/helpers/callable'
require 'legion/extensions/llm/anthropic/provider'

module Legion
  module Extensions
    module Llm
      module Anthropic
        module Runners
          # Anthropic discovery runner: ONLY the Anthropic-specific work. The
          # generic reconcile / claim / activate / probe (cadence + reactive) /
          # replace / weight-publication / health-display pipeline is mixed in
          # from the shared Discovery::Pipeline. Weight is NOT computed here —
          # the shared WeightReconciler recomputes it from live settings at
          # publish.
          #
          # The catalog is OpenAI-shaped (GET /v1/models -> body[:data]), so the
          # pipeline's default fetch_raw_models / model_id_from are reused. The
          # overrides are the Anthropic auth scheme (x-api-key +
          # anthropic-version, not bearer), the /v1/models readiness, the
          # 8-char-credential physical id, and the offering-draft evidence.
          module Discovery
            extend self
            include Legion::Extensions::Llm::Discovery::Pipeline

            # ── Anthropic instance-config keys / connection ───────────────────
            def catalog_base_url(instance_cfg:)
              instance_cfg[:anthropic_api_base] || 'https://api.anthropic.com'
            end

            def auth_token(instance_cfg:)
              token = instance_cfg[:anthropic_api_key] || instance_cfg.dig(:credentials, :api_key)
              token if token.is_a?(String) && !token.strip.empty?
            end

            # Anthropic authenticates with x-api-key + anthropic-version, not a
            # bearer Authorization header.
            def apply_auth_headers(faraday:, instance_cfg:)
              api_key = instance_cfg[:anthropic_api_key] || instance_cfg.dig(:credentials, :api_key)
              return unless api_key.is_a?(String) && !api_key.strip.empty?

              faraday.headers['x-api-key'] = api_key
              faraday.headers['anthropic-version'] =
                instance_cfg[:api_version] || instance_cfg[:anthropic_version] || '2023-10-16'
            end

            # Readiness is a safe non-inference GET /v1/models.
            def health_path = '/v1/models'

            def build_callable(instance_cfg:)
              Legion::Extensions::Llm::Anthropic::Helpers::Callable.new(instance_cfg: instance_cfg, logger: log)
            end

            # ── Secondary physical id (dedup/diagnostics only) ────────────────
            # host:port, or host:port/ak:<8-char credential digest> when a key
            # is present. Never identity — the instance identity is the
            # operator's config name.
            def derive_physical_id(instance_cfg:)
              host_port = extract_host_port(url: catalog_base_url(instance_cfg: instance_cfg))
              api_key = auth_token(instance_cfg: instance_cfg)
              return "#{host_port}/ak:#{::Digest::SHA256.hexdigest(api_key)[0, 8]}" if api_key

              host_port
            end

            def extract_host_port(url:)
              uri = URI.parse(url.to_s)
              "#{uri.host || 'api.anthropic.com'}:#{uri.port}"
            rescue URI::InvalidURIError => e
              handle_exception(e, level: :warn, handled: true,
                                  operation: 'anthropic.runner.discovery.extract_host_port', url: url.to_s)
              'unknown:0'
            end

            # ── Offering draft (evidence + metadata; NO weight) ───────────────
            def build_offering_draft(instance_cfg:, instance_key:, model_id:, model_data:)
              tier = instance_cfg[:tier] || :frontier

              Legion::Extensions::Llm::Inventory::OfferingDraft.new(
                provider_native_key:           model_id,
                model:                         model_id,
                tier:                          tier,
                operation_evidence:            build_operation_evidence(model_id: model_id, model_data: model_data),
                capability_evidence:           build_capability_evidence(model_id: model_id, model_data: model_data),
                context_evidence:              absent_value_evidence,
                max_output_evidence:           absent_value_evidence,
                embedding_dimensions_evidence: absent_value_evidence,
                model_revision_evidence:       absent_value_evidence,
                tokenizer_evidence:            absent_value_evidence,
                quota_domains:                 {},
                metadata:                      { raw_model: model_id, instance_id: instance_key.instance_id },
                publication_source:            :provider_catalog
              )
            end

            private

            # Authoritative operation evidence: an embedding model publishes
            # chat: :unsupported so a plain chat request can never misroute to
            # it; embed is published only for embedding models.
            def build_operation_evidence(model_id:, model_data:)
              now = Time.now.freeze
              return embedding_operations(now: now) if embedding_model?(model_id: model_id, model_data: model_data)

              {
                chat:         op_evidence(operation: :chat, status: :supported, observed_at: now),
                stream_chat:  op_evidence(operation: :stream_chat, status: :supported, observed_at: now),
                embed:        op_evidence(operation: :embed, status: :unsupported, observed_at: now),
                image:        op_evidence(operation: :image, status: :unsupported, observed_at: now),
                transcribe:   op_evidence(operation: :transcribe, status: :unsupported, observed_at: now),
                translate:    op_evidence(operation: :translate, status: :unsupported, observed_at: now),
                speak:        op_evidence(operation: :speak, status: :unsupported, observed_at: now),
                moderate:     op_evidence(operation: :moderate, status: :unsupported, observed_at: now),
                count_tokens: op_evidence(operation: :count_tokens, status: :unknown, observed_at: now)
              }
            end

            def embedding_operations(now:)
              result = %i[chat stream_chat image transcribe translate speak moderate count_tokens].to_h do |operation|
                [operation, op_evidence(operation: operation, status: :unsupported, observed_at: now)]
              end
              # The provider catalog is the authority that this model class
              # serves embed (type/id came from /v1/models).
              result[:embed] = Legion::Extensions::Llm::Inventory::OperationEvidence.new(
                operation: :embed, status: :supported, source: :provider_catalog, observed_at: now
              )
              result
            end

            def embedding_model?(model_id:, model_data:)
              (model_data.is_a?(Hash) && model_data[:type].to_s == 'embedding') ||
                model_id.to_s.include?('embed')
            end

            def op_evidence(operation:, status:, observed_at:)
              source = status == :unknown ? :default_false : :provider_implementation
              Legion::Extensions::Llm::Inventory::OperationEvidence.new(
                operation: operation, status: status, source: source, observed_at: observed_at
              )
            end

            def build_capability_evidence(model_id:, model_data:)
              if embedding_model?(model_id: model_id, model_data: model_data)
                # An embedding model serves embed and nothing else.
                return {
                  embedding: cap_evidence(capability: :embedding, status: :supported, source: :provider_catalog)
                }
              end

              {
                completion: cap_evidence(capability: :completion, status: :supported, source: :provider_implementation),
                streaming:  cap_evidence(capability: :streaming, status: :supported, source: :provider_implementation),
                tools:      cap_evidence(capability: :tools, status: :supported, source: :provider_implementation),
                thinking:   cap_evidence(capability: :thinking,
                                         status:     resolve_thinking_status(model_id: model_id, model_data: model_data),
                                         source:     resolve_thinking_source(model_id: model_id, model_data: model_data)),
                vision:     cap_evidence(capability: :vision, status: :supported, source: :provider_implementation),
                embedding:  cap_evidence(capability: :embedding, status: :unsupported, source: :provider_implementation)
              }
            end

            def cap_evidence(capability:, status:, source:)
              Legion::Extensions::Llm::Inventory::CapabilityEvidence.new(
                capability: capability, status: status, source: source, observed_at: Time.now.freeze
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

            def absent_value_evidence
              Legion::Extensions::Llm::Inventory::ValueEvidence.new(status: :unknown, source: :absent)
            end
          end
        end
      end
    end
  end
end
