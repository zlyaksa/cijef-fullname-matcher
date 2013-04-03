# this class gets people, based on name match, from a table that stores firstname/middlename/lastaname/suffix separately.
#
# try a series of searches (exact match first, then different variations) until success
# a lof of logics/examples (eg. middlename handling, suffix handling, when to use abbreviation, when to use 'regexp') are commented inline
#
# public methods:
# . new(table, mapping={}, options = {})
#   when constructing a name match using xxx = Fullname::Matcher.new(...), the first arg is the table where the search is executed in;
#   default column mapping is {:first => 'first', :middle => 'middle', :last => 'last', :suffix => 'suffix'};
#   - if the actual mapping is different, it should be provided as the second arg of new()
#   - options:
#     :skip_match_middle_name     default is false
# . set_condition(c)
#   if there's other condition (like "data_import_key = 'yyyy.mm.dd'") in search criteria, set it this way
#   
# . get_matches
#   if the name is one string, use get_matches(orig_name)
#   if the name is in pieces,  use get_matches(firstname, middlename, lastname, suffix)
#   return ALL matches of the first successful search or [] if all searches fail
# . match_fullname
#   alias of get_matches
# . names_match?(n1, style1, n2, style2)
#   return true if two names (n1 and n2) are same; false otherwise
#
require 'fullname/parser'
require 'fullname/equivalence'

