# frozen_string_literal: true

require 'spec_helper'
require 'legion/extensions/llm/fleet/provider_responder'
require 'legion/extensions/llm/anthropic/runners/fleet_worker'

# The fleet worker actor subclasses LegionIO's Subscription base, which only
# exists inside a LegionIO host. Stub it before the actor file loads (the
# actor file raises LoadError without the runtime).
module Legion
  module Extensions
    module Actors
      unless const_defined?(:Subscription, false)
        class Subscription
          def initialize(*) = true
        end
      end
    end
  end
end

require 'legion/extensions/llm/anthropic/actors/fleet_worker'

RSpec.describe Legion::Extensions::Llm::Anthropic::Runners::FleetWorker do
  let(:message) do
    {
      request_id:        'req-1',
      correlation_id:    'corr-1',
      idempotency_key:   'idem-1',
      operation:         'chat',
      provider:          'anthropic',
      provider_instance: 'local',
      model:             'claude-sonnet-4-6',
      params:            { messages: [] },
      reply_to:          'reply.local',
      routing_key:       'llm.anthropic.fleet.local.#',
      message_id:        'msg-1'
    }
  end
  before do
    allow(Legion::Extensions::Llm::Fleet::ProviderResponder).to receive(:call).and_return(:ok)
  end

  it 'delegates fleet execution to the shared lex-llm responder helper' do
    result = described_class.handle_fleet_request(**message)

    expect(result).to eq(:ok)
    expect(Legion::Extensions::Llm::Fleet::ProviderResponder).to have_received(:call).with(
      payload:         message,
      provider_family: :anthropic,
      registry:        Legion::Extensions::Llm::Inventory::Registry
    )
  end

  context 'Subscription actor dispatch (D13)' do
    let(:actor) { Legion::Extensions::Llm::Anthropic::Actor::FleetWorker.new }

    it 'dispatches runner_class.send(runner_function, **message) without error' do
      expect(Legion::Extensions::Llm::Fleet::ProviderResponder).to receive(:call).and_return(:dispatched)

      result = actor.runner_class.send(actor.runner_function, **message)

      expect(result).to eq(:dispatched)
    end

    it 'resolves a module constant runner_class (not a String)' do
      expect(actor.runner_class).to eq(Legion::Extensions::Llm::Anthropic::Runners::FleetWorker)
      expect(actor.runner_class).not_to be_a(String)
    end
  end
end
