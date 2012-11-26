require 'spec_helper'

describe MaestroDev::RightScaleWorker do
  before :all do
    @test_participant = MaestroDev::RightScaleWorker.new
    @test_participant.stubs(:write_output)
  end

  it "should fail to start a server with wrong credentials" do
    wi = Ruote::Workitem.new({'fields' => {
        'nickname' => 'RSB',
        'account_id' => '1234',
        'username' => 'test@example.com',
        'password' => 'qwerty',
    }})

    @test_participant.expects(:workitem => wi.to_h).at_least_once

    @test_participant.start

    wi.fields['__error__'].should eql('Invalid response HTTP code: 401: Permission denied')
  end

  # Replace with valid credentials and enable to test
  xit "should start a server with valid credentials" do
    wi = Ruote::Workitem.new({'fields' => {
        'nickname' => 'RSB',
        #'account_id' => '1234',
        #'username' => 'test@example.com',
        #'password' => 'qwerty',
    }})

    @test_participant.expects(:workitem => wi.to_h).at_least_once

    @test_participant.start

    wi.fields['__error__'].should eql('')
    wi.fields['rightscale_ip_address'].should_not be_nil
    wi.fields['rightscale_server_id'].should_not be_nil
  end

  # Replace with valid credentials and enable to test
  xit "should stop a server with valid credentials" do
    wi = Ruote::Workitem.new({'fields' => {
        'nickname' => 'RSB',
        #'account_id' => '1234',
        #'username' => 'test@example.com',
        #'password' => 'qwerty',
    }})

    @test_participant.expects(:workitem => wi.to_h).at_least_once

    @test_participant.stop

    wi.fields['__error__'].should eql('')
  end

  # Replace with valid credentials and enable to test
  xit "should stop a server using existing field item" do
    wi = Ruote::Workitem.new({'fields' => {
        #'rightscale_server_id' => '1234',
        #'account_id' => '1234',
        #'username' => 'test@example.com',
        #'password' => 'qwerty',
    }})

    @test_participant.expects(:workitem => wi.to_h).at_least_once

    @test_participant.stop

    wi.fields['__error__'].should eql('')
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
