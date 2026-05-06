# frozen_string_literal: true

require 'spec_helper'
require 'legion/extensions/llm/anthropic/provider'

RSpec.describe Legion::Extensions::Llm::Anthropic::Provider do
  it 'does not expose positional canonical provider arguments' do
    canonical_methods.each { |method_name| expect_keyword_compatible(method_name) }
  end

  def canonical_methods = %i[chat stream_chat embed image list_models discover_offerings health count_tokens]

  def expect_keyword_compatible(method_name)
    return unless described_class.method_defined?(method_name)

    params = described_class.instance_method(method_name).parameters
    expect(params).not_to include(%i[req messages]), "#{method_name} still has positional messages"
    expect(params).not_to include(%i[req text]), "#{method_name} still has positional text"
    expect(params).not_to include(%i[req prompt]), "#{method_name} still has positional prompt"
  end
end
