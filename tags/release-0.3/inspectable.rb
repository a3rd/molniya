require 'metaid'

module Inspectable

  ## TODO: this is all kind of broken
  ## specifically doesn't work with inheritance
  ## bone up on and fix properly

  module ClassMethods; end
  def self.included(klass)
    klass.extend(ClassMethods)
  end

  def inspect
    i = sprintf("#<%s", self.class.name)
    if self.class.respond_to? :inspect_methods
      i << " "
      self.class.inspect_methods.each do |ifield|
        i << sprintf("%s=\"%s\"", ifield, self.send(ifield))
      end
    else
      i << sprintf(":0x%x", self.object_id)
    end
    i << ">"
    return i
  end

  module ClassMethods
    def inspect_my(*fields)
      unless respond_to? :inspect_methods
        a = []
        meta_def(:inspect_methods) { a }
      end
      inspect_methods().concat(fields)
    end
  end
end
