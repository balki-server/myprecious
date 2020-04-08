require 'json'
require 'myprecious'
require 'myprecious/data_caches'
require 'open-uri'
require 'open3'
require 'parslet'
require 'rest-client'
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
    # Enumerate Python packages required or constrained in a project
    #
    # +packages_fpath+ should refer to a pip requirements.txt-style file
    #
    # Yields Hash objects extended with PackageRequirements, where each Hash
    # has one entry whose key is the name of a package and whose value is an
    # Array of Requirement objects.
    #
    def self.each_package_constrained(packages_fpath, only_constrain: false, &blk)
      return enum_for(:each_package_constrained, packages_fpath) unless block_given?
      
      packages_fpath = Pathname(packages_fpath)
      
      continued_line = ''
      packages_fpath.each_line do |pkg_line|
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
        
        process_package_line(packages_fpath, pkg_line, only_constrain: only_constrain, &blk)
      end
    end
    
    def self.process_package_line(fpath, pkg_line, only_constrain:, &blk)
      case pkg_line
      when /^-r (.)$/
        each_package_constrained(
          fpath.dirname / $1,
          only_constrain: only_constrain,
          &blk
        )
      when /^-c (.)$/
        each_package_constrained(
          fpath.dirname / $1,
          only_constrain: true,
          &blk
        )
      when /^-e/
        warn %Q{#{fpath} lists "editable" package: #{pkg_line}}
      else
        parse_tree = begin
          ReqSpecParser.new.parse(pkg_line)
        rescue Parslet::ParseFailed
          if (uri = URI.try_parse(pkg_line)) && ACCEPTED_URI_SCHEMES.include?(uri.scheme)
            yield_spec_from_uri(fpath, pkg_line, &blk) unless only_constrain
            return
          end
          warn("Unreportable line in #{fpath}: #{pkg_line}")
          return
        end
        
        # TODO: Better implementation that actually evaluates the marker logic
        # to determine if this spec applies to our situation
        spec_applies = !parse_tree.has_key?(:markers)
        
        if spec_applies
          # Transform parse tree into a spec
          spec = ReqSpecTransform.new.apply_spec(parse_tree)
          if spec.kind_of?(PackageRequirements)
            spec.each_pair do |pkg_name, reqs_or_dref|
              if !reqs_or_dref.kind_of?(URI)
                reqs_or_dref.each {|r| r.install ||= !only_constrain}
                yield ({pkg_name => reqs_or_dref}.extend(PackageRequirements))
              elsif !only_constrain
                yield_spec_from_uri(fpath, reqs_or_dref.to_s, &blk)
              end
            end
          else
            warn("Unhandled requirement parse tree: #{explain_parse_tree(parse_tree)}")
          end
        end
      end
    end
    
    def self.explain_parse_tree(parse_tree)
      case parse_tree
      when Array
        "[#{parse_tree.map {|i| "#<#{i.class.name}>"}.join(', ')}]"
      when Hash
        "{#{parse_tree.map {|k, v| "#{k.inspect} => #<#{v.class.name}>"}.join(', ')}}"
      else
        "#<#{parse_tree.class.name}>"
      end
    end
    
    def self.yield_spec_from_uri(fpath, pkg_line, &blk)
      uri = begin
        URI.parse(pkg_line)
      rescue URI::InvalidURIError
        warn("Unable to process package requirement in #{fpath}: #{pkg_line}")
        return
      end
      
      case uri.scheme
      when 'git'
        # uri is a git-clone URL
        yield_spec_from_git(uri, &blk)
      when /^git\+/
        uri = URI.parse(pkg_line[4..-1])
        # _now_ uri is a git-clone URL
        yield_spec_from_git(uri, &blk)
      when 'http', 'https'
        # uri is a .ZIP package
        yield_spec_from_zip_uri(uri, &blk)
      else
        warn("Unable to process URI package requirement in #{fpath}: #{pkg_line}")
      end
    end
    
    def self.yield_spec_from_git(uri, &blk)
      git_url = uri.dup
      git_url.path, committish = uri.path.split('@', 2)
      uri_fragment, git_url.fragment = uri.fragment, nil
      repo_path = CODE_CACHE_DIR.join("git_#{Digest::MD5.hexdigest(git_url.to_s)}.git")
      
      CODE_CACHE_DIR.mkpath
      
      if repo_path.exist?
        puts "Fetching #{git_url} to #{repo_path}..."
        output, status = Open3.capture2('git', '-C', repo_path.to_s, 'fetch',
          '--tags', 'origin', '+refs/heads/*:refs/heads/*')
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
      
      worktree_subdir = 'files'
      cmd = ['git', '-C', repo_path.to_s, 'worktree', 'add', worktree_subdir, committish || 'HEAD']
      output, status = Open3.capture2(*cmd)
      unless status.success?
        warn("Failed to check out #{committish} in #{repo_path}")
        return
      end
      begin
        # Look in uri.fragment for "subdirectory"
        fragment_parts = Hash[URI.decode_www_form(uri.fragment || '')]
        package_dir = repo_path.join(
          worktree_subdir,
          fragment_parts.fetch('subdirectory', '.')
        )
        
        # Run Python code to get package information
        yield_specs_from_setup_info(package_dir, &blk)
      ensure
        cmd = ['git', '-C', repo_path.to_s, 'worktree', 'remove', worktree_subdir]
        output, status = Open3.capture2(*cmd)
        unless status.success?
          warn("Failed to remove worktree 'files' in #{repo_path} (exit code #{status.exitstatus})")
        end
      end
    end
    
    def self.yield_spec_from_zip_uri(uri, &blk)
      puts "Downloading #{uri}"
      zip_path = CODE_CACHE_DIR.join("zip_#{Digest::MD5.hexdigest(uri.to_s)}")
      CODE_CACHE_DIR.mkpath
      uri.open('rb') do |uri_f|
        Zip::File.open_buffer(uri_f) do |zip_file|
          zip_file.each do |entry|
            if entry.name_safe?
              dest_file = zip_path.join(entry.name.split('/',2)[1])
              dest_file.dirname.mkpath
              entry.extract(dest_file.to_s) {:overwrite}
            else
              warn("Did not extract #{entry.name} from #{uri}")
            end
          end
        end
      end
      
      # Run Python code to get package information
      yield_specs_from_setup_info(zip_path, &blk)
    end
    
    def self.yield_specs_from_setup_info(local_copy_fpath, &blk)
      setup_info = load_setup_info(local_copy_fpath)
      setup_file = local_copy_fpath.join('setup.py')
      package_version_line = "#{setup_info['name']}==#{setup_info['version']}"
      process_package_line(setup_file, package_version_line, only_constrain: false, &blk)
      (setup_info['install_requires'] || []).each do |dep|
        process_package_line(setup_file, dep, only_constrain: false, &blk)
      end
    end
    
    def self.load_setup_info(workdir)
      cmd = ['python3']
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
      
      output, status = Dir.chdir(workdir) do
        Open3.capture2('python3', stdin_data: python_code)
      end
      raise "Failed to read setup.py in #{workdir}" unless status.success?
      JSON.parse(output)
    end
    
    def self.each_installed_package(packages_fpath)
      return enum_for(:each_installed_package, packages_fpath) unless block_given?
      
      package_constraints = {}.extend(PackageRequirements)
      
      each_package_constrained(packages_fpath) do |cnstrt|
        package_constraints += cnstrt
      end
      
      pkg_info = {}
      to_install = []
      package_constraints.each_pair do |pkg_name, reqs|
        next unless reqs.any? {|r| r.install}
        pkg_info[pkg_name] ||= new(pkg_name, reqs)
        to_install << pkg_name
      end
      
      while pkg_name = to_install.shift
        item = pkg_info[pkg_name]
        item.resolve_version!(package_constraints)
        yield item
        
        # Add any dependencies of item to to_install if they are not yet
        # in pkg_info
        item.each_transitive_requirement do |req|
          package_constraints += req
          req.keys.reject {|k| pkg_info.has_key?(k)}.each do |dep_name|
            dep_reqs = req[dep_name]
            pkg_info[dep_name] = new(dep_name, dep_reqs)
            to_install << dep_name
          end
        end
      end
    end
    
    def self.guess_req_file(fpath)
      COMMON_REQ_FILE_NAMES.find do |fname|
        fpath.join(fname).exist?
      end
    end
    
    def self.col_title(attr)
      case attr
      when :name then 'Package'
      else Reporting.common_col_title(attr)
      end
    end
    
    def initialize(name, version_reqs)
      super()
      @name = name
      @version_reqs = version_reqs
      dvreq = @version_reqs.find(&:determinative?)
      @current_version = dvreq && parse_version_str(dvreq.vernum)
    end
    attr_reader :name, :version_reqs
    #attr_accessor :current_version
    
    def current_version
      @current_version
    end
    
    def current_version=(val)
      @current_version = val.kind_of?(Version) ? val : parse_version_str(val)
    end
    
    def resolve_version!(pkg_constraints)
      # Determine version if @current_version.nil?
      unless self.current_version
        puts "Resolving current version of #{name}..."
        if inferred_ver = latest_version_satisfying_reqs
          self.current_version = inferred_ver
          puts "    -> #{inferred_ver}"
        else
          puts "    (unknown)"
        end
      end
    end
    
    def each_transitive_requirement(&blk)
      return if current_version.nil? || current_version.prerelease?
      transitive_require_info = get_release_info(current_version)['info']['requires_dist']
      (transitive_require_info || []).each do |reqmt_line|
        PyPackageInfo.process_package_line(
          nil,
          reqmt_line,
          only_constrain: false,
          &blk
        )
      end
    end
    
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
        return ver if version_reqs.all? {|req| req.satisfied_by?(ver.to_s)}
      end
      return nil
    end
    
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
    
    # Parses based on grammar in PEP 508 (https://www.python.org/dev/peps/pep-0508/#complete-grammar)
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
    
    class ReqSpecTransform < Parslet::Transform
      rule(:verreq => {op: simple(:o), ver: simple(:v)}) {Requirement.new(o.to_s, v.to_s)}
      rule(package: simple(:n)) {|c| package_reqs(c[:n].to_s => [Requirement.new('>=', '0a0dev')])}
      rule(package: simple(:n), verreqs: sequence(:rs)) {|c| package_reqs(c[:n].to_s => c[:rs])}
      rule(package: simple(:n), url: simple(:url)) do |c|
        package_reqs(c[:n].to_s => URI.parse(c[:url].to_s).extend(MayNeedInstall))
      end
      
      def self.package_reqs(reqs = {})
        reqs.dup.extend(PackageRequirements)
      end
      
      def apply_spec(ptree)
        norm_ptree = {}
        %i[package verreqs url].each do |c|
          norm_ptree[c] = ptree[c] if ptree.has_key?(c)
        end
        apply(norm_ptree)
      end
    end
    
    module PackageRequirements
      def +(rhs)
        unless rhs.kind_of?(PackageRequirements)
          raise TypeError, "right hand side of | must be PackageRequirements"
        end
        
        dup.extend(PackageRequirements).tap do |result|
          rhs.each_pair do |name, reqs|
            new_reqs = (result[name] || []).concat(reqs)
            
            result[name] = new_reqs
          end
        end
      end
    end
    
    module MayNeedInstall
      attr_accessor :install
      
      def self.on(obj, install_value = nil)
        obj.extend(self) unless obj.kind_of?(self)
        obj.install = install_value unless install_value.nil?
      end
    end
    
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
      
      include MayNeedInstall
      
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
          parts << "post#{@post}" if @post
          parts << "dev#{@dev}" if @dev
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
    
    def pypi_url
      "https://pypi.python.org/pypi/#{name}/json"
    end
    
    def pypi_release_url(release)
      "https://pypi.python.org/pypi/#{name}/#{release}/json"
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
      
      def nonpatch_versegs(ver)
        return nil if ver.nil?
        [ver.epoch] + ver.final.take(2)
      end
  end
end
