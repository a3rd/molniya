require 'metaid'

module Inspectable
  module ClassMethods; end
  def self.included(klass)
    klass.extend(ClassMethods)
  end

  def inspect
    i = sprintf("#<%s:0x%x", self.class.name, self.object_id)
    if self.class.respond_to? :inspect_methods
      i << " "
      self.class.inspect_methods.each do |ifield|
        i << sprintf("%s=\"%s\"", ifield, self.send(ifield))
      end
    end
    i << ">"
    return i
  end

  module ClassMethods
    def inspect_my(*fields)
      unless respond_to? :inspect_methods
        meta_def(:inspect_methods) { [] }
      end
      inspect_methods().concat(fields)
    end
  end
end
