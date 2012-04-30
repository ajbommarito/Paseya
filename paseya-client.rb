# sit on the client machines, attach to a server and keep an open pipline waiting for commands
# v0.2 - Eventmachine conversion
# v0.1 - first

#**resources
#http://www.erikveen.dds.nl/rubyscript2exe/
#http://exerb.sourceforge.jp/index.en.html
#http://www.ruby-doc.org/stdlib-1.9.3/libdoc/socket/rdoc/TCPServer.html

#**todo.  who is the server.  How does the client know to look for the right IP?
#why doesnt it run right under rubyw
#http://win32utils.rubyforge.org/

#**done
#hide the ruby window?
	#gem install ocra
	#ocra paseya-client.rb --windows
#multiple threaded connections?
#secure connections? #authentication?
#run when no one is logged in

require 'eventmachine'
require "base64"
require "fileutils"
require "logger"
require 'win32/daemon'
require 'win32/service'
include Win32
require 'sys/admin'
include Sys
require File.absolute_path(__FILE__).gsub(File.basename(__FILE__),'') + '/paseya-base.rb'

class PaseyaClient  < EventMachine::Connection
	include PaseyaBase
	@server = "192.168.225.101"
	
	def post_init()
		@thisMachine = ENV['COMPUTERNAME']
		@tempDir = ENV['TEMP']
		@l.info("Starting new client instance #{object_id}.")

		start_tls if @@useClientSSL
		if defined?(Ocra)
			@l.info("we're running inside of ocra. Exiting or OCRA will never finish mapping us")
			exit
		end
	end

	def PaseyaClient.start
		EventMachine.connect(@server, @@clientPort, PaseyaClient)
		#only check our install if we're running as an exe
		checkInstall if ENV['OCRA_EXECUTABLE'] != nil		
	end
	
	def PaseyaClient.stop
	end
	
	def PaseyaClient.installService
		if !Service.exists?('Paseya-client')
       Service.new(
         :service_name	=> 'Paseya-client',
         :display_name	=> 'Paseya',
         :description			=> 'paseya-client',
				 :start_type			=> Service::AUTO_START,
         :binary_path_name => 'c:\program files\paseya\paseya-client.exe'
      )	
		end
	end
	
	def PaseyaClient.deleteService
		if Service.exists?('Paseya-client')
			Service.delete('Paseya-client')
		end
	end
	
	#make sure we're installed in the right place, our EXE is there, our registry entries are there, etc.
	def checkInstall
		#create our dir if we need
		Dir.mkdir(ENV['ProgramFiles'] + '/Paseya/') if !Dir.exist?(ENV['ProgramFiles'] + '/Paseya/')
		if Dir.exist?(ENV['ProgramFiles'] + '/Paseya')
			ourPath = File.realdirpath(ENV['OCRA_EXECUTABLE']).gsub(File.basename(ENV['OCRA_EXECUTABLE']),'').to_s
			@l.info(ourPath)
			desiredPath = File.realdirpath(ENV['ProgramFiles'] + '/Paseya/').to_s 
			
			@l.info(desiredPath)
			if (desiredPath + "/" +@clientName).downcase != ENV['OCRA_EXECUTABLE'].downcase.gsub('\\','/')
				@l.info('Our client install is in ' + ENV['OCRA_EXECUTABLE'].downcase.gsub('\\','/'))
				@l.info('We want to be in ' + (desiredPath + "/" +@clientName).downcase)
				begin
					PaseyaClient.installService if !Service.exists?('Paseya-client')
					Service.stop('Paseya-client') if Service.status('Paseya-client').current_state.to_s == "running"
					@l.info(Service.status('Paseya-client').current_state.to_s )
					#delete the old client if it exists
					File.delete(desiredPath + @clientName) if File.exist?(desiredPath + @clientName)
					FileUtils.cp(ENV['OCRA_EXECUTABLE'],desiredPath + "/" +@clientName)
				rescue Exception => e
					@l.error('Failure trying to place client executable in the proper directory')
					@l.error(e.message)
				end
				begin
					#start up the proper copy
					Service.start('Paseya-client')	
				rescue Exception => e
					@l.error('Failure trying to execute service')
					@l.error(e.message)
				end
				exit
			end
		end		
	end
	
	def timer
		checkForLatestVersion
	end
	
	def setServer(ip)
		@server = ip
	end
	
	#set up a reverse vnc connection where the client acts the server and it's connecting out to a 
	#waiting client
	def reverseVNC(host)
		#winvnc -autoreconnect -connect host:port
		localVnc = ENV['TEMP'] + "/" + @vncName
		if !File.exists?(localVnc)
			send('sendVnc:')
		end
		return if !File.exists?(localVnc)
		`#{localVnc} -autoreconnect -connect #{host}:5500`
	end
	
	def processCommand(string)
		#a command is a base64 encoded string followed by a newline.
		command = Base64.decode64(string.to_s)
		#see if the passed text matches anything we know what to do with
		return if command == nil
		if command.index('cmd:') == 0
			shellCommand = command[4,command.length] + "\n"
			send(`#{shellCommand}`)
		end
		if command.index('reversevnc:') == 0
			reverseVNC(command[11,command.length])
		end
		if command.index('quit:') == 0
			@l.info("received exit signal from server.")
			exit
		end
		if command.index('version:') == 0
			send("version:#{@@newestClientVersion}")
		end
		if command.index('pushClient:') == 0 
			updateClient(command[11,command.length])
		end				
		if command.index('updateClient:') == 0
			updateClient(command[13,command.length])
		end
		if command.index('pushVnc:') == 0
			updateVnc(command[8,command.length])
		end				
	end
	
	def updateClient(binData)
		newExeFile = ENV['TEMP'] + "/" + @clientName
		fh = open(newExeFile, 'wb')
		fh.write(Base64.decode64(binData))
		fh.close
		system("start #{newExeFile}")
		exit
	end

	def updateVnc(binData)
		newExeFile = ENV['TEMP'] + "/" + @vncName
		fh = open(newExeFile, 'wb')
		fh.write(Base64.decode64(binData))
		fh.close
	end
	
	def unbind
		@l.close
		PaseyaClient.start
	end
end


class Daemon
	def service_main
		while running?
			EventMachine.run {
				if EventMachine.connection_count < 1
					PaseyaClient.start
				end
			}
		end
	end

	def service_stop
		EventMachine.stop_event_loop
	end
end

begin
	Daemon.mainloop
	exit
rescue
	#if we were invoked as a service, don't run from the command line
	p "we're running from the command line"
	EventMachine.run {
		if EventMachine.connection_count < 1
			PaseyaClient.start
		end
	}
end
