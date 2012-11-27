require 'maestro_agent'
require 'rest_connection'
require 'rubygems'

module MaestroDev
  class RightScaleWorker < Maestro::MaestroWorker

    def validate_fields
      set_error('')

      for f in %w(account_id username password)
        raise "Invalid fields, must provide #{f}" if get_field(f).nil?
      end
    end

    def start
      begin
        Maestro.log.info "Starting RightScale Worker"
        validate_fields

        server_name = get_field('nickname')
        server_id = get_field('server_id')

        raise 'Invalid fields, must provide nickname or server_id' if server_name.nil? and server_id.nil?

        init_server_connection()
        server = Server.find(:first) { |s| s.nickname =~ /#{server_name}/ }
        if server.nil?
          raise "No server matches #{server_name}"
        end
        Maestro.log.info "Found server, '#{server.nickname}'."

        server.reload_current
        server.start

        write_output "Requested server to start #{server.rs_id}\n"
        set_field('rightscale_server_id', server.rs_id)

        server.wait_for_operational_with_dns

        set_field('rightscale_ip_address', server.ip_address)
        set_field('rightscale_private_ip_address', server.private_ip_address)

        write_output "Server up at #{server.ip_address}\n"
      rescue Exception => e
        trace = e.backtrace.join("\n")
        Maestro.log.error("#{e.message}\n#{trace}")
        set_error e.message
      end

      Maestro.log.info "***********************Completed RightScale.start***************************"
    end

    def stop
      begin
        Maestro.log.info "Starting RightScale Worker"
        validate_fields

        server_name = get_field('nickname')
        server_id = get_field('server_id') || get_field('rightscale_server_id')

        raise 'Invalid fields, must provide nickname or server_id' if server_name.nil? and server_id.nil?

        init_server_connection()
        if server_id
          server = Server.find(:first) { |s| s.rs_id = server_id }
          if server.nil?
            raise "No server with id #{server_id}"
          end
          Maestro.log.info "Found server, '#{server.rs_id}'."
        else
          server = Server.find(:first) { |s| s.nickname =~ /#{server_name}/ }
          if server.nil?
            raise "No server matches #{server_name}"
          end
          Maestro.log.info "Found server, '#{server.nickname}'."
        end

        server.reload_current
        server.stop

        write_output "Requested server to stop #{server.rs_id}\n"

        server.wait_for_state("stopped") if get_field('wait_until_stopped')

        write_output "Server stopped\n"
      rescue Exception => e
        trace = e.backtrace.join("\n")
        Maestro.log.error("#{e.message}\n#{trace}")
        set_error e.message
      end

      Maestro.log.info "***********************Completed RightScale.stop***************************"
    end

    def wait
      begin
        Maestro.log.info "Starting RightScale Worker"
        validate_fields

        server_name = get_field('nickname')
        server_id = get_field('server_id') || get_field('rightscale_server_id')

        state = get_field('state')

        raise 'Invalid fields, must provide nickname or server_id' if server_name.nil? and server_id.nil?
        raise 'Invalid fields, must provide state' if state.nil?

        init_server_connection()
        if server_id
          server = Server.find(:first) { |s| s.rs_id = server_id }
          if server.nil?
            raise "No server with id #{server_id}"
          end
          Maestro.log.info "Found server, '#{server.rs_id}'."
        else
          server = Server.find(:first) { |s| s.nickname =~ /#{server_name}/ }
          if server.nil?
            raise "No server matches #{server_name}"
          end
          Maestro.log.info "Found server, '#{server.nickname}'."
        end

        server.reload_current

        write_output "Waiting until server #{server.rs_id} is #{state}\n"

        server.wait_for_state(state)

        write_output "Server is #{state}\n"
      rescue Exception => e
        trace = e.backtrace.join("\n")
        Maestro.log.error("#{e.message}\n#{trace}")
        set_error e.message
      end

      Maestro.log.info "***********************Completed RightScale.wait***************************"
    end

    def init_server_connection
      account_id = get_field('account_id')
      username = get_field('username')
      password = get_field('password')

      api_version = get_field('api_version') || "1.0"

      settings = {
          :user => username,
          :pass => password,
          :api_url => "https://my.rightscale.com/api/acct/#{account_id}",
          :common_headers => {
              'X_API_VERSION' => "#{api_version}"
          },
          :azure_hack_on => true,
          :azure_hack_retry_count => 5,
          :azure_hack_sleep_seconds => 60,
          :api_logging => false,
          :log => self,
      }
      # Used to detect API access inside Server calls
      Ec2SshKeyInternal.reconnect(settings)
      Server.reconnect(settings)
    end

    # Logging methods - TODO move into a utility class or the plugin parent?
    def write(message)
      write_output "#{message}"
    end

    def close()

    end
  end
end
