require 'myprecious'
require 'myprecious/data_caches'
require 'parslet'
require 'rest-client'

module MyPrecious
  class PyPackageInfo
    include DataCaching
    
    MIN_RELEASED_DAYS = 90
    MIN_STABLE_DAYS = 14
    
    PACKAGE_CACHE_DIR = MyPrecious.data_cache(DATA_DIR / "py-package-cache")
    
    ##
    # Enumerate Python packages required or constrained in a project
    #
    # +packages_fpath+ should refer to a pip requirements.txt-style file
    #
    def self.each_package_constrained(packages_fpath, only_constrain: false, &blk)
      return enum_for(:each_package_constrained, packages_fpath) unless block_given?
      
      packages_fpath = Pathname(packages_fpath)
      
      continued_line = ''
      packages_fpath.each_line do |pkg_line|
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
        next if pkg_line.strip.empty?
        
        process_package_line(packages_fpath, pkg_line, only_constrain: only_constrain, &blk)
      end
    end
    
    def self.process_package_line(fpath, pkg_line, only_constrain:)
      case pkg_line
      when /^-r (.)$/
        each_package_constrained(
          fpath.dirname / $1,
          only_constrain: only_constrain,
        ) {|pkg| yield pkg}
      when /^-c (.)$/
        each_package_constrained(
          fpath.dirname / $1,
          only_constrain: true,
        ) {|cstrt| yield cstrt}
      when /^-e/
        warn %Q{#{fpath} lists "editable" package: #{pkg_line}}
      else
        parse_tree = begin
          ReqSpecParser.new.parse(pkg_line)
        rescue Parslet::ParseFailed
          if /^https?:/ =~ pkg_line
            yield (URI.parse(pkg_line).extend(MayNeedInstall).tap do |uri|
              uri.install = !only_constrain
            end)
            return
          end
          warn("Unreportable line in #{fpath}: #{pkg_line}")
          return
        end
        
        # Transform parse tree into a spec
        spec = ReqSpecTransform.new.apply_spec(parse_tree)
        if spec.kind_of?(PackageRequirements)
          spec.values.each {|rs| rs.each {|r| r.install ||= !only_constrain}}
          yield spec
        end
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
      rule(package: simple(:n)) {|c| package_reqs(c[:n] => [Requirement.new('>=', '0a0dev')])}
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
      def |(rhs)
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
      
      def satisfied_by?(version)
        req_key = PyPackageInfo.parse_version_str(self.vernum)
        cand_key = PyPackageInfo.parse_version_str(version)
        
        return case op
        when :compatible
          req_key, cand_key = comp_keys(version)
          (cand_key <=> req_key) >= 0 && (cand_key <=> series(req_key)) == 0
        when :str_equal
          self.vernum == version
        else
          req_key, cand_key = comp_keys(version)
          (cand_key <=> req_key).send(op, 0)
        end
      end
      
      private
        def comp_keys(other)
          [self.vernum, other].map {|v| PyPackageInfo.parse_version_str(v)}
        end
        
        def series(comp_key)
          comp_key.dup.tap do |result|
            result[1].to_series
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
        (?<post> \d* )
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

    
    def self.parse_version_str(s)
      return s unless parts = VERSION_PATTERN.match(s.downcase)
      
      # Normalization
      pre_group = case parts[:pre_group]
      when 'alpha' then 'a'
      when 'beta' then 'b'
      when 'c', 'pre', 'preview' then 'rc'
      else parts[:pre_group]
      end
      
      return Version.new(
        final,
        epoch: parts[:epoch],
        pre: [pre_group, parts[:pre_n]],
        post: parts[:post],
        dev: parts[:dev],
        local: parts[:local],
      )
    end
    
    class Version
      NOT_PRE = ['z', 0]
      
      def initialize(final, epoch: 0, pre: [], post: nil, dev: nil, local: nil)
        @epoch = (epoch || 0).to_i
        @final = final.kind_of?(FinalVersion) ? final : FinalVersion.new(final)
        @pre = normalize_part(pre[1]) {|n| n && [pre[0], n]}
        @post = normalize_part(post) {|n| n && [n] }
        @dev = normalize_part(dev) {|n| n}
        @local = case local
        when Array then local
        else local.to_s.split(/[._-]/).map {|part| try_to_i(part)}
        end
      end
      attr_reader *%i[epoch final local]
      
      def pre_group
        @pre && @pre[0]
      end
      
      def pre_num
        @pre && @pre[1]
      end
      
      def <=>(rhs)
        return nil unless rhs.kind_of?(self.class)
        Enumerator.new do |comps|
          %i[epoch final pre_comp post_comp dev_comp].each do |attr|
            comps << (send(attr) <=> rhs.send(attr))
          end
          
          case [local, rhs.local].count(&:nil?)
          when 2 then comps << 0
          when 1 then comps << (local.nil? ? -1 : 1)
          else comps << (local <=> rhs.local)
          end
        end
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
        0..Float::INFINITY.lazy.each do |i|
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
  end
end
