require 'date'
require 'git'
require 'ostruct'
require 'pathname'
require 'rake/toolkit_program'

# Declare the module here so it doesn't cause problems for files in the
# "myprecious" directory (or _does_ cause problems if they try to declare
# it a class)
module MyPrecious; end
require 'myprecious/data_caches'
require 'myprecious/ruby_gems'

module MyPrecious
  extend Rake::DSL
  
  Program = Rake::ToolkitProgram
  Program.title = "myprecious Dependecy Reporting Tool"
  
  # Declare the tasks exposed as subcommands in this block
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
          outf.puts col_order.markdown_columns(MarkdownAdapter.new(gem))
        end
      end
        
    end
    
    desc "Clear all myprecious data caches"
    task('clear-caches').parse_args(into: OpenStruct.new) do |parser, args|
      args.prompt = true
      parser.on('--[no-]confirm', "Control confirmation prompt") {|v| args.prompt = v}
      
      # This option exists to force users to specify the full "--no-confirm"
      parser.on('--no-confir', "Warn about incomplete --no-confirm") do
        parser.invalid_args!("Incomplete --no-confirm flag")
      end
    end
    task 'clear-caches' do
      next if Program.args.prompt && !yes_no('Delete all cached data (y/n)?')
      MyPrecious.data_caches.each do |cache|
        begin
          rm_r cache
        rescue Errno::ENOENT
          # No problem, we wanted to delete this anyway
        end
      end
    end
  end
  
  ##
  # Prompt user for a yes/no answer
  #
  # It doesn't matter if they've redirected STDIN/STDOUT -- this grabs the TTY
  # directly.
  #
  def self.yes_no(prompt)
    Pathname('/dev/tty').open('r+') do |term|
      loop do
        term.write("#{prompt} ")
        case term.gets[0..-2]
        when 'y', 'Y', 'yes', 'Yes', 'YES'
          return true
        when 'n', 'N', 'no', 'No', 'NO'
          return false
        end
      end
    end
  end
  
  ##
  # Tool for getting information about the Git repository associated with a
  # directory
  #
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
  
  ##
  # Common behavior in dependency report generation
  #
  # The methods here are not specific to any language or dependency management
  # framework.  They do work with ColumnOrder and an expected set of attributes
  # on the dependency information objects.
  #
  module Reporting
    ##
    # Compute the default output filepath for a directory
    #
    def default_output_fpath(dir)
      dir / (GitInfoExtractor.new(dir).repo_name + "-dependency-tracking.md")
    end
    module_function :default_output_fpath
    
    ##
    # Read the column order from the file at the given path
    #
    # If +fpath+ indicates a file that does not exist, return the default
    # ColumnOrder.
    #
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
    
    ##
    # Generate header lines for the output Markdown table
    #
    # Returns an Array of strings, currently two lines giving header text and
    # divider row.
    #
    def header_lines(order, titlizer)
      col_titles = order.map {|c| titlizer.call(c)}
      return [
        col_titles.join(" | "),
        (["---"] * col_titles.length).join(" | "),
      ]
    end
    module_function :header_lines
    # TODO: Mark dependencies with colors a la https://stackoverflow.com/a/41247934
    
    ##
    # Converts an attribute name to the column title for generic attributes
    #
    # Dependency info classes (like RubyGemInfo) can delegate common column
    # title generation to this function.
    #
    def common_col_title(attr)
      case attr
      when :current_version then 'Our Version'
      when :age then 'Age (in days)'
      when :latest_version then 'Latest Version'
      when :latest_released then 'Date Available'
      when :recommended_version then 'Recommended Version'
      when :license then 'License Type'
      when :changelog then 'Change Log'
      when :obsolescence then 'How Bad'
      else
        warn("'#{attr}' column does not have a mapped name")
        attr
      end
    end
    module_function :common_col_title
    
    ##
    # Determine obsolescence level from days
    #
    # Returns one of +nil+, +:mild+, +:moderate+, or +:severe+.
    #
    # +at_least_moderate:+ allows putting a floor of +:moderate+ obsolescence
    # on the result.
    #
    def obsolescence_by_age(days, at_least_moderate: false)
      return case 
      when days < 270
        at_least_moderate ? :moderate : nil
      when days < 500
        at_least_moderate ? :moderate : :mild
      when days < 730
        :moderate
      else
        :severe
      end
    end
    module_function :obsolescence_by_age
  end
  
  ##
  # Order of columns in a Markdown table
  #
  # Contains the default column ordering when constructed.  Columns are
  # identified by the Symbol commonly used as an attribute on a dependency
  # info object (e.g. RubyGemInfo instance).  Objects of this class behave
  # to some extent like frozen Array instances.
  #
  class ColumnOrder
    DEFAULT = %i[name current_version age latest_version latest_released recommended_version license changelog].freeze
    COLUMN_FROM_TEXT_NAME = {
      'gem' => :name,
      'package' => :name,
      'module' => :name,
      'our version' => :current_version,
      'how bad' => :obsolescence,
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
    
    ##
    # Get the +n+-th column attribute Symbol
    #
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
    
    ##
    # Update the column order to match those in the given line
    #
    # Columns not included in the line are appended in the order they
    # appear in the default order.
    #
    def read_order_from_headers(headers_line)
      headers = headers_line.split('|').map {|h| h.strip.squeeze(' ')}
      @order = headers.map {|h| self.class.col_from_text_name(h)}.compact
      
      # Add in any missing columns at the end
      @order.concat(DEFAULT - @order)
      
      return @order.dup
    end
    
    ##
    # Render a line to include in a Markdown table for the given dependency
    #
    # The dependency must know how to respond to (Ruby) messages (i.e.
    # have attributes) for all columns currently included in the order as
    # represented by this instance.
    #
    def markdown_columns(dependency)
      map {|attr| dependency.send(attr)}.join(" | ")
    end
    
    ##
    # Given a text name, derive the equivalent column attribute
    #
    def self.col_from_text_name(n)
      n = n.downcase
      entry = COLUMN_FROM_TEXT_NAME.find {|k, v| k === n}
      return entry && entry[1]
    end
  end
  
  ##
  # Extension of String that can accomodate some additional commentary
  #
  # The +update_info+ attribute is used to pass information about changes
  # to licensing between the current and recommended version of a dependency,
  # and may be +nil+.
  #
  class LicenseDescription < String
    attr_accessor :update_info
  end
  
  ##
  # Dependency info wrapper to generate nice Markdown columns
  #
  # This wrapper takes basic data from the underlying dependency info object
  # and returns enhanced Markdown for selected columns (e.g. +name+).
  #
  class MarkdownAdapter
    def initialize(dep)
      super()
      @dependency = dep
    end
    attr_reader :dependency
    
    ##
    # Generate Markdown linking the +name+ to the homepage for the dependency
    #
    def name
      cswatch = begin
        color_swatch + ' '
      rescue StandardError
        ''
      end
      "#{cswatch}[#{dependency.name}](#{dependency.homepage_uri})"
    rescue StandardError
      dependency.name
    end
    
    ##
    # Include information about temporal difference between current and
    # recommended versions
    #
    def recommended_version
      recommended_version = dependency.recommended_version
      if dependency.current_version < recommended_version
        "**#{recommended_version}** -- #{dependency.days_between_current_and_recommended} days newer"
      else
        recommended_version
      end
    rescue StandardError
      recommended_version || "(error)"
    end
    
    ##
    # Include update info in the license column
    #
    def license
      value = dependency.license
      if value.update_info
        "#{value}<br/>(#{value.update_info})"
      else
        value
      end
    rescue StandardError
      "(error)"
    end
    
    ##
    # Render short links for http: or https: changelog URLs
    #
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
    
    def obsolescence
      color_swatch
    rescue StandardError
      ''
    end
    
    ##
    # Get a CSS-style hex color code corresponding to the obsolescence of the dependency
    #
    def color
      case dependency.obsolescence
      when :mild then "dde418"
      when :moderate then "f9b733"
      when :severe then "fb0e0e"
      else "4dda1b"
      end
    end
    
    ##
    # Markdown for an obsolescence color swatch
    # 
    # Sourced from: https://stackoverflow.com/a/41247934
    #
    def color_swatch
      "![##{color}](https://placehold.it/15/#{color}/000000?text=+)"
    end
    
    ##
    # Delegate other attribute queries to the base dependency object
    #
    # Errors are caught and rendered as "(error)"
    #
    def method_missing(meth, *args, &blk)
      dependency.send(meth, *args, &blk)
    rescue NoMethodError
      raise
    rescue StandardError
      "(error)"
    end
  end
end
