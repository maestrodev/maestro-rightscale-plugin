require 'spec_helper'

# Replace with valid credentials to integration tests below
VALID_ACCOUNT_ID='1234'
VALID_USERNAME='test@example.com'
VALID_PASSWORD='qwerty'
NICKNAME = 'RSB'
#NICKNAME = 'Rackspace'

describe MaestroDev::RightScaleWorker do

  let (:participant) { described_class.new }

  let (:default_fields) { {
    'account_id' => '11111',
    'username' => 'jdoe@acme.com',
    'password' => 'mypasswd'}
  }

  before :each do
    participant.stubs(:write_output)
  end

  describe 'start' do

    def start(fields)
      wi = Ruote::Workitem.new({'fields' => fields})
      participant.expects(:workitem => wi.to_h).at_least_once
      participant.start
    end

    it "should fail to start a server with wrong credentials" do
      start(default_fields.merge('nickname' => NICKNAME))
      participant.error.should eql('Invalid credentials provided: 401 Unauthorized')
    end

    # enable to test
    xit "should start a server with valid credentials" do
      wi = Ruote::Workitem.new({'fields' => {
          'nickname' => NICKNAME,
          'account_id' => VALID_ACCOUNT_ID,
          'username' => VALID_USERNAME,
          'password' => VALID_PASSWORD,
          'api_url' => 'https://us-3.rightscale.com'
      }})

      participant.expects(:workitem => wi.to_h).at_least_once
      participant.start
      participant.error.should be_nil
      wi.fields['rightscale_ip_address'].should_not be_nil
      wi.fields['rightscale_server_id'].should_not be_nil
    end

    it "should fail to validate if no nickname and no server_id" do
      start(default_fields)
      participant.error.should eql('Invalid fields, must provide nickname or server_id')
    end

    it "should fail to validate if no account_id" do
      start(default_fields.reject{|k,v| k=='account_id'})
      participant.error.should eql('Invalid fields, must provide nickname or server_id, account_id')
    end

    it "should fail to validate if no username" do
      start(default_fields.reject{|k,v| k=='username'})
      participant.error.should eql('Invalid fields, must provide nickname or server_id, username')
    end

    it "should fail to validate if no password" do
      start(default_fields.reject{|k,v| k=='password'})
      participant.error.should eql('Invalid fields, must provide nickname or server_id, password')
    end
  end

  describe 'stop' do

    let(:instance) { mock('instance') }
    let(:server) { mock('server', :current_instance => instance, :name => 'myserver', :href => "/api/servers/1") }
    let(:servers) { mock('servers') }

    before(:each) do
      participant.stubs(:init_server_connection)
      participant.client = stub('client', :servers => servers)
    end

    def stop(fields)
      wi = Ruote::Workitem.new({'fields' => default_fields.merge(fields)})
      participant.expects(:workitem => wi.to_h).at_least_once
      instance.expects(:terminate)
      participant.stop
      participant.error.should be_nil
    end

    it "should stop servers passed as field server_id" do
      servers.expects(:index).with(:id => 1).returns(server)
      stop({'server_id' => 1})
    end

    it "should stop servers passed as field nickname" do
      servers.expects(:index).with(:filter => ["name==myserver"]).returns([server])
      stop({'nickname' => 'myserver'})
    end

    it "should stop servers stored by start task" do
      servers.expects(:index).with(:id => '1').returns(server)
      servers.expects(:index).with(:id => '2').raises(RightApi::Exceptions::ApiException,
        "Error: HTTP Code: 422, Response body: ResourceNotFound: Couldn't find Server with ID=2")
      stop({'rightscale_ids' => ['1', '2']})
    end

    # enable to test
    xit "should stop a server with valid credentials" do
      wi = Ruote::Workitem.new({'fields' => {
          'nickname' => NICKNAME,
          'account_id' => VALID_ACCOUNT_ID,
          'username' => VALID_USERNAME,
          'password' => VALID_PASSWORD,
      }})

      participant.expects(:workitem => wi.to_h).at_least_once
      participant.stop
      participant.error.should be_nil
    end

    # enable to test
    xit "should stop a server using existing field item" do
      wi = Ruote::Workitem.new({'fields' => {
          'rightscale_server_id' => '1234',
          'account_id' => VALID_ACCOUNT_ID,
          'username' => VALID_USERNAME,
          'password' => VALID_PASSWORD,
      }})

      participant.expects(:workitem => wi.to_h).at_least_once
      participant.stop
      participant.error.should be_nil
    end
  end

end
