require 'spec_helper'

# Replace with valid credentials to integration tests below
VALID_ACCOUNT_ID='1234'
VALID_USERNAME='test@example.com'
VALID_PASSWORD='qwerty'
NICKNAME = 'RSB'
#NICKNAME = 'Rackspace'

describe MaestroDev::RightScaleWorker do
  before :all do
    @test_participant = MaestroDev::RightScaleWorker.new
    @test_participant.stubs(:write_output)
  end

  it "should fail to start a server with wrong credentials" do
    wi = Ruote::Workitem.new({'fields' => {
        'nickname' => NICKNAME,
        'account_id' => '1234',
        'username' => 'test@example.com',
        'password' => 'qwerty',
    }})

    @test_participant.expects(:workitem => wi.to_h).at_least_once

    @test_participant.start

    wi.fields['__error__'].should eql('Invalid credentials provided: 401 Unauthorized')
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

    @test_participant.expects(:workitem => wi.to_h).at_least_once

    @test_participant.start

    wi.fields['__error__'].should be_nil
    wi.fields['rightscale_ip_address'].should_not be_nil
    wi.fields['rightscale_server_id'].should_not be_nil
  end

  # enable to test
  xit "should stop a server with valid credentials" do
    wi = Ruote::Workitem.new({'fields' => {
        'nickname' => NICKNAME,
        'account_id' => VALID_ACCOUNT_ID,
        'username' => VALID_USERNAME,
        'password' => VALID_PASSWORD,
    }})

    @test_participant.expects(:workitem => wi.to_h).at_least_once

    @test_participant.stop

    wi.fields['__error__'].should be_nil
  end

  # enable to test
  xit "should stop a server using existing field item" do
    wi = Ruote::Workitem.new({'fields' => {
        'rightscale_server_id' => '1234',
        'account_id' => VALID_ACCOUNT_ID,
        'username' => VALID_USERNAME,
        'password' => VALID_PASSWORD,
    }})

    @test_participant.expects(:workitem => wi.to_h).at_least_once

    @test_participant.stop

    wi.fields['__error__'].should be_nil
  end

  it "should fail to validate if no nickname and no server_id" do
    wi = Ruote::Workitem.new({'fields' => {
        'account_id' => '1234',
        'username' => 'test@example.com',
        'password' => 'qwerty',
    }})

    @test_participant.expects(:workitem => wi.to_h).at_least_once

    @test_participant.start

    wi.fields['__error__'].should eql('Invalid fields, must provide nickname or server_id')
  end

  it "should fail to validate if no account_id" do
    wi = Ruote::Workitem.new({'fields' => {
        'username' => 'test@example.com',
        'password' => 'qwerty',
    }})

    @test_participant.expects(:workitem => wi.to_h).at_least_once

    @test_participant.start

    wi.fields['__error__'].should eql('Invalid fields, must provide account_id')
  end
  it "should fail to validate if no username" do
    wi = Ruote::Workitem.new({'fields' => {
        'account_id' => '1234',
        'password' => 'qwerty',
    }})

    @test_participant.expects(:workitem => wi.to_h).at_least_once

    @test_participant.start

    wi.fields['__error__'].should eql('Invalid fields, must provide username')
  end
  it "should fail to validate if no password" do
    wi = Ruote::Workitem.new({'fields' => {
        'account_id' => '1234',
        'username' => 'test@example.com',
    }})

    @test_participant.expects(:workitem => wi.to_h).at_least_once

    @test_participant.start

    wi.fields['__error__'].should eql('Invalid fields, must provide password')
  end
end
