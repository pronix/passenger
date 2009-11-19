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
require 'fileutils'
require 'phusion_passenger/abstract_installer'
require 'phusion_passenger/dependencies'
require 'phusion_passenger/platform_info'

module PhusionPassenger
module Multicorn

class RuntimeInstaller < AbstractInstaller
	def dependencies
		result = [
			Dependencies::GCC,
			Dependencies::Make,
			Dependencies::DownloadTool,
			Dependencies::Ruby_DevHeaders,
			Dependencies::Ruby_OpenSSL,
			Dependencies::RubyGems,
			Dependencies::Rake,
			Dependencies::Zlib_Dev
		]
		if Dependencies.fastthread_required?
			result << Dependencies::FastThread
		end
		return result
	end
	
	def install!
		show_welcome_screen
		check_dependencies(false) || exit(1)
		puts
		check_whether_we_can_write_to(@nginx_dir) || exit(1)
		
		source_dir = download_and_extract_nginx do |progress, total|
			show_progress(progress, total, 1, 7, "Extracting...")
		end
		if source_dir.nil?
			puts
			show_possible_solutions_for_download_and_extraction_problems
			exit(1)
		end
		compile_passenger_support_files do |progress, total, phase, status_text|
			if phase == 1
				show_progress(progress, total, 2, 7, status_text)
			else
				show_progress(progress, total, 3..5, 7, status_text)
			end
		end
		install_nginx(source_dir) do |progress, total, status_text|
			show_progress(progress, total, 6..7, 7, status_text)
		end
		puts
		color_puts "<green><b>All done!</b></green>"
		puts
	end

