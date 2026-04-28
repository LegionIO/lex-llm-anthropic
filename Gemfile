# frozen_string_literal: true

source 'https://rubygems.org'

group :test do
  llm_base_path = ENV.fetch('LEX_LLM_PATH', File.expand_path('../lex-llm', __dir__))
  gem 'lex-llm', path: llm_base_path if File.directory?(llm_base_path)
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