module Fullname::Matcher
  class Core

    DEFAULT_MAPPING = {:first => 'first', :middle => 'middle', :last => 'last', :suffix => 'suffix'}
    DEFAULT_OPTIONS = {
      :skip_match_middle_name => false, # skip match middle name if middle name not provided.
      :skip_match_suffix => false      # skip match suffix if suffix not provided or no column suffix in database.
    }

    class Error < StandardError ; end
    
    attr_accessor :options

    def initialize(table, mapping = {}, options = {})
      @table        = table
      @mapping      = DEFAULT_MAPPING.merge(mapping)
      @condition    = nil
      @options      = DEFAULT_OPTIONS.merge(options)
    end
    
    def set_condition(c)
      @condition = c
    end
    
    def get_matches(*args)
      name = nil
      match_options = {}
      case args.size
      when 1
        name = ::Fullname::Parser.parse_fullname(args[0])
      when 4,5
        name = {:first => args[0], :middle => args[1], :last => args[2], :suffix => args[3]}
        match_options = args.pop if args.size == 5
      else
        raise Error, 'illeagle arguments length of get_matches, must be the length of 1,4,5'
      end
      recursive = match_options.include?(:recursive) ? match_options[:recursive] : true
      return [] if name[:first].nil? || name[:last].nil?
      match_list = match_first_last_and_suffix(name)
      
      # skip validating middlename if @options[:skip_match_middle_name] == true
      # all matched result which middle name is NULL or NON-NULL will be returned
      return match_list if @options[:skip_match_middle_name] && match_list.size > 0
      
      if match_list.size > 0
        # 1. exactly match
        exact_match_list = match_list.select do |r|
          compare_without_dot(r.send(@mapping[:middle]), name[:middle]) && compare_without_dot(r.send(@mapping[:suffix]), name[:suffix])
        end
        return exact_match_list if exact_match_list.size > 0
        
        # 2. if name[:middle] is not NULL, regexp match
        if name[:middle]
          m_re = build_middlename_regexp(name[:middle])
          match_list_with_middlename = match_list.select do |r|
            r_middle_name = r.send(@mapping[:middle])
            r_middle_name && r_middle_name =~ m_re
          end
          return match_list_with_middlename if match_list_with_middlename.size > 0
          # 2.1 fuzzy match: if middlename in DB is NULL, it matches
          match_list_with_middlename = match_list.select{ |r| r.send(@mapping[:middle]).nil? }
          return match_list_with_middlename if match_list_with_middlename.size > 0
          # clear match list if don't match middlename
          match_list = []
        else
          # 2.2 fuzzy match: assume all matches since name[:middle] is NULL
          return match_list
        end        
      end
      
      # if nothing matches, try to search with equivalence of first name
      if match_list.size == 0 && recursive
        firstname_array = ::Fullname::Equivalence.get_name_equivalence(name[:first])
        firstname_array.each do |n|
          match_list += get_matches(n, name[:middle], name[:last], name[:suffix], {:recursive => false})
        end if firstname_array
      end
      
      return match_list
    end
  
    alias_method :match_fullname, :get_matches
    
    # return true if two names (n1 and n2) are same; false otherwise
    # style = :short means the pieces are first/middle/last/suffix; firstname/middlename/lastname/suffix otherwise
    def names_match?(n1, style1, n2, style2)
      f1 = style1 == :short ? n1.first : n1.firstname
      m1 = style1 == :short ? n1.middle : n1.middlename
      l1 = style1 == :short ? n1.last : n1.lastname
      
      f2 = style2 == :short ? n2.first : n2.firstname
      m2 = style2 == :short ? n2.middle : n2.middlename
      l2 = style2 == :short ? n2.last : n2.lastname
      
      # first/last name have to be provided
      return false if l1.nil? || l2.nil? || f1.nil? || f2.nil?
      return false if l1.downcase.strip != l2.downcase.strip
      
      unless @options[:skip_match_suffix]
        s1 = n1.suffix
        s2 = n2.suffix
        return false  if s1 && s2 && compare_without_dot(s1, s2) == false
      end
      
      return false if !abbr_match?(f1, f2)
      m1.nil? or m2.nil? or abbr_match?(m1, m2)
    end
    
    # 2 strings are 'abbr-match'ed if
    # . they are same, or
    # . one string is one char long and the other starts with it
    # ex: 'abc edf' abbr-matches 'a. e' or 'abc   edf', but not 'abc e'
    def abbr_match?(str1, str2)
      build_middlename_regexp(str1) =~ str2
    end
    
    private
  
    def match_first_last_and_suffix(name)
      conditions  = []
      queries     = []
      conditions << '(' + @condition + ')' if @condition
      queries    << '(placeholder)'
      conditions << "(#{@mapping[:first]} = ? OR #{@mapping[:first]} REGEXP ?)"
      queries    << name[:first]
      queries    << '^' + name[:first][0].chr + '([.]?' + (name[:first] =~ /^[a-z]\.?$/i ? '|[a-z]+' : '') + ')$'
      conditions << "#{@mapping[:last]} = ?"
      queries    << name[:last]
      queries[0] = conditions.join(' AND ')
      matched_list = @table.all(:conditions => queries)
      unless @options[:skip_match_suffix]
        
        # exactly match suffix
        matched_list_with_suffix = matched_list.select{|r| compare_without_dot(r.send(@mapping[:suffix]), name[:suffix]) }
        return matched_list_with_suffix if matched_list_with_suffix.size > 0
        
        # fuzzy match suffix( NULL matches NON-NULL )
        return matched_list.select{|r| r.send(@mapping[:suffix]).to_s.strip.empty? || name[:suffix].nil? }
        
      end
      return matched_list
    end

    def compare_without_dot(str1, str2)
      [str1, str2].map{|s| s.to_s.gsub('.', '').downcase.strip}.uniq.size == 1
    end
  
    def build_middlename_regexp(middlename)
      middle_arr  = middlename.split(/[. ]+/)
      tmp_reg     = []
      # Z M                   |Z M
      # Z. M.                 |ZM
      # Z.M.                  |Zoellner M
      # Z Miller              |Z Miller
      # Zoellner M            |Zoellner Miller
      # Zoellner Miller       |
      # K.Taylor
      if middle_arr.size > 1
        last_ele = middle_arr.pop
        tmp_reg << middle_arr.map{|m| Regexp.escape(m[0].chr) + '[. ]+'}.join + Regexp.escape(last_ele) + '[.]?'
        middle_arr.push(last_ele)
      end
      tmp_reg    << middle_arr.map{|m| m.size == 1 ? (Regexp.escape(m) + '\S*') : (Regexp.escape(m[0].chr) + '(' + Regexp.escape(m[1..-1]) + '|[.])?')}.join('[. ]+')
      Regexp.new("^(#{tmp_reg.join('|')})$", true)
    end
  
  end
end
