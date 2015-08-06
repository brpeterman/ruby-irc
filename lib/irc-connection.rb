# Manages the connection to the IRC server and passes messages
# back and forth. Stores server messages in the event queue.
#
# To use it, create a new IRCConnection object and add event handlers
# with add_handler.
#
# This implementation was heavily influenced by the Perl library
# Net::IRC.

module RubyIRC
  class IRCConnection
    require 'socket'
    require 'thread'
    require_relative 'irc-event'
    
    attr_reader :connected
    
    # Sets up instance vars and default event handlers.
    #
    # The first three parameters are the parts of
    # nick!~username@YourHost (realname)
    # [nick]     Client's nickname.
    # [username] Client's username. Not to be confused with nickname.
    # [realname] Client's real name. Nobody is checking if you lie. ;)
    # [password] If the server requires a password, specify it here.
    # [host]     Specify the IRC host if you want to connect
    #            immediately. Useful if you're connecting through irb.
    # [port]     Specify the IRC port if you want to connect
    #            immediately. Useful if you're connecting through irb.
    def initialize(nick, username, realname, password=nil, host=nil, port=nil)
      # Don't hang around if one thread crashes
      Thread.abort_on_exception = true
      
      @nick, @username, @realname, @password = nick, username, realname, password
      
      @crlf = "\r\n"
      @queue, @conn, @connected = nil
      
      # Message queue for flood control
      @write_queue = []
      
      # Control access to the write queue
      @write_access = Mutex.new
      
      # Control access to the queue structure
      @queue_access = Mutex.new
      
      # Synchronize writes to the socket
      @socket_access = Mutex.new
      
      # Set up default handlers
      add_default_handlers
      
      # If we're ready to connect, do it
      if (host && port) then
        connect(host, port)
      end
    end
    
    # Connect to the server and record messages.
    # [host] Address of the IRC server.
    # [port] Port the IRC server listens on.
    def connect(host, port)
      $stderr.puts "Connecting to server..." if @debug
      @host, @port = host, port
      
      # Open a TCP connection to the server
      @conn = TCPSocket.open(@host, @port)
      if (@conn) then
        $stderr.puts "Connected" if @debug
        @connected = true
        
        # Start the writer thread. Sends messages from the write queue
        # to the server at a specified throughput.
        @writeThread = Thread.new do
          throughput = 20
          interval = 20
          band = 0
          start_time = 0
          while (@connected) do
            if (@write_queue.length > 0) then
              if (band < throughput) then
                msg = ""
                @write_access.synchronize do
                  msg = @write_queue.shift
                end
                @socket_access.synchronize do
                  $stderr.puts "["+Time.now.to_s+"] Writing: "+msg if @debug
                  @conn.puts msg.strip+@crlf
                end
                band = band + 1
              end
            else
              # Sleep while there's nothing to do.
              Thread.stop
            end
            if (Time.now.to_i - start_time >= interval) then
              start_time = Time.now.to_i
              band = 0
            end
          end
        end
        
        # Send ident information
        if (@password) then
          pass(@password)
        end
        nick(@nick)
        user(@username, @realname)
        
        @threads = Array.new
        
        # Start a listener thread. Constantly reads the socket
        # and turns messages into events.
        Thread.abort_on_exception = true
        @readThread = Thread.new do
          while(@connected) do
            begin
              msg = @conn.readline
              
              # Convert this message to an event and add it
              # to the queue.
              add_event(msg.strip)
              
              # We may error if the connection terminates while
              # we're in the loop. This will ensure a smooth shutdown.
            rescue EOFError
              next
            rescue Errno::ETIMEDOUT => e
              $stderr.puts "Connection timed out. Disconnecting." if @debug
              @connected = nil
            rescue Errno::ECONNRESET => e
              $stderr.puts "Connection reset. Disconnecting." if @debug
              @connected = nil
            rescue Errno::ENETUNREACH => e
              $stderr.puts "Network unreachable. Disconnecting." if @debug
              @connected = nil
            rescue Errno::EHOSTUNREACH => e
              $stderr.puts "Host unreachable. Disconnecting." if @debug
              @connected = nil
            end
            
          end
        end
        
        # Start a thread to handle events. Reads the first event off
        # the queue and calls its handler, if it exists.
        @eventThread = Thread.new do
          # Hash of semaphores. Allow only one of each event type
          # to run at a time.
          control = {}
          while(@connected) do
            if (@queue) then
              $stderr.puts "Processing a "+@queue.command+" event" if @debug
              if (@handlers[@queue.command] or @generic_handler) then
                $stderr.puts "Handling a "+@queue.command+" event" if @debug
                # Spawn a new thread so we can handle events CONCURRENTLY!
                # Useful if you want to results of a request before the
                # current handler ends. Just set up a barrier and you
                # should be good to go.
                @threads << Thread.new(@queue) do |event|
                  if (!control[event.command]) then
                    control[event.command] = Mutex.new
                  end
                  control[event.command].synchronize do
                    if @handlers[event.command] then
                      @handlers[event.command].each do |f|
                        f.call(event)
                      end
                    end
                    if @generic_handler then
                      @generic_handler.call(event)
                    end
                  end
                end
              end
              dequeue
            else
              # Sleep while there's nothing to do.
              Thread.stop
            end
          end
          @threads.each {|t| t.join}
        end
        
        # Wait for all threads to terminate before ending execution
        [@readThread,@eventThread,@writeThread].each {|t| t.join}
        @conn.close
      else
        $stderr.puts "Failed to connect." if @debug
      end
    end
    
    # Registers default event handlers. You can overwrite them if you
    # like, but they probably already do what you want.
    def add_default_handlers
      # Reply to server ping
      add_handler('ping') do |event|
        write "PONG "+event.params.join(' ')
      end
      # Notice when we've been killed
      add_handler('kill') do |event|
        @connected = nil
        $stderr.puts "Disconnected from server. (KILL: "+event.params[0]+")" if @debug
      end
      # Disconnect on fatal error
      add_handler('error') do |event|
        if (event.params[0].index('Closing Link')) then
          @connected = nil
          $stderr.puts "Disconnected from server. (ERROR: "+event.params[0]+")" if @debug
        end
      end
      # Reply to CTCP clientinfo
      # Only modify this if you expand the class's features!
      add_handler('ctcp_clientinfo') do |event|
        from = event.from
        nick = from.split('!')[0]
        ctcp_reply(nick, 'CLIENTINFO ACTION CLIENTINFO PING TIME VERSION')
      end
      # Reply to CTCP ping
      add_handler('ctcp_ping') do |event|
        from = event.from
        nick = from.split('!')[0]
        ctcp_reply(nick, 'PING '+Time.now.to_i.to_s)
      end
      # Reply to CTCP version
      add_handler('ctcp_version') do |event|
        from = event.from
        nick = from.split('!')[0]
        ctcp_reply(nick, 'VERSION Ruby-IRC 0.1 by Brandon Peterman')
      end
      # Reply to CTCP time
      add_handler('ctcp_time') do |event|
        from = event.from
        nick = from.split('!')[0]
        ctcp_reply(nick, 'TIME '+Time.now.ctime)
      end
    end
    
    # Mechanism for adding event handlers. An event may have an arbitrary
    # number of handlers; they will all be run in the order they were
    # added.
    # [command] Command this handler listens to. Commands are specified
    #           in the human-readable format listed in irc-event.rb.
    # [block]   Block to execute when this event is handled.
    #
    # Example:
    #  conn = IRCConnection.new('MyNick', 'myname', 'Real Person')
    #  conn.add_handler('endofmotd') do |event|
    #      conn.join '#somechannel'
    #  end
    def add_handler(command, &block)
      # Make sure we have a handler hash
      if (!@handlers) then
        @handlers = Hash.new
      end
      if (!@handlers[command]) then
        @handlers[command] = Array.new
      end
      @handlers[command] << block
    end
    
    # Replaces all handlers for the give command with a specified handler.
    # Unlike add_handler, replace_handlers overwrites all existing
    # handlers.
    # [command] Command this handler listens to. Commands are specified
    #           in the human-readable format listed in irc-event.rb.
    # [block]   Block to execute when this event is handled.
    def replace_handlers(command, &block)
      clear_handlers(command)
      add_handler(command, &block)
    end
    
    # Delete a handler.
    def delete_handler(command, handler)
      @handlers[command].delete_if {|f| handler.object_id == f.object_id}
    end
    
    # Removes all event handlers for a specified event.
    def clear_handlers(command)
      if (@handlers) then
        @handlers[command] = nil
      end
    end
    
    # If set, this handler will fire on ALL events
    def set_generic_handler(&block)
      @generic_handler = block
    end
    
    # Convert a server message to an event and add it to the queue.
    # [msg] Server message to add to the queue.
    def add_event(msg)
      $stderr.puts "Adding event: "+msg if @debug
      parts, from, command, parstr = nil
      
      # Many messages will start with a sender, indicated by a leading
      # ':' character. Split these separately.
      if (msg[0] == ':'[0]) then
        parts = msg.split(' ', 3)
        from = (parts[0])[1..parts[0].length]
        command = parts[1]
        parstr = parts[2]
        
        # Otherwise, only split it into two parts
      else
        parts = msg.split(' ', 2)
        command = parts[0]
        parstr = parts[1]
      end
      
      params = Array.new
      splitdone = nil
      laststr = parstr
      
      # Split the parameter string into individual parameters.
      # We can't just use split(/ /) here because tokens that start with
      # ':' are to be contiguous through the end of the string.
      # Instead, we split on a case-by-case basis, ending when we find a
      # ':' char.
      parstr.split(//).map {|char|
        if (!splitdone) then
          if (char == ' ') then
            strsplit = laststr.split(' ', 2)
            params << strsplit[0]
            laststr = strsplit[1]
          elsif (char == ':') then
            splitdone = true
            longstr = laststr[1..laststr.length]
            params << longstr
          end
        end
      }
      if (laststr[0] != ':'[0]) then
        params << laststr
      end
      
      # Make the new event
      event = IRCEvent.new(command, params, from)
      
      # Queue it up
      enqueue(event)
    end
    
    # Add event to the queue.
    # [event] Event to add to the queue.
    def enqueue(event)
      # Find the end of the queue and append the event to it
      @queue_access.synchronize do
        if (!@queue) then
          @queue = event
        else
          node = @queue
          while(node.next) do
            node = node.next
          end
          node.next = event
        end
      end
      @eventThread.run if @eventThread.alive?
    end
    
    # Remove an event from the event queue.
    def dequeue
      @queue_access.synchronize do
        @queue = @queue.next
      end
    end
    
    # Write to the server.
    # Actually adds a message to the write queue.
    # [msg] String to send to the IRC server.
    def write(msg)
      # Don't let one thread write to the socket after another has closed it!
      if (@connected) then
        $stderr.puts "Writing '"+msg.strip+"'" if @debug
        # Ensure that only one thread is writing at a time
        @write_access.synchronize do
          @write_queue.push msg
          @writeThread.run if @writeThread.alive?
        end
        #@socket_access.synchronize do
        #    @conn.puts msg.strip+@crlf
        #end
      end
    end
    
    # Interrupt the write queue.
    # Deletes everything in the write queue. Can be used to stop flooding.
    def interrupt
      @write_access.synchronize do
        @write_queue = []
      end
    end
    
    ##############################################
    # Connection registration messages
    ##############################################
    
    # Send the server password.
    # [password] Server password.
    def pass(password)
      write "PASS "+password
    end
    
    # Specify a nickname.
    # [nickname] Nickname to change to.
    def nick(nickname)
      write "NICK "+nickname
    end
    
    # Submit user data.
    # [username] IRC username. Not to be confused with nickname.
    # [realname] Client's real name. Nobody is checking if you lie.
    def user(username, realname)
      write "USER "+username+" foo.bar.com "+@host+" :"+realname
    end
    
    # Disconnect from the server.
    # [msg] Quit message.
    def quit(msg=nil)
      write "QUIT"+(msg ? " :"+msg : '')
      @connected = nil
    end
    
    ##############################################
    # Channel operation messages
    ##############################################
    
    # Join a channel.
    # [chan] Channel to join.
    # [key]  Channel's passkey.
    def join(chan, key=nil)
      write "JOIN "+chan+(key ? " "+key : '')
    end
    
    # Leave a channel.
    # [chan] Channel to depart.
    def part(chan)
      write "PART "+chan
    end
    
    # Change modes. Works for both user and channel modes.
    # [target]     User or channel whose mode will be changed.
    # [modestring] Mode specifier. Something like +b or -m.
    # [limit]      User limit, if using mode +l.
    # [user]       If changing a channel mode, which user is targeted.
    # [mask]       If the mode is +b, specify a ban mask.
    def mode(target, modestring, limit=nil, user=nil, mask=nil)
      write "MODE "+target+" "+modestring+(limit ? " "+limit : "")+(user ? " "+user : "")+(mask ? " "+mask : "")
    end
    
    # Change the channel topic.
    # [chan] Channel whose topic you'd like to change.
    # [msg]  New channel topic. If not specified, the topic will be erased.
    def topic(chan, msg=nil)
      write "TOPIC :"+chan+(topic ? " :"+topic : "")
    end
    
    # Request the members of a channel.
    # [chan] Channel whose member list you'd like.
    def names(chan)
      write "NAMES "+chan
    end
    
    # Request a list of channels.
    # [chan] If specified, list will return information about this channel.
    #        Otherwise, it will return a list of channels on the server.
    def list(chan=nil)
      write "LIST"+(chan ? " "+chan : "")
    end
    
    # Invite a user to a channel.
    # [nick] User to invite.
    # [chan] Exclusive channel.
    def invite(nick, chan)
      write "INVITE "+nick+" "+chan
    end
    
    # Kick a user from a channel.
    # [chan] Channel in which the user is unwanted.
    # [user] Unwanted user.
    # [msg]  Witty message.
    def kick(chan, user, msg=nil)
      write "KICK "+chan+" "+user+(msg ? " :"+msg : "")
    end
    
    # Ban a user! An alias for mode(chan, '+b', nil, nil, mask)
    # [chan] Channel to ban the user from.
    # [mask] Ban mask.
    def ban(chan, mask)
      mode(chan, '+b', nil, nil, mask)
    end
    
    # Unban a user. Just like ban, but sets mode -b.
    # [chan] Channel to unban a user from.
    # [mask] Ban mask.
    def unban(chan, mask)
      mode(chan, '-b', nil, nil, mask)
    end
    
    # Kickban is just a combination of kick and ban.
    # The arguments are the same.
    def kickban(chan, user, mask)
      kick(chan, user)
      ban(chan, mask)
    end
    
    ##############################################
    # Messaging messages
    ##############################################
    
    # Standard private message to another user or a channel.
    # [receiver] Channel or user.
    # [msg]      Message string.
    def privmsg(receiver, msg)
      write "PRIVMSG "+receiver+" :"+msg
    end
    
    # Send a notice. Like a privmsg, but cannot generate an automatic response.
    # [nick] Recipient of the notice.
    # [msg]  Message string.
    def notice(nick, msg)
      write "NOTICE "+nick+" :"+msg
    end
    
    ##############################################
    # CTCP messages
    ##############################################
    
    # Ask another user which CTCP messages are suported.
    # [nick] User to query.
    def ctcp_ping(nick)
      privmsg(nick, "CLIENTINFO")
    end
    
    # Send an action message! (emote)
    # [chan] Channel to receive your emote.
    # [msg]  Outrageous action message.
    def ctcp_action(chan, msg)
      write "PRIVMSG "+chan+" :ACTION "+msg+""
    end
    
    # Send a ping to another user.
    # [nick] User to ping.
    def ctcp_ping(nick)
      privmsg(nick, "PING "+Time.now.to_i.to_s+"")
    end
    
    # Send a version request to another user.
    # [nick] User to query.
    def ctcp_version(nick)
      privmsg(nick, "VERSION")
    end
    
    # Send a time request to another user.
    # [nick] User to query.
    def ctcp_time(nick)
      privmsg(nick, "TIME")
    end
    
    # Send a CTCP reply.
    # [nick] User to receive the reply.
    # [msg]  Message to send.
    def ctcp_reply(nick, msg)
      notice(nick, ""+msg+"")
    end
    
    ##############################################
    # User query messages
    ##############################################
    
    # List users who match a specified mask.
    # [name] Mask.
    # [o]    Only search for server operators.
    def who(name, o=nil)
      write "WHO "+name+(o ? " o" : "")
    end
    
    # Request information about a user.
    # [nick]   User to query.
    # [server] Server on which the user is connected.
    def whois(nick, server=nil)
      write "WHOIS "+(server ? server+" " : "")+nick
    end
    
    # Request information about a recently-departed nickname.
    # [nick]   User to query.
    # [count]  Maximum number of entries to return.
    # [server] Server on which the user was connected.
    def whowas(nick, count=nil, server=nil)
      write "WHOWAS "+nick+(count ? " "+count : "")+(server ? " "+server : "")
    end
    
    ##############################################
    # Server query messages
    ##############################################
    
    # Request server version.
    # [server] Server to query (default: server you're connected to).
    def version(server=nil)
      write "VERSION"+(server ? " "+server : "")
    end
    
    # Request list of servers on the network.
    # [server] Server to query (default: server you're connected to).
    def links(server=nil)
      write "LINKS"+(server ? " "+server : "")
    end
    
    # Request a server's local time.
    # [server] Server to query (default: server you're connected to).
    def time(server=nil)
      write "TIME"+(server ? " "+server : "")
    end
    
    # Trace route to server.
    # [server] Server to query (default: server you're connected to).
    def trace(server=nil)
      write "TRACE"+(server ? " "+server : "")
    end
    
    # Request administrator info.
    # [server] Server to query (default: server you're connected to).
    def admin(server=nil)
      write "ADMIN"+(server ? " "+server : "")
    end
    
    # Request server info.
    # [server] Server to query (default: server you're connected to).
    def info(server=nil)
      write "INFO"+(server ? " "+server : "")
    end
    
    ##############################################
    # Optional messages
    ##############################################
    
    # Advertise client as away.
    # [msg] Away message.
    def away(msg=nil)
      write "AWAY"+(msg ? " :"+msg : "")
    end
    
    # Request list or number of users.
    # [server] Server to request list from (default: server you're connected to).
    def users(server=nil)
      write "USERS"+(server ? " "+server : "")
    end
    
    # Request a user's host. Can handle up to five requests at once.
    # [userX] Nickname of user you want information about.
    def userhost(user1, user2=nil, user3=nil, user4=nil, user5=nil)
      write "USERHOST "+user1+(user2 ? " "+user2 : "")
      +(user3 ? " "+user3 : "")+(user4 ? " "+user4 : "")
      +(user5 ? " "+user5 : "")
    end
    
    # Find out whether a user is online.
    # [nick] Nickname of the user you want information about.
    def ison(nick)
      write "ISON "+nick
    end
  end
end
