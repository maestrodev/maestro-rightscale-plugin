require 'maestro_agent'
require 'right_api_client'
require 'rubygems'

module MaestroDev
  class RightScaleWorker < Maestro::MaestroWorker

    def validate_fields(server_id)
      missing_fields = []
      for f in %w(account_id username password)
        missing_fields << f if get_field(f).nil?
      end

      fail "Invalid fields, must provide #{missing_fields}" unless missing_fields.empty?

      fail 'Invalid fields, must provide nickname or server_id' if get_field('nickname').nil? and server_id.nil?
    end

    def start
      Maestro.log.info "Starting RightScale Worker"

      server_name = get_field('nickname')
      # TODO: should be used, or make nickname required?
      server_id = get_field('server_id')

      begin
        validate_fields(server_id)
      rescue => e
        set_error e.message
        return
      end

      begin
        init_server_connection()
      rescue RestClient::Unauthorized => e
        set_error "Invalid credentials provided: #{e.message}"
        return
      end

      server = @client.servers.index(:filter => ["name==#{server_name}"]).first
      if server.nil?
        set_error "No server matches #{server_name}"
        return
      end

      Maestro.log.info "Found server, '#{server.name}'."

      begin
        instance_resource = server.launch
      rescue RightApi::Exceptions::ApiException => e
        # TODO: a new version with ApiError can check e.response.code
        if e.message =~ /422/
          set_error e.message
          return
        else
          raise e
        end
      end

      server_id = File.basename server.href

      write_output "Requested server to start #{server_id}\n"
      set_field('rightscale_server_id', server_id)

      wait_for_state('operational', server_id)

      instance = instance_resource.show
      ip_address = instance.public_ip_addresses.first
      set_field('rightscale_ip_address', ip_address)
      private_ip_address = instance.private_ip_addresses.first
      set_field('rightscale_private_ip_address', private_ip_address)

      context_servers = read_output_value('rightscale_servers') || {}
      context_servers[server_id] = {
          :name => server.name,
          :state => "operational",
          :public_ip_address => ip_address,
          :private_ip_address => private_ip_address,
          :multi_cloud_image => instance.multi_cloud_image.show.name,
          :server_template => instance.server_template.show.name,
          :deployment => instance.deployment.show.name,
          :resource_uid => instance.resource_uid
      }
      save_output_value('rightscale_servers', context_servers)

      write_output "Server up at #{ip_address}\n"

      Maestro.log.info "***********************Completed RightScale.start***************************"
    end

    def stop
      Maestro.log.info "Starting RightScale Worker"

      server_name = get_field('nickname')
      server_id = get_field('server_id') || get_field('rightscale_server_id')

      begin
        validate_fields(server_id)
      rescue => e
        set_error e.message
        return
      end

      init_server_connection()
      if server_id and server_id > 0
        server = @client.servers(:id => server_id).show
        if server.nil?
          set_error "No server with id #{server_id}"
          return
        end
        Maestro.log.info "Found server, '#{server_id}'."
      else
        server = @client.servers.index(:filter => ["name==#{server_name}"]).first
        if server.nil?
          set_error "No server matches #{server_name}"
          return
        end
        Maestro.log.info "Found server, '#{server.name}'."
      end

      server_id = File.basename server.href

      server.current_instance.terminate

      write_output "Requested server to stop #{server_id}\n"

      wait_for_state("inactive", server_id) if get_field('wait_until_stopped')

      context_servers = read_output_value('rightscale_servers') || {}
      context_servers[server_id][:state] = @client.servers(:id => server_id).show.state if context_servers[server_id]

      write_output "Server stopped\n"

      Maestro.log.info "***********************Completed RightScale.stop***************************"
    end

    def wait
      Maestro.log.info "Starting RightScale Worker"

      # TODO: validate states
      state = get_field('state')
      server_name = get_field('nickname')
      server_id = get_field('server_id') || get_field('rightscale_server_id')

      begin
        validate_fields(server_id)

        fail 'Invalid fields, must provide state' if state.nil?
      rescue => e
        set_error e.message
        return
      end

      init_server_connection()
      if server_id and server_id > 0
        server = @client.servers(:id => server_id).show
        if server.nil?
          set_error "No server with id #{server_id}"
          return
        end
        Maestro.log.info "Found server, '#{server_id}'."
      else
        server = @client.servers.index(:filter => ["name==#{server_name}"]).first
        if server.nil?
          set_error "No server matches #{server_name}"
          return
        end
        Maestro.log.info "Found server, '#{server.name}'."
      end

      server_id = File.basename server.href

      write_output "Waiting until server #{server_id} is #{state}\n"

      wait_for_state(state, server_id)

      context_servers = read_output_value('rightscale_servers') || {}
      context_servers[server_id][:state] = state if context_servers[server_id]

      write_output "Server is #{state}\n"

      Maestro.log.info "***********************Completed RightScale.wait***************************"
    end

    def init_server_connection
      account_id = get_field('account_id')
      username = get_field('username')
      password = get_field('password')
      api_version = get_field('api_version')
      api_url = get_field('api_url')

      @client = RightApi::Client.new(:email => username, :password => password, :account_id => account_id,
                                     :api_url => api_url, :api_version => api_version)

      @client.log LogWrapper.new
    end

    def wait_for_state(state, server_id, timeout=600, interval=10)
      (0..timeout).step(interval) do |i|
        server = @client.servers(:id => server_id).show
        Maestro.log.debug "Server state is #{server.state}, waiting for #{state} (#{i}/#{timeout})"
        return true if server.state == state
        sleep interval
      end
      server = @client.servers(:id => server_id).show
      fail "Timed out waiting for server #{server.name} to reach state #{state}, is currently #{server.state}"
    end

    def close()

    end
  end

  class LogWrapper
    def << s
      Maestro.log.debug s
    end
  end
end
