## formatting.rb: message formatting
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

module Molniya
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
      "#{s.name} for #{Molniya::brief_time_delta(s.soft_since)}"
    end

    def service_detail(svc)
      "#{svc.name}: #{svc.soft_state.to_s.upcase} for #{Molniya::brief_time_delta(svc.soft_since)}\nInfo: #{svc.info}"
      # TODO...
    end

    def host_detail(h)
      "#{h.name}: #{h.soft_state.to_s.upcase} for #{Molniya::brief_time_delta(h.soft_since)}"
    end

    def status_message(s)
      counts = Hash.new { |h, k| h[k] = 0 }
      s.values.each { |v| v.each { |state, items| counts[state] += items.size } }
      if counts.empty?
        "All clear"
      else
        counts.collect { |state, count| "#{count} #{state}" }.join(", ")
      end
    end

    def item_status_entry(i)
      case
      when i.is_a?(Nagios::Host)
        "#{i.name} for #{Molniya::brief_time_delta(i.soft_since)}"
      when i.is_a?(Nagios::Service)
        "#{i.host.name}/#{i.name} for #{Molniya::brief_time_delta(i.soft_since)}"
      else
        raise "Unexpected item #{i.inspect}!"
      end
    end

    def status_report(s)
      if (not s[:services].empty?) or (not s[:hosts].empty?)
        (s[:hosts] + s[:services]).collect do |state, items_r|
          items = items_r.to_a.sort
          sprintf("%s: %s",
                  state.to_s.upcase,
                  items.collect { |i| item_status_entry(i) }.join("; "))
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

    def host_link(host)
      a = REXML::Element.new 'a'
      a.attributes['href'] = nagios.status_uri(host.name)
      a.text = host.name
      return a
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

    def host_detail(h)
      div = REXML::Element.new('div')
      div.elements << host_link(h)
      div.add_text ": #{h.soft_state.to_s.upcase} "
      div.add_text "for #{Molniya::brief_time_delta(h.soft_since)}\nInfo: #{h.info}"
      return div
    end

    def service_notify(n)
      # "#{n.NOTIFICATIONTYPE}: Service #{n.SERVICEDESC} on #{n.HOSTNAME} is #{n.SERVICESTATE}\nInfo: #{n.SERVICEOUTPUT}"
      svc = n.referent
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
      div.add_text "for #{Molniya::brief_time_delta(svc.soft_since)}\nInfo: #{svc.info}"
      return div
    end

    def service_state(s)
      span = REXML::Element.new('span')
      span << host_svc_link(s)
      span.add_text " for "
      span.add_text Molniya::brief_time_delta(s.soft_since)
      return span
    end

    def service_state(s)
      span = REXML::Element.new('span')
      span << host_svc_link(s)
      span.add_text " for "
      span.add_text Molniya::brief_time_delta(s.soft_since)
      return span
    end

    def status_report(s)
      if (not s[:services].empty?) or (not s[:hosts].empty?)
        ## headings and sorting could stand some improvement
        div = REXML::Element.new 'div'
        (s[:hosts] + s[:services]).each do |state, items_r|
          items = items_r.to_a.sort
          sd = div.add_element('div')
          sd.add_text "#{state.to_s.upcase}: "
          items.each do |i|
            sd << i.link(self)
            sd.add_text(" for ")
            sd.add_text(Molniya::brief_time_delta(i.soft_since))
            if i != items.last
              sd.add_text("; ")
            end
          end
          sd.add_element('br')
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

end
