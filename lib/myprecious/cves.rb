require 'date'
require 'digest'
require 'json'
require 'myprecious/data_caches'
require 'open3'
require 'pathname'
require 'rest-client'
require 'set'

module MyPrecious
  module CVEs
    extend DataCaching
    
    MIN_GAP_SECONDS = 5
    CONFIG_FILE = '.myprecious-cves.rb'
    
    CVE_DATA_CACHE_DIR = MyPrecious.data_cache(DATA_DIR / "cve-data")
    
    class <<self
      attr_reader :config_dir
      
      def config_dir=(val)
        @config_dir = Pathname(val)
      end
    end
    
    def self.last_query_time
      @last_query_time ||= DateTime.now - 1
    end
    
    def self.queried!
      @last_query_time = DateTime.now
    end
    
    ##
    # If you don't specify version, you get to match against the applicable
    # configurations on your own to determine which CVEs returned apply to
    # the versions of the named package in which you are interested
    #
    def self.get_for(package_name, version='*')
      nvd_url = URI("https://services.nvd.nist.gov/rest/json/cves/1.0")
      nvd_url.query = URI.encode_www_form(
        cpeMatchString: "cpe:2.3:a:*:#{package_name.downcase}:#{version}:*:*:*:*:*:*:*",
      )
      
      cache = CVE_DATA_CACHE_DIR / "#{Digest::SHA256.hexdigest(nvd_url.to_s)}.json"
      cve_data = apply_cache(cache) do
        # Use last_query_time to sleep if necessary
        wait_time = MIN_GAP_SECONDS - (DateTime.now - last_query_time) * 24 * 3600
        if wait_time > 0
          sleep(wait_time)
        end
        
        response = RestClient.get(nvd_url.to_s)
        queried!
        
        JSON.parse(response.body)
      end
      
      begin
        return cve_data['result']['CVE_Items'].map do |e|
          applicability = objectify_configurations(package_name, e['configurations'])
          score = (((e['impact'] || {})['baseMetricV3'] || {})['cvssV3'] || {})['baseScore']
          cve = CVERecord.new(
            e['cve']['CVE_data_meta']['ID'],
            applicability.respond_to?(:vendors) ? applicability.vendors : nil,
            score
          )
          
          [cve, applicability]
        end.reject {|cve, a| a.respond_to?(:applies_to?) && !a.applies_to?(version)}
      rescue StandardError => e
        $stderr.puts "[WARN] #{e}\n\n#{JSON.dump(cve_data)}\n\n"
        []
      end
    end
    
    def self.config
      if !@config && config_dir
        if (config_path = config_dir / CONFIG_FILE).exist?
          @config = begin
            config_prog_output, status = Open3.capture2(RbConfig.ruby, config_path.to_s)
            if status.success?
              JSON.parse(config_prog_output)
            else
              $stderr.puts "#{config_path} did not exit cleanly (code ${status.exitstatus})"
              {}
            end
          rescue StandardError
          end
          
          unless @config.kind_of?(Hash)
            $stderr.puts "#{config_path} did not output a JSON configuration"
            @config = {}
          end
        else
          @config = {}
        end
      end
      @config ||= {}
    end
    
    def self.objectify_configurations(package_name, configs)
      if configs.kind_of?(Hash) && configs['CVE_data_version'] == "4.0"
        Applicability_V4_0.new(package_name, configs)
      else
        configs
      end
    end
    
    class CVERecord < String
      def initialize(id, vendors, score)
        super(id)
        
        @vendors = vendors
        @score = score
      end
      
      attr_accessor :vendors, :score
    end
    
    class Applicability_V4_0 < Hash
      def initialize(package, configs)
        super()
        self.update(configs)
        @package = package.downcase
      end
      attr_reader :package
      
      def nodes
        self['nodes']
      end
      
      def applies_to?(version)
        package_nodes(nodes).any? do |node|
          version_matches_node?(version, node)
        end
      end
      
      def vendors
        Set.new(each_vulnerable_cpe.map do |cpe|
          cpe.split(':')[3]
        end)
      end
      
      def package_nodes(node_list)
        node_list.select do |node|
          node['children'] || node['cpe_match'].any? do |pattern|
            pattern['cpe23Uri'] =~ package_cpe_regexp
          end
        end
      end
      
      def each_vulnerable_cpe
        return enum_for(:each_vulnerable_cpe) unless block_given?
        
        remaining = nodes.to_a.dup
        while (node = remaining.shift)
          if node['children']
            remaining.insert(0, *node['children'])
          else
            node['cpe_match'].each do |pattern|
              next unless pattern['vulnerable']
              cpe = pattern['cpe23Uri']
              if package_cpe_regexp =~ cpe
                yield cpe
              end
            end
          end
        end
      end
      
      def package_cpe_regexp
        /^cpe:2.3:a:[^:]*:#{package}(:|$)/
      end
      
      def version_matches_node?(version, node)
        test = (node['operator'] == 'AND') ? :all? : :any?
        if node['children']
          return node['children'].send(test) {|child| version_matches_node?(version, child)}
        end
        
        return node['cpe_match'].any? do |pattern|
          cpe_entry_indicates_vulnerable_version?(version, pattern)
        end
      end
      
      def cpe_entry_indicates_vulnerable_version?(version, pattern)
        return false unless pattern['vulnerable']
        
        cpe_vendor, cpe_product, cpe_version, cpe_update = pattern['cpe23Uri'].split(':')[3,4]
        return false if (CVEs.config['blockedProducts'] ||= []).include?([cpe_vendor, cpe_product].join(':'))
        return false if cpe_product != @package
        if version == '*'
          return true
        end
        return false unless [nil, '*', '-'].include?(cpe_update) # We'll ignore prerelease versions
        if cpe_version != '*' && cpe_version == version
          return true
        end
        
        if (range_start = pattern['versionStartIncluding'])
          range_test = :<=
        elsif (range_start = pattern['versionStartExcluding'])
          range_test = :<
        else
          range_test = nil
        end
        if range_test && !version_compare(range_start, version).send(range_test, 0)
          return false
        end
        
        if (range_end = pattern['versionEndIncluding'])
          range_test = :<=
        elsif (range_end = pattern['versionEndExcluding'])
          range_test = :<
        else
          range_test = nil
        end
        if range_test && !version_compare(version, range_end).send(range_test, 0)
          return false
        end
        
        return range_start || range_end
      end
      
      ##
      # Return a <=> b for version strings a and b
      #
      def version_compare(a, b)
        make_comparable(a) <=> make_comparable(b)
      end
      
      def make_comparable(ver_str)
        ver_str.split('.').map {|p| p.to_i}
      end
    end
  end
end
