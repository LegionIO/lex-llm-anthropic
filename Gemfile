# frozen_string_literal: true

source 'https://rubygems.org'

if ENV['LEX_LLM_PATH'] && File.directory?(ENV.fetch('LEX_LLM_PATH'))
  gem 'lex-llm', path: ENV.fetch('LEX_LLM_PATH')
else
  gem 'lex-llm', git: 'https://github.com/LegionIO/lex-llm',
                 branch: ENV.fetch('LEX_LLM_BRANCH', 'lex-llm-routing-base-20260425')
end

gemspec

group :development do
  gem 'bundler', '>= 2.0'
  gem 'rake', '>= 13.0'
  gem 'rspec', '~> 3.12'
  gem 'rubocop', '>= 1.0'
  gem 'rubocop-performance'
  gem 'rubocop-rake', '>= 0.6'
  gem 'rubocop-rspec'
end