private
	def show_welcome_screen
		render_template 'multicorn/welcome',
			:version => @version,
			:dir => @nginx_dir
		puts
	end
	
	def check_whether_we_can_write_to(dir)
		FileUtils.mkdir_p(dir)
		File.new("#{dir}/__test__.txt", "w").close
		return true
	rescue
		new_screen
		if Process.uid == 0
			render_template 'multicorn/cannot_write_to_dir', :dir => dir
		else
			render_template 'multicorn/run_installer_as_root', :dir => dir
		end
		return false
	ensure
		File.unlink("#{dir}/__test__.txt") rescue nil
	end
	
	def show_progress(progress, total, phase, total_phases, status_text = "")
		if !phase.is_a?(Range)
			phase = phase..phase
		end
		total_progress = (phase.first - 1).to_f / total_phases
		total_progress += (progress.to_f / total) * ((phase.last - phase.first + 1).to_f / total_phases)
		
		max_width = 79
		progress_bar_width = 45
		text = sprintf("[%-#{progress_bar_width}s] %s",
			'*' * (progress_bar_width * total_progress).to_i,
			status_text)
		text = text.ljust(max_width)
		text = text[0 .. max_width - 1]
		STDOUT.write("#{text}\r")
		STDOUT.flush
	end
	
	def myself
		return `whoami`.strip
	end
	
	def download_and_extract_nginx
		color_puts "<banner>Downloading Nginx...</banner>"
		
		basename   = "#{myself}-nginx-#{@version}.tar.gz"
		original_output_dir = "/tmp/nginx-#{@version}"
		output_dir = "/tmp/#{myself}-nginx-#{@version}"
		File.unlink("/tmp/#{basename}") rescue nil
		FileUtils.rm_rf(original_output_dir)
		FileUtils.rm_rf(output_dir)
		
		if !download("http://sysoev.ru/nginx/nginx-#{@version}.tar.gz", "/tmp/#{basename}")
			return nil
		end
		Dir.chdir("/tmp") do
			color_puts "<banner>Installing Nginx core...</banner>"
			File.open(basename) do |f|
				IO.popen("tar xzf -", "w") do |io|
					buffer = ''
					total_size = File.size(basename)
					bytes_read = 0
					yield(bytes_read, total_size)
					begin
						while !f.eof?
							f.read(1024 * 8, buffer)
							io.write(buffer)
							io.flush
							bytes_read += buffer.size
							yield(bytes_read, total_size)
						end
					rescue Errno::EPIPE
						return nil
					end
				end
				if $?.exitstatus != 0
					return nil
				end
			end
			File.rename(original_output_dir, output_dir)
			return output_dir
		end
	rescue Interrupt
		exit 2
	end
	
	def show_possible_solutions_for_download_and_extraction_problems
		new_screen
		render_template "multicorn/possible_solutions_for_download_and_extraction_problems"
		puts
	end
	
	def run_command_with_throbber(command, status_text)
		backlog = ""
		IO.popen("#{command} 2>&1", "r") do |io|
			throbbers = ['-', '\\', '|', '/']
			index = 0
			while !io.eof?
				backlog << io.readline
				yield("#{status_text} #{throbbers[index]}")
				index = (index + 1) % throbbers.size
			end
		end
		if $?.exitstatus != 0
			STDERR.puts
			STDERR.puts backlog
			STDERR.puts "*** ERROR: command failed: #{command}"
			exit 1
		end
	end
	
	def copy_files(files, target)
		FileUtils.mkdir_p(target)
		files.each_with_index do |filename, i|
			next if File.directory?(filename)
			dir = "#{target}/#{File.dirname(filename)}"
			if !File.directory?(dir)
				FileUtils.mkdir_p(dir)
			end
			FileUtils.install(filename, "#{target}/#{filename}")
			yield(i + 1, files.size)
		end
	end
	
	def run_rake_task!(target)
		rake = "#{PlatformInfo::RUBY} #{PlatformInfo.rake}"
		total_lines = `#{rake} #{target} --dry-run`.split("\n").size - 1
		backlog = ""
		
		IO.popen("#{rake} #{target} --trace STDERR_TO_STDOUT=1", "r") do |io|
			progress = 1
			while !io.eof?
				line = io.readline
				if line =~ /^\*\* /
					yield(progress, total_lines)
					backlog.replace("")
					progress += 1
				else
					backlog << line
				end
			end
		end
		if $?.exitstatus != 0
			STDERR.puts
			STDERR.puts "*** ERROR: the following command failed:"
			STDERR.puts(backlog)
			exit 1
		end
	end
	
	def compile_passenger_support_files
		myself = `whoami`.strip
		rake = "#{PlatformInfo::RUBY} #{PlatformInfo.rake}"
		
		# Copy Phusion Passenger sources to designated directory.
		yield(0, 1, 1, "Preparing Phusion Passenger...")
		FileUtils.rm_rf(@multicorn_dir)
		Dir.chdir(PASSENGER_ROOT) do
			files = `#{rake} package:filelist --silent`.split("\n")
			copy_files(files, @multicorn_dir) do |progress, total|
				yield(progress, total, 1, "Copying files...")
			end
		end
		
		# Then compile it.
		yield(0, 1, 2, "Preparing Phusion Passenger...")
		Dir.chdir(@multicorn_dir) do
			clean_command = "#{rake} nginx:clean --silent REALLY_QUIET=1"
			if !system(clean_command)
				STDERR.puts
				STDERR.puts "*** Command failed: #{clean_command}"
				exit 1
			end
			run_rake_task!("nginx") do |progress, total|
				yield(progress, total, 2, "Compiling Phusion Passenger...")
			end
		end
	end
	
	def install_nginx(source_dir)
		Dir.chdir(source_dir) do
			command = "./configure '--prefix=#{@nginx_dir}' --without-pcre " <<
				"--without-http_rewrite_module " <<
				"--without-http_fastcgi_module " <<
				"'--add-module=#{@multicorn_dir}/ext/nginx'"
			run_command_with_throbber(command, "Preparing Nginx...") do |status_text|
				yield(0, 1, status_text)
			end
			
			backlog = ""
			total_lines = `make --dry-run`.split("\n").size
			IO.popen("make 2>&1", "r") do |io|
				progress = 1
				while !io.eof?
					line = io.readline
					backlog << line
					yield(progress, total_lines, "Compiling Nginx core...")
					progress += 1
				end
			end
			if $?.exitstatus != 0
				STDERR.puts
				STDERR.puts "*** ERROR: unable to compile Nginx."
				STDERR.puts backlog
				exit 1
			end
			
			command = "make install"
			run_command_with_throbber(command, "Copying files...") do |status_text|
				yield(1, 1, status_text)
			end
		end
	end
end

end # module Multicorn
end # module PhusionPassenger
