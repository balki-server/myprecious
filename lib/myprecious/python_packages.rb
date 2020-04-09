require 'json'
require 'myprecious'
require 'myprecious/data_caches'
require 'open-uri'
require 'open3'
require 'parslet'
require 'rest-client'
require 'rubygems/package'
require 'shellwords'
require 'tmpdir'
require 'zip'

module MyPrecious
  class PyPackageInfo
    include DataCaching
    
    COMMON_REQ_FILE_NAMES = %w[requirements.txt Packages]
    MIN_RELEASED_DAYS = 90
    MIN_STABLE_DAYS = 14
    
    PACKAGE_CACHE_DIR = MyPrecious.data_cache(DATA_DIR / "py-package-cache")
    CODE_CACHE_DIR = MyPrecious.data_cache(DATA_DIR / "py-code-cache")
    
    ACCEPTED_URI_SCHEMES = %w[
      http
      https
      git
      git+git
      git+http
      git+https
      git+ssh
    ]
    
    ##
    # Guess the name of the requirements file in the given directory
    #
    # Best effort (currently, consulting a static list of likely file names for
    # existence), and may return +nil+.
    #
    def self.guess_req_file(fpath)
      COMMON_REQ_FILE_NAMES.find do |fname|
        fpath.join(fname).exist?
      end
    end
    
    ##
    # Get an appropriate, human friendly column title for an attribute
    #
    def self.col_title(attr)
      case attr
      when :name then 'Package'
      else Reporting.common_col_title(attr)
      end
    end
    
    ##
    # Construct an instance
    #
    # At least one of the keywords +name:+ or +url:+ _MUST_ be provided.
    #
    def initialize(name: nil, version_reqs: [], url: nil, install: false)
      super()
      if name.nil? and url.nil?
        raise ArgumentError, "At least one of name: or url: must be specified"
      end
      @name = name
      @version_reqs = version_reqs
      @url = url && URI(url)
      @install = install
      if pinning_req = self.version_reqs.find(&:determinative?)
        current_version = pinning_req.vernum
      end
    end
    attr_reader :name, :version_reqs, :url
    attr_accessor :install
    alias_method :install?, :install
    
    ##
    # Was this requirement specified as a direct reference to a URL providing
    # the package?
    #
    def direct_reference?
      !url.nil?
    end
    
    ##
    # For packages specified without a name, do what is necessary to find the
    # name
    #
    def resolve_name!
      return unless direct_reference?
      
      name_from_setup = setup_data['name']
      if !@name.nil? && @name != name_from_setup
        warn("Requirement file entry for #{@name} points to archive for #{name_from_setup}")
      else
        @name = name_from_setup
      end
    end
    
    ##
    # For requirements not deterministically specifying a version, determine
    # which version would be installed
    #
    def resolve_version!
      return @current_version if @current_version
      
      if direct_reference?
        # Use setup_data
        @current_version = parse_version_str(setup_data['version'] || '0a0.dev0')
      elsif pinning_req = self.version_reqs.find(&:determinative?)
        @current_version = parse_version_str(pinning_req.vernum)
      else
        # Use data from pypi
        puts "Resolving current version of #{name}..."
        if inferred_ver = latest_version_satisfying_reqs
          self.current_version = inferred_ver
          puts "    -> #{inferred_ver}"
        else
          puts "    (unknown)"
        end
      end
    end
    
    ##
    # Test if the version constraints on this package are satisfied by the
    # given version
    #
    # All current version requirements are in #version_reqs.
    #
    def satisfied_by?(version)
      version_reqs.all? {|r| r.satisfied_by?(version)}
    end
    
    ##
    # Incorporate the requirements for this package specified in another object
    # into this instance
    #
    def incorporate(other_req)
      if other_req.name != self.name
        raise ArgumentError, "Cannot incorporate requirements for #{other_req.name} into #{self.name}"
      end
      
      self.version_reqs.concat(other_req.version_reqs)
      self.install ||= other_req.install
      if current_version.nil? && (pinning_req = self.version_reqs.find(&:determinative?))
        current_version = pinning_req.vernum
      end
    end
    
    def current_version
      @current_version
    end
    
    def current_version=(val)
      @current_version = val.kind_of?(Version) ? val : parse_version_str(val)
    end
    
    ##
    # An Array of Arrays containing version (MyPrecious::PyPackageInfo::Version
    # or String) and release date (Time)
    #
    # The returned Array is sorted in order of descending version number, with
    # strings not conforming to PEP-440 sorted lexicographically following all
    # PEP-440 conformant versions, the latter presented as
    # MyPrecious::PyPackageInfo::Version objects.
    #
    def versions_with_release
      @versions ||= begin
        all_releases = get_package_info.fetch('releases', {})
        ver_release_pairs = all_releases.each_pair.map do |ver, info|
          [
            parse_version_str(ver),
            info.select {|f| f['packagetype'] == 'sdist'}.map do |f|
              Time.parse(f['upload_time_iso_8601'])
            end.min
          ].freeze
        end
        ver_release_pairs.reject! do |vn, rd|
          (vn.kind_of?(Version) && vn.prerelease?) || rd.nil?
        end
        ver_release_pairs.sort! do |l, r|
          case 
          when l[0].kind_of?(String) && r[0].kind_of?(Version) then -1
          when l[0].kind_of?(Version) && r[0].kind_of?(String) then 1
          else l <=> r
          end
        end
        ver_release_pairs.reverse!
        ver_release_pairs.freeze
      end
    end
    
    def latest_version_satisfying_reqs
      versions_with_release.each do |ver, rel_date|
        return ver if self.satisfied_by?(ver.to_s)
        return ver if version_reqs.all? {|req| req.satisfied_by?(ver.to_s)}
      end
      return nil
    end
    
    ##
    # Age in days of the current version
    #
    def age
      return @age if defined? @age
      @age = get_age
    end
    
    def latest_version
      versions_with_release[0][0].to_s
    end
    
    def latest_released
      versions_with_release[0][1]
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
      horizon_versegs = nil
      versions_with_release.each do |vn, rd|
        if vn.kind_of?(Version)
          horizon_versegs = nonpatch_versegs(vn)
          break
        end
      end
      
      versions_with_release.each do |ver, released|
        next if ver.kind_of?(String) || ver.prerelease?
        return (@recommended_version = current_version) if current_version && current_version >= ver
        
        # Reset the time-horizon clock if moving back into previous patch-series
        if (nonpatch_versegs(ver) <=> horizon_versegs) < 0
          time_horizon = orig_time_horizon
        end
        
        if released < time_horizon && version_reqs.all? {|r| r.satisfied_by?(ver, strict: false)}
          return (@recommended_version = ver)
        end
        time_horizon = [time_horizon, released - (MIN_STABLE_DAYS * ONE_DAY)].min
      end
      return (@recommended_version = nil)
    end
    
    def homepage_uri
      get_package_info['info']['home_page']
    end
    
    def license
      # TODO: Implement better, showing difference between current and recommended
      LicenseDescription.new(get_package_info['info']['license'])
    end
    
    def changelog
      # This is wrong
      info = get_package_info['info']
      return info['project_url']
    end
    
    def days_between_current_and_recommended
      v, cv_rel = versions_with_release.find do |v, r|
        case 
        when current_version.prerelease?
          v < current_version
        else
          v == current_version
        end
      end || []
      v, rv_rel = versions_with_release.find {|v, r| v == recommended_version} || []
      return nil if cv_rel.nil? || rv_rel.nil?
      
      return ((rv_rel - cv_rel) / ONE_DAY).to_i
    end
    
    def obsolescence
      at_least_moderate = false
      if current_version.kind_of?(Version) && recommended_version
        cv_major = [current_version.epoch, current_version.final.first]
        rv_major = [recommended_version.epoch, recommended_version.final.first]
        
        case 
        when rv_major[0] < cv_major[0]
          return nil
        when cv_major[0] < rv_major[0]
          # Can't compare, rely on days_between_current_and_recommended
        when cv_major[1] + 1 < rv_major[1]
          return :severe
        when cv_major[1] < rv_major[1]
          at_least_moderate = true
        end
        
        days_between = days_between_current_and_recommended
        
        return Reporting.obsolescence_by_age(
          days_between,
          at_least_moderate: at_least_moderate,
        )
      end
    end
    
    ##
    # Parses requirement line based on grammar in PEP 508
    # (https://www.python.org/dev/peps/pep-0508/#complete-grammar)
    #
    class ReqSpecParser < Parslet::Parser
      COMPARATORS = %w[<= < != === == >= > ~=]
      ENVVARS = %w[
        python_version python_full_version
        os_name sys_platform platform_release
        platform_system platform_version
        platform_machine platform_python_implementation
        implementation_name implementation_version
        extra
      ]
      root :specification
      
      rule(:wsp) { match[' \t'] }
      rule(:wsp_r) { wsp.repeat }
      rule(:version_cmp) { wsp_r >> COMPARATORS.map {|o| str(o)}.inject(&:|) }
      rule(:version) { wsp_r >> (match['[:alnum:]_.*+!-']).repeat(1) }
      rule(:version_one) { (version_cmp.as(:op) >> version.as(:ver)).as(:verreq) }
      rule(:version_many) { version_one.repeat(1,1) >> (wsp_r >> str(',') >> version_one).repeat }
      rule(:versionspec) { (str('(') >> version_many >> str(')')) | version_many }
      rule(:urlspec) { str('@') >> wsp_r >> uri_reference.as(:url) }
      rule(:marker_op) { version_cmp | (wsp_r >> str('in')) | (wsp_r >> str('not') >> wsp.repeat(1) >> str('in')) }
      rule(:python_str_c) { (wsp | match['A-Za-z0-9().{}_*#:;,/?\[\]!~`@$%^&=+|<>-']) }
      rule(:dquote) { str('"') }
      rule(:squote) { str("'") }
      rule(:python_str) {
        (squote >> (python_str_c | dquote).repeat.as(:str) >> squote) | \
        (dquote >> (python_str_c | squote).repeat.as(:str) >> dquote)
      }
      rule(:env_var) { ENVVARS.map {|n| str(n)}.inject(&:|) }
      rule(:marker_var) { wsp_r >> (env_var | python_str)}
      rule(:marker_expr) { marker_var.as(:l) >> marker_op.as(:o) >> marker_var.as(:r) | wsp_r >> str('(') >> marker >> wsp_r >> str(')') }
      rule(:marker_and) { marker_expr.as(:l) >> wsp_r >> str('and').as(:o) >> marker_expr.as(:r) | marker_expr }
      rule(:marker_or) { marker_and.as(:l) >> wsp_r >> str('or').as(:o) >> marker_and.as(:r) | marker_and }
      rule(:marker) { marker_or }
      rule(:quoted_marker) { str(';') >> wsp_r >> marker.as(:markers) }
      rule(:identifier_end) { match['[:alnum:]'] | match['_.-'].repeat >> match['[:alnum:]'] }
      rule(:identifier) { match['[:alnum:]'] >> identifier_end.repeat }
      rule(:name) { identifier }
      rule(:extras_list) { identifier.as(:id).repeat(1,1) >> (wsp_r >> str(',') >> wsp_r >> identifier.as(:id)).repeat }
      rule(:extras) { str('[') >> wsp_r >> extras_list >> wsp_r >> str(']') }
      rule(:name_req) { name.as(:package) >> wsp_r >> extras.as(:extras).maybe >> wsp_r >> versionspec.as(:verreqs).maybe >> wsp_r >> quoted_marker.maybe }
      rule(:url_req) { name.as(:package) >> wsp_r >> extras.as(:extras).maybe >> wsp_r >> urlspec >> (wsp.repeat(1) | any.absent?) >> quoted_marker.maybe }
      rule(:specification) { wsp_r >> (url_req | name_req) >> wsp_r }
      
      # URI
      rule(:uri_reference) { uri | relative_ref }
      rule(:query_maybe) { (str('?') >> query).maybe }
      rule(:fragment_maybe) { (str('#') >> fragment).maybe }
      rule(:uri) { scheme >> str(':') >> hier_part >> query_maybe >> fragment_maybe }
      rule(:hier_part) { (str('//') >> authority >> path_abempty) | path_absolute | path_rootless | path_empty }
      rule(:absolute_uri) { scheme >> str(':') >> hier_part >> query_maybe }
      rule(:relative_ref) { relative_part >> query_maybe >> fragment_maybe }
      rule(:relative_part) { str('//') >> authority >> path_abempty | path_absolute | path_noscheme | path_empty }
      rule(:scheme) { match['[:alpha:]'] >> match['[:alnum:]+.-'].repeat }
      rule(:authority) { (userinfo >> str('@')).maybe >> host >> (str(':') >> port).maybe }
      rule(:userinfo) { (unreserved | pct_encoded | sub_delims | str(':')).repeat }
      rule(:host) { ip_literal | ipv4address | reg_name }
      rule(:port) { match['0-9'].repeat }
      rule(:ip_literal) { str('[') >> (ipv6address | ipvfuture) >> str(']') }
      rule(:ipvfuture) { str('v') >> match['[:xdigit:]'].repeat(1) >> str('.') >> (unreserved | sub_delims | str(':')).repeat(1) }
      rule(:ipv6address) {
        c = str(':')
        cc = str('::')
        
        (h16 >> c).repeat(6,6) >> ls32 |
        cc >> (h16 >> c).repeat(5,5) >> ls32 |
        h16.maybe >> cc >> (h16 >> c).repeat(4,4) >> ls32 |
        ((h16 >> c).maybe >> h16).maybe >> cc >> (h16 >> c).repeat(3,3) >> ls32 |
        ((h16 >> c).repeat(0,2) >> h16).maybe >> cc >> (h16 >> c).repeat(2,2) >> ls32 |
        ((h16 >> c).repeat(0,3) >> h16).maybe >> cc >> h16 >> c >> ls32 |
        ((h16 >> c).repeat(0,4) >> h16).maybe >> cc >> ls32 |
        ((h16 >> c).repeat(0,5) >> h16).maybe >> cc >> h16 |
        ((h16 >> c).repeat(0,6) >> h16).maybe >> cc
      }
      rule(:h16) { match['[:xdigit:]'].repeat(1,4) }
      rule(:ls32) { h16 >> str(':') >> h16 | ipv4address }
      rule(:ipv4address) { dec_octet >> (str('.') >> dec_octet).repeat(3,3) }
      rule(:dec_octet) {
        d = match['0-9']
        nz = match['1-9']
        
        d |
        nz >> d |
        str('1') >> d.repeat(2,2) |
        str('2') >> match['0-4'] >> d |
        str('25') >> match['0-5']
      }
      rule(:reg_name) { (unreserved | pct_encoded | sub_delims).repeat }
      rule(:path) { path_abempty | path_absolute | path_noscheme | path_rootless | path_empty }
      Parslet.str('/').tap do |sl|
        rule(:path_abempty) { (sl >> segment).repeat }
        rule(:path_absolute) { sl >> (segment_nz >> (sl >> segment).repeat).maybe }
        rule(:path_noscheme) { segment_nz_nc >> (sl >> segment).repeat }
        rule(:path_rootless) { segment_nz >> (sl >> segment).repeat }
      end
      rule(:path_empty) { pchar.absent? }
      rule(:segment) { pchar.repeat }
      rule(:segment_nz) { pchar.repeat(1) }
      rule(:segment_nz_nc) { (unreserved | pct_encoded | sub_delims | str('@')).repeat(1) }
      rule(:pchar) { unreserved | pct_encoded | sub_delims | match[':@'] }
      rule(:query) { (pchar | match['/?']).repeat }
      rule(:fragment) { (pchar | match['/?']).repeat }
      rule(:pct_encoded) { str('%') >> match['[:xdigit:]'].repeat(2,2) }
      rule(:unreserved) { match['[:alnum:]._~-'] }
      rule(:reserved) { gen_delims | sub_delims }
      rule(:gen_delims) { match[':/?#()@'] }
      rule(:sub_delims) { match["!$&'()*+,;="] }
    end
    
    ##
    # Transforms parse tree from ReqSpecParser to usable objects
    #
    class ReqSpecTransform < Parslet::Transform
      rule(:verreq => {op: simple(:o), ver: simple(:v)}) {Requirement.new(o.to_s, v.to_s)}
      rule(package: simple(:n)) {|c| PyPackageInfo.new(name: c[:n].to_s)}
      rule(package: simple(:n), verreqs: sequence(:rs)) {|c| PyPackageInfo.new(
        name: c[:n].to_s,
        version_reqs: c[:rs],
      )}
      rule(package: simple(:n), url: simple(:url)) {|c| PyPackageInfo.new(
        name: c[:n].to_s,
        url: c[:url].to_s,
      )}
      
      ##
      # Apply transform after normalizing a parse tree
      #
      # This method should be applied only to a parse tree expected to come
      # from a requirement specification.
      #
      def apply_spec(ptree)
        norm_ptree = {}
        # TODO: :extras should be in this list, and we should default them to []
        %i[package verreqs url].each do |c|
          norm_ptree[c] = ptree[c] if ptree.has_key?(c)
        end
        apply(norm_ptree)
      end
    end
    
    ##
    # Representation of a single requirement clause
    #
    class Requirement
      def initialize(op, vernum)
        super()
        @op = case op
        when '<' then :<
        when '<=' then :<=
        when '==' then :==
        when '>=' then :>=
        when '>' then :>
        when '!=' then :!=
        when '~=' then :compatible
        when '===' then :str_equal
        when Symbol then op
        else
          raise "Unknown requirement operator #{op.inspect}"
        end
        @vernum = vernum
      end
      attr_reader :op, :vernum
      
      def determinative?
        [:==, :str_equal].include?(op)
      end
      
      ##
      # Query if this requirement is satisfied by a particular version
      #
      # When +strict:+ is false and the instance is an equality-type requirement
      # (i.e. the +op+ is +:==+ or +:str_equal+), the result is always +true+.
      #
      def satisfied_by?(version, strict: true)
        req_key = PyPackageInfo.parse_version_str(self.vernum)
        cand_key = PyPackageInfo.parse_version_str(version)
        
        return true if !strict && %i[== str_equal].include?(op)
        
        return case op
        when :compatible
          req_key, cand_key = comp_keys(version)
          (cand_key <=> req_key) >= 0 && (cand_key <=> series(req_key)) == 0
        when :str_equal
          self.vernum == version.to_s
        else
          req_key, cand_key = comp_keys(version)
          if comp_result = (cand_key <=> req_key)
            comp_result.send(op, 0)
          else
            warn("Cannot test #{cand_key.inspect} #{op} #{req_key} (<=> returned nil)")
          end
        end
      end
      
      private
        def comp_keys(other)
          [self.vernum, other].map {|v| PyPackageInfo.parse_version_str(v)}
        end
        
        def series(comp_key)
          comp_key.dup.tap do |result|
            result.final.to_series
          end
        end
    end
    
    VERSION_PATTERN = /^
      ((?<epoch> \d+ ) ! )?
      (?<final> \d+ (\.\d+)* (\.\*)? )
      (           # Pre-release (a | b | rc) group
        [._-]? 
        (?<pre_group> a(lpha)? | b(eta)? | c | pre(view)? | rc )
        [._-]?
        (?<pre_n> \d* )
      )?
      (           # Post-release group
        (
          [._-]? (post|r(ev)?) [._-]?
          |
          - # Implicit post release
        )
        (?<post> ((?<![._-]) | \d) \d* )
      )?
      (           # Development release group
        [._-]?
        dev
        (?<dev> \d* )
      )?
      (           # Local version segment
        \+
        (?<local>.*)
      )?
    $/x

    module VersionParsing
      def parse_version_str(s)
        return s if s.kind_of?(Version)
        return s unless parts = VERSION_PATTERN.match(s.downcase)
        
        # Normalization
        pre_group = case parts[:pre_group]
        when 'alpha' then 'a'
        when 'beta' then 'b'
        when 'c', 'pre', 'preview' then 'rc'
        else parts[:pre_group]
        end
        
        return Version.new(
          FinalVersion.new(parts[:final]),
          epoch: parts[:epoch],
          pre: [pre_group, parts[:pre_n]],
          post: parts[:post],
          dev: parts[:dev],
          local: parts[:local],
        )
      end
    end
    extend VersionParsing
    include VersionParsing
    
    ##
    # Represents a full PEP-440 version
    #
    class Version
      NOT_PRE = ['z', 0]
      
      def initialize(final, epoch: 0, pre: [], post: nil, dev: nil, local: nil)
        @epoch = (epoch || 0).to_i
        @final = final.kind_of?(FinalVersion) ? final : FinalVersion.new(final)
        @pre = normalize_part(pre[1]) {|n| n && [pre[0], n]}
        @post = normalize_part(post) {|n| n && [n] }
        @dev = normalize_part(dev) {|n| n}
        @local = case local
        when nil then nil
        when Array then local
        else local.to_s.split(/[._-]/).map {|part| try_to_i(part)}
        end
      end
      attr_reader *%i[epoch final local]
      
      def inspect
        "#<#{self.class.name} #{to_s.inspect}>"
      end
      
      def to_s
        [].tap do |parts|
          parts << "#{epoch}!" unless epoch == 0
          parts << final.to_s
          parts << "#{@pre[0]}#{@pre[1]}" if @pre
          parts << ".post#{@post}" if @post
          parts << ".dev#{@dev}" if @dev
          parts << "+#{local}" if local
        end.join('')
      end
      
      def pre_group
        @pre && @pre[0]
      end
      
      def pre_num
        @pre && @pre[1]
      end
      
      def <=>(rhs)
        return nil unless rhs.kind_of?(self.class)
        steps = Enumerator.new do |comps|
          %i[epoch final pre_comp post_comp dev_comp].each do |attr|
            comps << (send(attr) <=> rhs.send(attr))
          end
          
          case [local, rhs.local].count(&:nil?)
          when 2 then comps << 0
          when 1 then comps << (local.nil? ? -1 : 1)
          else comps << (local <=> rhs.local)
          end
        end
        steps.find {|v| v != 0} || 0
      end
      include Comparable
      
      def prerelease?
        !!(@pre || @dev)
      end
      
      private
        def normalize_part(value)
          yield case value
          when '' then 0
          when nil then nil
          else value.to_i
          end
        end
        
        def try_to_i(s)
          if /^\d+$/ =~ s
            s.to_i
          else
            s
          end
        end
        
        def pre_comp
          @pre || NOT_PRE
        end
        
        def post_comp
          @post || []
        end
        
        def dev_comp
          @dev || Float::INFINITY
        end
    end
    
    ##
    # Represents the "final" part of a PEP-440 version string
    #
    class FinalVersion
      def initialize(final_ver)
        @value = case final_ver
        when Array then final_ver
        else final_ver.split('.').map {|s| seg_value(s)}
        end
      end
      
      def [](n)
        @value[n]
      end
      
      def length
        @value.length
      end
      
      def each(&blk)
        @value.each(&blk)
      end
      include Enumerable
      
      def to_s
        @value.join('.')
      end
      
      def inspect
        "#<#{self.class.name} #{to_s}>"
      end
      
      def <=>(rhs)
        nil unless rhs.kind_of?(FinalVersion)
        (0..Float::INFINITY).lazy.each do |i|
          return 0 if self[i].nil? && rhs[i].nil?
          return 0 if [self[i], rhs[i]].include?(:*)
          diff = (self[i] || 0) <=> (rhs[i] || 0)
          return diff if diff != 0
        end
      end
      include Comparable
      
      def to_series
        self.class.new(@value.dup.tap do |mver|
          mver[-1] = :*
        end.join('.'))
      end
      
      private
        def seg_value(s)
          if s == '*'
            :*
          else
            s.to_i
          end
        end
    end
    
    ##
    # Reads package requirements from a file
    #
    class Reader
      def initialize(packages_fpath, only_constrain: false)
        super()
        @files = [Pathname(packages_fpath)]
        @only_constrain = only_constrain
      end
      
      ##
      # Enumerate packages described by requirements targeted by this instance
      #
      # Each invocation of the block receives a PyPackageInfo object, which
      # will have, at minimum, either a #name or #url not +nil+.  It is
      # possible that multiple iterations will process separate PyPackageInfo
      # for the same package, in which case PyPackageInfo#incorporate is useful.
      #
      # An Enumerator is returned if no block is given.
      #
      def each_package_constrained
        generator = Enumerator.new do |items|
          continued_line = ''
          current_file.each_line do |pkg_line|
            pkg_line = pkg_line.chomp
            next if /^#/ =~ pkg_line
            if /(?<=\s)#.*$/ =~ pkg_line
              pkg_line = pkg_line[0...-$&.length]
            end
            
            # Yes, this _does_ happen after comment lines are skipped :facepalm:
            if /\\$/ =~ pkg_line
              continued_line += pkg_line[0..-2]
              next
            end
            pkg_line, continued_line = (continued_line + pkg_line).strip, ''
            next if pkg_line.empty?
            
            process_line_into(items, pkg_line)
          end
        end
        
        if block_given?
          generator.each {|item| yield item}
        else
          generator
        end
      end
      
      ##
      # Enumerate packages targeted for installation by this instance
      #
      # Each invocation of the block receives a PyPackageInfo object targeted
      # for installation.  Each of these PyPackageInfo object will have a
      # resolved #name and #current_version (if possible).
      #
      # An Enumerator is returned if no block is given.
      #
      def each_installed_package
        generator = Enumerator.new do |items|
          packages = {}
          
          each_package_constrained do |pkg|
            pkg.resolve_name!
            if packages.has_key?(pkg.name)
              packages[pkg.name].incorporate(pkg)
            else
              packages[pkg.name] = pkg
            end
          end
          
          to_install = []
          packages.each_value do |pkg|
            next unless pkg.install?
            to_install << pkg.name
          end
          
          while pkg_name = to_install.shift
            pkg = packages[pkg_name]
            pkg.resolve_version!
            items << pkg
          end
        end
        
        if block_given?
          generator.each {|item| yield item}
        else
          generator
        end
      end
      
      private
        def current_file
          @files.last
        end
        
        def in_file(fpath)
          @files << Pathname(fpath)
          begin
            yield
          ensure
            @files.pop
          end
        end
        
        def only_constrain?
          @only_constrain
        end
        
        def reading_constraints
          prev_val, @only_constrain = @only_constrain, true
          begin
            yield
          ensure
            @only_constrain = prev_val
          end
        end
        
        def process_line_into(items, pkg_line)
          case pkg_line
          when /^-r (.)$/
            if only_constrain?
              warn("-r directive appears in constraints file #{current_file}")
            end
            in_file(current_file.dirname / $1) do
              each_package_constrained {|pkg| items << pkg}
            end
          when /^-c (.)$/
            in_file(current_file.dirname / $1) do
              reading_constraints do
                each_package_constrained {|pkg| items << pkg}
              end
            end
          when /^-e/
            warn %Q{#{current_file} lists "editable" package: #{pkg_line}}
          else
            insert_package_from_line_into(items, pkg_line)
          end
        end
        
        def insert_package_from_line_into(items, pkg_line)
          parse_tree = begin
            ReqSpecParser.new.parse(pkg_line)
          rescue Parslet::ParseFailed
            if (uri = URI.try_parse(pkg_line)) && ACCEPTED_URI_SCHEMES.include?(uri.scheme)
              if only_constrain?
                warn("#{current_file} is a constraints file but specifies URL #{uri}")
              else
                items << PyPackageInfo.new(url: uri, install: true)
              end
              return
            end
            warn("Unreportable line in #{current_file}: #{pkg_line}")
            return
          end
          
          # Transform parse tree into a spec
          spec = ReqSpecTransform.new.apply_spec(parse_tree)
          if spec.kind_of?(PyPackageInfo)
            spec.install ||= !only_constrain?
            items << spec
          else
            warn("Unhandled requirement parse tree: #{explain_parse_tree parse_tree}")
          end
        end
        
        def explain_parse_tree(parse_tree)
          case parse_tree
          when Array
            "[#{parse_tree.map {|i| "#<#{i.class.name}>"}.join(', ')}]"
          when Hash
            "{#{parse_tree.map {|k, v| "#{k.inspect} => #<#{v.class.name}>"}.join(', ')}}"
          else
            "#<#{parse_tree.class.name}>"
          end
        end
    end
    
    def pypi_url
      "https://pypi.org/pypi/#{name}/json"
    end
    
    def pypi_release_url(release)
      "https://pypi.org/pypi/#{name}/#{release}/json"
    end
    
    private
      def get_package_info
        cache = PACKAGE_CACHE_DIR.join("#{name}.json")
        apply_cache(cache) do
          pypi_response = RestClient.get(pypi_url)
          JSON.parse(pypi_response)
        end
      end
      
      def get_release_info(release)
        cache = PACKAGE_CACHE_DIR.join(name, "#{release}.json")
        apply_cache(cache) do
          pypi_response = RestClient.get(pypi_release_url(release))
          JSON.parse(pypi_response)
        end
      end
      
      def get_age
        versions_with_release.each do |vnum, released|
          return ((Time.now - released) / ONE_DAY).to_i if vnum == current_version
        end
        return nil
      end
      
      ##
      # Given a version, return the parts that we expect to define the
      # major/minor release series
      #
      # Returns an Array
      #
      def nonpatch_versegs(ver)
        return nil if ver.nil?
        [ver.epoch] + ver.final.take(2)
      end
      
      ##
      # Get data from the setup.py file of the package
      #
      def setup_data
        return @setup_data if defined? @setup_data
        unless self.url
          raise "#setup_data called for #{name}, may only be called for packages specified by URL"
        end
        
        python_code = <<~END_OF_PYTHON
          import json, sys
          from unittest.mock import patch

          sys.path[0:0] = ['.']

          def capture_setup(**kwargs):
              capture_setup.captured = kwargs

          with patch('setuptools.setup', capture_setup):
              import setup

          json.dump(
            capture_setup.captured,
            sys.stdout,
            default=lambda o: "<{}.{}>".format(type(o).__module__, type(o).__qualname__),
          )
        END_OF_PYTHON
        
        output, status = with_package_files do |workdir|
          Dir.chdir(workdir) do
            Open3.capture2('python3', stdin_data: python_code)
          end
        end || []
        
        @setup_data = begin
          case status
          when nil
            warn("Package files unavailable, could not read setup.py")
            {}
          when :success?.to_proc
            JSON.parse(output)
          else
            warn("Failed to read setup.py in for #{self.url}")
            {}
          end
        rescue StandardError => ex
          warn("Failed to read setup.py in for #{self.url}: #{ex}")
          {}
        end
      end
      
      ##
      # Yield a Pathname for the directory containing the package files
      #
      # Returns the result of the block, or +nil+ if the block is not
      # executed.  The directory with the package files may be removed when
      # the block exits.
      #
      def with_package_files(&blk)
        case self.url.scheme
        when 'git'
          return with_git_worktree(self.url, &blk)
        when /^git\+/
          git_uri = self.url.dup
          git_uri.scheme = self.url.scheme[4..-1]
          return with_git_worktree(git_uri, &blk)
        when 'http', 'https'
          case
          when zip_url?
            return with_unzipped_files(&blk)
          when tgz_url?
            return with_untarred_files(&blk)
          else
            warn("Unknown archive type for URL: #{self.url}")
            return nil
          end
        else
          warn("Unable to process URI package requirement: #{self.url}")
        end
      end
      
      ##
      # Implementation of #with_package_files for git URIs
      #
      def with_git_worktree(uri)
        git_url = uri.dup
        git_url.path, committish = uri.path.split('@', 2)
        uri_fragment, git_url.fragment = uri.fragment, nil
        repo_path = CODE_CACHE_DIR.join("git_#{Digest::MD5.hexdigest(git_url.to_s)}.git")
        
        CODE_CACHE_DIR.mkpath
        
        in_dir_git_cmd = ['git', '-C', repo_path.to_s]
        
        if repo_path.exist?
          puts "Fetching #{git_url} to #{repo_path}..."
          cmd = in_dir_git_cmd + ['fetch', '--tags', 'origin', '+refs/heads/*:refs/heads/*']
          output, status = Open3.capture2(*cmd)
          unless status.success?
            warn("Failed to fetch 'origin' in #{repo_path}")
            return
          end
        else
          cmd = ['git', 'clone', '--bare', git_url.to_s, repo_path.to_s]
          output, status = Open3.capture2(*cmd)
          unless status.success?
            warn("Failed to clone #{git_url}")
            return
          end
        end
        
        committish ||= (
          cmd = in_dir_git_cmd + ['ls-remote', 'origin', 'HEAD']
          output, status = Open3.capture2(*cmd)
          unless status.success?
            raise "Unable to read the HEAD of orgin"
          end
          output.split("\t")[0]
        )
        Dir.mktmpdir("myprecious-git-") do |workdir|
          cmds = [
            in_dir_git_cmd + ['archive', committish],
            ['tar', '-x', '-C', workdir.to_s],
          ]
          statuses = Open3.pipeline(*cmds, in: :close)
          if failed_i = statuses.find {|s| s.exited? && !s.success?}
            exitstatus = statuses[failed_i].exitstatus
            failed_cmd_str = cmds[failed_i].shelljoin
            warn(
              "Failed to create temporary folder at command:\n" +
              "    #{failed_cmd.light_red} (exited with code #{exitstatus})"
            )
            return
          end
          
          fragment_parts = Hash[URI.decode_www_form(uri.fragment || '')]
          package_dir = Pathname(workdir).join(
            fragment_parts.fetch('subdirectory', '.')
          )
          return (yield package_dir)
        end
      end
      
      def get_url_content_type
        # TODO: Make a HEAD request to the URL to find out the content type
        return 'application/octet-stream'
      end
      
      def zip_url?
        case get_url_content_type
        when 'application/zip' then true
        when 'application/octet-stream'
          self.url.path.downcase.end_with?('.zip')
        else false
        end
      end
      
      ##
      # Implementation of #with_package_files for ZIP file URLs
      #
      def with_unzipped_files
        zip_path = extracted_url("zip") do |url_f, zip_path|
          Zip::File.open_buffer(url_f) do |zip_file|
            zip_file.each do |entry|
              if entry.name_safe?
                dest_file = zip_path.join(entry.name.split('/', 2)[1])
                dest_file.dirname.mkpath
                entry.extract(dest_file.to_s) {:overwrite}
              else
                warn("Did not extract #{entry.name} from #{self.url}")
              end
            end
          end
        end
        
        return (yield zip_path)
      end
      
      def tgz_url?
        case get_url_content_type
        when %r{^application/(x-tar(\+gzip)?|gzip)$} then true
        when 'application/octet-stream'
          !!(self.url.path.downcase =~ /\.(tar\.gz|tgz)$/)
        else false
        end
      end
      
      ##
      # Implementation of #with_package_files for TGZ file URLs
      #
      def with_untarred_files
        tar_path = extracted_url("tar") do |url_f, tar_path|
          Gem::Package::TarReader.new(Zlib::GzipReader.new(url_f)) do |tar_file|
            tar_file.each do |entry|
              if entry.full_name =~ %r{(^|/)\.\./}
                warn("Did not extract #{entry.name} from #{self.url}")
              elsif entry.file?
                dest_file = tar_path.join(entry.full_name.split('/', 2)[1])
                dest_file.dirname.mkpath
                dest_file.open('wb') do |df|
                  IO.copy_stream(entry, df)
                end
              end
            end
          end
        end
        
        return (yield tar_path)
      end
      
      def extracted_url(archive_type, &blk)
        puts "Downloading #{self.url}"
        extraction_path = CODE_CACHE_DIR.join(
          "#{archive_type}_#{Digest::MD5.hexdigest(self.url.to_s)}"
        )
        CODE_CACHE_DIR.mkpath
        
        if %w[http https].include?(self.url.scheme)
          # TODO: Make a HEAD request to see if re-download is necessary
        end
        
        self.url.open('rb') {|url_f| yield url_f, extraction_path}
        
        return extraction_path
      end
  end
end
