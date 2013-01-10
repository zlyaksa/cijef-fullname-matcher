require 'fullname/matcher/core'
require 'fullname/matcher/version'

module Fullname
  module Matcher
    
    def self.create(table, mapping = {}, options = {}, &blk)
      core = Core.new(table, mapping, options)
      blk.call(core) if block_given?
      core
    end
  
  end
end

