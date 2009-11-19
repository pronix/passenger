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

class StopCommand < Command
	def self.description
		return "Stop a running Multicorn instance."
	end
	
	def run
		parse_options!("stop") do |opts|
			opts.on("--pid-file FILE", String,
				wrap_desc("PID file of a running Multicorn instance.")) do |value|
				@options[:pid_file] = value
			end
		end
		
		determine_various_resource_locations(false)
		create_nginx_controller
		begin
			running = @nginx.running?
		rescue SystemCallError, IOError
			running = false
		end
		if running
			@nginx.stop
		else
			STDERR.puts "According to the PID file '#{@options[:pid_file]}', " <<
				"Multicorn doesn't seem to be running."
			STDERR.puts
			STDERR.puts "If you know that Multicorn is running then you've " <<
				"probably specified the wrong PID file. In that case, " <<
				"please specify the right one with --pid-file."
			exit 1
		end
	end
end

end
end