require 'maestro_agent'
require 'rubygems'
require File.expand_path('../rightscale_api_helper', __FILE__)

module MaestroDev
  class RightScaleWorker < Maestro::MaestroWorker

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
      server_id = (File.basename server.href).to_i

      write_output "Requesting server start for id=#{server_id}\n"

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

      set_field('rightscale_server_id', server_id)
      instance = result.value
      ip_address = instance.public_ip_addresses.first
      set_field('rightscale_ip_address', ip_address)
      private_ip_address = instance.private_ip_addresses.first
      set_field('rightscale_private_ip_address', private_ip_address)

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
      server_id = (File.basename server.href).to_i

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

      server = client.get_server(
          :server_id => server_id,
          :server_name => server_name,
          :deployment_id => deployment_id,
          :deployment_name => deployment_name
      )
      server_id = (File.basename server.href).to_i

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
  end
end
