require 'right_api_client'
require 'rubygems'
require 'logger'
require 'optparse'
require 'open-uri'

module MaestroDev
  module RightScalePlugin
    class RightScaleApiHelper
      CONNECT_PARAMS = %w(email password account_id api_url api_version cookies refresh_token oauth_url)
  
      DEFAULT_API_URL = 'https://my.rightscale.com'
      DEFAULT_API_VERSION = '1.5'
      DEFAULT_OAUTH_URL = 'https://my.rightscale.com/api/oauth2'
  
      DEFAULT_TIMEOUT = 600
      DEFAULT_INTERVAL = 10
  
      STATE_INACTIVE = 'inactive'
      STATE_PENDING = 'pending'
      STATE_BOOTING = 'booting'
      STATE_OPERATIONAL = 'operational'
      STATE_TERMINATING = 'terminating'
      STATE_DECOMMISSIONING = 'decommissioning'
  
      CLOUDFLOW_PROCESS_PATH = '/api/cloud_flow/processes'
      SESSION_PATH = '/api/session'
      ACCOUNTS_PATH = '/api/accounts'
  
      @trace = false,
      @email, @password, @account_id, @oauth_url, @refresh_token, @api_url = DEFAULT_API_URL, @api_version = DEFAULT_API_VERSION
  
      ##
      # Constructor
      # Params
      # +args+:: hash of params listed below
      # +:email+:: RightScale user email
      # +:password+:: RightScale user password
      # +:oauth_url+:: RightScale API OAuth URL
      # +:refresh_token+:: RightScale refresh token (can be used instead of email/password)
      # +:account_id+:: RightScale account id
      # +:api_url+:: RightScale API URL
      # +:api_version+:: RightScale API Version (default: 1.5)
      # +:delay_connect+:: do not connect on initialization (currently only used internally for CLI)
      # +:verbose+:: Enable DEBUG level logging
      def initialize(args)
        delay_connect = args[:delay_connect] || false
        @logger = args[:logger] || Logger.new(STDOUT)
        @verbose = args[:verbose]
        @trace = args[:trace]
  
        # if this is a logger instance, set the level
        if (@logger.instance_of?Logger)
          if @verbose || @trace
            @logger.level = Logger::DEBUG
            @logger.debug 'Setting log level to DEBUG'
          else
            @logger.level = Logger::INFO
          end
        end
  
        args_no_pass = args.reject {|key, _| key == :password }
        @logger.debug "new(#{args_no_pass.inspect})"
  
        if !delay_connect
          # initialize accepts all connect settings
          if args[:account_id] && ((args[:email] && args[:password]) || args[:refresh_token])
            connect(args)
          else
            # we don't have sufficient credentials, so throw error
            if !args[:account_id]
              raise InsufficientCredentials.new('Account ID was not provided');
            else
              raise InsufficientCredentials.new('Either Email and Password must both be specified or refresh_token must be specified');
            end
          end
        end
      end
  
      def connect(args={}) # :nodoc:
        indent = args[:indent] || ''
        cookies = args[:cookies] || {}
  
        args_no_pass = args.reject {|key, _| key == :password }
        @logger.debug "#{indent}connect(#{args_no_pass.inspect})"
  
        # Initializing all instance variables from hash, else use what's already in the instance vars
        args.each { |key,value|
          instance_variable_set("@#{key}", value) if value && CONNECT_PARAMS.include?(key.to_s)
        } if args.is_a? Hash
  
        # FIXME - handle timeout of the session token here
        if @client.nil?
          if @refresh_token
            @logger.debug "#{indent}connect(): getting access token from refresh token"
            result = get_access_token(
                :account_id => @account_id,
                :refresh_token => @refresh_token,
                :oauth_url => @oauth_url,
                :api_url => @api_url,
                :api_version => @api_version,
                :indent => "#{indent}  ")
  
            access_token = result.value
            cookies[:rs_gbl] = "#{access_token}"
            @logger.debug "#{indent}connect(): using cookies: #{cookies}"
  
            @logger.debug "#{indent}connect(): Creating a RightApi client (refresh_token=#{@refresh_token},access_token=#{access_token},email=#{@email},password=*****,account_id=#{@account_id},api_url=#{@api_url},api_version=#{@api_version})"
            @client = RightApi::Client.new(
                :account_id => @account_id,
                :api_url => @api_url,
                :api_version => @api_version,
                :cookies => cookies)
          else
            @client = RightApi::Client.new(:email => @email, :password => @password, :account_id => @account_id, :api_url => @api_url, :api_version => @api_version)
          end
          if @trace
            @client.log LogWrapper.new(@logger)
          end
        else
          @logger.debug "#{indent}connect(): Already have a RightApi client, skipping"
        end
      end
  
      ##
      # Start a server
      # Params
      # +args+:: hash of params listed below
      # +:server_id+:: The ID of the server to start
      # +:server_name+:: The nickname of the server to start
      # +:deployment_id+:: The deployment the server is in (combined with server_name for unique lookup)
      # +:deployment_name+:: The deployment the server is in (combined with server_name for unique lookup)
      # +:wait_until_started+:: Whether or not to wait until the server reaches the Operational state before returning
      # +:timeout+:: The maximum amount of time to wait (in seconds) for the server to reach Operational state
      # +:timeout_interval+:: The amount of time to wait (in seconds) between requests for server state
      # +:timeout_reset+:: Whether or not to reset the timeout when the server state changes (e.g. pending -> booting)
      # +:show_progress+:: Whether or not to log progress checks when waiting for Operational server state
      # +:indent+:: Used internally to indent log messages for pretty call stack tracing
      def start(args)
        # for readability
        server_id = args[:server_id]
        server_name = args[:server_name]
        deployment_id = args[:deployment_id]
        deployment_name = args[:deployment_name]
        wait_until_started = args[:wait_until_started]
        timeout = args[:timeout]
        timeout_interval = args[:timeout_interval]
        timeout_reset = args[:timeout_reset]
        show_progress = args[:show_progress]
        indent = args[:indent] || ''
  
        args_no_pass = args.reject {|key, _| key == :password }
        @logger.debug "#{indent}start(#{args_no_pass.inspect})"
  
        server = get_server(
            :server_id => server_id,
            :server_name => server_name,
            :deployment_id => deployment_id,
            :deployment_name => deployment_name,
            :indent => "#{indent}  "
        )
  
        if server.nil?
          @logger.error "#{indent}start(): Server (id=#{server_id}, name=#{server.name}, deployment_id=#{deployment_id}, deployment_name=#{deployment_name} state=#{server.state}) cannot be found"
          return Result.new(:success => false, :errors => [Exception.new("Cannot find Server (id=#{server_id}, name=#{server.name}, deployment_id=#{deployment_id}, deployment_name=#{deployment_name}) to start")])
        end
  
        @logger.info "#{indent}start(): Starting Server (id=#{server_id}, name=#{server_name})"
  
        if server.state == STATE_PENDING || server.state == STATE_BOOTING
          @logger.info "#{indent}start(): Server (id=#{server_id}, name=#{server.name}, state=#{server.state}) already pending/booting"
        elsif server.state == STATE_OPERATIONAL
          @logger.error "#{indent}start(): Not starting Server (id=#{server_id}, name=#{server.name}, state=#{server.state}), already operational"
          return Result.new(:success => true, :notices => [Exception.new('Cannot start server that is already operational')], :value => server.show.current_instance.show)
        elsif server.state != STATE_INACTIVE
          @logger.error "#{indent}start(): Not starting Server (id=#{server_id}, name=#{server.name}, state=#{server.state}), not inactive"
          return Result.new(:success => false, :errors => [Exception.new('Cannot start server that is not in inactive state')], :value => server)
        end
  
        # get the server id from the server href
        # note: this is dumb, but the server id doesn't come back as a field in RightScale data.  sigh.
        server_id = (File.basename server.href).to_i
  
        instance = nil
        if server.state == STATE_INACTIVE
          @logger.info "#{indent}start(): Requesting start of Server (id=#{server_id}, name=#{server_name})"
  
          # launch the server
          begin
            instance_resource = server.launch
            instance = instance_resource.show
          rescue => e
            @logger.error("start(): Error launching Server (id=#{server_id}, name=#{server_name}): #{e.message}")
            return Result.new(:success => false, :errors => [e])
          end
        else
          instance = server.show.current_instance.show
        end
  
        if wait_until_started
          @logger.info "#{indent}start(): Waiting for Server (id=#{server_id}, name=#{server_name}) to start up"
          result = wait(
              :state => STATE_OPERATIONAL,
              :server_id => server_id,
              :show_progress => show_progress,
              :timeout => timeout,
              :timeout_interval => timeout_interval,
              :timeout_reset => timeout_reset,
              :indent => "#{indent}  "
          )
          # replace the instance with a newer one, that'll have updated information after the wait
          instance = @client.servers(:id => server_id).show.current_instance.show
          if !result.success
            @logger.info "#{indent}start(): Started Server (id=#{server_id}, name=#{server_name}), but failed to wait for state"
            return Result.new(:success => false, :errors => result.errors, :value => instance)
          end
          @logger.info "#{indent}start(): Started Server (id=#{server_id}, name=#{server_name})"
        else
          @logger.info "#{indent}start(): Requested start of Server (id=#{server_id}, name=#{server_name})"
        end
  
        @logger.debug "#{indent}start(): Server (id=#{server_id}, name=#{server_name}) dump: #{instance.inspect}"
        return Result.new(:success => true, :value => instance)
      end
  
      ##
      # Stop a server
      # Params
      # +args+:: hash of params listed below
      # +:server_id+:: The ID of the server to stop
      # +:server_name+:: The nickname of the server to stop
      # +:deployment_id+:: The deployment the server is in (combined with server_name for unique lookup)
      # +:deployment_name+:: The deployment the server is in (combined with server_name for unique lookup)
      # +:wait_until_stopped+:: Whether or not to wait until the server reaches the Inactive state before returning
      # +:timeout+:: The maximum amount of time to wait (in seconds) for the server to reach Inactive state
      # +:timeout_interval+:: The amount of time to wait (in seconds) between requests for server state
      # +:timeout_reset+:: Whether or not to reset the timeout when the server state changes (e.g. decommissioning -> stopping)
      # +:show_progress+:: Whether or not to log progress checks when waiting for Inactive server state
      # +:indent+:: Used internally to indent log messages for pretty call stack tracing
      def stop(args)
        # for readability
        server_id = args[:server_id]
        server_name = args[:server_name]
        deployment_id = args[:deployment_id]
        deployment_name = args[:deployment_name]
        wait_until_stopped = args[:wait_until_stopped]
        show_progress = args[:show_progress]
        timeout = args[:timeout]
        timeout_interval = args[:timeout_interval]
        timeout_reset = args[:timeout_reset]
        indent = args[:indent] || ''
  
        args_no_pass = args.reject {|key, _| key == :password }
        @logger.debug "#{indent}stop(#{args_no_pass.inspect})"
  
        server = get_server(
            :server_id => server_id,
            :server_name => server_name,
            :deployment_id => deployment_id,
            :deployment_name => deployment_name,
            :indent => "#{indent}  "
        )
  
        if server.nil?
          @logger.error "#{indent}start(): Server (id=#{server_id}, name=#{server.name}, deployment_id=#{deployment_id}, deployment_name=#{deployment_name} state=#{server.state}) cannot be found"
          return Result.new(:success => false, :errors => [Exception.new("Cannot find Server (id=#{server_id}, name=#{server.name}, deployment_id=#{deployment_id}, deployment_name=#{deployment_name}) to stop")])
        end
  
        @logger.info "#{indent}stop(): Stopping Server (id=#{server_id}, name=#{server_name})"
  
        if server.state == STATE_TERMINATING || server.state == STATE_DECOMMISSIONING
          @logger.info "#{indent}stop(): Server (id=#{server_id}, name=#{server.name}, state=#{server.state}) already terminating/decommissioning"
        elsif server.state == STATE_INACTIVE
          @logger.error "#{indent}stop(): Not stopping Server (id=#{server_id}, name=#{server.name}, state=#{server.state}), not operational"
          return Result.new(:success => true, :notice => [Exception.new('Cannot stop server that is inactive')], :value => server)
        elsif server.state != STATE_OPERATIONAL
          @logger.error "#{indent}stop(): Not stopping Server (id=#{server_id}, name=#{server.name}, state=#{server.state}), not operational"
          return Result.new(:success => false, :errors => [Exception.new('Cannot stop server that is not in operational state')], :value => server)
        end
  
        # get the server id from the server href
        # note: this is dumb, but the server id doesn't come back as a field in RightScale data.  sigh.
        server_id = (File.basename server.href).to_i
  
        if server.state == STATE_OPERATIONAL
          @logger.info "#{indent}stop(): Requesting stop of Server (id=#{server_id}, name=#{server_name})"
  
          # terminate this server instance
          begin
            server.current_instance.terminate
          rescue => e
            @logger.error("stop(): Error launching server '#{server.name}' "+e.message)
            return Result.new(:success => false, :errors => [e], :value => server)
          end
        end
  
        if wait_until_stopped
          @logger.info "#{indent}stop(): Waiting for Server (id=#{server_id}, name=#{server_name}) to stop"
          result = wait(
              :state => STATE_INACTIVE,
              :server_id => server_id,
              :show_progress => show_progress,
              :timeout => timeout,
              :timeout_interval => timeout_interval,
              :timeout_reset => timeout_reset,
              :indent => "#{indent}  "
          )
          @logger.info "#{indent}stop(): Stopped Server (id=#{server_id}, name=#{server_name})"
          if !result.success
            return Result.new(:success => false, :errors => result.errors, :value => result.value)
          end
        else
          @logger.info "#{indent}stop(): Stopping Server (id=#{server_id}, name=#{server_name})"
        end
  
        return Result.new(:success => true, :value => server)
      end
  
      ##
      # Wait for a server to reach a specified state.
      # Params
      # +args+:: hash of params listed below
      # +:server_id+:: The ID of the server to wait for
      # +:server_name+:: The nickname of the server to wait for
      # +:deployment_id+:: The deployment the server is in (combined with server_name for unique lookup)
      # +:deployment_name+:: The deployment the server is in (combined with server_name for unique lookup)
      # +:state+:: The state to wait for the server to enter before returning
      # +:timeout+:: The maximum amount of time to wait (in seconds) for the server to reach Inactive state
      # +:timeout_interval+:: The amount of time to wait (in seconds) between requests for server state
      # +:timeout_reset+:: Whether or not to reset the timeout when the server state changes (e.g. decommissioning -> stopping)
      # +:show_progress+:: Whether or not to log progress checks when waiting for Inactive server state
      # +:indent+:: Used internally to indent log messages for pretty call stack tracing
      def wait(args)
        # for readability
        server_id = args[:server_id]
        server_name = args[:server_name]
        deployment_id = args[:deployment_id]
        deployment_name = args[:deployment_name]
        state = args[:state]
        timeout = args[:timeout] || DEFAULT_TIMEOUT
        timeout_interval = args[:timeout_interval] || DEFAULT_INTERVAL
        reset_timer_on_state_change = args[:timeout_reset] || false
        show_progress = args[:show_progress]
        indent = args[:indent] || ''
  
        args_no_pass = args.reject {|key, _| key == :password }
        @logger.debug "#{indent}wait(#{args_no_pass.inspect})"
  
        server = get_server(
            :server_id => server_id,
            :server_name => server_name,
            :deployment_id => deployment_id,
            :deployment_name => deployment_name,
            :indent => "#{indent}  "
        )
  
        if timeout <= 0
          if server.state != state
            # not in the right state and no time to wait, so fast fail here
            return Result.new(:success => false, :errors => [Exception.new("Timeout <= 0 when waiting for Server (id=#{server_id}, name=#{server.name}) in deployment (id=#{deployment_id}, name=#{deployment_name}) to reach state #{state}")])
          else
            # if we're already in the right state, then return true
            return Result.new(:success => true, :value => server)
          end
        end
  
        if server.nil?
          @logger.error "#{indent}wait(): Server (id=#{server_id}, name=#{server.name}, deployment_id=#{deployment_id}, deployment_name=#{deployment_name} state=#{server.state}) cannot be found"
          return Result.new(:success => false, :errors => [Exception.new("Cannot find Server (id=#{server_id}, name=#{server.name}, deployment_id=#{deployment_id}, deployment_name=#{deployment_name}) to wait for")])
        end
  
        @logger.info "#{indent}wait(): Waiting for Server (id=#{server_id}, name=#{server_name}) to enter state #{state}"
  
        # get the server id from the server href, if we were only called with server_name
        if server_id.nil?
          server_id = (File.basename server.href).to_i
        end
  
        last_state = nil
        i = 0
        while i <= timeout do
          server = get_server(
              :server_id => server_id,
              :server_name => server_name,
              :deployment_id => deployment_id,
              :deployment_name => deployment_name,
              :indent => "#{indent}  "
          )
  
          if server.state == state
            @logger.debug "#{indent}wait(): Server (id=#{server_id}, name=#{server.name}, deployment_id=#{deployment_id}, deployment_name=#{deployment_name}) state is now #{server.state}"
            return Result.new(:success => true, :value => server)
          end
  
          # we've done our last check
          if i == timeout
            break
          end
  
          # print in the output if server changed state, and reset timeout
          if server.state != last_state
            last_state = server.state
            if reset_timer_on_state_change
              i = 0
            end
  
            if show_progress
              @logger.info "#{indent}wait(): Server state is now #{server.state}, waiting for #{state}"
            else
              @logger.debug "#{indent}wait(): Server state is now #{server.state}, waiting for #{state}"
            end
          else
            if show_progress
              @logger.info "#{indent}wait(): Server state is #{server.state}, waiting for #{state} (#{i}/#{timeout})"
            else
              @logger.debug "#{indent}wait(): Server state is #{server.state}, waiting for #{state} (#{i}/#{timeout})"
            end
          end
  
          sleep timeout_interval
          i += timeout_interval
        end
  
        @logger.info "#{indent}wait(): Timed out after #{timeout}s waiting for Server (id=#{server_id}, name=#{server.name}, deployment_id=#{deployment_id}, deployment_name=#{deployment_name}) to reach state #{state}, currently in state #{server.state}"
        return Result.new(:success => false, :errors => [Exception.new("Timed out after #{timeout}s waiting for Server (id=#{server_id}, name=#{server.name}, deployment_id=#{deployment_id}, deployment_name=#{deployment_name}) to reach state #{state}, currently in state #{server.state}")], :value => server)
      end
  
      ##
      # Get a server
      # Params
      # +args+:: hash of params listed below
      # +:server_id+:: The ID of the server to get
      # +:server_name+:: The nickname of the server to get
      # +:deployment_id+:: The deployment the server is in (combined with server_name for unique lookup)
      # +:deployment_name+:: The deployment the server is in (combined with server_name for unique lookup)
      # +:indent+:: Used internally to indent log messages for pretty call stack tracing
      def get_server(args)
        # for convenience
        server_id = args[:server_id]
        server_name = args[:server_name]
        deployment_id = args[:deployment_id]
        deployment_name = args[:deployment_name]
        indent = args[:indent] || ''
  
        args_no_pass = args.reject {|key, _| key == :password }
        @logger.debug "#{indent}get_server(#{args_no_pass.inspect})"
  
        if server_id and server_id > 0
          server = @client.servers(:id => server_id).show
          if server.nil?
            @logger.warn "#{indent}get_server(): No Server (id=#{server_id}) found"
            return
          end
  
          d = server.deployment
          deployment_id = (File.basename d.href).to_i
  
          @logger.debug "#{indent}get_server(): Found Server (id=#{server_id}) in Deployment (id=#{deployment_id})"
        else
          servers = @client.servers.index(:filter => ["name==#{server_name}"])
          # exact match the name
          servers.delete_if {|s| s.name != server_name }
          @logger.debug "#{indent}get_server(): #{servers.size} exact matches for server name '#{server_name}'."
  
          filtered = []
          # find the server with the correct deployment id, if specified
          if deployment_id || deployment_name
            servers.each {|s|
              server_id = (File.basename s.href).to_i
              # get the deployment for the server
              d = s.deployment
              d_id = (File.basename d.href).to_i
              @logger.debug "#{indent}get_server(): Server (id=#{server_id}) in Deployment (id=#{deployment_id})"
  
              # if we have the deployment id, perfect match, save it
              if d_id == deployment_id
                @logger.debug "#{indent}get_server(): Server matches Deployment by id"
                deployment_name = d.name
                filtered = [s]
                break
              # else we have to get the deployment by name and take the first that matches
              elsif deployment_name
                @logger.debug "#{indent}get_server(): Seeing if Deployment (id=#{d_id}) matches deployment by name '#{deployment_name}'"
                d = get_deployment(:deployment_id => d_id.to_i)
                if d.name == deployment_name
                  @logger.debug "#{indent}get_server(): Matched Deployment (id=#{d_id}, name=#{d.name})"
                  deployment_id = d_id
                  filtered = [s]
                  break
                end
              end
            }
  
            servers = filtered
          end
  
          if servers.nil? || servers.empty?
            @logger.warn "#{indent}get_server(): No server matches name='#{server_name}'"
            return
          elsif servers.size > 1
            @logger.warn "#{indent}get_server(): Multiple server matches for name='#{server_name}'"
            return
          end
  
          @logger.debug "#{indent}get_server(): Found servers for Server (id=#{server_id}, name=#{server_name}) in Deployment (id=#{deployment_id}, name=#{deployment_name})"
          # only one server left
          server = servers.first.show
        end
  
        @logger.debug "#{indent}get_server(): Returning Server (id=#{server_id}, name=#{server_name}) dump: #{server.inspect}"
  
        return server
      end
  
      ##
      # Get a deployment
      # Params
      # +args+:: hash of params listed below
      # +:deployment_id+:: The id of the deployment to get
      # +:deployment_name+:: The name of the deployment to get
      # +:indent+:: Used internally to indent log messages for pretty call stack tracing
      def get_deployment(args)
        # for convenience
        deployment_id = args[:deployment_id]
        deployment_name = args[:deployment_name]
        indent = args[:indent] || ''
  
        args_no_pass = args.reject {|key, _| key == :password }
        @logger.debug "#{indent}get_deployment(#{args_no_pass.inspect})"
  
        deployment = nil
        if deployment_id and deployment_id > 0
          deployment = @client.deployments(:id => deployment_id).show
          if deployment.nil?
            @logger.warn "#{indent}get_deployment(): No deployment with id '#{deployment_id}'"
            return
          end
          @logger.debug "#{indent}get_deployment(): Found deployment '#{deployment_id}'."
        else
          deployments = @client.deployments.index(:filter => ["name==#{deployment_name}"]);
          if deployments.nil?
            @logger.warn "#{indent}get_deployment(): No deployments match '#{deployment_name}'"
            return
          elsif deployments.size > 1
            @logger.warn "#{indent}get_deployment(): Multiple deployments match '#{deployment_name}'"
            return
          end
  
          # only one deployment left
          deployment = deployments.first
          @logger.debug "#{indent}get_deployment(): Found deployment '#{deployment.name}'."
        end
  
        deployment_id = (File.basename deployment.href).to_i
        @logger.debug "#{indent}get_deployment(): Deployment (id=#{deployment_id}, name=#{deployment_name}): #{deployment.inspect}"
  
        return deployment
      end
  
      ##
      # Get a list of all servers in a deployment
      # Params
      # +args+:: hash of params listed below
      # +:deployment_id+:: The id of the deployment the servers are in
      # +:deployment_name+:: The name of the deployment the servers are in
      # +:indent+:: Used internally to indent log messages for pretty call stack tracing
      def get_servers_in_deployment(args)
        # for convenience
        deployment_id = args[:deployment_id]
        deployment_name = args[:deployment_name]
        indent = args[:indent] || ''
  
        args_no_pass = args.reject {|key, _| key == :password }
        @logger.debug "#{indent}get_servers_in_deployment(#{args_no_pass.inspect})"
        @logger.debug "#{indent}get_servers_in_deployment(): Getting servers in Deployment (id=#{deployment_id}, name=#{deployment_name})"
  
        deployment = get_deployment(:deployment_id => deployment_id, :deployment_name => deployment_name, :indent => "#{indent}  ");
        if deployment.nil?
          @logger.warn "#{indent}get_servers_in_deployment(): Deployment (id=#{deployment_id}, name=#{deployment_name}) not found"
          return
        end
  
        servers = deployment.show.servers.index
        @logger.warn "#{indent}get_servers_in_deployment(): Returning servers for deployment (name=#{deployment_name}, id=#{deployment_id}): #{servers.inspect}"
        return servers
      end
  
      ##
      # Start all servers in a deployment
      # Params
      # +args+:: hash of params listed below
      # +:deployment_id+:: The deployment the servers are in
      # +:deployment_name+:: The deployment the servers are in
      # +:wait_until_started+:: Whether or not to wait until all the servers reach the Operational state before returning
      # +:timeout+:: The maximum amount of time to wait (in seconds) for the servers to reach Inactive state
      # +:timeout_interval+:: The amount of time to wait (in seconds) between requests for servers' states
      # +:timeout_reset+:: Whether or not to reset the timeout when a server's state changes (e.g. pending -> booting)
      # +:show_progress+:: Whether or not to log progress checks when waiting for Operational servers' state
      # +:indent+:: Used internally to indent log messages for pretty call stack tracing
      def start_servers_in_deployment(args)
        # for convenience
        deployment_id = args[:deployment_id]
        deployment_name = args[:deployment_name]
        wait_until_started = args[:wait_until_started]
        timeout = args[:timeout] || DEFAULT_TIMEOUT
        timeout_interval = args[:timeout_interval] || DEFAULT_INTERVAL
        timeout_reset = args[:timeout_reset]
        show_progress = args[:show_progress]
        indent = args[:indent] || ''
  
        args_no_pass = args.reject {|key, _| key == :password }
        @logger.debug "#{indent}start_servers_in_deployment(#{args_no_pass.inspect})"
        @logger.info "#{indent}start_servers_in_deployment(): Starting Deployment (id=#{deployment_id}, name=#{deployment_name})"
  
        servers = get_servers_in_deployment(:deployment_id => deployment_id, :deployment_name => deployment_name, :indent => "#{indent}  ")
  
        if servers.nil?
          @logger.warn "#{indent}start_servers_in_deployment(): No servers were found in Deployment (id=#{deployment_id}, name=#{deployment_name})"
          return
        end
  
        errors = []
        notices = []
        launched_servers = []
        server_instances = Hash.new()
  
        # for each server, fork the starts in parallel
        servers.each {|server|
          error = nil
          server_id = (File.basename server.href).to_i
  
          if server.state == STATE_INACTIVE
            begin
              # start this server without waiting
              @logger.info "#{indent}start_servers_in_deployment(): Starting server (name=#{server.name}, id=#{server_id}) in deployment (name=#{deployment_name}, id=#{deployment_id})"
              instance = start(:server_id => server_id, :show_progress => show_progress, :indent => "#{indent}  ")
              launched_servers << server
              server_instances[server_id] = instance
            rescue => e
              @logger.error "#{indent}start_servers_in_deployment(): Couldn't start Server (id=#{server_id}, name=#{server.name}) in deployment (name=#{deployment_name}, id=#{deployment_id})"
              @logger.error "#{indent}start_servers_in_deployment():   #{e.message}"
              @logger.error "#{indent}start_servers_in_deployment():   #{e.backtrace}"
              errors << e
            end
          elsif server.state == STATE_PENDING || server.state == STATE_BOOTING
            @logger.info "#{indent}start_servers_in_deployment(): Server (id=#{server_id}, name=#{server.name}, state=#{server.state}) in deployment (name=#{deployment_name}, id=#{deployment_id}) already pending/booting"
            launched_servers << server
            server_instances[server_id] = server.show.current_instance.show
          else
            @logger.info "#{indent}start_servers_in_deployment(): Not starting Server (id=#{server_id}, name=#{server.name}, state=#{server.state}) in deployment (name=#{deployment_name}, id=#{deployment_id}), not inactive"
            launched_servers << server
            notices << Exception.new("Couldn't start server (id=#{server_id}, name=#{server.name}, state=#{server.state}) in deployment (name=#{deployment_name}, id=#{deployment_id}), not inactive")
            server_instances[server_id] = server.show.current_instance.show
          end
        }
  
        if wait_until_started
          timeout_left = timeout
          start_time = Time.now.to_i
  
          # waiting for each server in the deployment
          launched_servers.each {|server|
            server_id = (File.basename server.href).to_i
  
            # if timeout interval is 0, just return
            if timeout_left == 0
              @logger.info "#{indent}start_servers_in_deployment(): Timed out waiting for other servers in the deployment, no time left to wait for Server (id=#{server_id}, name=#{server.name}) in deployment (id=#{deployment_id}, name=#{deployment_name}) to reach state #{state}, currently in state #{server.state}"
              return Result.new(:success => false, :errors => [Exception.new("Timed out waiting for other servers in the deployment, no time left to wait for Server (id=#{server_id}, name=#{server.name}) in deployment (id=#{deployment_id}, name=#{deployment_name}) to reach state #{state}, currently in state #{server.state}")], :value => server)
            else
              @logger.info "#{indent}start_servers_in_deployment(): Waiting for Server (id=#{server_id}, name=#{server.name}) in deployment (id=#{deployment_id}, name=#{deployment_name})"
            end
  
            begin
              result = wait(
                  :state => STATE_OPERATIONAL,
                  :server_id => server_id,
                  :show_progress => show_progress,
                  :timeout => timeout_left,
                  :timeout_interval => timeout_interval,
                  :timeout_reset => timeout_reset,
                  :indent => "#{indent}  "
              )
  
              # the timeout is for all servers, so let's make sure we are removing elapsed time from the max time we have
              # left to wait
              end_time=Time.now.to_i
              time_elapsed = end_time - start_time
              timeout_left -= time_elapsed
              if timeout_left < 0
                timeout_left = 0
              end
              @logger.debug "#{indent}start_servers_in_deployment(): timeout_left=#{timeout_left} start_time=#{start_time} end_time=#{end_time} time_elapsed=#{time_elapsed}"
  
              if !result.success
                @logger.error "#{indent}start_servers_in_deployment(): Timed out waiting for Server (id=#{server_id}, name=#{server.name}) in deployment (name=#{deployment_name}, id=#{deployment_id})"
                errors << result.errors.first
              end
            rescue => e
              @logger.error "#{indent}start_servers_in_deployment(): Error waiting for Server (id=#{server_id}, name=#{server.name}) in deployment (name=#{deployment_name}, id=#{deployment_id}): #{e.message}"
              errors << e
            end
          }
        end
  
        @logger.debug "#{indent}start_servers_in_deployment(): returning result (error count=#{errors.size}, notice count=#{notices.count})"
        return Result.new(:success => (errors.size==0), :errors => errors, :notices => notices, :value => server_instances)
      end
  
      ##
      # Start all servers in a deployment
      # Params
      # +args+:: hash of params listed below
      # +:deployment_id+:: The deployment the servers are in
      # +:deployment_name+:: The deployment the servers are in
      # +:wait_until_stopped+:: Whether or not to wait until all the servers reach the Inactive state before returning
      # +:timeout+:: The maximum amount of time to wait (in seconds) for the servers to reach Inactive state
      # +:timeout_interval+:: The amount of time to wait (in seconds) between requests for servers' states
      # +:timeout_reset+:: Whether or not to reset the timeout when a server's state changes (e.g. decommissioning -> stopping)
      # +:show_progress+:: Whether or not to log progress checks when waiting for Inactive servers' state
      # +:indent+:: Used internally to indent log messages for pretty call stack tracing
      def stop_servers_in_deployment(args)
        # for convenience
        deployment_id = args[:deployment_id]
        deployment_name = args[:deployment_name]
        wait_until_stopped = args[:wait_until_stopped]
        timeout = args[:timeout] || DEFAULT_TIMEOUT
        timeout_interval = args[:timeout_interval] || DEFAULT_INTERVAL
        timeout_reset = args[:timeout_reset]
        show_progress = args[:show_progress]
        indent = args[:indent] || ''
  
        args_no_pass = args.reject {|key, _| key == :password }
        @logger.debug "#{indent}stop_servers_in_deployment(#{args_no_pass.inspect})"
        @logger.debug "#{indent}stop_servers_in_deployment(#{args.inspect})"
        @logger.info "#{indent}stop_servers_in_deployment(): Stopping Deployment (id=#{deployment_id}, name=#{deployment_name})"
  
        servers = get_servers_in_deployment(:deployment_id => deployment_id, :deployment_name => deployment_name, :indent => "#{indent}  ")
  
        if servers.nil?
          @logger.warn "#{indent}stop_servers_in_deployment(): No servers were found in Deployment (id=#{deployment_id}, name=#{deployment_name})"
          return
        end
  
        errors = []
        notices = []
        wait_for_servers = []
        stopped_servers = Hash.new()
  
        # for each server, fork the starts in parallel
        servers.each {|server|
          error = nil
          server_id = (File.basename server.href).to_i
  
          if server.state == STATE_OPERATIONAL
            # stop this server without waiting
            @logger.info "#{indent}stop_servers_in_deployment(): Stopping server (name=#{server.name}, id=#{server_id}) in deployment (name=#{deployment_name}, id=#{deployment_id})"
            result = stop(:server_id => server_id, :show_progress => args[:show_progress], :indent => "#{indent}  ")
            if !result.errors.nil? && result.errors.size > 0
              errors << result.errors
            else
              wait_for_servers << server
            end
          elsif server.state == STATE_TERMINATING
            # servers that have are trying to stop, we want to wait for these too
            @logger.info "#{indent}stop_servers_in_deployment(): Server (id=#{server_id}, name=#{server.name}) in deployment (name=#{deployment_name}, id=#{deployment_id}) already stopping"
            wait_for_servers << server
          else
            @logger.info "#{indent}stop_servers_in_deployment(): Not stopping Server (id=#{server_id}, name=#{server.name}, state=#{server.state}) in deployment (name=#{deployment_name}, id=#{deployment_id}), not operational"
            notices << Exception.new("Couldn't stop server (id=#{server_id}, name=#{server.name}, state=#{server.state}) in deployment (name=#{deployment_name}, id=#{deployment_id}), not operational")
          end
  
          stopped_servers[server_id] = server
        }
  
        if wait_until_stopped
          timeout_left = timeout
          start_time = Time.now.to_i
  
          # waiting for each server in the deployment that we just stopped or we're actively trying to shut down
          wait_for_servers.each {|server|
            server_id = (File.basename server.href).to_i
  
            # if timeout interval is 0, just return
            if timeout_left == 0
              @logger.info "#{indent}stop_servers_in_deployment(): Timed out waiting for other servers in the deployment, no time left to wait for Server (id=#{server_id}, name=#{server.name}) in deployment (id=#{deployment_id}, name=#{deployment_name}) to reach state #{state}, currently in state #{server.state}"
              return Result.new(:success => false, :errors => [Exception.new("Timed out waiting for other servers in the deployment, no time left to wait for Server (id=#{server_id}, name=#{server.name}) in deployment (id=#{deployment_id}, name=#{deployment_name}) to reach state #{state}, currently in state #{server.state}")], :value => server)
            else
              @logger.info "#{indent}stop_servers_in_deployment(): Waiting for Server (id=#{server_id}, name=#{server.name}) in deployment (id=#{deployment_id}, name=#{deployment_name})"
            end
  
            begin
              result = wait(
                  :state => STATE_INACTIVE,
                  :server_id => server_id,
                  :show_progress => show_progress,
                  :timeout => timeout,
                  :timeout_interval => timeout_interval,
                  :timeout_reset => timeout_reset,
                  :indent => "#{indent}  "
              )
  
              # the timeout is for all servers, so let's make sure we are removing elapsed time from the max time we have
              # left to wait
              end_time=Time.now.to_i
              time_elapsed = end_time - start_time
              timeout_left -= time_elapsed
              if timeout_left < 0
                timeout_left = 0
              end
              @logger.debug "#{indent}stop_servers_in_deployment(): timeout_left=#{timeout_left} start_time=#{start_time} end_time=#{end_time} time_elapsed=#{time_elapsed}"
  
              if !result.success
                @logger.error "#{indent}stop_servers_in_deployment(): Timed out waiting for Server (id=#{server_id}, name=#{server.name}) in deployment (name=#{deployment_name}, id=#{deployment_id})"
                errors << result.errors.first
              end
            rescue => e
              @logger.error "#{indent}stop_servers_in_deployment(): Error waiting for Server (id=#{server_id}, name=#{server.name}) in deployment (name=#{deployment_name}, id=#{deployment_id}): #{e.message}"
              errors << e
            end
          }
        end
  
        @logger.debug "#{indent}stop_servers_in_deployment(): returning result (error count=#{errors.size}, notice count=#{notices.count})"
        return Result.new(:success => (errors.size==0), :errors => errors, :notices => notices, :value => stopped_servers)
      end
  
      ##
      # Create a CloudFlow process
      # Params
      # +args+:: hash of params listed below
      # +:cloudflow_name+:: The CloudFlow name
      # +:cloudflow_inputs+:: The CloudFlow inputs as a hash of key => value
      # +:cloudflow_definition+:: The CloudFlow definition
      # +:wait_until_complete+:: Whether or not to wait until the CloudFlow finishes executing before returning
      # +:timeout+:: The maximum amount of time to wait (in seconds) for the servers to reach Inactive state
      # +:timeout_interval+:: The amount of time to wait (in seconds) between requests for servers' states
      # +:timeout_reset+:: Whether or not to reset the timeout when a server's state changes (e.g. pending -> booting)
      # +:show_progress+:: Whether or not to log progress checks when waiting for Operational servers' state
      # +:indent+:: Used internally to indent log messages for pretty call stack tracing
      def create_cloudflow_process(args)
        # for convenience
        cloudflow_name = args[:cloudflow_name]
        cloudflow_inputs = args[:cloudflow_inputs]
        cloudflow_definition = args[:cloudflow_definition]
        wait_until_complete = args[:wait_until_complete]
        timeout = args[:timeout] || DEFAULT_TIMEOUT
        timeout_interval = args[:timeout_interval] || DEFAULT_INTERVAL
        timeout_reset = args[:timeout_reset]
        # TODO - must needs refactor, since the creds should only need to be in this instance and then used as needed
        access_token = args[:access_token]
        show_progress = args[:show_progress]
        api_version = DEFAULT_API_VERSION
        indent = args[:indent] || ''
  
        args_no_pass = args.reject {|key, _| key == :password }
        @logger.debug "#{indent}create_cloudflow_process(#{args_no_pass.inspect})"
        @logger.info "#{indent}create_cloudflow_process(): Creating CloudFlow process (name=#{cloudflow_name})"
  
        errors = []
        notices = []
        location = nil
        access_token = nil
  
        begin
          post_data = Hash.new();
  
          client = RestClient::Resource.new("#{@api_url}#{CLOUDFLOW_PROCESS_PATH}", :timeout => timeout)
          if @trace
            RestClient.log = LogWrapper.new(@logger)
          end
  
          if cloudflow_inputs
            if !cloudflow_inputs.is_a?(Hash)
              @logger.error "#{indent}create_cloudflow_process(): CloudFlow inputs are invalid"
              return Result.new(:success => false, :errors => [Exception.new('CloudFlow inputs are invalid')])
            else
              cloudflow_inputs.each{|key, value|
                post_data["cloud_flow_process[inputs]#{key}"] = value
              }
            end
          end
  
          if !access_token
            # get an access token
            new_args = args
            new_args[:indent => "#{indent}  "]
            result = get_access_token(new_args)
            if !result.success
              @logger.error "#{indent}get_cloudflow_process(): No credentials provided}"
              return Result.new(:success => false, :errors => [Exception.new('No credentials provided')], :value => result.to_hash)
            end
            access_token = result.value
          end
  
          # cloud_flow_process[name]=start_deploy_test1
          # cloud_flow_process[inputs]['$deployment_id']=391022003
          # cloud_flow_process[cloud_flow_definition]
          post_data['cloud_flow_process[name]'] = cloudflow_name
          post_data['cloud_flow_process[cloud_flow_definition]'] = cloudflow_definition
          @logger.debug "#{indent}create_cloudflow_process(): Posting data: #{post_data.inspect}"
          client.post(post_data,
                       :X_API_VERSION => api_version,
                       :content_type => 'application/x-www-form-urlencoded',
                       :accept => '*/*',
                       :cookie => ["rs_gbl=#{access_token}"]
          ) do |response, request, result|
            @logger.debug "#{indent}create_cloudflow_process(): got response: response=#{response.inspect} result=#{result.to_hash.inspect}"
  
            case response.code
              when 201
                #Location: /api/cloud_flow/processes/e22bd546b1ea1e12b79719227537a344
                location = result["Location"]
                @logger.debug "#{indent}create_cloudflow_process(): Successfully created CloudFlow process: #{location}"
              when 403
                @logger.error "#{indent}create_cloudflow_process(): #{response}"
                return Result.new(:success => false, :errors => [Exception.new("#{response}")], :value => result.to_hash)
              else
                response_hash = nil
                begin
                  response_hash = JSON.parse(response)
                rescue => e
                  # do nothing
                end
  
                if response_hash && response_hash.is_a?(Hash) && response_hash.has_key?('summary')
                  @logger.error "#{indent}create_cloudflow_process(): Error creating CloudFlow process: summary: #{response_hash['summary']}"
                  return Result.new(:success => false, :errors => [Exception.new(response_hash['summary'])])
                elsif result.to_hash.has_key?('create_cloudflow_process')
                  @logger.error "#{indent}create_cloudflow_process(): Error creating CloudFlow process: error_description: #{result.to_hash['error_description']}"
                  return Result.new(:success => false, :errors => [Exception.new(result.to_hash['error_description'])])
                else
                  @logger.error "#{indent}create_cloudflow_process(): Error creating CloudFlow process: response: #{reponse.code} #{response}"
                  return Result.new(:success => false, :errors => [Exception.new("#{reponse.code} #{response}")])
                end
            end
          end
        rescue RestClient::Exception => e
          @logger.error "#{indent}create_cloudflow_process(): Error creating CloudFlow process: #{e.response}"
          return Result.new(:success => false, :errors => [Exception.new(e.response['error_description'])], :value => e.response)
        rescue => e
          @logger.error "#{indent}create_cloudflow_process(): Error creating CloudFlow process: #{e.message}"
          return Result.new(:success => false, :errors => [e])
        end
  
        process_id = File.basename location
  
        if wait_until_complete
          args[:access_token] = access_token
          begin
            timeout_left = timeout
            last_state = ''
            interval_start = Time.now()
            while timeout_left > 0
              current_interval_start = Time.now()
              @logger.info "#{indent}create_cloudflow_process(): Waiting for CloudFlow process (id=#{process_id}, location=#{location})"
              result = get_cloudflow_process(:process_id => process_id, :indent => "#{indent}  ", :timeout => timeout, :access_token => access_token)
  
              # get the amount of time it took to do the get
              current_interval_completed = Time.now() - current_interval_start
              current_interval_left = timeout_interval - current_interval_completed > 0 ? timeout_interval - current_interval_completed : 0
  
              if result.success
                process = result.value
                state = process['state']
                @logger.debug "#{indent}create_cloudflow_process(): returned process is #{process}"
  
                reset = false
                if state != last_state
                  last_state = state
                  if timeout_reset
                    timeout_left = timeout
                    reset = true
                  end
  
                  if show_progress
                    @logger.info "#{indent}create_cloudflow_process(): Process state is now #{state}"
                  else
                    @logger.debug "#{indent}create_cloudflow_process(): Process state is now #{state}"
                  end
                else
                  if show_progress
                    @logger.info "#{indent}create_cloudflow_process(): Process state is #{state} (#{timeout-timeout_left}/#{timeout})"
                  else
                    @logger.debug "#{indent}create_cloudflow_process(): Process state is #{state} (#{timeout-timeout_left}/#{timeout})"
                  end
                end
  
                if state == 'terminated'
                  @logger.info "#{indent}create_cloudflow_process(): Process (id=#{process_id}, location=#{location}) is now stopped"
                  break
                elsif state == 'in_error'
                  # FIXME - we should attempt to abort this CloudFlow
                  @logger.error "#{indent}create_cloudflow_process(): Process (id=#{process_id}, location=#{location}) had an error, attempting to cancel it"
                  return Result.new(:success => false, :errors => [Exception.new('CloudFlow failed to complete successfully')])
                end
  
                sleep_for = current_interval_left
                if reset
                  # we're going to sleep for a full interval now
                  sleep_for = timeout_interval
                end
  
                # as long as sleeping won't make us go past our timeout, sleep
                if Time.now() + sleep_for - interval_start < timeout
                  @logger.info "#{indent}create_cloudflow_process(): Sleeping for #{sleep_for} seconds"
                  sleep sleep_for
                else
                  return Result.new(:success => false, :errors => [Exception.new('Timed out waiting for CloudFlow to complete')])
                end
  
                # less get time + sleep time
                timeout_left -= current_interval_completed + sleep_for
              else
                @logger.error "#{indent}create_cloudflow_process(): Problem getting state for CloudFlow Process (id=#{process_id}, location=#{location}): #{result.errors.inspect}"
                return Result.new(:success => false, :errors => result.errors, :notices => result.notices)
              end
            end
          rescue => e
            @logger.error "#{indent}create_cloudflow_process(): Error waiting for CloudFlow to terminate (id=#{process_id}, location=#{location}): #{e.message}"
            return Result.new(:success => true, :errors => [e])
          end
        end
  
        @logger.debug "#{indent}create_cloudflow_process(): Returning from CloudFlow create: #{location}"
        return Result.new(:success => true, :value => process_id)
      end
  
      # Get a CloudFlow process
      # Params
      # +args+:: hash of params listed below
      # +:process_id+:: The CloudFlow process id
      # +:timeout+:: The maximum amount of time to wait (in seconds) for the servers to reach Inactive state
      # +:indent+:: Used internally to indent log messages for pretty call stack tracing
      #
      # Example
      # {
      # "launched_at": "2012-06-11 17:12:18 UTC",
      # "name": "test",
      # "created_at": "2012-06-11 17:12:17 UTC",
      # "updated_at": "2012-06-11 17:12:19 UTC",
      # "max_process_size": 1048576,
      # "links": [
      #   {
      #     "href": "/api/cloud_flow/processes/98ccfcdc3be811e1abbb81f6594ef2ec",
      #     "rel": "self"
      #   },
      #   {
      #     "href": "/api/cloud_flow/processes/98ccfcdc3be811e1abbb81f6594ef2ec/tasks",
      #     "rel": "cloud_flow_tasks"
      #   }
      # ],
      # "state": "running",
      # "process_size": 3912
      # }
      def get_cloudflow_process(args)
        # for convenience
        process_id = args[:process_id]
        timeout = args[:timeout] || DEFAULT_TIMEOUT
        api_version = DEFAULT_API_VERSION
        # TODO - must needs refactor, since the creds should only need to be in this instance and then used as needed
        access_token = args[:access_token]
        indent = args[:indent] || ''
  
        args_no_pass = args.reject {|key, _| key == :password }
        @logger.debug "#{indent}get_cloudflow_process(#{args_no_pass.inspect})"
        @logger.info "#{indent}get_cloudflow_process(): Fetching CloudFlow process (process_id=#{process_id})"
  
        # FIXME - return here if there is no process_id
        if !process_id || process_id.nil?
          return Result.new(:success => false, :errors => [Exception.new('CloudFlow process ID must be specified')])
        end
  
        location = nil
  
        begin
          if !access_token
            # get an access token
            new_args = args
            new_args[:indent => "#{indent}  "]
            result = get_access_token(new_args)
            if !result.success
              @logger.error "#{indent}get_cloudflow_process(): No credentials provided}"
              return Result.new(:success => false, :errors => result.errors, :notices => result.notices)
            end
            access_token = result.value
          end
  
          # get the cloudflow
          @client = RestClient::Resource.new("#{@api_url}#{CLOUDFLOW_PROCESS_PATH}/#{process_id}", :timeout => timeout)
          if @trace
            RestClient.log = LogWrapper.new(@logger)
          end
  
          @client.get(:X_API_VERSION => api_version, :accept => '*/*', :cookie => ["rs_gbl=#{access_token}"]
          ) do |response, request, result|
            @logger.debug "#{indent}get_cloudflow_process(): got response: response=#{response.inspect} result=#{result.to_hash.inspect}"
  
            response_hash = nil
            begin
              response_hash = JSON.parse(response)
            rescue => e
              # do nothing
            end
  
            case response.code
              when 200
                @logger.debug "#{indent}get_cloudflow_process(): Successfully fetched CloudFlow process: #{response}"
                return Result.new(:success => true, :value => response_hash)
              when 403
                @logger.error "#{indent}get_cloudflow_process(): #{response}"
                return Result.new(:success => false, :errors => [Exception.new("#{response}")], :value => result.to_hash)
              else
                if response_hash && response_hash.is_a?(Hash) && response_hash.has_key?('summary')
                  @logger.error "#{indent}get_cloudflow_process(): Error fetching CloudFlow process: summary: #{response_hash['summary']}"
                  return Result.new(:success => false, :errors => [Exception.new(response_hash['summary'])])
                elsif result.to_hash.has_key?('error_description')
                  @logger.error "#{indent}get_cloudflow_process(): Error fetching CloudFlow process: error_description: #{result.to_hash['error_description']}"
                  return Result.new(:success => false, :errors => [Exception.new(result.to_hash['error_description'])])
                else
                  @logger.error "#{indent}get_cloudflow_process(): Error fetching CloudFlow process: response: #{reponse.code} #{response}"
                  return Result.new(:success => false, :errors => [Exception.new("#{reponse.code} #{response}")])
                end
            end
          end
        rescue RestClient::Exception => e
          @logger.error "#{indent}get_cloudflow_process(): Error fetching CloudFlow process: #{e.response}"
          return Result.new(:success => false, :errors => [Exception.new(e.response['error_description'])], :value => e.response)
        rescue => e
          @logger.error "#{indent}get_cloudflow_process(): Error fetching CloudFlow process: #{e.message}"
          return Result.new(:success => false, :errors => [e])
        end
      end
  
      ##
      # Get an access token, which can be used as a session cookie
      # Params
      # +args+:: hash of params listed below
      # +:oauth_url+:: OAuth URL needed to obtain an access token from a refresh token (required if using refresh_token)
      # +:refresh_token+:: The refresh token (required if using refresh_token)
      # +:api_url+:: The base API url (required if using user/pass)
      # +:email+:: if a refresh token is not specified, then we'll use regular creds (required if using user/pass)
      # +:password+:: if a refresh token is not specified, then we'll use regular creds (required if using user/pass)
      # +:api_version+:: The API version to use (default is 1.5)
      # +:indent+:: Used internally to indent log messages for pretty call stack tracing
      def get_access_token(args)
        api_url = args[:api_url] || DEFAULT_API_URL
        oauth_url = args[:oauth_url] || DEFAULT_OAUTH_URL
        refresh_token = args[:refresh_token]
        email = args[:email]
        password = args[:password]
        account_id = args[:account_id] || @account_id
        api_version = args[:api_version] || DEFAULT_API_VERSION
        timeout = args[:timeout] || DEFAULT_TIMEOUT
        indent = args[:indent] || ''
  
        args_no_pass = args.delete_if {|key, _| key == "password" }
        @logger.debug "#{indent}get_access_token(#{args_no_pass.inspect})"
  
        if @trace
          RestClient.log = LogWrapper.new(@logger)
        end
  
        if refresh_token
          begin
            client = RestClient::Resource.new(oauth_url, :timeout => timeout)
  
            post_data = Hash.new()
            post_data['grant_type'] = 'refresh_token'
            post_data['refresh_token'] = refresh_token
            client.post(post_data,
                :X_API_VERSION => api_version,
                :content_type => 'application/x-www-form-urlencoded',
                :accept => '*/*'
            ) do |response, request, result|
              @logger.debug "#{indent}get_access_token(): got response: response=#{response.inspect} result=#{result.to_hash.inspect}"
  
              data = JSON.parse(response)
              case response.code
                when 200
                  @logger.debug "#{indent}get_access_token(): got access token: #{data['access_token']}"
                  return Result.new(:success => true, :value => data['access_token'])
                else
                  @logger.error "#{indent}get_access_token(): error while getting access token: #{e.response}"
                  return Result.new(:success => false, :errors => [Exception.new(data['error_description'])], :value => data)
              end
            end
          rescue RestClient::Exception => e
            @logger.error "#{indent}get_access_token(): error while getting access token: #{e.response}"
            return Result.new(:success => false, :errors => [Exception.new(e.response['error_description'])], :value => e.response)
          rescue => e
            @logger.error "#{indent}get_access_token(): error while getting access token: #{e}"
            return Result.new(:success => false, :errors => [e])
          end
        elsif email && password && account_id
          begin
            #curl -v -X GET -H X-API-Version:1.5 -d 'username=user@@maestrodev.com' -d 'password=pass' -d 'account_href=/api/accounts/$id' https://us-3.rightscale.com/api/session
            client = RestClient::Resource.new("#{api_url}#{SESSION_PATH}", :timeout => timeout)
  
            post_data = Hash.new()
            post_data['email'] = email
            post_data['password'] = password
            post_data['account_href'] = "#{ACCOUNTS_PATH}/#{account_id}"
            client.post(post_data, :X_API_VERSION => api_version, :accept => '*/*'
            ) do |response, request, result|
              @logger.debug "#{indent}get_access_token(): got response: response=#{response.inspect} result=#{result.to_hash.inspect}"
  
              data = result.to_hash
              case response.code
                when 204
                  cookies = nil
                  if data['set-cookie']
                    cookies = data['set-cookie']
                  elsif data['Set-Cookie']
                    cookies = data['Set-Cookie']
                  else
                    @logger.error "#{indent}get_access_token(): Couldn't find access token in response: #{data.inspect}"
                    return Result.new(:success => false, :errors => [Exception.new("Couldn't find access token in response")], :value => data)
                  end
  
                  # find the correct cookie, strip out the access token, URI decode to translate %3D back into =
                  access_token = nil;
                  cookies.each {|cookie|
                    if matches = /rs_gbl=([^;]+)/.match(cookie)
                      access_token = URI::decode(matches[0][7..-1]) # strip the rs_gbl=
                      break
                    end
                  }
  
                  @logger.debug "#{indent}get_access_token(): got access token: #{access_token}"
                  return Result.new(:success => true, :value => access_token)
                else
                  @logger.error "#{indent}get_access_token(): error while getting access token: #{e.response}"
                  return Result.new(:success => false, :errors => [Exception.new(data['error_description'])], :value => data)
              end
            end
          rescue RestClient::Exception => e
            @logger.error "#{indent}get_access_token(): error while getting access token: #{e.response}"
            return Result.new(:success => false, :errors => [Exception.new(e.response['error_description'])], :value => e.response)
          rescue => e
            @logger.error "#{indent}get_access_token(): error while getting access token: #{e}"
            return Result.new(:success => false, :errors => [e])
          end
        else
          return Result.new(:success => false, :errors => [Exception.new('No refresh token was specified, nor was a username/password/account')])
        end
      end
  
      class LogWrapper # :nodoc: all
        def initialize(logger)
          @logger = logger
        end
        def << (s)
          @logger.debug s
        end
      end
  
      class Result  # :nodoc: all
        @success = true
        @notices = []
        @errors = []
        @value = nil
  
        def initialize(args)
          # initializing all instance variables from hash, else use what's already in the instance vars
          args.each { |key,value|
            instance_variable_set("@#{key}", value) if value
          } if args.is_a? Hash
        end
  
        def success
          return @success
        end
  
        # an array of non-fatal exceptions
        def notices
          return @notices
        end
  
        # an array of fatal exceptions
        def errors
          return @errors
        end
  
        def value
          return @value
        end
  
        def inspect
          "success=#{@success} value=#{@value} errors=#{@errors} notices=#{@notices}"
        end
      end
    end
  
    class InsufficientCredentials < Exception
      def initialize(message="")
        super(message)
      end
    end
  
    # This is some CLI code for testing
    if __FILE__ == $0
      options = {}
      parser = OptionParser.new do |opts|
        opts.banner = "Usage: #{__FILE__} [options]"
  
        opts.separator ''
        opts.separator 'API Client options:'
  
        # API client options
        opts.on('--refresh-token [token]', 'Refresh token') do |t|
          options[:refresh_token] = t
        end
        opts.separator ''
        opts.on('--username [email]', 'Username') do |u|
          options[:email] = u
        end
        opts.on('--password [password]', 'Password') do |p|
          options[:password] = p
        end
  
        opts.on('--account [id]', 'Account ID') do |a|
          options[:account_id] = a
        end
        opts.on('--api-url [url]', 'API URL') do |u|
          options[:api_url] = u
        end
        opts.on('--oauth-url [url]', 'OAuth URL') do |u|
          options[:oauth_url] = u
        end
        opts.on('--api-version [version]', 'API Version (1.0 or 1.5)') do |version|
          options[:api_version] = version
        end
  
        opts.separator ''
        opts.separator 'Operation options:'
  
        opts.on('--operation operation', 'Operation to invoke\n',
                'get-access-token - Get the access token using either the --refresh-token, or --username and --password',
                'get-server - Get the server specified by --server-id or --server-name',
                'start-server - Start the server specified by --server-id or --server-name',
                'stop-server - Stop the server specified by --server-id or --server-name',
                'get-deployment - Get the deployment specified by --deployment-id or --deployment-name',
                'get-servers-in-deployment - Get the servers in the deployment specified by --deployment-id or --deployment-name',
                'start-servers-in-deployment - Start the servers in the deployment specified by --deployment-id or --deployment-name',
                'stop-servers-in-deployment - Stop the servers in the deployment specified by --deployment-id or --deployment-name',
                'get-cloudflow-process - Get the specified CloudFlow process',
                'create-cloudflow-process - Create the specified CloudFlow process using --cloudflow-name, --cloudflow-inputs, --cloudflow-definition'
        ) do |operation|
          options[:operation] = operation
        end
  
        opts.separator ''
        opts.separator 'Server options:'
  
        # Fields for API calls
        opts.on('--server-id [id]', Integer, 'Server ID') do |i|
          options[:server_id] = i
        end
        opts.on('--server-name [name]', 'Server Name') do |n|
          options[:server_name] = n
        end
  
        opts.separator ''
        opts.separator 'Deployment options:'
  
        opts.on('--deployment-id [id]', Integer, 'Deployment ID') do |i|
          options[:deployment_id] = i
        end
        opts.on('--deployment-name [name]', 'Deployment Name') do |n|
          options[:deployment_name] = n
        end
  
        opts.separator ''
        opts.separator 'CloudFlow options:'
  
        opts.on('--process-id [id]', String, 'CloudFlow Process ID') do |i|
          options[:process_id] = i
        end
        opts.on('--cloudflow-name [name]', String, 'CloudFlow Name') do |i|
          options[:cloudflow_name] = i
        end
        opts.on('--cloudflow-inputs [input,input,input]', Array, 'CloudFlow Input (example: [$x]=value *becomes* cloud_flow_process[inputs][$x]=value)') do |a|
          hash = Hash.new()
          a.each{|input|
            key, value = input.split(/=/)
            hash[key] = value
          }
          options[:cloudflow_inputs] = hash
        end
        opts.on('--cloudflow-definition [definition]', String, 'CloudFlow Definition (either a string or a filename prepended with @)') do |d|
          if d.start_with?("@")
            options[:cloudflow_definition] = IO.read(d[1..-1])
          else
            options[:cloudflow_definition] = d
          end
        end
        opts.on('--wait-until-complete', 'Wait until the CloudFlow has completed before returning') do |w|
          options[:wait_until_complete] = w
        end
  
        opts.separator ''
        opts.separator 'Startup/shutdown options:'
  
        opts.on('--wait-until-started', 'Wait until started before returning') do |w|
          options[:wait_until_started] = w
        end
        opts.on('--wait-until-stopped', 'Wait until stopped before returning') do |w|
          options[:wait_until_stopped] = w
        end
  
        opts.separator ''
        opts.separator 'Shared options:'
  
        opts.on('--timeout seconds', Integer, 'Wait for start/stop this long before failing') do |w|
          options[:timeout] = w
        end
        opts.on('--timeout-interval seconds', Integer, 'Poll in intervals this long until --wait-timeout has passed') do |w|
          options[:timeout_interval] = w
        end
        opts.on('--timeout-reset', 'Reset the timeout on state change (e.g. inactive -> pending, pending -> booting') do |w|
          options[:timeout_reset] = w
        end
        opts.on('--show-progress', 'Show wait progress') do |w|
          options[:show_progress] = w
        end
  
        opts.separator ''
        opts.separator 'Debugging options:'
  
        opts.on('-v', '--verbose', 'Enable debug logging') do |v|
          options[:verbose] = v
        end
        opts.on('-t', '--trace', 'Enable trace logging (show RightScale API REST calls)') do |t|
          options[:trace] = t
        end
      end
  
      parser.parse!
  
      logger = Logger.new(STDOUT)
      indent = ''
  
      if options[:verbose] || options[:trace]
        options_without_password = options.reject{|key, _| key == :password}
        options[:logger] = logger
        logger.debug "#{indent}using options: #{options_without_password.inspect}"
      end
  
      helper = nil
      begin
        # if we're just getting an access token, we don't want to connect the client
        if options[:operation] == 'get-access-token'
          options[:delay_connect] = true
        end
  
        helper = RightScaleApiHelper.new(options)
      rescue InsufficientCredentials => e
        # looks like we didn't have sufficient credentials
        puts "Error connecting to API: #{e.message}"
        puts "#{e.backtrace.inspect}" if options[:verbose] || options[:trace]
        exit 1
      rescue => e
        # looks like we didn't have sufficient credentials
        puts "Problem creating API client: #{e.message}"
        puts "#{e.backtrace.inspect}" if options[:verbose] || options[:trace]
        exit 1
      end
  
      if options[:operation] == 'get-access-token'
        result = helper.get_access_token(options)
        if result.success
          puts "Access token=#{result.value}"
          return
        end
  
        puts 'There were errors getting the access token'
  
        # print errors and notices
        if !result.errors.nil?
          puts "#{result.errors.size} Errors getting access token"
          result.errors.each{|error|
            puts "  #{error.message}, backtrace=#{error.backtrace}"
          }
        end
  
        if !result.notices.nil?
          puts "#{result.notices.size} Notices getting access token"
          result.notices.each{|notice|
            puts "  #{notice.inspect}"
          }
        end
      elsif options[:operation] == 'get-server'
        server = helper.get_server(options)
        puts "Server name=#{server.name} description=#{server.description} state=#{server.state} created_at=#{server.created_at} updated_at=#{server.updated_at}"
        if server.state == MaestroDev::RightScalePlugin::RightScaleApiHelper::STATE_OPERATIONAL
          instance = server.show.current_instance.show
          puts "  resource_uid: #{instance.resource_uid}"
          puts "  deployment: #{instance.deployment.show.name}"
          puts "  public_ip_addresses: #{instance.public_ip_addresses}"
          puts "  private_ip_addresses: #{instance.public_ip_addresses}"
          puts "  multi_cloud_image: #{instance.multi_cloud_image.show.name}"
          puts "  server_template: #{instance.server_template.show.name}"
        end
      elsif options[:operation] == 'get-deployment'
        deployment = helper.get_deployment(options)
        servers = helper.get_servers_in_deployment(options)
        puts "Deployment name=#{deployment.name} description=#{deployment.description}"
      elsif options[:operation] == 'start-server'
        result = helper.start(options)
        if result.success
          if options[:wait_until_started]
            puts "Server (id=#{options[:server_id]} name=#{options[:server_name]}) started"
            instance = result.value
            puts "  resource_uid: #{instance.resource_uid}"
            puts "  deployment: #{instance.deployment.show.name}"
            puts "  public_ip_addresses: #{instance.public_ip_addresses}"
            puts "  private_ip_addresses: #{instance.public_ip_addresses}"
            puts "  multi_cloud_image: #{instance.multi_cloud_image.show.name}"
            puts "  server_template: #{instance.server_template.show.name}"
          else
            puts "Server (id=#{options[:server_id]} name=#{options[:server_name]}) launched"
          end
        else
          puts "Server (id=#{options[:server_id]} name=#{options[:server_name]}) start had errors"
        end
  
        # print errors and notices
        if !result.errors.nil?
          puts "#{result.errors.size} Errors starting server (id=#{options[:server_id]} name=#{options[:server_name]})"
          result.errors.each{|error|
            puts "  #{error.message}, backtrace=#{error.backtrace}"
          }
        end
  
        if !result.notices.nil?
          puts "#{result.notices.size} Notices starting server (id=#{options[:server_id]} name=#{options[:server_name]})"
          result.notices.each{|notice|
            puts "  #{notice.inspect}"
          }
        end
      elsif options[:operation] == 'stop-server'
        result = helper.stop(options)
        if options[:wait_until_stopped]
          puts "Server (id=#{options[:server_id]} name=#{options[:server_name]}) stopped"
        else
          puts "Server (id=#{options[:server_id]} name=#{options[:server_name]}) stop requested"
        end
  
        # print errors and notices
        if !result.errors.nil?
          puts "#{result.errors.size} Errors stopping server (id=#{options[:server_id]} name=#{options[:server_name]})"
          result.errors.each{|error|
            puts "  #{error.message}, backtrace=#{error.backtrace}"
          }
        end
  
        if !result.notices.nil?
          puts "#{result.notices.size} Notices stopping server (id=#{options[:server_id]} name=#{options[:server_name]})"
          result.notices.each{|notice|
            puts "  #{notice.inspect}"
          }
        end
      elsif options[:operation] == 'get-servers-in-deployment'
        servers = helper.get_servers_in_deployment(options)
        if servers.nil?
          puts "No servers in Deployment (id=#{options[:deployment_id]} name=#{options[:deployment_name]})"
        else
          servers.each {|server|
            puts "Server name=#{server.name} description=#{server.description} state=#{server.state} created_at=#{server.created_at} updated_at=#{server.updated_at}"
          }
        end
      elsif options[:operation] == 'start-servers-in-deployment'
        result = helper.start_servers_in_deployment(options)
        puts "result=#{result.inspect}"
  
        if result.success
          if options[:wait_until_started]
            puts "Deployment (id=#{options[:deployment_id]} name=#{options[:deployment_name]}) started"
          else
            puts "Deployment (id=#{options[:deployment_id]} name=#{options[:deployment_name]}) launched"
          end
        else
          puts "Deployment (id=#{options[:deployment_id]} name=#{options[:deployment_name]}) startup had errors"
        end
  
        server_instances = result.value
        if server_instances.nil? || server_instances.size == 0
          puts "No servers in deployment (id=#{options[:deployment_id]} name=#{options[:deployment_name]}) were started"
          exit 0
        end
  
        if !result.errors.nil?
          puts "#{result.errors.size} Errors starting deployment (id=#{options[:deployment_id]} name=#{options[:deployment_name]})"
          result.errors.each{|error|
            puts "  #{error.message}, backtrace=#{error.backtrace}"
          }
        end
  
        if !result.notices.nil?
          puts "#{result.notices.size} Notices starting deployment (id=#{options[:deployment_id]} name=#{options[:deployment_name]})"
          result.notices.each{|notice|
            puts "  #{notice.inspect}"
          }
        end
  
        # FIXME - issue here on shutdown, one of the instances being returned doesn't have valid state
        server_instances.each {|server_id, instance|
          puts "Server instance id=#{server_id} state=#{instance.state} dump=#{instance.inspect} resource_uid=#{instance.resource_uid}"
          puts "  resource_uid: #{instance.resource_uid}"
          puts "  deployment: #{instance.deployment.show.name}"
          puts "  public_ip_addresses: #{instance.public_ip_addresses}"
          puts "  private_ip_addresses: #{instance.public_ip_addresses}"
          puts "  multi_cloud_image: #{instance.multi_cloud_image.show.name}"
          puts "  server_template: #{instance.server_template.show.name}"
        }
      elsif options[:operation] == 'stop-servers-in-deployment'
        result = helper.stop_servers_in_deployment(options)
        puts "result=#{result.inspect}"
  
        servers = result.value
  
        if result.success
          if servers.nil? || servers.size == 0
            puts "No servers in deployment (id=#{options[:deployment_id]} name=#{options[:deployment_name]})"
            return
          end
  
          if !result.errors.nil?
            puts "#{result.errors.size} Errors stopping deployment (id=#{options[:deployment_id]} name=#{options[:deployment_name]})"
            result.errors.each{|error|
              puts "  #{error.message}, backtrace=#{error.backtrace}"
            }
          end
  
          if !result.notices.nil?
            puts "#{result.notices.size} Notices stopping deployment (id=#{options[:deployment_id]} name=#{options[:deployment_name]})"
            result.notices.each{|notice|
              puts "  #{notice.inspect}"
            }
          end
  
          servers.each {|server_id, server|
            puts "Server (id=#{server_id} state=#{server.state}): dump=#{server.inspect}"
          }
        else
          puts "Deployment (id=#{options[:deployment_id]} name=#{options[:deployment_name]}) started with errors"
          if !result.errors.nil?
            puts "#{result.errors.size} Errors starting deployment (id=#{options[:deployment_id]} name=#{options[:deployment_name]})"
            result.errors.each{|error|
              puts "  #{error.message}, backtrace=#{error.backtrace}"
            }
          end
  
          if !result.notices.nil?
            puts "#{result.notices.size} Notices starting deployment (id=#{options[:deployment_id]} name=#{options[:deployment_name]})"
            result.notices.each{|notice|
              puts "  #{notice.inspect}"
            }
          end
        end
      elsif options[:operation] == 'get-cloudflow-process'
        result = helper.get_cloudflow_process(options)
        if result.success
          cloudflow_process = result.value
          puts "CloudFlow Process:"
          puts "#{cloudflow_process.inspect}"
        end
  
        if !result.errors.nil?
          puts "#{result.errors.size} Errors getting CloudFlow process (id=#{options[:process_id]})"
          result.errors.each{|error|
            puts "  #{error.message}, backtrace=#{error.backtrace}"
          }
        end
  
        if !result.notices.nil?
          puts "#{result.notices.size} Notices getting CloudFlow process (id=#{options[:process_id]})"
          result.notices.each{|notice|
            puts "  #{notice.inspect}"
          }
        end
      elsif options[:operation] == 'create-cloudflow-process'
        puts "Creating CloudFlow with definition:\n#{options[:cloudflow_definition]}" if options[:verbose] || options[:trace]
        result = helper.create_cloudflow_process(options)
        if result.success
          cloudflow_process_id = result.value
          puts "CloudFlow Process ID: #{cloudflow_process_id}"
        end
  
        if !result.errors.nil?
          puts "#{result.errors.size} Errors creating CloudFlow process (id=#{options[:process_id]})"
          result.errors.each{|error|
            puts "  #{error.message}, backtrace=#{error.backtrace}"
          }
        end
  
        if !result.notices.nil?
          puts "#{result.notices.size} Notices creating CloudFlow process (id=#{options[:process_id]})"
          result.notices.each{|notice|
            puts "  #{notice.inspect}"
          }
        end
      else
        puts parser.help
      end
    end
  end
end
