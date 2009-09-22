## Molniya: an IM gateway for Nagios
##
## Dedicated to Sergey Korolev, the Chief Designer,
## and Boris Chertok, who wrote it all down for us.
##
## Copyright 2009 Windermere Services Company.
## By Clayton Wheeler, cswheeler@gmail.com
##
## This program is free software; you can redistribute it and/or modify
## it under the terms of the GNU General Public License as published by
## the Free Software Foundation; version 2 of the License.
##   
## This program is distributed in the hope that it will be useful,
## but WITHOUT ANY WARRANTY; without even the implied warranty of
## MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
## General Public License for more details.

require 'logger'
require 'timeout'
require 'thread'
require 'ostruct'
require 'pathname'
require 'net/smtp'
require 'rexml/document'
require 'set'
require 'strscan'
require 'uri'

require 'rack'
require 'sinatra/base'
require 'xmpp4r'
require 'xmpp4r/roster'
require 'xmpp4r/xhtml'
require 'yaml'

require 'inspectable'
require 'nagios'
require 'commands'
require 'formatting'

#### TODO
# rosters
# commands (down, ack, etc)
# proper service initialization / linking
# hosts in status
# consider filtering out stuff (sweeps et al) from status reports
# summarize dependencies
# broadcast
# dialogue

module Molniya

  SECOND = 1
  MINUTE = 60
  HOUR = 60 * MINUTE
  DAY = 24 * HOUR
  WEEK = 7 * DAY

  TSPEC = [[WEEK, 'w'],
           [DAY, 'd'],
           [HOUR, 'h'],
           [MINUTE, 'm'],
           [SECOND, 's']]

  XMPP_AVAIL = [:chat, nil]

  LOG = Logger.new(STDERR)

  def self.brief_time_delta(t)
    Molniya::brief_duration((Time.now - t).to_i)
  end

  def self.brief_duration(secs, parts=TSPEC)
    if parts.empty?
      return ''
    else
      n, char = parts[0]
      if secs > n
        part = (secs / n).to_s + char
        return part + Molniya::brief_duration(secs % n, parts[1..1])
      else
        return Molniya::brief_duration(secs, parts[1..-1])
      end
    end
  end

  class Contact
    include Inspectable
    attr_accessor :jid, :roster_item, :missed, :recent, :seq
    inspect_my :jid

    def initialize(jid)
      @jid = jid
      @recent = {}
      @seq = 0
      @missed = []
    end

    def available?
      if ! roster_item
        LOG.warn "WARNING: no roster item for #{jid}: #{self.inspect}"
        return false
      end
      if roster_item.online?
        show = roster_item.presences.last.show
        return XMPP_AVAIL.member?(show)
      else
        return false
      end
    end

    def record_notification(n)
      if seq < 9
        @seq = (@seq + 1)
      else
        @seq = 0
      end
      recent[seq] = n
      return seq
    end

    def to_s
      ""
    end

  end

  class TraceClient < Jabber::Client
    def send(xml, &block)
      $stderr.puts "XMPP: sending #{xml}"
      return super(xml, &block)
    end

    def receive(e)
      $stderr.puts "XMPP: received #{e}"
      return super(e)
    end
  end

  class XMPPClient
    include Inspectable
    attr_accessor :sb, :client, :roster, :contacts, :inbox, :worker
    inspect_my :client

    COMMAND_DEFS = [Commands::Status, Commands::Check, Commands::Reply,
                    Commands::Admin, Commands::Help, Commands::Eval]

    def initialize(sb)
      @sb = sb
      @contacts = {} # Hash.new {|h, jid| h[jid] = Contact.new(jid)}
      @inbox = Queue.new
      @client = Jabber::Client.new(sb.conf['username'])
      # @client = TraceClient.new(sb.conf['username'])
      LOG.info "Connecting to XMPP server..."
      client.on_exception do |e, client, where|
        LOG.error "Error connecting in #{where}: #{e}"
        LOG.error e.backtrace.join("\n")
      end
      initial_connect()
      LOG.debug "Setting up roster helper."
      @roster = Jabber::Roster::Helper.new(client)
      init_callbacks
      presence()
      client.on_exception do |e, client, where|
        LOG.warn "Reconnecting after exception in #{where}: #{e}"
        $stderr.puts e.backtrace.join("\n")
        reconnect()
      end
      @worker = nil
    end

    def start_worker()
      @worker = Thread.new { run() }
    end

    def initial_connect()
      status = Timeout::timeout(15) do
        connect()
      end
    end

    def connect()
      client.connect()
      LOG.info "Connected."
      client.auth(sb.conf['password'])
      LOG.debug "Authenticated."
    end

    def reconnect()
      connect()
      presence()
    end

    def enqueue_in(item)
      inbox << item
      #if not success
      #  log "inbox full, dropped #{item.inspect}"
      #end
    end

    def init_callbacks
      ## client callbacks are invoked in parser thread, must enqueue
      client.add_message_callback { |msg| enqueue_in([:message, msg]) }

      ## roster callbacks are invoked in separate threads, just do stuff
      roster.add_presence_callback do |roster_item, old_pres, new_pres|
        # LOG.debug "got presence for #{roster_item.inspect}: old #{old_pres}, new #{new_pres}"
        jid = roster_item.jid.strip
        unless contacts.has_key? jid
          c = Contact.new(jid)
          c.roster_item = roster_item
          contacts[jid.to_s] = c
        end
        if old_pres \
          && (! XMPP_AVAIL.member?(old_pres.show)) \
          && XMPP_AVAIL.member?(new_pres.show)
          # came online, catch up
          contact = contacts[jid]
          sb.catch_up(contact)
        end
      end
      # TODO: subscription stuff
    end

    ### handle incoming XMPP traffic

    def known_sender?(msg)
      # TODO
      return true
      addr = msg.from.strip
      unless contacts.has_key? addr
        LOG.warn "unknown sender: #{msg.from}"
        return false
      end
      unless sb.is_xmpp_contact?(addr)
        LOG.warn "not a Nagios contact: #{addr}"
        return false
      end
      return true
    end

    def handle_message(msg)
      ## TODO: down
      ## TODO: ls
      ## TODO: admin alias (?? what was this supposed to be?)
      unless msg.body
        #LOG.debug "message with no body."
        return
      end
      unless known_sender? msg
        return
      end
      contact = contacts[msg.from.strip]
      scanner = StringScanner.new(msg.body)
      first = scanner.scan(/[\w@]+/)
      if not first
        LOG.warn "empty body? #{msg.body.inspect}"
        return
      end
      begin
        ## TODO: check contact can_submit_commands property on writes
        cd = COMMAND_DEFS.find { |cd| cd.cmd === first }
        if cd
          LOG.debug "invoking command: #{cd}"
          invoke_cmd(cd, first, msg, contact, scanner)
        else
          # not a recognized command, is it host or host/svc?
          host = sb.find_host(first)
          if host
            if scanner.scan(/\//)
              # host/svc
              svc = sb.resolve_service_name(host, scanner)
              invoke_cmd(Commands::ServiceDetail,
                         first, msg, contact, scanner, svc)
            else
              invoke_cmd(Commands::HostDetail,
                         first, msg, contact, scanner, host)
            end
          else
            send_msg(msg.from,
                     "I\'m sorry, I didn\'t quite catch that?")
          end
        end
      rescue Exception => e
        send_msg(msg.from, "Oops. #{e}")
        #raise
        LOG.error e
        LOG.error e.backtrace.join("\n")
      end
    end

    def invoke_cmd(cmd_def, cmd_text, msg, contact, scanner, *rest)
      cmd = cmd_def.new
      cmd.cmd_text = cmd_text
      cmd.msg = msg
      cmd.contact = contact
      cmd.scanner = scanner
      cmd.sb = sb
      cmd.client = self
      cmd.invoke(*rest)
    end

    ### send messages

    def presence()
      client.send(Jabber::Presence.new(:chat, self.sb.status_msg))
    end

    def send_msg(jid, contents)
      LOG.debug "sending message to #{jid}: #{contents}"
      client.send(Jabber::Message.new(jid, contents))
    end

    def invite(jid)
      LOG.info "#{jid} is not on our list, asking..."
      @im.add(jid)
    end
    
    def send_if_online(jid, message)
      if @contacts.has_key? jid
        # existing contact
        if online?(jid)
          return send_msg(jid, message)
        else
          LOG.debug "#{jid} is #{status}, not sending"
          return false
        end
      else
        invite(jid)
        return false
      end
    end

    def online?(jid)
      @contacts[jid] == :online
    end

    def run()
      LOG.debug "Beginning XMPP message processing."
      while true
        msg = nil
        begin
          item = inbox.pop()
          type = item[0]
          case type
          when :message
            msg = item[1]
            if known_sender?(msg)
              LOG.debug "received message: #{msg}"
              handle_message(msg)
            else
              LOG.warn "message from unknown sender: #{msg}"
            end
          else
            LOG.error "unhandled inbox item: #{item.inspect}"
          end
        rescue Exception => e
          LOG.error e
          LOG.error e.backtrace.join("\n")
          if msg
            client.send_msg(msg.from, "Oops. #{e}")
          end
        end
      end
    end

  end

  class NagiosInstance
    include Inspectable
    ### thread-safe

    ## interesting commands
    # ACKNOWLEDGE_[HOST|SVC]_PROBLEM
    # ENABLE/DISABLE_ALL_NOTIFICATIONS_BEYOND_HOST
    # SAVE_STATE_INFORMATION
    # SCHEDULE_[HOST|SVC]_DOWNTIME
    # SCHEDULE_AND_PROPAGATE_HOST_DOWNTIME
    # SCHEDULE_HOSTGROUP_[HOST|SVC]_DOWNTIME
    # SCHEDULE_SERVICEGROUP_[HOST|SVC]_DOWNTIME
    # SEND_CUSTOM_[HOST|SVC]_NOTIFICATION

    ## TODO:
    # summarize dependencies in outages: 
    #   CRITICAL: host/some service and 8 dependent services

    attr_accessor :conf, :last, :last_mtime, :config, :status, :sb, :cmd_t

    def initialize(conf, sb)
      @conf = conf
      @last = nil
      @last_mtime = nil
      @sb = sb
      nagios_var = Pathname.new(conf['nagios_var'])
      #log "Nagios /var is #{nagios_var}"
      @config = Nagios::Config.new(nagios_var + 'objects.cache', self)
      @status = Nagios::Status.new(nagios_var + 'status.dat', self)
      @cmd_t = Nagios::CommandTarget.new(nagios_var + 'rw' + 'nagios.cmd')
    end

    SVC_PROBLEMS = [:critical, :warning, :unknown]
    
    def status_report()
      ok_hosts, bad_hosts =
        config.contents.hosts.values.partition { |h| h.cur_state == :ok }
      hosts = Set.new(bad_hosts)
      hosts_c = hosts.classify { |h| h.cur_state }
      problem_svcs = ok_hosts.collect do |h|
        h.services.values.find_all do |s|
          SVC_PROBLEMS.include? s.cur_state
        end
      end.flatten.to_set
      svcs_c = problem_svcs.classify { |s| s.cur_state }
      return {
        :hosts => hosts_c.to_a,
        :services => svcs_c.to_a
      }
    end

    def base_uri
      conf['nagios_uri']
    end

    def cgi(name)
      "#{base_uri}/cgi-bin/#{name}.cgi"
    end

    def status_uri(host)
      # http://nagios.example.com/nagios/cgi-bin/status.cgi?host=fran
      sprintf("%s?host=%s",
              cgi('status'),
              URI.encode(host))
    end

    def service_uri(host, svc)
      sprintf("%s?type=2&host=%s&service=%s",
              cgi('extinfo'),
              URI.encode(host),
              URI.encode(svc))
    end
  end

  class WebApp < Sinatra::Base
    include Inspectable

    attr_accessor :sb

    post '/contact/:cname/notify' do
      #log "notification request with parameters: #{params.inspect}"
      sb.notification(params[:cname], params['policy'], OpenStruct.new(params))
      status 204
    end
    
    post '/contact/:jid/send' do
      sb.send_msg(params[:jid], params[:message] || params['rack.input'].read)
      status 204
    end
    
  end

  class Switchboard
    include Inspectable

    attr_accessor :conf, :nagios, :xmpp, :http, :fmt, :status_msg, :uri
    attr_reader :http_worker
    # :smtp, :http
    
    def initialize(conf)
      @conf = conf
      if conf.has_key? :log_config
        Molniya.const_set(:LOG, Logger.new(*conf[:log_config]))
      elsif conf.has_key? :log_file
        Molniya.const_set(:LOG, Logger.new(conf[:log_file], 'daily'))
      end
      if conf.has_key? :log_level
        LOG.level = Logger.const_get(conf[:log_level])
      end
      @nagios = NagiosInstance.new(conf, self)
      @fmt = {
        :xmpp => XMPPHTMLFormatter.new(self),
        :email => EmailFormatter.new,
        :email_subject => EmailSubjectFormatter.new
      }
      update_status_msg()
      LOG.debug "setting up XMPPClient"
      @xmpp = XMPPClient.new(self)
      @http = WebApp.new
      @http.sb = self
    end

    def start
      xmpp.start_worker()
      LOG.debug "Starting HTTP server."
      @http_worker = Thread.new { Rack::Handler::Mongrel.run(@http, @conf['http_opts']) }
    end

    def run
      interval = 30
      LOG.info "Switchboard running."
      while true
        unless xmpp.worker.alive?
          raise "XMPPClient worker thread died!"
        end
        update_status_msg()
        if nagios.status.listeners?
          interval = 2
        else
          interval = 10
        end
        sleep(interval)
      end
    end

    def is_xmpp_contact?(addr)
      find_nagios_contact_with_jid(addr)
    end

    def find_nagios_contact_with_jid(addr)
      addr_s = addr.to_s
      field = conf['xmpp_field']
      contacts = nagios.config.contents.contacts
      return contacts.values.find { |c| c.props[field] == addr_s }
    end

    def find_host(name)
      return nagios.config.contents.hosts[name]
    end

    def find_service(hname, sname)
      h = find_host(hname)
      if h
        return h.services[sname]
      else
        return nil
      end
    end

    def find_notification_referent(n)
      case n.ntype
      when 'host'
        return find_host(n.HOSTNAME)
      when 'service'
        return find_service(n.HOSTNAME, n.SERVICEDESC)
      end
    end

    def resolve_service_name(host, scanner)
      sname = host.services.keys.find { |n| scanner.scan(Regexp.new(n)) }
      if sname
        return host.services[sname]
      else
        raise "Unknown service starting with #{scanner.rest} for host #{host.name}"
      end
    end

    def update_status_msg
      nagios.config.refresh_if_needed()
      nagios.status.refresh_if_needed()
      @status_msg = fmt[:xmpp].status_message(nagios.status_report())
      if xmpp
        xmpp.presence()
      end
    end

    def check(item, notify=nil)
      req_t = Time.now
      ## force a check
      item.force_check(req_t)
      ## register if needed
      if notify
        nagios.status.register do |sv|
          if item.last_check > req_t
            ## got an update, report on it
            xmpp.send_msg(notify.jid, item.detail(:xmpp))
            ## deregister
            false
          else
            ## no update yet, stay registered
            true
          end
        end
      end
    end

    def notification(contact_name, policy_spec, n)
      contacts = nagios.config.contents.contacts
      contact = contacts.fetch(contact_name)
      n.referent = find_notification_referent(n)
      unless n.referent
        raise "Couldn't find what notification referred to: #{n.inspect}"
      end
      policy_spec.split(';').each do |policy|
        case policy
        when 'xmpp'
          if xmpp_notification(contact, n)
            break
          end
        when 'email'
          email_notification(contact, contact.props.fetch('email'), n)
          break
        when 'pager'
          email_notification(contact, contact.props.fetch('pager'), n)
          break
        else
          raise "unknown policy #{policy} for #{contact}!"
        end
      end
    end

    def xmpp_notification(contact, n)
      jid = contact.props[conf['xmpp_field']]
      unless jid
        raise "Contact #{contact.name} does not have a JID in #{conf['xmpp_field']}: props #{contact.props.inspect}"
      end
      x_contact = xmpp.contacts[jid]
      unless x_contact
        LOG.warn "no contact with jid #{jid}, not sending message"
        return false
      end
      if x_contact.available?
        n.seq = x_contact.record_notification(n)
        xmpp.send_msg(jid, fmt[:xmpp].notification(n))
        return true
      else
        x_contact.missed << n
        return false
      end
    end

    def catch_up(contact)
      ## just came online
      # TODO
      # while you were away:
      # for each host/service with a problem notification:
      #   if it's not OK now, notify
      LOG.debug "Catching up with contact #{contact.jid}."
      if not contact.missed.empty?
        LOG.debug "Has #{contact.missed.length} missed notifications"
        ## TODO: filter just for problem notifications?
        m_refs = contact.missed.find_all { |n| n.referent }.collect { |n| n.referent }
        m_bad = m_refs.find_all { |ref| ref.hard_state != :ok }
        m_hosts = Set.new(m_bad.find_all { |ref| ref.is_a? Nagios::Host })
        m_svcs = Set.new(m_bad.find_all { |ref| ref.is_a? Nagios::Service })
        if (not m_hosts.empty?) || (not m_svcs.empty?)
          LOG.debug "Had problem notifications for existing problems."
          ## TODO: use a proper formatting mechanism
          msg = "While you were out:\n"
          if not m_hosts.empty?
            hmsg = m_hosts.classify { |h| h.hard_state }.collect do |state, hosts|
              sprintf("%s: %s", state,
                      hosts.sort.collect { |h| h.name }.join(", "))
            end.join("; ")
            msg << hmsg << "\n"
          end
          if not m_svcs.empty?
            smsg = m_svcs.classify { |s| s.hard_state }.sort.collect do |state, svcs|
              sprintf("%s: %s", state,
                      svcs.sort.collect { |s| "#{s.host.name}/#{s.name}" }.join(", "))
            end.join("; ")
            msg << smsg << "\n"
          end
          LOG.debug "Sending message: #{msg}"
          send_msg(contact.jid, msg)
        end
      end
    end
    
    def send_msg(jid, msg)
      xmpp.send_msg(jid, msg)
    end

    def email_notification(contact, to, n)
      from = conf.fetch('smtp_from')
      subject = fmt[:email_subject].notification(n)
      body = fmt[:email].notification(n)
      message = <<EOF
From: Nagios <#{from}>
To: #{contact.props.fetch('alias')} <#{to}>
Date: #{Time.now.rfc822}
Subject: #{subject}

#{body}
EOF
      with_smtp_conn do |conn|
        conn.send_message(message, from, to)
        LOG.info "Sent notification to #{to} via SMTP."
      end
    end

    def with_smtp_conn
      Net::SMTP.start(conf['smtp_relay'], 25) do |smtp|
        yield smtp
      end
    end
    
  end

  def self.launch
    sb = Switchboard.new(YAML::load(File.read(ARGV[0])))
    sb.start
    sb.run
  end
end

