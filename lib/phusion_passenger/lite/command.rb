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
require 'optparse'
require 'phusion_passenger/packaging'

module PhusionPassenger
module Lite

class Command
	DEFAULT_OPTIONS = {
		:address       => '0.0.0.0',
		:port          => 3000,
		:env           => ENV['RAILS_ENV'] || ENV['RACK_ENV'] || 'development',
		:nginx_version => '0.7.64'
	}.freeze
	
	def self.show_in_command_list
		return true
	end
	
	def self.description
		return nil
	end
	
	def initialize(args)
		@args = args.dup
		@original_args = args.dup
		@options = DEFAULT_OPTIONS.dup
	end

private
	def require_daemon_controller
		if !defined?(DaemonController)
			begin
				require 'daemon_controller'
				begin
					require 'daemon_controller/version'
				rescue LoadError
					STDERR.puts "*** Your version of daemon_controller is too old. " <<
						"You must install 0.2.3 or later. Please upgrade:"
					STDERR.puts
					STDERR.puts " sudo gem uninstall FooBarWidget-daemon_controller"
					STDERR.puts " sudo gem install daemon_controller"
					exit 1
				end
			rescue LoadError
				STDERR.puts "*** Please install daemon_controller first: " <<
					"sudo gem install daemon_controller"
				exit 1
			end
		end
	end
	
	def require_erb
		require 'erb' unless defined?(ERB)
	end
	
	def debugging?
		return ENV['PASSENGER_DEBUG']
	end
	
	def parse_options!(command_name, description = nil)
		help = false
		parser = OptionParser.new do |opts|
			opts.banner = "Usage: passenger #{command_name} [options]"
			opts.separator description if description
			opts.separator " "
			opts.separator "Options:"
			yield opts
			opts.on("-h", "--help", "Show this help message") do
				help = true
			end
		end
		parser.parse!(@args)
		if help
			puts parser
			exit 0
		end
	end
	
	# Word wrap the given option description text so that it is formatted
	# nicely in the --help output.
	def wrap_desc(description_text)
		line_prefix = "\n" << (' ' * 37)
		col = 43
		result = description_text.gsub(/(.{1,#{col}})( +|$\n?)|(.{1,#{col}})/, "\\1\\3#{line_prefix}")
		result.strip!
		return result
	end
	
	def looks_like_app_directory?(dir)
		return File.exist?("#{dir}/config/environment.rb") ||
			File.exist?("#{dir}/config.ru") ||
			File.exist?("#{dir}/passenger_wsgi.py")
	end
	
	def determine_various_resource_locations(create_subdirs = true)
		if @options[:socket_file]
			pid_basename = "passenger.pid"
			log_basename = "passenger.log"
		else
			pid_basename = "passenger.#{@options[:port]}.pid"
			log_basename = "passenger.#{@options[:port]}.log"
		end
		if @args.empty?
			if looks_like_app_directory?(".")
				@options[:pid_file] ||= File.expand_path("tmp/pids/#{pid_basename}")
				@options[:log_file] ||= File.expand_path("log/#{log_basename}")
				if create_subdirs
					ensure_directory_exists(File.dirname(@options[:pid_file]))
					ensure_directory_exists(File.dirname(@options[:log_file]))
				end
			else
				@options[:pid_file] ||= File.expand_path(pid_basename)
				@options[:log_file] ||= File.expand_path(log_basename)
			end
		else
			@options[:pid_file] ||= File.expand_path(File.join(@args[0], pid_basename))
			@options[:log_file] ||= File.expand_path(File.join(@args[0], log_basename))
		end
	end
	
	def create_nginx_config_file
		File.open(@config_filename, 'w') do |f|
			f.chmod(0644)
			template_filename = File.join(TEMPLATES_DIR, "lite", "config.erb")
			require_erb
			erb = ERB.new(File.read(template_filename))
			
			if debugging?
				passenger_root = SOURCE_ROOT
			else
				passenger_root = passenger_support_files_dir
			end
			# The template requires some helper methods which are defined in start_command.rb.
			output = erb.result(binding)
			f.write(output)
			puts output if debugging?
		end
	end
	
	def determine_nginx_start_command
		return "#{nginx_dir}/sbin/nginx -c '#{@config_filename}'"
	end
	
	def ping_nginx
		require 'socket' unless defined?(UNIXSocket)
		if @options[:socket_file]
			UNIXSocket.new(@options[:socket_file])
		else
			TCPSocket.new(@options[:address], @options[:port])
		end
	end
	
	def create_nginx_controller
		require_daemon_controller
		@config_filename = "/tmp/passenger-lite.#{$$}.conf"
		@nginx = DaemonController.new(
			:identifier    => 'Nginx',
			:before_start  => method(:create_nginx_config_file),
			:start_command => method(:determine_nginx_start_command),
			:ping_command  => method(:ping_nginx),
			:pid_file      => @options[:pid_file],
			:log_file      => @options[:log_file],
			:timeout       => 25
		)
		@nginx_mutex = Mutex.new
	end
end

end
end
