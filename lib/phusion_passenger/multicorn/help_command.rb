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
require 'phusion_passenger/multicorn/command'

module PhusionPassenger
module Multicorn

class HelpCommand < Command
	def self.show_in_command_list
		return false
	end
	
	def run
		puts "Available commands:"
		puts
		Multicorn::App.each_command do |command_name, command_class|
			if command_class.show_in_command_list
				printf "  multicorn %-10s  %s\n", command_name, command_class.description
			end
		end
		puts
		puts "Special options:"
		puts
		puts "  multicorn --help      Display this help message."
		puts "  multicorn --version   Display version number."
		puts
		puts "For more information about a specific command, please type 'multicorn <COMMAND> --help', e.g. 'multicorn start --help'."
	end
end

end
end