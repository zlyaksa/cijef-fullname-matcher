fullname_matcher
================

Provide fullname, search in database with proper conditions

Usage
================

require 'fullname/matcher'

matcher = Fullname::Matcher.create(User, :first => 'firstname', :middle => 'middlename', :last => 'lastname', :suffix => 'suffix') do |m|
  m.set_condition "data_import_key = '2013.01.01'"
  m.match_fullname('Xiaohui, Zhang') # match fullname string in block
end

matcher.match_fullname('Zhang', nil, 'Xiaohui', nil) # match parsed fullname out of block
