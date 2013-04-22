require 'rubygems'
require 'rspec'

$LOAD_PATH.unshift(File.dirname(__FILE__) + '/../src') unless $LOAD_PATH.include?(File.dirname(__FILE__) + '/../src')

require 'right_scale_worker'

RSpec.configure do |config|
  config.mock_framework = :mocha
end
