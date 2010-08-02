## commands.rb: Molniya commands
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

require 'metaid'

module Molniya
  module Commands
    class Base
      attr_accessor :cmd_text, :msg, :contact, :scanner, :sb, :client, :parent

      def self.cmd(word)
        meta_def(:cmd) { word }
      end

      def invoke_child(klass, c_cmd_text)
        c = klass.new
        c.cmd_text = c_cmd_text
        c.msg = msg
        c.contact = contact
        c.scanner = scanner
        c.sb = sb
        c.client = client
        c.parent = self
        c.invoke
      end

      def parse_host_or_svc()
        case
        when scanner.scan(/([^\s\/]+)\//)
          # host/svc
          host = sb.find_host(scanner[1]) or raise "Unknown host #{scanner[1]}"
          svc = sb.resolve_service_name(host, scanner)
          return svc
        when scanner.scan(/([^\s\/]+)/)
          # host
          host = sb.find_host(scanner[1]) or raise "Unknown host #{scanner[1]}"
          return host
        else
          raise "Parse error at: #{scanner.rest.inspect}"
        end
        
      end
    end

    class Status < Base
      cmd 'status'

      def invoke
        report = sb.nagios.status_report()
        client.send_msg(msg.from,
                        sb.fmt[:xmpp].status_report(report))
      end
    end

    class HostDetail < Base
      def invoke(host)
        client.send_msg(msg.from, host.detail(:xmpp))
      end
    end

    class ServiceDetail < Base
      def invoke(svc)
        client.send_msg(msg.from, svc.detail(:xmpp))
      end
    end

    class Check < Base
      cmd 'check'
      def invoke
        scanner.skip(/\s*/) or raise 'syntax'
        sb.check(parse_host_or_svc(), contact)
      end
    end

    class Ack < Base
      cmd 'ack'

      def invoke
        scanner.skip(/\s*/) or raise 'syntax'
        entity = parse_host_or_svc()
        scanner.skip(/\s*/)
        if scanner.check(/\S/)
          comment = scanner.rest
        else
          comment = "acknowledged."
        end
        n_contact = sb.find_nagios_contact_with_jid(contact.jid)
        raise "No Nagios contact with JID #{contact.jid}?" unless n_contact
        entity.acknowledge(:author => n_contact.name,
                           :comment => comment)
      end
    end

    class ReplyAck < Base
      cmd 'ack'

      def invoke
        n_contact = sb.find_nagios_contact_with_jid(contact.jid)
        raise "No Nagios contact with JID #{contact.jid}?" unless n_contact
        scanner.skip(/\s*/)
        if scanner.scan_until(/\S.+/)
          comment = scanner.matched
        else
          comment = "acknowledged."
        end
        parent.n.referent.acknowledge(:author => n_contact.name,
                                      :comment => comment)
      end
    end

    class ReplyCheck < Base
      cmd 'check'

      def invoke
        sb.check(parent.n.referent, contact)
      end
    end

    class Reply < Base
      attr_accessor :n
      cmd /^@(\d)/

      SUB = [ReplyAck, ReplyCheck]

      def invoke
        unless cmd_text =~ self.class.cmd
          raise "inconsistent dispatch!"
        end
        self.n = contact.recent[$1.to_i]
        if n
          scanner.skip(/\s*/)
          scmd_w = scanner.scan(/\w+/) or raise "Missing subcommand!"
          scmd_def = SUB.find { |sd| sd.cmd === scmd_w }
          if scmd_def
            invoke_child(scmd_def, scmd_w)
          else
            client.send_msg(msg.from, "Unknown reply command #{scmd_w}!")
          end
        else
          client.send_msg(msg.from, "No record of notification #{$1}, sorry.")
          LOG.debug "Recent: #{contact.recent.inspect}"
        end        
      end
    end

    class Admin < Base
      cmd "admin"

      def invoke
        scanner.skip(/\s*/) or raise 'syntax'
        admin_cmd = scanner.scan(/\S+/)
        scanner.skip(/\s*/)
        case admin_cmd
        when 'list-roster'
          client.send_msg(msg.from,
                          "Roster: " + client.roster.items.keys.sort.join(", "))
        when 'add'
          if scanner.scan(/(\S+)\s+(\S+)/)
            jid = scanner[1]
            iname = scanner[2]
            client.roster.add(Jabber::JID.new(jid), iname, true)
            client.send_msg(msg.from, "Added #{jid} (#{iname}) to roster and requested presence subscription.")
          else
            client.send_msg(msg.from, "Usage: admin add <jid> <alias>")
          end
        when 'remove'
          jid = scanner.scan(/\S+/)
          if jid
            client.roster[jid].remove()
            client.send_msg(msg.from, "Contact #{jid} successfully removed from roster.")
          else
            client.send_msg(msg.from, "Usage: admin remove <jid>")
          end
        else
          client.send_msg(msg.from, "Unknown admin command #{admin_cmd}")
        end
      end
    end

    class Eval < Base
      cmd "eval"

      def invoke
        ## TODO: conditionalize for debugging
        scanner.skip(/\s*/)
        expr = scanner.rest()
        LOG.debug "evaluating expression: #{expr.inspect}"
        
        begin
          result = eval(expr).to_s
        rescue Exception => e
          $stderr.puts "ERROR: #{e}"
          result = "ERROR: #{e}"
        end
        LOG.debug "got: #{result.inspect}"
        client.send_msg(msg.from, result)
      end
    end

    class Help < Base
      cmd "help"

      def invoke
        client.send_msg(msg.from, <<EOF)
Nagios switchboard commands:
status: get a status report
<host | host/svc>: get details on the named host or srevice
check <host | host/svc>: force a check of the named host or service
ack <host | host/svc> [message]: acknowledge a host or service problem, with optional message
You can respond to a notification with its @ number, like so:
@N ack [message]: acknowledge a host or service problem, with optional message
@N check: force a check of the host or service referred to
EOF
      end
    end

  end
end
