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
require 'phusion_passenger/lite/command'

module PhusionPassenger
module Lite

class App
	COMMANDS = [
		['start',   'StartCommand'],
		['stop',    'StopCommand'],
		['status',  'StatusCommand'],
		['version', 'VersionCommand'],
		['help',    'HelpCommand']
	]
	
	def self.run!(argv)
		new.run!(argv)
	end
	
	def self.each_command
		COMMANDS.each do |command_spec|
			command_name = command_spec[0]
			require "phusion_passenger/lite/#{command_name}_command"
			command_class = Lite.const_get(command_spec[1])
			yield(command_name, command_class)
		end
	end
	
	def run!(argv)
		command = argv[0]
		if command.nil? || command == '-h' || command == '--help'
			run_command('help')
			exit
		elsif command == '-v' || command == '--version'
			run_command('version')
			exit
		elsif command_exists?(command)
			begin
				run_command(command, argv[1..-1])
			rescue OptionParser::ParseError => e
				puts e
				puts
				puts "Please see '--help' for valid options."
				exit 1
			end
		else
			STDERR.puts "Unknown command '#{command}'. Please type --help for options."
			exit 1
		end
	end

private
	def command_exists?(name)
		return COMMANDS.any? do |element|
			element[0] == name
		end
	end
	
	def run_command(name, args = [])
		App.each_command do |command_name, command_class|
			if command_name == name
				return command_class.new(args).run
			end
		end
		raise ArgumentError, "Command '#{name}' doesn't exist"
	end
end

end # module Lite
end # module PhusionPassenger
