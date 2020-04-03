require 'myprecious'

class <<MyPrecious
  attr_accessor :caching_disabled
  
  ##
  # Declare a path as a data cache
  #
  # This method returns the path it was given in +fpath+.
  #
  def data_cache(fpath)
    (@data_caches ||= []) << fpath
    return fpath
  end
  
  ##
  # Retrieve an Array of all known data caches
  #
  def data_caches
    (@data_caches || [])
  end
end
