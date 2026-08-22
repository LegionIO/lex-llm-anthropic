# frozen_string_literal: true

require 'faraday'

require 'legion/extensions/llm/routing/provider_outcome'
require 'legion/extensions/llm/canonical'
require 'legion/extensions/llm/anthropic/provider'

module Legion
  module Extensions
    module Llm
      module Anthropic
        module Helpers
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
          # at the transport layer map to :connection_failure (which the
          # discovery harness may escalate to :instance_unavailable).
          class Callable
            # Provider dispatch kwargs the 0.8.0 base funnel accepts by name.
            # temperature is not one of them (05 O4) — it lives only in
            # Canonical::Params. Any other fleet param is merged into the
            # provider `params:` passthrough as canonical Params.
            CHAT_PROVIDER_KEYS = %i[tools params headers schema thinking tool_prefs].freeze
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

            def chat(messages, model:, **rest)
              # Canonical boundary (N x N law): fleet dispatch delivers
              # Canonical::Message objects only. Native/Hash shapes are the
              # bypass class (the 2026-08-19 incident) — reject loudly, never coerce.
              provider.enforce_canonical_messages!(messages)
              provider.chat(messages, model:,
                                      **dispatch_kwargs(rest, known: CHAT_PROVIDER_KEYS))
            end

            def stream_chat(messages, model:, **rest, &)
              provider.enforce_canonical_messages!(messages)
              provider.stream_chat(messages, model:,
                                             **dispatch_kwargs(rest, known: CHAT_PROVIDER_KEYS), &)
            end

            def embed(text:, model:, **rest)
              provider.embed(text: text, model:,
                                       **dispatch_kwargs(rest, known: EMBED_PROVIDER_KEYS))
            end

            def count_tokens(messages:, model:, **rest)
              provider.count_tokens(messages: messages, model:, params: rest)
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

            # The 0.8.0 completion funnel receives canonical values only
            # (08 F3): the folded wire params become a Canonical::Params at
            # the dispatch boundary — temperature is a params member (05 O4),
            # never a kwarg. In-process dispatch already passes canonical
            # values; they converge here.
            def dispatch_kwargs(rest, known:)
              known_part = rest.slice(*known)
              extra = rest.except(*known)
              known_part[:params] = canonical_params(known_part[:params], extra)
              known_part
            end

            def canonical_params(params, extra)
              base = case params
                     when Legion::Extensions::Llm::Canonical::Params then params.to_h
                     when Hash then params.transform_keys(&:to_sym)
                     else {}
                     end
              base = base.merge(extra.transform_keys(&:to_sym)) unless extra.empty?
              return nil if base.empty?

              Legion::Extensions::Llm::Canonical::Params.from_hash(base)
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
