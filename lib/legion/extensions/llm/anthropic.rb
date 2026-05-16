# frozen_string_literal: true

require 'legion/extensions/llm'
require 'legion/logging/helper'
require 'legion/extensions/llm/anthropic/registry_event_builder'
require 'legion/extensions/llm/anthropic/registry_publisher'
require 'legion/extensions/llm/anthropic/provider'
require 'legion/extensions/llm/anthropic/version'

module Legion
  module Extensions
    module Llm
      # Anthropic provider extension namespace.
      module Anthropic # rubocop:disable Metrics/ModuleLength
        extend ::Legion::Extensions::Core if ::Legion::Extensions.const_defined?(:Core, false)
        extend Legion::Logging::Helper
        extend Legion::Extensions::Llm::AutoRegistration

        PROVIDER_FAMILY = :anthropic

        def self.default_settings
          ::Legion::Extensions::Llm.provider_settings(
            family: PROVIDER_FAMILY,
            instance: {
              default_model: 'claude-sonnet-4-6',
              endpoint: 'https://api.anthropic.com',
              tier: :frontier,
              transport: :http,
              credentials: { api_key: 'env://ANTHROPIC_API_KEY' },
              usage: { inference: true, embedding: false, image: false },
              limits: { concurrency: 4 },
              fleet: {
                enabled: false,
                respond_to_requests: false,
                capabilities: %i[chat stream_chat],
                lanes: [],
                concurrency: 4,
                queue_suffix: nil
              }
            }
          )
        end

        def self.provider_class
          Provider
        end

        def self.provider_aliases
          []
        end

        def self.discover_instances # rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity
          candidates = {}

          env_key = CredentialSources.env('ANTHROPIC_API_KEY')
          if env_key
            candidates[:env] = {
              api_key: env_key,
              anthropic_api_key: env_key,
              tier: :frontier,
              source: CredentialSources.source_tag(:env, 'ANTHROPIC_API_KEY'),
              credential_fingerprint: CredentialSources.credential_fingerprint(env_key)
            }
          end

          claude_key = CredentialSources.claude_config_value(:anthropicApiKey)
          if claude_key
            candidates[:claude] = {
              api_key: claude_key,
              anthropic_api_key: claude_key,
              tier: :frontier,
              source: CredentialSources.source_tag(:file, '~/.claude/settings.json', 'anthropicApiKey'),
              credential_fingerprint: CredentialSources.credential_fingerprint(claude_key)
            }
          end

          settings_config = CredentialSources.setting(:extensions, :llm, :anthropic)
          if settings_config.is_a?(Hash)
            settings_key = settings_config[:api_key] || settings_config['api_key']
            if settings_key
              candidates[:settings] = normalize_instance_config(settings_config).merge(
                api_key: settings_key,
                anthropic_api_key: settings_key,
                tier: :frontier,
                source: CredentialSources.source_tag(:settings, 'extensions.llm.anthropic'),
                credential_fingerprint: CredentialSources.credential_fingerprint(settings_key)
              )
            end

            settings_instances(settings_config).each do |name, config|
              next unless config.is_a?(Hash)

              normalized = normalize_instance_config(config)
              next unless normalized[:anthropic_api_key]

              normalized[:api_key] = normalized[:anthropic_api_key]
              normalized[:source] =
                CredentialSources.source_tag(:settings, "extensions.llm.anthropic.instances.#{name}")
              normalized[:credential_fingerprint] =
                CredentialSources.credential_fingerprint(normalized[:anthropic_api_key])
              candidates[name.to_sym] = normalized.merge(tier: :frontier)
            end
          end

          if defined?(Legion::Identity::Broker)
            broker_cred = Legion::Identity::Broker.credential_for(:anthropic)
            if broker_cred
              candidates[:broker] = {
                api_key: broker_cred,
                anthropic_api_key: broker_cred,
                tier: :frontier,
                source: CredentialSources.source_tag(:broker, 'identity', 'anthropic'),
                credential_fingerprint: CredentialSources.credential_fingerprint(broker_cred)
              }
            end
          end

          CredentialSources.dedup_credentials(candidates).transform_values do |config|
            sanitized = sanitize_instance_config(config)
            sanitized[:capabilities] ||= %i[completion streaming vision tools].freeze
            sanitized[:default_model] ||= 'claude-sonnet-4-6'
            sanitized
          end
        end

        def self.settings_instances(config)
          instances = config[:instances] || config['instances']
          instances.is_a?(Hash) ? instances : {}
        end

        def self.normalize_instance_config(config) # rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity
          normalized = config.to_h.transform_keys { |key| key.respond_to?(:to_sym) ? key.to_sym : key }
          normalized[:anthropic_api_key] ||= normalized.delete(:api_key)
          normalized[:anthropic_api_base] ||= normalized.delete(:base_url)
          normalized[:anthropic_api_base] ||= normalized.delete(:api_base)
          normalized[:anthropic_api_base] ||= normalized.delete(:endpoint)
          normalized[:anthropic_version] ||= normalized.delete(:version)
          normalized.compact.except(:instances)
        end

        def self.sanitize_instance_config(config)
          config.except(:api_key)
        end

        Legion::Extensions::Llm::Configuration.register_provider_options(Provider.configuration_options) if
          Legion::Extensions::Llm::Configuration.respond_to?(:register_provider_options)
      end
    end
  end
end
