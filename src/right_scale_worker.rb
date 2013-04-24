require 'maestro_agent'
require 'right_api_client'
require 'rubygems'
require 'pp'

module MaestroDev
  class RightScaleWorker < Maestro::MaestroWorker

    attr_accessor :client

    def provider
      'rightscale'
    end

    def validate_fields(server_id)
      missing_fields = []
      if get_field('nickname').nil? and (server_id.nil? or server_id.empty?)
        missing_fields << 'nickname or server_id'
      end
      for f in %w(account_id username password)
        missing_fields << f if get_field(f).nil?
      end

      set_error("Invalid fields, must provide #{missing_fields.join(", ")}") unless missing_fields.empty?
    end

    def start
      Maestro.log.info "Starting RightScale Worker"

      server_name = get_field('nickname')
      # TODO: should be used, or make nickname required?
      server_id = get_field('server_id')

      validate_fields(server_id)
      return if error?

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

      server_id = get_server_id(server)

      write_output "Requested server to start #{server_id}\n"
      set_field('rightscale_server_id', server_id) # deprecated
      set_field("#{provider}_ids", (get_field("#{provider}_ids") || []) << server_id)
      set_field("cloud_ids", (get_field("cloud_ids") || []) << server_id)

      wait_for_state('operational', server_id)
      return if error?

      instance = instance_resource.show
      ip_address = instance.public_ip_addresses.first
      private_ip_address = instance.private_ip_addresses.first

      # save some values in the workitem so they are accessible for deprovision and other tasks
      # using same naming as the fog plugin
      set_field('rightscale_ip_address', ip_address) # deprecated
      set_field('rightscale_private_ip_address', private_ip_address) # deprecated

      set_field("#{provider}_private_ips", (get_field("#{provider}_private_ips") || []) << private_ip_address)
      set_field("cloud_private_ips", (get_field("cloud_private_ips") || []) << private_ip_address)
      set_field("#{provider}_ips", (get_field("#{provider}_ips") || []) << ip_address)
      set_field("cloud_ips", (get_field("cloud_ips") || []) << ip_address)


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
      Maestro.log.info "Stopping RightScale servers"

      server_name = get_field('nickname')

      # what to stop
      server_id = get_field('server_id')
      if server_id and server_id > 0
        # stop server id set in task
        server_ids = [server_id]
      elsif server_name
        # stop server name set in task
        server_ids = nil
      else
        # stop previously started servers
        server_ids = get_field("#{provider}_ids") || []
      end

      validate_fields(server_ids)
      return if error?

      init_server_connection()

      # stop servers
      servers = []
      if server_ids
        servers = server_ids.map do |id|
          begin
            @client.servers.index(:id => id)
          rescue RightApi::Exceptions::ApiException => e
            write_output "Unable to get server with id #{id}: #{e.message}. Ignoring\n"
            nil
          end
        end.compact
      else
        servers = @client.servers.index(:filter => ["name==#{server_name}"])
      end
      stopped_servers = []
      servers.each do |s|
        begin
          stop_server(s)
          stopped_servers << s
        rescue RightApi::Exceptions::ApiException => e
          msg = "Error stopping server [#{get_server_id(s)}] #{s.name}: #{e.message}. Ignoring"
          Maestro.log.error msg
          write_output "#{msg}\n"
        end
      end

      if get_field('wait_until_stopped')
        stopped_servers.each do |server|
          server_id = get_server_id(server)
          msg = "Waiting for server to stop [#{server_id}] #{server.name}"
          write_output "#{msg}\n"
          Maestro.log.info msg
          wait_for_state("inactive", server_id)
        end
      end

      context_servers = read_output_value('rightscale_servers') || {}
      servers.each do |server|
        next unless context_servers[get_server_id(server)]
        begin
          state = @client.servers(:id => get_server_id(server)).show.state
          context_servers[get_server_id(server)][:state] = state
        rescue RightApi::Exceptions::ApiException => e
          Maestro.log.info "Unable to get server[#{get_server_id(server)}] #{server.name}: #{e.message}. Ignoring\n"
        end
      end

      write_output "Servers stopped\n"

      Maestro.log.info "***********************Completed RightScale.stop***************************"
    end

    def stop_server(server)
      msg = "Stopping server [#{get_server_id(server)}] #{server.name}"
      write_output "#{msg}\n"
      Maestro.log.info msg
      server.current_instance.terminate
    end

    def wait
      Maestro.log.info "Waiting for RightScale servers"

      # TODO: validate states
      state = get_field('state')
      server_name = get_field('nickname')
      server_id = get_field('server_id') || get_field('rightscale_server_id')

      validate_fields(server_id)
      set_error('Invalid fields, must provide state') if !error? and state.nil?
      return if error?

      init_server_connection()
      if server_id and server_id.to_i > 0
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

      server_id = get_server_id(server)

      write_output "Waiting until server #{server_id} is #{state}\n"

      wait_for_state(state, server_id)
      return if error?

      context_servers = read_output_value('rightscale_servers') || {}
      context_servers[server_id][:state] = state if context_servers[server_id]

      write_output "Server is #{state}\n"

      Maestro.log.info "***********************Completed RightScale.wait***************************"
    end

    def get_server
      Maestro.log.info "Retrieving RightScale server information into the Composition"

      # TODO: much duplication with start, but refactor after other changes for deployments land

      server_name = get_field('nickname')
      # TODO: should be used, or make nickname required?
      server_id = get_field('server_id')

      validate_fields(server_id)
      return if error?

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

      server_id = get_server_id(server)

      set_field('rightscale_server_id', server_id) # deprecated
      set_field("#{provider}_ids", (get_field("#{provider}_ids") || []) << server_id)
      set_field("cloud_ids", (get_field("cloud_ids") || []) << server_id)

      context_server = {
          :name => server.name,
          :state => server.state,
      }
      if server.respond_to? :current_instance
        instance = server.current_instance.show
        ip_address = instance.public_ip_addresses.first
        private_ip_address = instance.private_ip_addresses.first

        # save some values in the workitem so they are accessible for deprovision and other tasks
        # using same naming as the fog plugin
        set_field('rightscale_ip_address', ip_address) # deprecated
        set_field('rightscale_private_ip_address', private_ip_address) # deprecated

        set_field("#{provider}_private_ips", (get_field("#{provider}_private_ips") || []) << private_ip_address)
        set_field("cloud_private_ips", (get_field("cloud_private_ips") || []) << private_ip_address)
        set_field("#{provider}_ips", (get_field("#{provider}_ips") || []) << ip_address)
        set_field("cloud_ips", (get_field("cloud_ips") || []) << ip_address)
        context_server = {
            :public_ip_address => ip_address,
            :private_ip_address => private_ip_address,
            :multi_cloud_image => instance.multi_cloud_image.show.name,
            :server_template => instance.server_template.show.name,
            :deployment => instance.deployment.show.name,
            :resource_uid => instance.resource_uid
        }.merge context_server
      end

      write_output "Server information: #{PP.pp context_server, out = ''}\n"

      context_servers = read_output_value('rightscale_servers') || {}
      context_servers[server_id] = context_server
      save_output_value('rightscale_servers', context_servers)

      Maestro.log.info "***********************Completed RightScale.get_server***************************"
    end

    def execute
      Maestro.log.info "Executing RightScript"

      # TODO: much duplication with stop, but refactor after other changes for deployments land

      server_name = get_field('nickname')

      # what to execute on
      server_id = get_field('server_id')
      if server_id and server_id > 0
        # stop server id set in task
        server_ids = [server_id]
      elsif server_name
        # stop server name set in task
        server_ids = nil
      else
        # stop previously started servers
        server_ids = get_field("#{provider}_ids") || []
      end

      validate_fields(server_ids)
      return if error?

      recipe = get_field('recipe')
      unless recipe
        set_error("Invalid fields, must provide recipe")
        return
      end

      init_server_connection()

      # execute on servers
      servers = []
      if server_ids
        servers = server_ids.map do |id|
          begin
            @client.servers.index(:id => id)
          rescue RightApi::Exceptions::ApiException => e
            write_output "Unable to get server with id #{id}: #{e.message}. Ignoring\n"
            nil
          end
        end.compact
      else
        servers = @client.servers.index(:filter => ["name==#{server_name}"])
      end
      tasks = []
      servers.each do |s|
        begin
          task = execute_on_server(recipe, s)
          tasks << task
        rescue RightApi::Exceptions::ApiException => e
          msg = "Error executing on server [#{get_server_id(s)}] #{s.name}: #{e.message}. Ignoring"
          Maestro.log.error msg
          write_output "#{msg}\n"
        end
      end

      if get_field('wait_for_completion')
        tasks.each do |t|
          wait_for_task(recipe, t)
        end
      end

      Maestro.log.info "***********************Completed RightScale.execute***************************"
    end

    def execute_on_server(recipe, s)
      msg = "Executing '#{recipe}' on server [#{get_server_id(s)}] #{s.name}"
      write_output "#{msg}\n"
      Maestro.log.info msg
      s.current_instance.show.run_executable :recipe_name => recipe
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

    # wait for server to be in a state.
    # Timeout after 600s without changing state, check every 10s
    def wait_for_state(state, server_id, timeout=600, interval=10)
      server = nil
      last_state = nil
      i = 0
      while i <= timeout do
        server = @client.servers(:id => server_id).show
        return true if server.state == state

        # print in the output if server changed state, and reset timeout
        if server.state != last_state
          last_state = server.state
          i = 0
          msg = "Server state is now #{server.state}, waiting for #{state}"
          write_output "#{msg}\n"
          Maestro.log.info msg
        else
          Maestro.log.debug "Server state is #{server.state}, waiting for #{state} (#{i}/#{timeout})"
        end

        sleep interval
        i += interval
      end

      msg = "Timed out after #{timeout}s waiting for server #{server.name} to reach state #{state}, is currently #{server.state}"
      Maestro.log.info msg
      set_error msg
    end

    # wait for task to complete
    # Timeout after 600s without changing state, check every 5s
    def wait_for_task(recipe, task, timeout=600, interval=5)
      desired_summary = "completed: #{recipe}"
      last_state = nil
      i = 0
      while i <= timeout do
        summary = task.show.summary
        return true if summary == desired_summary

        # print in the output if task changed state, and reset timeout
        if summary != last_state
          last_state = summary
          i = 0
          msg = "Task is now #{summary}, waiting for #{desired_summary}"
          write_output "#{msg}\n"
          Maestro.log.info msg
        else
          Maestro.log.debug "Server state is #{summary}, waiting for #{desired_summary} (#{i}/#{timeout})"
        end

        sleep interval
        i += interval
      end

      msg = "Timed out after #{timeout}s waiting for receipe #{recipe} to complete, is currently #{task.show.summary}"
      Maestro.log.info msg
      set_error msg
    end

    def close()
    end

    private

    # get the id of a server object returned by the API
    def get_server_id(server)
      File.basename server.href
    end

  end

  class LogWrapper
    def << s
      Maestro.log.debug s
    end
  end
end
