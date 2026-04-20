# frozen_string_literal: true

source "https://rubygems.org"

ruby ">= 3.1"

group :development do
  gem "rubocop",             require: false
  gem "rubocop-performance", require: false
end

group :test do
  gem "minitest", require: false
  gem "rake",     require: false
  # Optional at runtime (UI selector checks). Required in CI so the full
  # inline test suite exercises the Nokogiri-backed selector engine paths.
  gem "nokogiri", require: false
end
