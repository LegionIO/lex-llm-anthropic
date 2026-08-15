# frozen_string_literal: true

require 'spec_helper'

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

RSpec.describe Legion::Extensions::Llm::Anthropic::Actor::FleetWorker do
  subject(:actor) { described_class.new }

  it 'uses the provider-owned fleet runner as a resolvable module constant' do
    # The Subscription dispatch path (use_runner? = false) calls
    # runner_class.send(runner_function, **message) — a String runner_class
    # cannot be send-ed and the entry point must accept the message as kwargs.
    expect(actor.runner_class).to eq(Legion::Extensions::Llm::Anthropic::Runners::FleetWorker)
    expect(actor.runner_class).not_to be_a(String)
    expect(actor.runner_function).to eq('handle_fleet_request')
    expect(actor.use_runner?).to be(false)
  end

  it 'dispatches the Subscription message shape (module.send fn, **message)' do
    allow(Legion::Extensions::Llm::Fleet::ProviderResponder).to receive(:call).and_return(:dispatched)

    result = actor.runner_class.send(actor.runner_function, request_id: 'req-1', operation: 'chat')

    expect(result).to eq(:dispatched)
    expect(Legion::Extensions::Llm::Fleet::ProviderResponder).to have_received(:call)
  end

  it 'is enabled only when at least one provider instance responds to fleet requests' do
    allow(Legion::Extensions::Llm::Anthropic).to receive(:discover_instances)
      .and_return(local: { fleet: { respond_to_requests: true } })

    expect(actor.enabled?).to be(true)
  end
end
