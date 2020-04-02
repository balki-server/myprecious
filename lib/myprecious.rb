require 'date'
require 'git'
require 'myprecious/ruby_gems'
require 'ostruct'
require 'pathname'
require 'rake/toolkit_program'

module MyPrecious
  extend Rake::DSL
  
  Program = Rake::ToolkitProgram
  Program.title = "myprecious Dependecy Reporting Tool"
  
  class << self
    attr_accessor :caching_disabled
  end
  
  Program.command_tasks do
    desc "Generate report on Ruby gems"
    task('ruby-gems').parse_args(into: OpenStruct.new) do |parser, args|
      parser.expect_positional_cardinality(0)
      
      parser.on(
        '-o', '--out FILE',
        "Output file to generate",
      ) {|fpath| args.output_file = Pathname(fpath)}
      
      args.target = Pathname.pwd
      parser.on(
        '-C', '--dir PATH',
        "Path to inspect",
      ) do |fpath|
        fpath = Pathname(fpath)
        parser.invalid_args!("#{fpath} does not exist.") unless fpath.exist?
        args.target = fpath
      end
      
      parser.on(
        '--[no-]cache',
        "Control caching of gem information"
      ) {|v| MyPrecious.caching_disabled = v}
    end
    task 'ruby-gems' do
      args = Program.args
      out_fpath = args.output_file || Reporting.default_output_fpath(args.target)
      
      col_order = Reporting.read_column_order_from(out_fpath)
      
      # Get all gems used via RubyGemInfo.each_gem_used, accumulating version requirements
      gems = RubyGemInfo.accum_gem_lock_info(args.target)
      
      out_fpath.open('w') do |outf|
        # Header
        outf.puts "Last updated: #{Time.now.rfc2822}; Use for directional purposes only, this data is not real time and might be slightly inaccurate"
        outf.puts
        
        Reporting.header_lines(
          col_order,
          RubyGemInfo.method(:col_title)
        ).each {|l| outf.puts l}
        
        # Iterate all gems in name order, pulling column values from the RubyGemInfo objects
        gems.keys.sort_by {|n| n.downcase}.map {|name| gems[name]}.each do |gem|
          outf.puts(col_order.map do |attr|
            MarkdownAdapter.new(gem).send(attr)
          end.join(" | "))
        end
      end
        
    end
  end
  
  class GitInfoExtractor
    URL_PATTERN = /\/([^\/]+)\.git$/
    
    def initialize(dir)
      super()
      @dir = dir
    end
    attr_reader :dir
    
    def git_info
      @git_info ||= Git.open(self.dir)
    end
    
    def origin_remote
      git_info.remotes.find {|r| r.name == 'origin'}
    end
    
    def repo_name
      @repo_name ||= (URL_PATTERN =~ origin_remote.url) && $1
    end
  end
  
  module Reporting
    def default_output_fpath(dir)
      dir / (GitInfoExtractor.new(dir).repo_name + "-dependency-tracking.md")
    end
    module_function :default_output_fpath
    
    def read_column_order_from(fpath)
      result = ColumnOrder.new
      begin
        prev_line = nil
        fpath.open {|inf| inf.each_line do |line|
          if prev_line && /^-+(?:\|-+)*$/ =~ line.gsub(' ', '')
            result.read_order_from_headers(prev_line)
            break
          end
          prev_line = line
        end}
      rescue Errno::ENOENT
        # No problem
      end
      return result
    end
    module_function :read_column_order_from
    
    def header_lines(order, titlizer)
      col_titles = order.map {|c| titlizer.call(c)}
      return [
        col_titles.join(" | "),
        (["---"] * col_titles.length).join(" | "),
      ]
    end
    module_function :header_lines
    # TODO: Mark dependencies with colors a la https://stackoverflow.com/a/41247934
    
    def common_col_title(attr)
      case attr
      when :current_version then 'Our Version'
      when :age then 'Age (in days)'
      when :latest_version then 'Latest Version'
      when :latest_released then 'Date Available'
      when :recommended_version then 'Recommended Version'
      when :license then 'License Type'
      when :changelog then 'Change Log'
      else
        warn("'#{attr}' column does not have a mapped name")
        attr
      end
    end
    module_function :common_col_title
  end
  
  class ColumnOrder
    DEFAULT = %i[name current_version age latest_version latest_released recommended_version license changelog].freeze
    COLUMN_FROM_TEXT_NAME = {
      'gem' => :name,
      'package' => :name,
      'module' => :name,
      'our version' => :current_version,
      'latest version' => :latest_version,
      'date available' => :latest_released,
      'age (in days)' => :age,
      'license type' => :license,
      /change ?log/ => :changelog,
      'recommended version' => :recommended_version,
    }
    
    def initialize
      super
      @order = DEFAULT
    end
    
    def [](n)
      @order[n]
    end
    
    def length
      @order.length
    end
    
    def each(&blk)
      @order.each(&blk)
    end
    include Enumerable
    
    def read_order_from_headers(headers_line)
      headers = headers_line.split('|').map {|h| h.strip.squeeze(' ')}
      @order = headers.map {|h| self.class.col_from_text_name(h)}.compact
      
      # Add in any missing columns at the end
      @order.concat(DEFAULT - @order)
      
      return @order.dup
    end
    
    def self.col_from_text_name(n)
      n = n.downcase
      entry = COLUMN_FROM_TEXT_NAME.find {|k, v| k === n}
      return entry && entry[1]
    end
  end
  
  class MarkdownAdapter
    def initialize(dep)
      super()
      @dependency = dep
    end
    attr_reader :dependency
    
    def name
      "[#{dependency.name}](#{dependency.homepage_uri})"
    rescue StandardError
      dependency.name
    end
    
    def changelog
      base_val = begin
        dependency.changelog
      rescue StandardError
        return "(error)"
      end
      
      begin
        uri = URI.parse(base_val)
        if ['http', 'https'].include?(uri.scheme)
          return "[on #{uri.hostname}](#{base_val})"
        end
      rescue StandardError
      end
      return base_val
    end
    
    def method_missing(name)
      dependency.send(name)
    rescue NoMethodError
      raise
    rescue StandardError
      "(error)"
    end
  end
end
