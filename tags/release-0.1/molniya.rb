## Molniya: an IM gateway for Nagios
##
## Dedicated to Sergey Korolev.
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

require 'nagios'

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

  MINUTE = 60
  HOUR = 60 * MINUTE
  DAY = 24 * HOUR
  WEEK = 7 * DAY

  TSPEC = [[WEEK, 'w'],
           [DAY, 'd'],
           [HOUR, 'h'],
           [MINUTE, 'm']]

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
    attr_accessor :jid, :roster_item, :missed, :recent, :seq

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
        return XMPP_AVAIL.member? show
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
    attr_accessor :sb, :client, :roster, :contacts, :inbox, :worker

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
      LOG.info "Setting up roster helper."
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
        #LOG.debug "got presence for #{roster_item.inspect}: old #{old_pres}, new #{new_pres}"
        jid = roster_item.jid.strip
        unless contacts.has_key? jid
          c = Contact.new(jid)
          c.roster_item = roster_item
          contacts[jid.to_s] = c
          #log "registered contact for #{jid}"
        end
        if (! XMPP_AVAIL.member?(old_pres)) && XMPP_AVAIL.member?(new_pres)
          # came online, catch up
          contact = contacts[jid]
          sb.catch_up(contact)
        end
      end
      # TODO: subscription stuff
    end

    ### handle incoming XMPP traffic

    # OLD
    def update_status
      @im.presence_updates.each do |jid, status, desc|
        # @contacts[jid.strip].status = status
      end
    end

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
      ## TODO: ack
      ## TODO: check
      ## TODO: down
      ## TODO: help
      ## TODO: ls
      ## TODO: admin list-roster
      ## TODO: admin unsubscribe
      ## TODO: admin alias
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
        case first
        when 'status'
          send(msg.from, sb.status_report())
        when 'check'
          scanner.skip(/\s*/) or raise 'syntax'
          # IWBNI we could register for notification of the check results...
          case
          when scanner.scan(/(\w+)\//)
            # host/svc
            host = sb.find_host(scanner[1]) or raise "Unknown host #{scanner[1]}"
            svc = sb.resolve_service_name(host, scanner)
            sb.check(svc)
          when scanner.scan(/(\w+)/)
            # host
            host = sb.find_host(scanner[1]) or raise "Unknown host #{scanner[1]}"
            sb.check(host)
          else
            raise 'syntax'
          end
        when /^@(\d)/
          ## @2 whatever: reacting to a notification
          n = contact.recent[$1.to_i]
          if n
            scanner.skip(/\s*/)
            cmd = scanner.scan(/\w+/) or raise "Missing subcommand!"
            case cmd
            when 'ack'
              n_contact = sb.find_nagios_contact_with_jid(contact.jid)
              raise "No Nagios contact with JID #{contact.jid}?" unless n_contact
              scanner.skip(/\s*/)
              if scanner.scan_until(/\S.+/)
                comment = scanner.matched
              else
                comment = "acknowledged."
              end
              sb.nagios.ack(n, n_contact, comment)
            when 'check'
              ref = sb.find_notification_referent(n)
              unless ref
                raise "Couldn't find what notification referred to: #{n.inspect}"
              end
              sb.nagios.check(ref)
            end
          else
            send(msg.from, "No record of notification #{$1}, sorry.")
            LOG.debug "Recent: #{contact.recent.inspect}"
          end
        when 'help'
          send(msg.from, <<EOF)
Nagios switchboard commands:
status: get a status report
check <host | host/svc>: force a check of the named host or service
You can respond to a notification with its @ number, like so:
@N ack [message]: acknowledge a host or service problem, with optional message
@N check: force a check of the host or service referred to
EOF
        when 'eval'
          ## disabled in public release for security reasons
          ## TODO: conditionalize for debugging
          #scanner.skip(/\s*/)
          #send(msg.from, eval(scanner.rest()).inspect)
        when 'admin'
          scanner.skip(/\s*/) or raise 'syntax'
          admin_cmd = scanner.scan(/\S+/)
          scanner.skip(/\s*/)
          case admin_cmd
          when 'list-roster'
            send(msg.from, "Roster: " + roster.items.keys.sort.join(", "))
          when 'add'
            if scanner.scan(/(\S+)\s+(\S+)/)
              jid = scanner[0]
              iname = scanner[1]
              roster.add(Jabber::JID.new(jid), iname, true)
              send(msg.from, "Added #{jid} (#{iname}) to roster and requested presence subscription.")
            else
              send(msg.from, "Usage: admin add <jid> <alias>")
            end
          when 'remove'
            jid = scanner.scan(/\S+/)
            if jid
              roster[jid].remove()
              send(msg.from, "Contact #{jid} successfully removed from roster.")
            else
              send(msg.from, "Usage: admin remove <jid>")
            end
          else
            send(msg.from, "Unknown admin command #{admin_cmd}")
          end
        else
          # not a recognized command, is it host or host/svc?
          host = sb.find_host(first)
          if host
            if scanner.scan(/\//)
              # host/svc
              svc = sb.resolve_service_name(host, scanner)
              send(msg.from, sb.service_detail(svc))
            else
              # TODO
              send(msg.from, "Sorry, host details not implemented yet.")
            end
          else
            send(msg.from, "I\'m sorry, I didn\'t quite catch that?")
          end
        end
      rescue
        send(msg.from, "Oops. #{$!}")
        #raise
        LOG.error $!
        LOG.error $!.backtrace.join("\n")
      end
    end

    ### send messages

    def presence()
      client.send(Jabber::Presence.new(:chat, self.sb.status_msg))
    end

    def send(jid, contents)
      client.send(Jabber::Message.new(jid, contents))
    end

    def send_(jid, message)
      if @contacts.has_key? jid
        # existing contact
        @im.deliver(jid, message)
        return true
      else
        invite(jid)
        return false
      end
    end

    def invite(jid)
      LOG.info "#{jid} is not on our list, asking..."
      @im.add(jid)
    end
    
    def send_if_online(jid, message)
      if @contacts.has_key? jid
        # existing contact
        if online?(jid)
          return send(jid, message)
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
      end
    end

  end

  class NagiosInstance
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

    attr_accessor :conf, :last, :last_mtime, :config, :status

    def initialize(conf)
      @conf = conf
      @last = nil
      @last_mtime = nil
      nagios_var = Pathname.new(conf['nagios_var'])
      #log "Nagios /var is #{nagios_var}"
      @config = Nagios::Config.new(nagios_var + 'objects.cache')
      @status = Nagios::Status.new(nagios_var + 'status.dat', @config)
      @cmd_t = Nagios::CommandTarget.new(nagios_var + 'rw' + 'nagios.cmd')
    end

    def status_report()
      s = status.contents()
      report = { :hosts => [], :services => [] }
      [:down, :unreachable].each do |status|
        hosts = s.hosts_by[status]
        unless hosts.empty?
          report[:hosts] << [status, hosts]
        end
      end
      [:critical, :warning, :unknown].each do |status|
        svcs = s.services_by[status]
        unless svcs.empty?
          report[:services] << [status, svcs]
        end
      end      
      return report
    end

    def check(thing, at=Time.now)
      thing.force_check(@cmd_t, at)
    end

    def ack(n, user, comment="acknowledged")
      case n.ntype
      when 'service'
        @cmd_t.acknowledge_svc_problem(n.HOSTNAME,
                                       n.SERVICEDESC,
                                       0, # sticky
                                       1, # notify
                                       1, # persistent
                                       user.name, # author
                                       comment)
      when 'host'
        @cmd_t.acknowledge_host_problem(n.HOSTNAME,
                                        0, # sticky
                                        1, # notify
                                        1, # persistent
                                        user.name, # author
                                        comment)
      else
        raise "unsupported ntype #{n.ntype}"
      end
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

  class BaseFormatter

    def notification(data)
      case data.ntype
      when 'host'
        return host_notify(data)
      when 'service'
        return service_notify(data)
      else
        raise "unhandled notification type #{data.ntype}!"
      end
    end

  end

  class XMPPFormatter < BaseFormatter

    def host_notify(n)
      # todo: eval
      s = "@#{n.seq} #{n.NOTIFICATIONTYPE}: #{n.HOSTNAME} is #{n.HOSTSTATE}\n"
      case n.NOTIFICATIONTYPE
      when "PROBLEM", "RECOVERY"
        s << "Info: #{n.HOSTOUTPUT}"
      when "ACKNOWLEDGEMENT", "CUSTOM", "DOWNTIMESTART", "DOWNTIMEEND"
        s << "Info: #{n.NOTIFICATIONCOMMENT}"
      else
        LOG.error "unexpected NOTIFICATIONTYPE: #{n.NOTIFICATIONTYPE}"
      end
      return s
    end

    def service_notify(n)
      s = "@#{n.seq} #{n.NOTIFICATIONTYPE}: Service #{n.SERVICEDESC} on #{n.HOSTNAME} is #{n.SERVICESTATE}\n"
      case n.NOTIFICATIONTYPE
      when "PROBLEM", "RECOVERY"
        s << "Info: #{n.SERVICEOUTPUT}"
      when "ACKNOWLEDGEMENT", "CUSTOM", "DOWNTIMESTART", "DOWNTIMEEND"
        s << "Info: #{n.NOTIFICATIONCOMMENT}"
      else
        LOG.error "unexpected NOTIFICATIONTYPE: #{n.NOTIFICATIONTYPE}"
      end
      return s
    end

    def service_state(s)
      "#{s.name} for #{Molniya::brief_time_delta(s.last_ok)}"
    end

    def service_detail(svc)
      "#{svc.name}: #{svc.soft_state.to_s.upcase} for #{Molniya::brief_time_delta(svc.last_ok)}\nInfo: #{svc.info}"
      # TODO...
    end

    def host_detail(h)
      "#{h.name}: #{h.soft_state.to_s.upcase} for #{Molniya::brief_time_delta(h.last_ok)}"
    end

    def status_message(s)
      if not s[:services].empty?
        s[:services].collect { |state, items| "#{items.size} #{state}" }.join(", ")
      else
        "All clear"
      end
    end

    def status_report(s)
      if not s.empty?
        s.collect do |state, items|
          sprintf("%s: %s",
                  state.to_s.upcase,
                  items.collect { |i| service_state(i) }.join("; "))
        end.join("\n")
      else
        "All clear."
      end
    end
  end

  class XMPPHTMLFormatter < XMPPFormatter

    attr_accessor :sb

    def initialize(sb)
      @sb = sb
    end

    def nagios
      sb.nagios
    end

    def svc_link(svc)
      a = REXML::Element.new 'a'
      a.attributes['href'] = nagios.service_uri(svc.host.name,
                                                svc.desc)
      a.text = svc.name
      return a
    end
    
    def host_svc_link(svc)
      s = REXML::Element.new 'span'
      h = s.add_element 'a', { 'href' => nagios.status_uri(svc.host.name) }
      h.text = svc.host.name
      s.add_text '/'
      sa = s.add_element 'a', { 'href' => nagios.service_uri(svc.host.name,
                                                             svc.name) }
      sa.text = svc.name
      return s
    end
    
    def service_notify(n)
      # "#{n.NOTIFICATIONTYPE}: Service #{n.SERVICEDESC} on #{n.HOSTNAME} is #{n.SERVICESTATE}\nInfo: #{n.SERVICEOUTPUT}"
      host = sb.find_host(n.HOSTNAME)
      unless host
        raise "Notification for #{n.HOSTNAME} but could not find host definition!"
      end
      svc = host.services.fetch(n.SERVICEDESC)
      div = REXML::Element.new('div')
      div.add_text "@#{n.seq} "
      div.add_text "#{n.NOTIFICATIONTYPE}: Service "
      div.elements << host_svc_link(svc)
      div.add_text " is #{n.SERVICESTATE}\n"
      div.add_text "Info: #{n.SERVICEOUTPUT}"
      return div
    end

    def service_detail(svc)
      div = REXML::Element.new('div')
      div.elements << host_svc_link(svc)
      div.add_text ": #{svc.soft_state.to_s.upcase} "
      div.add_text "for #{Molniya::brief_time_delta(svc.last_ok)}\nInfo: #{svc.info}"
      return div
    end
    
    def service_state(s)
      span = REXML::Element.new('span')
      span << host_svc_link(s)
      span.add_text " for "
      span.add_text Molniya::brief_time_delta(s.last_ok)
      return span
    end

    def status_report(s)
      if not s[:services].empty?
        div = REXML::Element.new 'div'
        s[:services].each do |state, items|
          sd = div.add_element 'div'
          sd.add_text "#{state.to_s.upcase}: "
          items.each do |i|
            sd << service_state(i)
            if i != items.last
              sd.add_text "; "
            end
          end
          sd.add_element 'br'
        end
        html = Jabber::XHTML::HTML.new(div)
        #return [html.to_text, html]
        return html
      else
        "All clear."
      end
    end
    
  end

  class EmailFormatter < BaseFormatter

    def host_notify(n)
      # todo: eval
      "#{n.NOTIFICATIONTYPE}: #{n.HOSTNAME} is #{n.HOSTSTATE}\nInfo: #{n.HOSTOUTPUT}"
    end

    def service_notify(n)
      "#{n.NOTIFICATIONTYPE}: Service #{n.SERVICEDESC} on #{n.HOSTNAME} is #{n.SERVICESTATE}\nInfo: #{n.SERVICEOUTPUT}"
    end

  end

  class EmailSubjectFormatter < BaseFormatter

    def host_notify(n)
      # todo: eval
      "#{n.NOTIFICATIONTYPE}: #{n.HOSTNAME} is #{n.HOSTSTATE}\nInfo: #{n.HOSTOUTPUT}"
    end

    def service_notify(n)
      "#{n.NOTIFICATIONTYPE}: Service #{n.SERVICEDESC} on #{n.HOSTNAME} is #{n.SERVICESTATE}\nInfo: #{n.SERVICEOUTPUT}"
    end

  end


  class WebApp < Sinatra::Base
    attr_accessor :sb

    post '/contact/:cname/notify' do
      #log "notification request with parameters: #{params.inspect}"
      sb.notification(params[:cname], params['policy'], OpenStruct.new(params))
      status 204
    end
    
    post '/contact/:jid/send' do
      sb.send(params[:jid], params[:message] || params['rack.input'].read)
      status 204
    end
    
  end

  class Switchboard
    attr_accessor :conf, :nagios, :xmpp, :http, :fmt, :status_msg, :uri
    attr_reader :http_worker
    # :smtp, :http
    
    def initialize(conf)
      @conf = conf
      @nagios = NagiosInstance.new(conf)
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
      @status_msg = fmt[:xmpp].status_message(nagios.status_report())
      if xmpp
        xmpp.presence()
      end
    end

    def status_report
      fmt[:xmpp].status_report(nagios.status_report())
    end

    def service_detail(service)
      fmt[:xmpp].service_detail(service)
    end

    def check(item)
      nagios.check(item)
    end

    def notification(contact_name, policy_spec, n)
      contacts = nagios.config.contents.contacts
      contact = contacts.fetch(contact_name)
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
      # log "Extracting XMPP field #{conf['xmpp_field'].inspect} from contact #{contact.name} with props #{contact.props.inspect}"
      jid = contact.props[conf['xmpp_field']]
      unless jid
        raise "Contact #{contact.name} does not have a JID in #{conf['xmpp_field']}: props #{contact.props.inspect}"
      end
      #log "XMPP contacts: #{xmpp.contacts.inspect}"
      x_contact = xmpp.contacts[jid]
      unless x_contact
        LOG.warn "no contact with jid #{jid}, not sending message"
        return false
      end
      if x_contact.available?
        n.seq = x_contact.record_notification(n)
        xmpp.send(jid, fmt[:xmpp].notification(n))
        return true
      else
        x_contact.missed << n
        return false
      end
    end

    def catch_up(x_contact)
      ## just came online
      # TODO
      # while you were away:
      # for each host/service with a problem notification:
      #   if it's not OK now, notify
      if not x_contact.missed.empty?
        m_hosts = Set.new
        m_svcs = Set.new
        nh = nagios.config.contents.hosts
        x_contact.missed.each do |n|
          case n.ntype
          when 'host'
            host = nh[n.HOSTNAME]
            if host.hard_state != :ok
              m_hosts << host
            end
          when 'service'
            svc = nh[n.HOSTNAME].services[n.SERVICEDESC]
            if svc.hard_state != :ok
              m_svcs << svc
            end
          else
            raise "unexpected ntype in #{n.inspect}!"
          end
        end
        if (not m_hosts.empty?) || (not m_svcs.empty?)
          msg = "While you were out:\n"
          if not m_hosts.empty?
            hmsg = m_hosts.classify { |h| h.hard_state }.sort.collect do |state, hosts|
              sprintf("%s: %s", state,
                      hosts.collect { |h| h.name }.join(", "))
            end.join("; ")
            msg << hmsg << "\n"
          end
          if not m_svcs.empty?
            smsg = m_svcs.classify { |s| s.hard_state }.sort.collect do |state, svcs|
              sprintf("%s: %s", state,
                      svcs.collect { |s| "#{s.host.name}/#{s.name}" }.join(", "))
            end.join("; ")
            msg << smsg << "\n"
          end
          send(x_contact.jid, msg)
        end
      end
    end
    
    def send(jid, msg)
      xmpp.send(jid, msg)
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
    LOG.info "started switchboard."
    while true
      sleep 30
      sb.update_status_msg
    end
  end
end
