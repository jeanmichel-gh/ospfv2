# frozen_string_literal: true

source 'https://rubygems.org'

gemspec

# The gemspec depends on bfd4r, which is not published. This takes it
# from the sibling checkout, as isis takes datalink-socket.
gem 'bfd4r', path: '../bfd4r'

group :development, :test do
  gem 'rake', '>= 13.0'
  gem 'test-unit', '>= 3.5'
end
