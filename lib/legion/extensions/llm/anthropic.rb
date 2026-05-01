# frozen_string_literal: true

require 'legion/extensions/llm'
require 'legion/extensions/llm/anthropic/registry_event_builder'
require 'legion/extensions/llm/anthropic/registry_publisher'
require 'legion/extensions/llm/anthropic/provider'
require 'legion/extensions/llm/anthropic/version'

module Legion
  module Extensions
    module Llm
      # Anthropic provider extension namespace.
      module Anthropic
        extend ::Legion::Extensions::Core if ::Legion::Extensions.const_defined?(:Core, false)
        extend Legion::Extensions::Llm::AutoRegistration

        PROVIDER_FAMILY = :anthropic

        def self.default_settings
          ::Legion::Extensions::Llm.provider_settings(
            family: PROVIDER_FAMILY,
            instance: {
              endpoint: 'https://api.anthropic.com',
              tier: :frontier,
              transport: :http,
              credentials: { api_key: 'env://ANTHROPIC_API_KEY' },
              usage: { inference: true, embedding: false },
              limits: { concurrency: 4 }
            }
          )
        end

        def self.provider_class
          Provider
        end

        def self.discover_instances # rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity
          candidates = {}

          env_key = CredentialSources.env('ANTHROPIC_API_KEY')
          if env_key
            candidates[:env] = {
              api_key: env_key,
              anthropic_api_key: env_key,
              tier: :frontier
            }
          end

          claude_key = CredentialSources.claude_config_value(:anthropicApiKey)
          if claude_key
            candidates[:claude] = {
              api_key: claude_key,
              anthropic_api_key: claude_key,
              tier: :frontier
            }
          end

          settings_config = CredentialSources.setting(:extensions, :llm, :anthropic)
          if settings_config.is_a?(Hash)
            settings_key = settings_config[:api_key] || settings_config['api_key']
            if settings_key
              candidates[:settings] = settings_config.merge(
                anthropic_api_key: settings_key,
                tier: :frontier
              )
            end
          end

          if defined?(Legion::Identity::Broker)
            broker_cred = Legion::Identity::Broker.credential_for(:anthropic)
            if broker_cred
              candidates[:broker] = {
                api_key: broker_cred,
                anthropic_api_key: broker_cred,
                tier: :frontier
              }
            end
          end

          CredentialSources.dedup_credentials(candidates)
        end

        def self.register_discovered_instances
          super
          return unless defined?(Legion::LLM::Call::Registry)

          Legion::LLM::Call::Registry.instances_for(:anthropic).each do |instance_id, adapter|
            Legion::LLM::Call::Registry.register(:claude, adapter, instance: instance_id)
          end
        end
      end
    end
  end
end

Legion::Extensions::Llm::Anthropic.register_discovered_instances
