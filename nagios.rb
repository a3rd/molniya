## nagios.rb: a Nagios library
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

require 'thread'
require 'metaid'
require 'monitor'
require 'rexml/document'
require 'set'
require 'ostruct'

require 'inspectable'

module Nagios

  HOST_STATE_SYMS = {
    0 => :ok,
    1 => :down,
    2 => :unreachable
  }

  SVC_STATE_SYMS = {
    0 => :ok,
    1 => :warning,
    2 => :critical,
    3 => :unknown
  }

  def Nagios.pstate(sstr)
    SVC_STATE_SYMS.fetch(sstr.to_i)
  end

  def Nagios.ptime(tstr)
    Time.at(tstr.to_i)
  end

  def Nagios.parse_status(f)
    objs = []
    while true
      line = f.gets
      if line != nil
	if line =~ /(\w+)\s*\{/
	  # object start
	  otype = $1
	  kv = parse_object(f)
	  objs << [otype, kv]
	end
      else
	# EOF
	break
      end
    end
    return objs
  end

  def Nagios.parse_object(f)
    data = {}
    while true
      line = f.readline
      if line =~ /\s*([a-zA-Z0-9_]+)=(.*)/
	data[$1] = $2
      elsif line =~ /\s*\}/
	break
      else
	raise "unexpected line: #{line}"
      end
    end
    return data
  end

  def Nagios.parse_defs(f)
    objs = []
    while true
      line = f.gets
      if line != nil
	if line =~ /\s*define\s+(\w+)\s*\{/
	  # def start
	  otype = $1
	  kv = parse_def(f)
	  objs << [otype, kv]
	end
      else
	# EOF
	break
      end
    end
    return objs
  end

  def Nagios.parse_def(f)
    data = {}
    while true
      line = f.readline
      if line =~ /\s*([a-zA-Z0-9_]+)\s+(.*)/
	data[$1] = $2
      elsif line =~ /\s*\}/
	break
      else
	raise "unexpected line: #{line}"
      end
    end
    return data
  end

  module Cached
    attr_accessor :source

    def init_mutex
      @mutex = Monitor.new
      @listeners = []
    end

    def refresh_if_needed()
      @mutex.synchronize do
        if source.exist?
          if (not @contents) || (not @mtime) || (source.mtime > @mtime)
            _refresh()
            return true
          else
            return false
          end
        end
      end
    end

    def wait_and_refresh(newer, timeout)
      @mutex.synchronize do
        now = Time.now
        timeout_t = now + timeout
        refreshed = false
        while (! refreshed) && now < timeout_t
          if source.mtime >= newer
            _refresh()
            refreshed = true
          else
            sleep 1
            now = Time.now
          end
        end
        unless refreshed
          raise "Timed out waiting to refresh #{source} with a newer version than #{newer}"
        end
      end
    end

    def _refresh()
      # $stderr.puts "Parsing #{source}: #{source.size} bytes, mtime #{source.mtime}"
      mtime = source.mtime
      self.contents = load(parse())
      @mtime = mtime
    end

    def contents()
      refresh_if_needed()
      unless @contents
        raise "Failed to load contents of #{self.class}!"
      end
      return @contents
    end

    def current_contents()
      @contents
    end

    def contents=(v)
      @contents = v
      ## call all listeners
      ## retain only those that return true
      @listeners = @listeners.select { |l| l.call(v) }
    end

    def register(&listener)
      @listeners << listener
    end

    def listeners?
      return ! @listeners.empty?
    end

  end

  module Monitored
    include Inspectable

    attr_reader :soft_state, :hard_state, :soft_since, :hard_since, :last_ok, :last_check
    inspect_my :hard_state

    def update_state(state)
      @state = state
      @soft_state = state_sym(state['current_state'].to_i)
      @hard_state = state_sym(state['last_hard_state'].to_i)
      @soft_since = Nagios.ptime(state['last_state_change'])
      @hard_since = Nagios.ptime(state['last_hard_state_change'])
      @last_ok = Nagios.ptime(state['last_time_ok'])
      @last_check = Nagios.ptime(state['last_check'])
    end

    def cur_state
      soft_state || hard_state
    end

    def info
      return @state['plugin_output']
    end

    def active_checks?
      props['active_checks_enabled'] == '0'
    end
  end

  class ConfigItem
    include Inspectable

    attr_reader :type, :name, :props, :cfg
    inspect_my :name

    def self.tag_is(tag)
      meta_def :tag do; tag; end
    end

    def self.name_field
      "#{self.tag}_name"
    end

    def initialize(props, cfg)
      @props = props
      @name = props[self.class.name_field]
      @cfg = cfg
    end

    def cmd_t
      cfg.nagios.cmd_t
    end

  end

  class Group < ConfigItem
    attr_reader :members

    def self.group_of(klass)
      @@group_of = klass
      klass.group=(self)
    end

    def initialize(*args)
      super(*args)
      @members = Set.new
    end

  end

  class GroupMember < ConfigItem
    attr_reader :groups

    def self.group=(klass)
      @@group_class = klass
    end

    def initialize(*args)
      super(*args)
      @groups = Set.new
    end
  end

  class Command < ConfigItem
    tag_is 'command'
  end

  class Contact < GroupMember
    tag_is 'contact'
  end

  class ContactGroup < Group
    tag_is 'contactgroup'
    group_of Contact
  end

  class Host < GroupMember
    include Monitored
    tag_is 'host'
    attr_reader :services

    def initialize(*args)
      super(*args)
      @services = {}
    end

    def acknowledge(opts_a)
      opts = { :sticky => 0, :notify => 1, :persistent => 1 }
      opts.merge! opts_a
      cmd_t.acknowledge_host_problem(self.name,
                                     opts[:sticky],
                                     opts[:notify],
                                     opts[:persistent],
                                     opts[:author],
                                     opts[:comment])
    end

    def force_check(at)
      cmd_t.schedule_forced_host_check(self.name, at.to_i)
    end

    def state_sym(v)
      HOST_STATE_SYMS[v]
    end

    def link(fmt)
      fmt.host_link(self)
    end

    def <=>(other)
      name <=> other.name
    end

    def detail(fmt)
      cfg.nagios.sb.fmt[fmt].host_detail(self)
    end

    def to_s
      "Host #{name}: #{cur_state}"
    end
  end

  class HostGroup < Group
    tag_is 'hostgroup'
    group_of Host
  end

  # TODO: not uniquely identified by description
  class Service < GroupMember
    include Monitored
    tag_is 'service'
    attr_reader :host

    def initialize(defs, cfg, host)
      super(defs, cfg)
      @host = host
    end

    def self.name_field
      'service_description'
    end

    def host_name
      host.name
    end

    def acknowledge(opts_a)
      opts = { :sticky => 0, :notify => 1, :persistent => 1 }
      opts.merge! opts_a
      cmd_t.acknowledge_svc_problem(self.host.name,
                                    self.name,
                                    opts[:sticky],
                                    opts[:notify],
                                    opts[:persistent],
                                    opts[:author],
                                    opts[:comment])
    end

    def force_check(at)
      cmd_t.schedule_forced_svc_check(self.host.name,
                                      self.name,
                                      at.to_i)
    end

    def state_sym(v)
      SVC_STATE_SYMS[v]
    end

    def link(fmt)
      fmt.host_svc_link(self)
    end

    def <=>(other)
      hcmp = host.name <=> other.host.name
      if hcmp != 0
        return hcmp
      else
        return name <=> other.name
      end
    end

    def detail(fmt)
      cfg.nagios.sb.fmt[fmt].service_detail(self)
    end

    def to_s
      "Service #{name}: #{cur_state}"
    end

  end

  class ServiceGroup < Group
    tag_is 'servicegroup'
    group_of Service
  end

  class ServiceEscalation < ConfigItem
    tag_is 'serviceescalation'
  end

  class TimePeriod < ConfigItem
    tag_is 'timeperiod'
  end

  OBJECT_TYPES = [Command, Contact, ContactGroup, Host, HostGroup,
                  ServiceGroup, ServiceEscalation, TimePeriod]
  OTYPE_BY_TAG = Hash[*OBJECT_TYPES.collect { |t| [t.tag, t] }.flatten()]
  
  class Config
    include Cached
    include Inspectable

    attr_reader :nagios
    inspect_my :source

    def initialize(source, nagios)
      self.source = source
      @nagios = nagios
      init_mutex()
    end

    def sb
      nagios.sb
    end

    def refresh_if_needed()
      refreshed = super()
      if refreshed
        nagios.status.wait_and_refresh(@mtime, 60)
      else
        nagios.status.refresh_if_needed()
      end
    end

    def parse()
      source.open() { |f| Nagios.parse_defs(f) }
    end

    def load(defs)
      ## TODO: reinit Status also
      kspec = OBJECT_TYPES.collect { |t| [t.tag, t] }.flatten()
      by_tag = Hash.new { |h, k| h[k] = {} }
      svcs = []
      defs.each do |tag, data|
        otype = OTYPE_BY_TAG[tag]
        if otype
          item = otype.new(data, self)
          by_tag[tag][item.name] = item
        elsif tag == Service.tag
          # special handling for Services since they are children of Hosts
          svcs << data
        else
          ## fall through for unrecognized object types
          ## e.g. hostescalation, hostextinfo, etc
        end
      end
      svcs.each do |svc_def|
        host = by_tag[Host.tag][svc_def['host_name']]
        raise "No such host #{host}!" unless host
        svc = Service.new(svc_def, self, host)
        host.services[svc.name] = svc
      end
      # make plural aliases
      by_tag.keys.each { |k| by_tag["#{k}s"] = by_tag[k] }
      return OpenStruct.new(by_tag)
    end
  end

  class Status
    include Cached
    include Inspectable

    attr_accessor :config, :services, :hosts_by, :services_by, :nagios
    attr_reader :source
    inspect_my :source

    def initialize(path, nagios)
      self.nagios = nagios
      self.source = path
      self.config = nagios.config
      init_mutex()
    end

    def parse()
      source.open() { |f| Nagios.parse_status(f) }
    end

    def load(objs)
      rec = OpenStruct.new
      rec.hosts_by = {
	:ok => [],
        :down => [],
        :unreachable => []
      }
      rec.services_by = {
	:ok => [],
	:warning => [],
	:critical => [],
	:unknown => []
      }
      hosts = config.current_contents.hosts
      objs.each do |otype, data|
	case otype
	when "hoststatus"
          host = hosts[data['host_name']]
          host.update_state(data)
          unless host.cur_state
            $stderr.puts "host #{host.name} in #{host.cur_state}; soft #{host.soft_state}, hard #{host.hard_state}"
          end
	  rec.hosts_by[host.cur_state] << host
	when "servicestatus"
          host = hosts[data['host_name']]
          unless host
            raise "No host def: #{data['host_name']}"
          end
          s = host.services[data['service_description']]
          unless s
            raise "No service #{data['service_description']} for host #{host.name}; services #{host.services.keys.sort.inspect}"
          end
          s.update_state(data)
	  rec.services_by[s.cur_state] << s
	end
      end
      rec.hosts_by.values.each { |a| a.sort! }
      rec.services_by.values.each { |a| a.sort! }
      return rec
    end
  end

  class CommandTarget
    include Inspectable

    def initialize(cmd_f)
      @f = cmd_f
    end

    def method_missing(cmd, *args)
      t = Time.now
      cmd_s = sprintf("[%d] %s;%s\n",
                      Time.now.to_i,
                      cmd.to_s.upcase,
                      args.collect { |a| a.to_s }.join(';'))
      $stderr.puts "sending command to Nagios: #{cmd_s}"
      @f.open('r+') do |f|
        f.write(cmd_s)
      end
    end
  end
end
	  
