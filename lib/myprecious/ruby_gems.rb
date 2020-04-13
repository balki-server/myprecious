require 'gems'
require 'myprecious/data_caches'
require 'pathname'

module MyPrecious
  class RubyGemInfo
    include DataCaching
    
    MIN_RELEASED_DAYS = 90
    MIN_STABLE_DAYS = 14
    
    INFO_CACHE_DIR = MyPrecious.data_cache(DATA_DIR / 'rb-info-cache')
    VERSIONS_CACHE_DIR = MyPrecious.data_cache(DATA_DIR / 'rb-versions-cache')
    
    SOURCE_CODE_URI_ENTRIES = %w[github_repo source_code_uri]
    
    ##
    # Enumerate Ruby gems used in a project
    #
    # The project at +fpath+ must have a "Gemfile.lock" file as used by the
    # +bundler+ gem.
    #
    # The block receives an Array with three values:
    # - Either +:current+ or +:reqs+, indicating the meaning of the element at
    #   index 2,
    # - The name of the gem, and
    # - Either a Gem::Version (if the index-0 element is :current) or a
    #   Gem::Requirement (if the index-0 element is :reqs)
    #
    # Iterations yielding +:current+ given the version of the gem currently
    # specified by the Gemfile.lock in the project.  Iterations yielding
    # +:reqs+ give requirements on the specified gem dictated by other gems
    # used by the project.  Each gem name will appear in only one +:current+
    # iteration, but may occur in multiple +:reqs+ iterations.
    # 
    def self.each_gem_used(fpath)
      return enum_for(:each_gem_used, fpath) unless block_given?
      
      gemlock = Pathname(fpath).join('Gemfile.lock')
      raise "No Gemfile.lock in #{fpath}" unless gemlock.exist?
      
      section = nil
      gemlock.each_line do |l|
        break if l.upcase == l && section == 'GEM'
        
        case l
        when /^[A-Z]*\s*$/
          section = l.strip
        when /^\s*(?<gem>\S+)\s+\(\s*(?<gemver>\d[^)]*)\)/
          yield [:current, $~[:gem], Gem::Version.new($~[:gemver])] if section == 'GEM'
        when /^\s*(?<gem>\S+)\s+\(\s*(?<verreqs>[^)]*)\)/
          yield [:reqs, $~[:gem], Gem::Requirement.new(*$~[:verreqs].split(/,\s*/))] if section == 'GEM'
        end
      end
    end
    
    ##
    # Build a Hash mapping names of gems used by a project to RubyGemInfo about them
    #
    # The project at +fpath+ must have a "Gemfile.lock" file as used by the
    # +bundler+ gem.
    #
    # The accumulated RubyGemInfo instances should have non-+nil+
    # #current_version values and meaningful information in #version_reqs,
    # as indicated in the Gemfile.lock for +fpath+.
    #
    def self.accum_gem_lock_info(fpath)
      {}.tap do |gems|
        each_gem_used(fpath) do |entry_type, name, verreq|
          g = (gems[name] ||= RubyGemInfo.new(name))
          
          case entry_type
          when :current
            g.current_version = verreq
          when :reqs
            g.version_reqs.concat verreq.as_list
          end
        end
      end
    end
    
    ##
    # Get an appropriate, human friendly column title for an attribute
    #
    def self.col_title(attr)
      case attr
      when :name then 'Gem'
      else Reporting.common_col_title(attr)
      end
    end
    
    def initialize(name)
      super()
      @name = name
      @version_reqs = Gem::Requirement.new
    end
    attr_reader :name, :version_reqs
    attr_accessor :current_version
    
    def inspect
      %Q{#<#{self.class.name}:#{'%#.8x' % (object_id << 1)} "#{name}">}
    end
    
    def homepage_uri
      get_gems_info['homepage_uri']
    end
    
    ##
    # An Array of Arrays containing version (Gem::Version) and release date (Time)
    #
    # The returned Array is sorted in order of descending version number.
    #
    def versions_with_release
      @versions ||= get_gems_versions.map do |ver|
        [
          Gem::Version.new(ver['number']),
          Time.parse(ver['created_at']).freeze
        ].freeze
      end.reject {|vn, rd| vn.prerelease?}.sort.reverse.freeze
    end
    
    ##
    # Version number recommended based on stability criteria
    #
    # May return +nil+ if no version meets the established criteria
    #
    def recommended_version
      return nil if versions_with_release.empty?
      return @recommended_version if defined? @recommended_version
      
      orig_time_horizon = time_horizon = \
        Time.now - (MIN_RELEASED_DAYS * ONE_DAY)
      horizon_versegs = nonpatch_versegs(versions_with_release[0][0])
      
      versions_with_release.each do |ver, released|
        next if ver.prerelease?
        return (@recommended_version = current_version) if current_version && current_version >= ver
        
        # Reset the time-horizon clock if moving back into previous patch-series
        if (nonpatch_versegs(ver) <=> horizon_versegs) < 0
          time_horizon = orig_time_horizon
        end
        
        if released < time_horizon && version_reqs.satisfied_by?(ver)
          return (@recommended_version = ver)
        end
        time_horizon = [time_horizon, released - (MIN_STABLE_DAYS * ONE_DAY)].min
      end
      return (@recommended_version = nil)
    end
    
    def latest_version
      return nil if versions_with_release.empty?
      versions_with_release[0][0]
    end
    
    def latest_released
      return nil if versions_with_release.empty?
      versions_with_release[0][1]
    end
    
    ##
    # Age in days of the current version
    #
    def age
      return @age if defined? @age
      @age = get_age
    end
    
    def license
      gv_data = get_gems_versions
      
      curver_data = gv_data.find {|v| Gem::Version.new(v['number']) == current_version}
      current_licenses = curver_data && curver_data['licenses'] || []
      
      rcmdd_data = gv_data.find {|v| Gem::Version.new(v['number']) == recommended_version}
      rcmdd_licenses = rcmdd_data && rcmdd_data['licenses'] || current_licenses
      
      now_included = rcmdd_licenses - current_licenses
      now_excluded = current_licenses - rcmdd_licenses
      
      case 
      when now_included.empty? && now_excluded.empty?
        LicenseDescription.new(current_licenses.join(' or '))
      when !now_excluded.empty?
        # "#{current_licenses.join(' or ')} (but rec'd ver. doesn't allow #{now_excluded.join(' or ')})"
        LicenseDescription.new(current_licenses.join(' or ')).tap do |desc|
          desc.update_info = "rec'd ver. doesn't allow #{now_excluded.join(' or ')}"
        end
      when current_licenses.empty? && !now_included.empty?
        LicenseDescription.new("Rec'd ver.: #{now_included.join(' or ')}")
      when !now_included.empty?
        # "#{current_licenses.join(' or ')} (or #{now_included.join(' or ')} on upgrade to rec'd ver.)"
        LicenseDescription.new(current_licenses.join(' or ')).tap do |desc|
          desc.update_info = "or #{now_included.join(' or ')} on upgrade to rec'd ver."
        end
      else
        # "#{current_licenses.join(' or ')} (rec'd ver.: #{rcmdd_licenses.join(' or ')})"
        LicenseDescription.new(current_licenses.join(' or ')).tap do |desc|
          desc.update_info = "rec'd ver.: #{rcmdd_licenses.join(' or ')}"
        end
      end
    end
    
    def changelogs
      gv_data = get_gems_versions.sort_by {|v| Gem::Version.new(v['number'])}.reverse
      if current_version
        gv_data = gv_data.take_while {|v| Gem::Version.new(v['number']) > current_version}
      end
      gv_data.collect {|v| (v['metadata'] || {})['changelog_uri']}.compact.uniq
    end
    
    def changelog
      changelogs[0]
    end
    
    def days_between_current_and_recommended
      v, cv_rel = versions_with_release.find {|v, r| v == current_version} || []
      v, rv_rel = versions_with_release.find {|v, r| v == recommended_version} || []
      return nil if cv_rel.nil? || rv_rel.nil?
      
      return ((rv_rel - cv_rel) / ONE_DAY).to_i
    end
    
    def obsolescence
      cv_major = current_version && current_version.segments[0]
      rv_major = recommended_version && recommended_version.segments[0]
      at_least_moderate = false
      case 
      when cv_major.nil? || rv_major.nil?
        # Can't compare
      when cv_major + 1 < rv_major
        # More than a single major version difference is severe
        return :severe
      when cv_major < rv_major
        # Moderate obsolescence if we're a major version behind
        at_least_moderate = true
      end
      
      days_between = days_between_current_and_recommended
      
      return Reporting.obsolescence_by_age(days_between, at_least_moderate: at_least_moderate)
    end
    
    def source_code_uri
      metadata = get_gems_info['metadata']
      SOURCE_CODE_URI_ENTRIES.each {|k| return metadata[k] if metadata[k]}
      return nil
    end
    
    private
      def get_gems_info
        cache = INFO_CACHE_DIR.join("#{name}.json")
        apply_cache(cache) {Gems.info(name)}
      end
      
      def get_gems_versions
        cache = VERSIONS_CACHE_DIR.join("#{name}.json")
        apply_cache(cache) {Gems.versions(name)}
      end
      
      def get_age
        versions_with_release.each do |ver, released|
          return ((Time.now - released) / ONE_DAY).to_i if ver == current_version
        end
        return nil
      end
      
      def nonpatch_versegs(v)
        v.segments[0..-2]
      end
  end
end
