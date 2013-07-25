require 'spec_helper'

# Replace with valid credentials to integration tests below
EMAIL="user@maestrodev.com"
PASSWORD="xxxxx"
ACCOUNT_ID=67284
API_URL="https://us-3.rightscale.com"
API_VERSION="1.5"

DEPLOYMENT_NAME="David Test"
SERVER_NAME="Centrepoint Tomcat"
SERVER_ID=747597003

describe MaestroDev::RightScalePlugin::RightScaleApiHelper do

  #describe 'get_server' do
  #  before :all do
  #    @helper = MaestroDev::RightScalePlugin::RightScaleApiHelper.new(:email => EMAIL, :password => PASSWORD, :account_id => ACCOUNT_ID, :api_url => API_URL, :api_version => API_VERSION)
  #  end
  #
  #  it "should successfully get server info" do
  #    server = @helper.get_server(:server_id => SERVER_ID)
  #    server.name.should eq(SERVER_NAME)
  #  end
  #end
  #
  #describe 'start' do
  #  before :all do
  #    @helper = MaestroDev::RightScalePlugin::RightScaleApiHelper.new(:email => EMAIL, :password => PASSWORD, :account_id => ACCOUNT_ID, :api_url => API_URL, :api_version => API_VERSION)
  #  end
  #  after :all do
  #    @helper.stop(:server_id => SERVER_ID, :wait_until_started => true)
  #  end
  #
  #  it "should successfully start server by id" do
  #    result = @helper.start(:server_id => SERVER_ID, :wait_until_started => true)
  #    instance = result.instance
  #    result.success.should eq(true)
  #    result.instance.state eq("operational")
  #  end
  #end
end
