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

RSpec.describe Legion::Extensions::Llm::Anthropic::Actor::FleetWorker do # rubocop:disable RSpec/SpecFilePathFormat
  subject(:actor) { described_class.new }

  it 'uses the provider-owned fleet runner' do
    expect(actor.runner_class).to eq('Legion::Extensions::Llm::Anthropic::Runners::FleetWorker')
    expect(actor.runner_function).to eq('handle_fleet_request')
    expect(actor.use_runner?).to be(false)
  end

  it 'is enabled only when at least one provider instance responds to fleet requests' do
    allow(Legion::Extensions::Llm::Anthropic).to receive(:discover_instances)
      .and_return(local: { fleet: { respond_to_requests: true } })

    expect(actor.enabled?).to be(true)
  end
end
