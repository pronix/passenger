#  Phusion Passenger - http://www.modrails.com/
#  Copyright (c) 2009 Phusion
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
require 'phusion_passenger/multicorn/command'

module PhusionPassenger
module Multicorn

class StartCommand < Command
	DEFAULT_OPTIONS = {
		:address       => '0.0.0.0',
		:port          => 3000,
		:env           => ENV['RAILS_ENV'] || ENV['RACK_ENV'] || 'development',
		:nginx_version => '0.7.63'
	}.freeze
	
	def self.description
		return "Start Multicorn."
	end
	
	def initialize(args)
		super(args)
		@console_mutex = Mutex.new
	end
	
	def run
		@options = DEFAULT_OPTIONS.dup
		description = "Starts Multicorn in order to serve a Ruby web application."
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
			opts.on("-e", "--environment ENV", String,
				wrap_desc("Framework environment (default: #{@options[:env]})")) do |value|
				@options[:port] = value
			end
			opts.on("-d", "--daemonize",
				wrap_desc("Daemonize into the background")) do
				@options[:daemonize] = true
			end
			opts.on("--user USERNAME", String,
				wrap_desc("User to run as. Ignored unless running as root.")) do |value|
				@options[:user] = value
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
		
		create_nginx_controller
		begin
			@nginx.start
		rescue DaemonController::AlreadyStarted
			begin
				pid = @nginx.pid
			rescue SystemCallError, IOError
				pid = nil
			end
			if pid
				STDERR.puts "*** ERROR: Multicorn is already running on PID #{pid}."
			else
				STDERR.puts "*** ERROR: Multicorn is already running."
			end
			exit 1
		rescue DaemonController::StartError => e
			STDERR.puts "*** ERROR: could not start Multicorn Nginx core:"
			STDERR.puts e
			exit 1
		ensure
			File.unlink(@config_filename) rescue nil
		end
		
		puts "=============== Multicorn web server started ==============="
		puts "PID file: #{@options[:pid_file]}"
		puts "Log file: #{@options[:log_file]}"
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
			puts "You can stop Multicorn by pressing Ctrl-C."
		end
		puts "============================================================"
		
		daemonize if @options[:daemonize]
		Thread.abort_on_exception = true
		watch_directories_in_background if @apps.size > 1
		watch_log_files_in_background if !@options[:daemonize]
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
	# that it must re-run Multicorn with sudo.
	def check_port_and_display_sudo_suggestion
		if !@options[:socket_file] && @options[:port] < 1024 && Process.euid != 0
			begin
				TCPServer.new('127.0.0.1', @options[:port]).close
			rescue Errno::EACCES
				myself = `whoami`.strip
				STDERR.puts "Only the 'root' user can run Multicorn on port #{@options[:port]}. You are currently running"
				STDERR.puts "as '#{myself}'. Please re-run Multicorn with root privileges with the"
				STDERR.puts "following command:"
				STDERR.puts
				STDERR.puts "  sudo multicorn start #{@original_args.join(' ')} --user=#{myself}"
				STDERR.puts
				STDERR.puts "Don't forget the '--user' part! That will make Multicorn drop root privileges"
				STDERR.puts "and switch to '#{myself}' after it has obtained port #{@options[:port]}."
				exit 1
			end
		end
	end
	
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
	
	def install_runtime(multicorn_dir, nginx_dir, version)
		require 'phusion_passenger/multicorn/runtime_installer'
		RuntimeInstaller.new(:multicorn_dir => multicorn_dir,
			:nginx_dir => nginx_dir,
			:version => version).start
	end
	
	def ensure_nginx_installed
		home           = Etc.getpwuid.dir
		nginx_version  = @options[:nginx_version]
		@multicorn_dir = "/var/lib/multicorn/#{VERSION_STRING}"
		@nginx_dir     = "#{@multicorn_dir}/nginx-#{nginx_version}"
		if !File.exist?("#{@nginx_dir}/sbin/nginx")
			if Process.euid == 0
				install_runtime(@multicorn_dir, @nginx_dir, nginx_version)
			else
				@multicorn_dir = "#{home}/.multicorn/#{VERSION_STRING}"
				@nginx_dir     = "#{@multicorn_dir}/nginx-#{nginx_version}"
				if !File.exist?("#{@nginx_dir}/sbin/nginx")
					install_runtime(@multicorn_dir, @nginx_dir, nginx_version)
				end
			end
		end
		
		@temp_dir = "#{home}/.multicorn/#{VERSION_STRING}/nginx-#{nginx_version}/temp"
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
		while true
			sleep 3
			new_mtimes = directory_mtimes
			if old_mtimes != new_mtimes
				old_mtimes = new_mtimes
				yield
			end
		end
	end
	
	def watch_directories_in_background
		Thread.new do
			watch_directories do
				puts "*** #{Time.now}: redeploying applications ***"
				determine_apps_to_serve
				begin
					pid = @nginx.pid
				rescue SystemCallError, IOError
					STDERR.puts "*** Error: unable to retrieve the web server's PID."
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
					sleep 3
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
			Thread.new do
				watch_log_file("#{app[:root]}/log/#{@options[:env]}.log")
			end
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
				socket = TCPSocket.new(@options[:address], @options[:port])
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
		@nginx_mutex.synchronize do
			STDOUT.write("Stopping web server...")
			STDOUT.flush
			@nginx.stop
			STDOUT.puts " done"
			STDOUT.flush
		end
	end
	
	#### Config file template helpers ####
	
	def nginx_listen_address
		if @options[:socket_file]
			return "unix:" + File.expand_path(@options[:socket_file])
		else
			return "#{@options[:address]}:#{@options[:port]}"
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