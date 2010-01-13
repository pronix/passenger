#  Phusion Passenger - http://www.modrails.com/
#  Copyright (c) 2010 Phusion
#
#  "Phusion Passenger" is a trademark of Hongli Lai & Ninh Bui.
#
#  Permission is hereby granted, free of charge, to any person obtaining a copy
#  of this software and associated documentation files (the "Software"), to deal
#  in the Software without restriction, including without limitation the rights
#  to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
#  copies of the Software, and to permit persons to whom the Software is
#  furnished to do so, subject to the following conditions:
#
#  The above copyright notice and this permission notice shall be included in
#  all copies or substantial portions of the Software.
#
#  THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
#  IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
#  FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
#  AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
#  LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
#  OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
#  THE SOFTWARE.
require 'socket'
require 'thread'
require 'etc'
require 'phusion_passenger/constants'
require 'phusion_passenger/platform_info'
require 'phusion_passenger/lite/command'

module PhusionPassenger
module Lite

class StartCommand < Command
	def self.description
		return "Start Phusion Passenger Lite."
	end
	
	def initialize(args)
		super(args)
		@console_mutex = Mutex.new
		@termination_pipe = IO.pipe
		@threads = []
		@interruptable_threads = []
	end
	
	def run
		description = "Starts Phusion Passenger Lite and serve one or more Ruby web applications."
		parse_options!("start [directory]", description) do |opts|
			opts.on("-a", "--address HOST", String,
				wrap_desc("Bind to HOST address (default: #{@options[:address]})")) do |value|
				@options[:address] = value
				@options[:tcp_explicitly_given] = true
			end
			opts.on("-p", "--port NUMBER", Integer,
				wrap_desc("Use the given port number (default: #{@options[:port]})")) do |value|
				@options[:port] = value
				@options[:tcp_explicitly_given] = true
			end
			opts.on("-S", "--socket FILE", String,
				wrap_desc("Bind to Unix domain socket instead of TCP socket")) do |value|
				@options[:socket_file] = value
			end
			
			opts.separator ""
			opts.on("-e", "--environment ENV", String,
				wrap_desc("Framework environment (default: #{@options[:env]})")) do |value|
				@options[:port] = value
			end
			opts.on("--max-pool-size NUMBER", Integer,
				wrap_desc("Maximum number of application processes (default: #{@options[:max_pool_size]})")) do |value|
				@options[:max_pool_size] = value
			end
			opts.on("--min-instances NUMBER", Integer,
				wrap_desc("Minimum number of processes per application (default: #{@options[:min_instances]})")) do |value|
				@options[:min_instances] = value
			end
			
			opts.separator ""
			opts.on("--from-launchd",
				wrap_desc("For internal use. Do not specify this argument.")) do
				@options[:from_launchd] = true
			end
			opts.on("--show-dock-icon",
				wrap_desc("Show a MacOS X dock icon.")) do
				@options[:show_dock_icon] = true
			end
			opts.on("-d", "--daemonize",
				wrap_desc("Daemonize into the background")) do
				@options[:daemonize] = true
			end
			opts.on("--user USERNAME", String,
				wrap_desc("User to run as. Ignored unless running as root.")) do |value|
				@options[:user] = value
			end
			opts.on("--log-file FILENAME", String,
				wrap_desc("Where to write log messages (default: console, or /dev/null when daemonized)")) do |value|
				@options[:log_file] = value
			end
			opts.on("--pid-file FILENAME", String,
				wrap_desc("Where to store the PID file")) do |value|
				@options[:pid_file] = value
			end
			opts.on("--nginx-bin FILENAME", String,
				wrap_desc("Nginx binary to use as core")) do |value|
				@options[:nginx_bin] = value
			end
			opts.on("--nginx-version VERSION", String,
				wrap_desc("Nginx version to use as core (default: #{@options[:nginx_version]})")) do |value|
				@options[:nginx_version] = value
			end
			opts.on("--nginx-tarball FILENAME", String,
				wrap_desc("If Nginx needs to be installed, then the given tarball will " +
				          "be used instead of downloading from the Internet")) do |value|
				@options[:nginx_tarball] = value
			end
		end
		if @options[:tcp_explicitly_given] && @options[:socket_file]
			STDERR.puts "You cannot specify both --address/--port and --socket. Please choose either one."
			exit 1
		end
		
		check_port_and_display_sudo_suggestion
		ensure_nginx_installed
		require_file_tail if !@options[:daemonize]
		determine_various_resource_locations
		determine_apps_to_serve
		
		controller_options = {}
		dock_icon = show_dock_icon if @options[:show_dock_icon]
		process_socket_from_launchd(controller_options) if @options[:from_launchd]
		create_nginx_controller(controller_options)
		begin
			@nginx.start
		rescue DaemonController::AlreadyStarted
			begin
				pid = @nginx.pid
			rescue SystemCallError, IOError
				pid = nil
			end
			if pid
				STDERR.puts "*** ERROR: Phusion Passenger Lite is already running on PID #{pid}."
			else
				STDERR.puts "*** ERROR: Phusion Passenger Lite is already running."
			end
			exit 1
		rescue DaemonController::StartError => e
			STDERR.puts "*** ERROR: could not start Passenger Nginx core:"
			STDERR.puts e
			exit 1
		ensure
			File.unlink(@config_filename) rescue nil
		end
		
		puts "=============== Phusion Passenger Lite web server started ==============="
		puts "PID file: #{@options[:pid_file]}"
		puts "Log file: #{@options[:log_file]}"
		puts "Environment: #{@options[:env]}"
		if @apps.size > 1
			puts
			if @options[:socket_file]
				puts "Serving these applications:"
			else
				puts "Serving these applications on #{@options[:address]} port #{@options[:port]}:"
			end
			puts " Host name                     Directory"
			puts "------------------------------------------------------------"
			@apps.each do |app|
				printf " %-26s    %s\n", app[:server_names][0], app[:root]
			end
		else
			puts "Accessible via: #{listen_url}"
		end
		puts
		if @options[:daemonize]
			puts "Serving in the background as a daemon."
		else
			puts "You can stop Phusion Passenger Lite by pressing Ctrl-C."
		end
		puts "========================================================================="
		
		daemonize if @options[:daemonize]
		Thread.abort_on_exception = true
		watch_directories_in_background if @apps.size > 1
		watch_log_files_in_background if !@options[:daemonize] && !@options[:from_launchd]
		begin
			wait_until_nginx_has_exited
		rescue Interrupt
			stop_nginx
			exit 2
		rescue SignalException => signal
			stop_nginx
			if signal.message == 'SIGINT' || signal.message == 'SIGTERM'
				exit 2
			else
				raise
			end
		rescue Exception => e
			stop_nginx
			raise
		end
		stop_threads
	ensure
		dock_icon.close if dock_icon
	end

