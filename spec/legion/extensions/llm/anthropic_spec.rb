# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Legion::Extensions::Llm::Anthropic do
  it 'exposes provider defaults with inherited fleet settings' do
    settings = described_class.default_settings

    expect(settings[:provider_family]).to eq(:anthropic)
    expect(settings[:fleet]).to include(:enabled)
    expect(settings.dig(:instances, :default, :endpoint)).to eq('https://api.anthropic.com')
    expect(settings.dig(:instances, :default, :usage, :embedding)).to be false
  end
end
