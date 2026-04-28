# frozen_string_literal: true

module Legion
  module Extensions
    module Llm
      module Anthropic
        # Best-effort publisher for Anthropic provider availability events.
        class RegistryPublisher
          APP_ID = 'lex-llm-anthropic'

          def initialize(builder: RegistryEventBuilder.new)
            @builder = builder
          end

          def publish_models_async(models, readiness:)
            schedule do
              Array(models).each do |model|
                publish_event(@builder.model_available(model, readiness:))
              end
            end
          end

          private

          def schedule(&)
            return false unless publishing_available?

            Thread.new do
              Thread.current.abort_on_exception = false
              yield
            rescue StandardError => e
              log_publish_failure(e, level: :debug)
            end
          rescue StandardError => e
            log_publish_failure(e, level: :debug)
            false
          end

          def publish_event(event)
            return false unless publishing_available?

            message_class.new(event:, app_id: APP_ID).publish(spool: false)
          rescue StandardError => e
            log_publish_failure(e)
            false
          end

          def publishing_available?
            return false unless registry_event_available?
            return false unless transport_message_available?
            return true unless defined?(::Legion::Transport::Connection)
            return true unless ::Legion::Transport::Connection.respond_to?(:session_open?)

            ::Legion::Transport::Connection.session_open?
          rescue StandardError
            false
          end

          def registry_event_available?
            defined?(::Legion::Extensions::Llm::Routing::RegistryEvent)
          end

          def transport_message_available?
            return true if message_class_defined?
            return false unless defined?(::Legion::Transport::Message) && defined?(::Legion::Transport::Exchange)

            require 'legion/extensions/llm/anthropic/transport/messages/registry_event'
            message_class_defined?
          rescue LoadError
            false
          end

          def message_class_defined?
            defined?(::Legion::Extensions::Llm::Anthropic::Transport::Messages::RegistryEvent)
          end

          def message_class
            ::Legion::Extensions::Llm::Anthropic::Transport::Messages::RegistryEvent
          end

          def log_publish_failure(error, level: :warn)
            message = "[lex-llm-anthropic] llm.registry publish failed: #{error.class}: #{error.message}"
            logger = ::Legion::Extensions::Llm.logger if defined?(::Legion::Extensions::Llm)
            if logger.respond_to?(level)
              logger.public_send(level, message)
            elsif logger.respond_to?(:debug)
              logger.debug(message)
            end
          rescue StandardError
            nil
          end
        end
      end
    end
  end
end
