require 'thread'
require 'metaid'
require 'rexml/document'
require 'set'
require 'ostruct'

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
      if line =~ /\s*([a-z0-9_]+)=(.*)/
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
      if line =~ /\s*([a-z0-9_]+)\s+(.*)/
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
      @mutex = Mutex.new
    end

    def refresh_if_needed()
      @mutex.synchronize do 
        if (not @contents) || (not @mtime) || (source.mtime > @mtime)
          mtime = source.mtime
          @contents = load(parse())
          @mtime = mtime
        end
      end
    end

    def contents()
      refresh_if_needed()
      return @contents
    end

  end

  module Monitored
    attr_reader :soft_state, :hard_state,
      :soft_since, :hard_since, :last_ok

    def update_state(state)
      @state = state
      @soft_state = state_sym(state['current_state'].to_i)
      @hard_state = state_sym(state['last_hard_state'].to_i)
      @soft_since = Nagios.ptime(state['last_state_change'])
      @hard_since = Nagios.ptime(state['last_hard_state_change'])
      @last_ok = Nagios.ptime(state['last_time_ok'])
    end

    def cur_state
      soft_state || hard_state
    end

    def info
      return @state['plugin_output']
    end
  end

  class ConfigItem
    attr_reader :type, :name, :props

    def self.tag_is(tag)
      meta_def :tag do; tag; end
    end

    def self.name_field
      "#{self.tag}_name"
    end

    def initialize(props)
      @props = props
      @name = props[self.class.name_field]
    end

  end

  class Group < ConfigItem
    attr_reader :members

    def self.group_of(klass)
      @@group_of = klass
      klass.group=(self)
    end

    def initialize(props)
      super(props)
      @members = Set.new
    end

  end

  class GroupMember < ConfigItem
    attr_reader :groups

    def self.group=(klass)
      @@group_class = klass
    end

    def initialize(props)
      super(props)
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

    def force_check(target, at)
      target.schedule_forced_host_check(self.name, at.to_i)
    end

    def state_sym(v)
      HOST_STATE_SYMS[v]
    end

    def <=>(other)
      name <=> other.name
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

    def initialize(defs, host)
      super(defs)
      @host = host
    end

    def self.name_field
      'service_description'
    end

    def force_check(target, at)
      target.schedule_forced_svc_check(self.host.name, self.name, at.to_i)
    end

    def state_sym(v)
      SVC_STATE_SYMS[v]
    end

    def <=>(other)
      name <=> other.name
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

  # removed Service
  OBJECT_TYPES = [Command, Contact, ContactGroup, Host, HostGroup,
                  ServiceGroup, ServiceEscalation, TimePeriod]
  OTYPE_BY_TAG = Hash[*OBJECT_TYPES.collect { |t| [t.tag, t] }.flatten()]
  
  class Config
    include Cached

    def initialize(source)
      self.source = source
      init_mutex()
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
        if tag != Service.tag
          item = OTYPE_BY_TAG[tag].new(data)
          by_tag[tag][item.name] = item
        else
          # special handling for Services since they are children of Hosts
          svcs << data
        end
      end
      svcs.each do |svc_def|
        host = by_tag[Host.tag][svc_def['host_name']]
        raise "No such host #{host}!" unless host
        svc = Service.new(svc_def, host)
        host.services[svc.name] = svc
      end
      # make plural aliases
      by_tag.keys.each { |k| by_tag["#{k}s"] = by_tag[k] }
      return OpenStruct.new(by_tag)
    end
  end

  #### revise below

  class ServiceInstance
    include Monitored 

    attr_reader :host, :desc

    def initialize(host, desc)
      @host = host
      @desc = desc
    end

    def state_sym(v)
      SVC_STATE_SYMS[v]
    end

    def host_name
      host.name
    end

    def name
      "#{host.name}/#{desc}"
    end

    def <=>(other)
      name <=> other.name
    end

    def to_s
      "Service #{name}: #{cur_state}"
    end

    def force_check(target, at)
      target.schedule_forced_svc_check(self.host.name, self.desc, at.to_i)
    end
  end
      
  class Status
    include Cached

    attr_accessor :config, :services, :hosts_by, :services_by

    def initialize(path, config)
      self.source = path
      self.config = config
      init_mutex()
#       hosts = config.contents.hosts
#       svcs = config.contents.services
#       parse().each do |otype, data|
#         if otype == 'servicestatus'
#           # TODO: check name vs desc
#           host = hosts[data['host_name']]
#           unless host
#             raise "missing host for #{data.inspect}"
#           end
#           svc_desc = data['service_description']
#           si = ServiceInstance.new(host, svc_desc)
#           host.services[svc_desc] = si
#         end
#       end
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
      hosts = config.contents.hosts
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
	  