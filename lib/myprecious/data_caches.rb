require 'myprecious'
require 'pathname'

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

module MyPrecious
  module DataCaching
    ##
    # Use cached data in or write data to a file cache
    #
    # +cache+ should be a Pathname to a file in which JSON data or can
    # be cached.
    #
    # The block given will only be invoked if the cache does not exist or
    # is stale.  The block must return JSON.dump -able data.
    #
    def apply_cache(cache, &get_data)
      cache = Pathname(cache)
      if !MyPrecious.caching_disabled && cache.exist? && cache.stat.mtime > Time.now - ONE_DAY
        return cache.open('r') {|inf| JSON.load(inf)}
      else
        # Short-circuit to error if we've already received one for filling this cache
        if @data_cache_errors_fetching && @data_cache_errors_fetching[cache]
          raise @data_cache_errors_fetching[cache]
        end
        
        result = begin
          DataCaching.print_error_info(cache.basename('.json'), &get_data)
        rescue StandardError => e
          # Remember this error in case there is another attempt to fill this cache
          (@data_cache_errors_fetching ||= {})[cache] = e
          raise
        end
        
        cache.dirname.mkpath
        cache.open('w') {|outf| JSON.dump(result, outf)}
        return result
      end
    end
    private :apply_cache
    
    
    def self.print_error_info(target)
      yield
    rescue Interrupt
      raise
    rescue StandardError => e
      $stderr.puts "Error fetching data for #{target}: #{e.message}"
      raise
    end
  end
end
