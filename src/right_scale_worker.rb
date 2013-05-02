require 'maestro_agent'
require 'rubygems'
require File.expand_path('../rightscale_api_helper', __FILE__)

module MaestroDev
  class RightScaleWorker < Maestro::MaestroWorker

    def provider
      'rightscale'
    end

    # FIXME - convert everything over to allowing RightScale Refresh Tokens instead of username/password
    def validate_base_fields(missing_fields)
      if get_field('account_id').nil?
        missing_fields << 'account_id'
      end
      if get_field('refresh_token').nil? && get_field('username').nil? && get_field('password').nil?
        # missing everything, we'll mark all the fields
        missing_fields << '(username and password) or refresh_token'
      elsif get_field('refresh_token').nil?
        # if not refresh token, but either username/password we'll specify which one
        if get_field('username').nil?
          missing_fields << 'username'
        else
          missing_fields << 'password'
        end
      end
    end

    def validate_server_fields(missing_fields = [])
      if get_field('server_id').nil? and ((get_field('nickname').nil? or (get_field('deployment_id').nil? and get_field('deployment_name').nil?)))
        missing_fields << '(nickname and deployment_id) or (nickname and deployment_name) or server_id'
      end
      validate_base_fields(missing_fields)

      set_error("Invalid fields, must provide #{missing_fields.join(", ")}") unless missing_fields.empty?
    end

    def validate_wait_fields
      missing_fields = []
      if get_field('state').nil?
        missing_fields << 'state'
      end
      validate_server_fields(missing_fields)

      set_error("Invalid fields, must provide #{missing_fields.join(", ")}") unless missing_fields.empty?
    end

    def validate_deployment_fields
      missing_fields = []
      if get_field('deployment_id').nil? and get_field('deployment_name').nil?
        missing_fields << 'deployment'
      end
      validate_base_fields(missing_fields)

      set_error("Invalid fields, must provide #{missing_fields.join(", ")}") unless missing_fields.empty?
    end

    # set a wrapper that writes output to maestro
    class MaestroLogWrapper
      @worker
      def initialize(worker)
        @worker = worker
      end
      def << m
        self.info(m)
      end
      def error(m)
        Maestro.log.error m
        @worker.write_output "ERROR: #{m}\n"
      end
      def warn(m)
        Maestro.log.warn m
        @worker.write_output "WARN: #{m}\n"
      end
      def info(m)
        Maestro.log.info m
        @worker.write_output "INFO: #{m}\n"
      end
      def debug(m)
        Maestro.log.debug m
        @worker.write_output "DEBUG: #{m}\n"
      end
      def level(l)
        case l
        when Logger::ERROR
          Maestro.log_level=:error
        when Logger::WARN
          Maestro.log_level=:warn
        when Logger::INFO
          Maestro.log_level=:info
        when Logger::DEBUG
          Maestro.log_level=:debug
        end
      end
    end

    def get_client()
      account_id = get_field('account_id')
      username = get_field('username')
      password = get_field('password')
      api_url = get_field('api_url')
      refresh_token = get_field('refresh_token')
      oauth_url = get_field('oauth_url')

      @log_wrapper = MaestroLogWrapper.new(self)
      
      client = RightScaleApiHelper.new(
          :account_id => account_id,
          :username => username,
          :password => password,
          :api_url => api_url,
          :oauth_url => oauth_url,
          :refresh_token => refresh_token,
          :logger => @log_wrapper
      )

      return client
    end

    # TODO: refactor to use helper, the trim down
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

    def start
      Maestro.log.info "Starting RightScale Worker"

      # make sure we have all the necessary fields
      validate_server_fields()
      return if error?

      client = get_client()

      # either server_id is needed, or server_name + deployment is needed
      server_id = get_field('server_id')
      server_name = get_field('nickname')
      deployment_id = get_field('deployment_id')
      deployment_name = get_field('deployment_name')
      wait_until_started = get_field('wait_until_started')

      if server_id
        write_output "Looking up server by id=#{server_id}\n"
      else
        if deployment_id
          write_output "Looking up server by nickname=#{server_name} deployment_id=#{deployment_id}\n"
        else
          write_output "Looking up server by nickname=#{server_name} deployment_name=#{deployment_name}\n"
        end
      end

      server = client.get_server(
          :server_id => server_id,
          :server_name => server_name,
          :deployment_id => deployment_id,
          :deployment_name => deployment_name
      )
      server_id = get_server_id(server)

      write_output "Requesting server start for id=#{server_id}\n"

      set_field('rightscale_server_id', server_id) # deprecated
      set_field("#{provider}_ids", (get_field("#{provider}_ids") || []) << server_id)
      set_field("cloud_ids", (get_field("cloud_ids") || []) << server_id)

      result = client.start(
        :server_id => server_id,
        :wait_until_started => wait_until_started
      )

      if !result.success
        errors = result.errors
        write_output "Error starting server for id=#{server_id}\n"
        set_error errors.first.message
        return
      end

      instance = result.value
      ip_address = instance.public_ip_addresses.first
      private_ip_address = instance.private_ip_addresses.first

      set_field('rightscale_ip_address', ip_address)
      set_field('rightscale_private_ip_address', private_ip_address)

      set_field("#{provider}_private_ips", (get_field("#{provider}_private_ips") || []) << private_ip_address)
      set_field("cloud_private_ips", (get_field("cloud_private_ips") || []) << private_ip_address)
      set_field("#{provider}_ips", (get_field("#{provider}_ips") || []) << ip_address)
      set_field("cloud_ips", (get_field("cloud_ips") || []) << ip_address)

      context_servers = read_output_value('rightscale_servers') || {}
      context_servers[server_id] = {
          :name => server.name,
          :state => server.state,
          :public_ip_address => ip_address,
          :private_ip_address => private_ip_address,
          :multi_cloud_image => instance.multi_cloud_image.show.name,
          :server_template => instance.server_template.show.name,
          :deployment => instance.deployment.show.name,
          :resource_uid => instance.resource_uid
      }
      save_output_value('rightscale_servers', context_servers)
      set_field('state', server.show.state)

      write_output "Server up at #{ip_address}\n"

      Maestro.log.info "***********************Completed RightScale.start***************************"
    end

    def stop
      Maestro.log.info "Stopping RightScale Worker"

      # make sure we have all the necessary fields
      validate_server_fields()
      return if error?

      client = get_client()

      # either server_id is needed, or server_name + deployment is needed
      server_id = get_field('server_id')
      server_name = get_field('nickname')
      deployment_id = get_field('deployment_id')
      deployment_name = get_field('deployment_name')
      wait_until_stopped = get_field('wait_until_stopped')

      if server_id
        write_output "Looking up server by id=#{server_id}\n"
      elsif server_name
        if deployment_id
          write_output "Looking up server by nickname=#{server_name} deployment_id=#{deployment_id}\n"
        else
          write_output "Looking up server by nickname=#{server_name} deployment_name=#{deployment_name}\n"
        end
      else
        # get the last previously started server
        sid = get_field('rightscale_server_id')
        if server_id && server_id.to_i > 0
          server_id = sid
          write_output "Using previously started RightScale server id=#{server_id}\n"
        else
          set_error 'Unable to find server id or name to stop.'
          return
        end
      end

      server = client.get_server(
          :server_id => server_id,
          :server_name => server_name,
          :deployment_id => deployment_id,
          :deployment_name => deployment_name
      )
      server_id = get_server_id(server)

      write_output "Requesting server stop for id=#{server_id}\n"

      result = client.stop(
          :server_id => server_id,
          :wait_until_stopped => wait_until_stopped
      )

      if !result.success
        errors = result.errors
        set_error errors.first.message
        return
      end

      server = result.value

      set_field('rightscale_server_id', server_id)
      context_servers = read_output_value('rightscale_servers') || {}
      context_servers[server_id][:state] = server.show.state if context_servers[server_id]
      set_field('state', server.show.state)

      write_output "Server stopped successfully for id=#{server_id}\n"

      Maestro.log.info "***********************Completed RightScale.stop***************************"
    end

    def wait
      Maestro.log.info "Waiting for RightScale Worker"

      # make sure we have all the necessary fields
      validate_server_fields()
      return if error?

      client = get_client()

      # either server_id is needed, or server_name + deployment is needed
      server_id = get_field('server_id')
      server_name = get_field('nickname')
      deployment_id = get_field('deployment_id')
      deployment_name = get_field('deployment_name')
      state = get_field('state')

      if server_id
        write_output "Looking up server by id=#{server_id}\n"
      else
        if deployment_id
          write_output "Looking up server by nickname=#{server_name} deployment_id=#{deployment_id}\n"
        else
          write_output "Looking up server by nickname=#{server_name} deployment_name=#{deployment_name}\n"
        end
      end

      # if we don't already have the server id, do other lookups to get it
      if !server_id
        server = client.get_server(
            :server_id => server_id,
            :server_name => server_name,
            :deployment_id => deployment_id,
            :deployment_name => deployment_name
        )
        server_id = get_server_id(server)
      end

      write_output "Waiting for Server (id=#{server_id}, name=#{server_name}) to enter state=#{state}\n"

      result = client.wait(
          :server_id => server_id,
          :state => state
      )

      set_field('rightscale_server_id', server_id)

      if !result.success
        errors = result.errors
        set_error errors.first.message
        return
      end

      server = result.value

      context_servers = read_output_value('rightscale_servers') || {}
      context_servers[server_id][:state] = server.show.state if context_servers[server_id]
      set_field('state', server.show.state)

      write_output "Server reached state successfully for id=#{server_id}\n"

      Maestro.log.info "***********************Completed RightScale.wait***************************"
    end

    def start_deployment
      Maestro.log.info "Starting RightScale Deployment"

      deployment_id = get_field('deployment_id')
      deployment_name = get_field('deployment_name')
      wait_until_started = get_field('wait_until_started')
      show_progress = get_field('show_progress')

      validate_deployment_fields()
      return if error?

      client = get_client()

      result = client.start_servers_in_deployment(
          :deployment_id => deployment_id,
          :deployment_name => deployment_name,
          :wait_until_started => wait_until_started,
          :show_progress => show_progress
      )

      # FIXME - start using the log wrapper to write to the maestro log and write_output, but write_output should
      # probably be less verbose at some point in the near future
      if result.success
        if wait_until_started
          @log_wrapper.info "Deployment (id=#{deployment_id} name=#{deployment_name}) started"
        else
          @log_wrapper.info "Deployment (id=#{deployment_id} name=#{deployment_name}) launched"
        end
      else
        @log_wrapper.error "Deployment (id=#{deployment_id} name=#{deployment_name}) startup had errors"
      end

      server_instances = result.value
      if server_instances.nil? || server_instances.size == 0
        @log_wrapper.info "No servers in deployment (id=#{deployment_id} name=#{deployment_name}) to start"
        return
      end

      if !result.errors.nil?
        @log_wrapper.info "#{result.errors.size} Errors starting deployment (id=#{deployment_id} name=#{deployment_name})"
        result.errors.each{|error|
          @log_wrapper.error "  #{error.message}, backtrace=#{error.backtrace}"
        }
      end

      if !result.notices.nil?
        @log_wrapper.info "#{result.notices.size} Notices starting deployment (id=#{deployment_id} name=#{deployment_name})"
        result.notices.each{|notice|
          @log_wrapper.warn "  #{notice.message}"
        }
      end

      # bail if there are errors
      if !result.errors.nil?
        return
      end

      server_instances.each {|server_id, instance|
        ip_address = instance.public_ip_addresses.first
        private_ip_address = instance.private_ip_addresses.first

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

        Maestro.log.info "Server up at #{ip_address}\n"
        write_output "Server up at #{ip_address}\n"

        @log_wrapper.debug "Server instance id=#{server_id} state=#{instance.state} dump=#{instance.inspect} resource_uid=#{instance.resource_uid}"
        @log_wrapper.debug "  resource_uid: #{instance.resource_uid}"
        @log_wrapper.debug "  deployment: #{instance.deployment.show.name}"
        @log_wrapper.debug "  public_ip_addresses: #{instance.public_ip_addresses}"
        @log_wrapper.debug "  private_ip_addresses: #{instance.public_ip_addresses}"
        @log_wrapper.debug "  multi_cloud_image: #{instance.multi_cloud_image.show.name}"
        @log_wrapper.debug "  server_template: #{instance.server_template.show.name}"
      }

      Maestro.log.info "***********************Completed RightScale.start***************************"
    end


    def stop_deployment
      Maestro.log.info "Stopping RightScale Deployment"

      deployment_id = get_field('deployment_id')
      deployment_name = get_field('deployment_name')
      wait_until_stopped = get_field('wait_until_stopped')
      show_progress = get_field('show_progress')

      validate_deployment_fields()
      return if error?

      client = get_client()

      result = client.stop_servers_in_deployment(
          :deployment_id => deployment_id,
          :deployment_name => deployment_name,
          :wait_until_stopped => wait_until_stopped,
          :show_progress => show_progress
      )

      # FIXME - start using the log wrapper to write to the maestro log and write_output, but write_output should
      # probably be less verbose at some point in the near future
      if result.success
        if wait_until_stopped
          @log_wrapper.info "Deployment (id=#{deployment_id} name=#{deployment_name}) stopped"
        else
          @log_wrapper.info "Deployment (id=#{deployment_id} name=#{deployment_name}) stop requested"
        end
      else
        @log_wrapper.error "Deployment (id=#{deployment_id} name=#{deployment_name}) stop had errors"
      end

      server_instances = result.value
      if server_instances.nil? || server_instances.size == 0
        @log_wrapper.info "No servers in deployment (id=#{deployment_id} name=#{deployment_name}) to stop"
        return
      end

      if !result.errors.nil?
        @log_wrapper.info "#{result.errors.size} Errors stopping deployment (id=#{deployment_id} name=#{deployment_name})"
        result.errors.each{|error|
          @log_wrapper.error "  #{error.message}, backtrace=#{error.backtrace}"
        }
      end

      if !result.notices.nil?
        @log_wrapper.info "#{result.notices.size} Notices stopping deployment (id=#{deployment_id} name=#{deployment_name})"
        result.notices.each{|notice|
          @log_wrapper.warn "  #{notice.message}"
        }
      end

      # bail if there are errors
      if !result.errors.nil?
        return
      end

      server_instances.each {|server_id, instance|
        context_servers = read_output_value('rightscale_servers') || {}
        context_servers[server_id] = {
            :name => server.name,
            :state => "inactive"
        }
        save_output_value('rightscale_servers', context_servers)

        @log_wrapper.debug "Server (id=#{server_id}, name=#{server.name}) down"
      }

      Maestro.log.info "***********************Completed RightScale.stop***************************"
    end

    # TODO: pull code into helper and trim this down
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

    private
    # get the id of a server object returned by the API
    def get_server_id(server)
      if (server)
        return (File.basename server.href).to_i
      end
      return nil
    end
  end
end