private
	def require_file_tail
		begin
			require 'file/tail'
		rescue LoadError
			STDERR.puts "*** Please install file-tail first: sudo gem install file-tail"
			exit 1
		end
	end
	
	def require_file_utils
		require 'fileutils' unless defined?(FileUtils)
	end
	
	# Most platforms don't allow non-root processes to bind to a port lower than 1024.
	# Check whether this is the case for the current platform and if so, tell the user
	# that it must re-run Phusion Passenger Lite with sudo.
	def check_port_and_display_sudo_suggestion
		if !@options[:socket_file] && @options[:port] < 1024 && Process.euid != 0
			begin
				TCPServer.new('127.0.0.1', @options[:port]).close
			rescue Errno::EACCES
				myself = `whoami`.strip
				STDERR.puts "Only the 'root' user can run Phusion Passenger Lite on port #{@options[:port]}. You are"
				STDERR.puts "currently running as '#{myself}'. Please re-run Lite with root privileges with"
				STDERR.puts "the following command:"
				STDERR.puts
				STDERR.puts "  sudo passenger start #{@original_args.join(' ')} --user=#{myself}"
				STDERR.puts
				STDERR.puts "Don't forget the '--user' part! That will make Phusion Passenger Lite drop root"
				STDERR.puts "privileges and switch to '#{myself}' after it has obtained port #{@options[:port]}."
				exit 1
			end
		end
	end
	
	# Returns the URL that Nginx will be listening on.
	def listen_url
		if @options[:socket_file]
			return @options[:socket_file]
		else
			result = "http://#{@options[:address]}"
			if @options[:port] != 80
				result << ":#{@options[:port]}"
			end
			result << "/"
			return result
		end
	end
	
	def install_runtime
		require 'phusion_passenger/lite/runtime_installer'
		installer = RuntimeInstaller.new(
			:source_root => SOURCE_ROOT,
			:support_dir => passenger_support_files_dir,
			:nginx_dir   => nginx_dir,
			:version     => @options[:nginx_version],
			:tarball     => @options[:nginx_tarball])
		installer.start
	end
	
	def runtime_version_string
		if defined?(RUBY_ENGINE)
			ruby_engine = RUBY_ENGINE
		else
			ruby_engine = "ruby"
		end
		return "#{VERSION_STRING}-#{ruby_engine}#{RUBY_VERSION}-#{RUBY_PLATFORM}"
	end
	
	def passenger_support_files_dir
		return "#{@runtime_dir}/support"
	end
	
	def nginx_dir
		return "#{@runtime_dir}/nginx-#{@options[:nginx_version]}"
	end
	
	def ensure_nginx_installed
		if @options[:nginx_bin] && !File.exist?(@options[:nginx_bin])
			STDERR.puts "The given Nginx binary '#{@options[:nginx_bin]}' does not exist."
			exit 1
		end
		
		home           = Etc.getpwuid.dir
		@runtime_dir   = "/var/lib/passenger-lite/#{runtime_version_string}"
		if !File.exist?("#{nginx_dir}/sbin/nginx")
			if Process.euid == 0
				install_runtime
			else
				@runtime_dir = "#{home}/.passenger-lite/#{runtime_version_string}"
				if !File.exist?("#{nginx_dir}/sbin/nginx")
					install_runtime
				end
			end
		end
		
		nginx_version = @options[:nginx_version]
		@temp_dir = "#{home}/.passenger-lite/#{runtime_version_string}/nginx-#{nginx_version}/temp"
		ensure_directory_exists(@temp_dir)
	end
	
	def filename_to_server_names(filename)
		basename = File.basename(filename)
		names = [basename]
		if basename !~ /^www\.$/i
			names << "www.#{basename}"
		end
		return names
	end
	
	def ensure_directory_exists(dir)
		if !File.exist?(dir)
			require_file_utils
			FileUtils.mkdir_p(dir)
		end
	end
	
	def determine_apps_to_serve
		@apps = []
		if @args.empty?
			if looks_like_app_directory?(".")
				@apps << {
					:server_names => ["_"],
					:root => File.expand_path(".")
				}
			else
				Dir["./*"].each do |entry|
					if looks_like_app_directory?(entry)
						server_names = filename_to_server_names(entry)
						@apps << {
							:server_names => server_names,
							:root => File.expand_path(entry)
						}
					end
				end
			end
		else
			@args.each do |arg|
				if looks_like_app_directory?(arg)
					server_names = filename_to_server_names(arg)
					@apps << {
						:server_names => server_names,
						:root => File.expand_path(arg)
					}
				else
					Dir["#{arg}/*"].each do |entry|
						if looks_like_app_directory?(entry)
							server_names = filename_to_server_names(entry)
							@apps << {
								:server_names => server_names,
								:root => File.expand_path(entry)
							}
						end
					end
				end
			end
		end
		
		@apps.map! do |app|
			config_filename = File.join(app[:root], "passenger.conf")
			if File.exist?(config_filename)
				options = load_config_file(:local_config, config_filename)
				options = @options.merge(options)
				options.merge!(app)
				options
			else
				@options.merge(app)
			end
		end
	end
	
	def daemonize
		pid = fork
		if pid
			# Parent
			exit!
		else
			# Child
			trap "HUP", "IGNORE"
			STDIN.reopen("/dev/null", "r")
			STDOUT.reopen(@options[:log_file], "a")
			STDERR.reopen(@options[:log_file], "a")
			STDOUT.sync = true
			STDERR.sync = true
			Process.setsid
		end
	end
	
	def show_dock_icon
		exe = "#{MACOSX_DOCK_ICON_APP_DIR}/Contents/MacOS/Phusion Passenger Lite"
		return IO.popen("\"#{exe}\" #{@termination_pipe[0].fileno} #{$$}", "r")
	end
	
	def process_socket_from_launchd(controller_options)
		require 'phusion_passenger/utils'
		fd = NativeSupport.get_socket_from_launchd("ServerSocket")
		if fd.nil?
			raise "No server socket received from launchd."
		else
			# fd is a TCP/IP server socket. To pass this to Nginx,
			# we abuse Nginx's on-the-fly-binary-switching mechanism.
			server = TCPServer.for_fd(fd)
			ENV["NGINX"] = "#{fd};"
			controller_options[:keep_ios] = [server]
			
			# When in binary switching mode Nginx doesn't daemonize,
			# so let daemon_controller do it.
			controller_options[:daemonize_for_me] = true
		end
	end
	
	# Wait until the termination pipe becomes readable (a hint for threads to shut down),
	# or until the timeout has been reached. Returns true if the termination pipe
	# is closed, false if the timeout has been reached.
	def wait_on_termination_pipe(timeout)
		ios = select([@termination_pipe[0]], nil, nil, timeout)
		return !ios.nil?
	end
	
	def directory_mtimes
		if @args.empty?
			dirs = ["."]
		else
			dirs = @args.sort
		end
		dirs.map! do |dir|
			File.stat(dir).mtime
		end
		return dirs
	end
	
	def watch_directories
		old_mtimes = directory_mtimes
		while !wait_on_termination_pipe(3)
			new_mtimes = directory_mtimes
			if old_mtimes != new_mtimes
				old_mtimes = new_mtimes
				yield
			end
		end
	end
	
	def watch_directories_in_background
		@threads << Thread.new do
			watch_directories do
				puts "*** #{Time.now}: redeploying applications ***"
				determine_apps_to_serve
				begin
					pid = @nginx.pid
				rescue SystemCallError, IOError => e
					# Failing to read the PID file most likely means that the
					# web server's no longer running, in which case we're supposed
					# to quit anyway. Only print an error if the web server's still
					# running.
					#
					# We wait at most 6 seconds for the main thread to detect that
					# Nginx has quit. 6 because on OS X shutting down the Nginx
					# HelperServer might need 5 seconds (see comment in Watchdog.cpp).
					if !wait_on_termination_pipe(6)
						STDERR.puts "*** Error: unable to retrieve the web server's PID (#{e})."
					end
					next
				end
				create_nginx_config_file
				begin
					Process.kill('HUP', pid) rescue nil
					
					@console_mutex.synchronize do
						puts "Now serving these applications:"
						puts " Host name                     Directory"
						puts "------------------------------------------------------------"
						@apps.each do |app|
							printf " %-26s    %s\n", app[:server_names][0], app[:root]
						end
						puts "------------------------------------------------------------"
					end
					
					# Wait a short period for Nginx to reload its config
					# before deleting the config file.
					wait_on_termination_pipe(3)
				ensure
					File.unlink(@config_filename) rescue nil
				end
			end
		end
	end
	
	def watch_log_file(log_file)
		if File.exist?(log_file)
			backward = 0
		else
			# File::Tail bails out if the file doesn't exist, so wait until it exists.
			while !File.exist?(log_file)
				sleep 1
			end
			backward = 10
		end
		
		File::Tail::Logfile.open(log_file, :backward => backward) do |log|
			log.interval = 0.1
			log.max_interval = 1
			log.tail do |line|
				@console_mutex.synchronize do
					STDOUT.write(line)
					STDOUT.flush
				end
			end
		end
	end
	
	def watch_log_files_in_background
		@apps.each do |app|
			thread = Thread.new do
				watch_log_file("#{app[:root]}/log/#{@options[:env]}.log")
			end
			@threads << thread
			@interruptable_threads << thread
		end
	end
	
	def wait_until_nginx_has_exited
		# Since Nginx is not our child process (it daemonizes or we daemonize)
		# we cannot use Process.waitpid to wait for it. A busy-sleep-loop with
		# Process.kill(0, pid) isn't very efficient. Instead we do this:
		#
		# Connect to Nginx and wait until Nginx disconnects the socket because of
		# timeout. Keep doing this until we can no longer connect.
		while true
			if @options[:socket_file]
				socket = UNIXSocket.new(@options[:socket_file])
			else
				socket = TCPSocket.new(@options[:address], nginx_ping_port)
			end
			begin
				socket.read rescue nil
			ensure
				socket.close rescue nil
			end
		end
	rescue Errno::ECONNREFUSED, Errno::ECONNRESET
	end
	
	def stop_nginx
		stop_threads
		@console_mutex.synchronize do
			STDOUT.write("Stopping web server...")
			STDOUT.flush
			@nginx.stop
			STDOUT.puts " done"
			STDOUT.flush
		end
	end
	
	def stop_threads
		@termination_pipe[1].write("x")
		@termination_pipe[1].close
		@interruptable_threads.each do |thread|
			thread.terminate
		end
		@threads.each do |thread|
			thread.join
		end
	end
	
	#### Config file template helpers ####
	
	def nginx_listen_address(is_ping = false)
		if @options[:socket_file]
			return "unix:" + File.expand_path(@options[:socket_file])
		else
			if is_ping
				port = nginx_ping_port
			else
				port = @options[:port]
			end
			return "#{@options[:address]}:#{port}"
		end
	end
	
	def default_group_for(username)
		user = Etc.getpwnam(username)
		group = Etc.getgrgid(user.gid)
		return group.name
	end
end

end
end
