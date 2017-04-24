require 'gems'
require 'date'

class MyPrecious
  def self.update
    file = File.new("Gemfile", "r")

    File.open('myprecious.md', 'w') { |write_file|
      write_file.puts "gem | Our Version | Latest Version | Date available | Age (in days) | Home Page | Change Log" 
      write_file.puts "--- | --- | --- | --- | --- | --- | ---"
      while (line = file.gets)
        gem_line = line.strip
        if (gem_line.include? 'gem') && !gem_line.start_with?('#') && !gem_line.start_with?('source')
          name = gem_line.split(' ')[1].split(',')[0].split('\'')[1]
          # gems_info = Gems.versions name
          begin
            a = require name
            if a
              current_version = Gem::Specification.find_all_by_name(name).max.version
              gems_info = Gems.versions name
              gems_latest_info = Gems.info name
              latest_build = ''
              #write_file.puts "Gem Name: " + name
              #write_file.puts "Current Version: " + current_version.to_s
              #write_file.puts "Latest Version: " + gems_latest_info["version"].to_s
              #write_file.puts "Home Page Url: " + gems_latest_info["homepage_uri"].to_s
              #write_file.puts "Change log: " + gems_latest_info["changelog_uri"].to_s
              gems_info.each do |gem_info|
                if gem_info["number"].to_s == gems_latest_info["version"].to_s
                  latest_build = Date.parse gem_info["built_at"]
                  #write_file.puts "Latest Version Date: " + (latest_build).to_s
                end
                if gem_info["number"].to_s == current_version.to_s
                  current_build = Date.parse gem_info["built_at"]
                  days_complete = latest_build - current_build
                  #write_file.puts name + ":" + days_complete.to_i.to_s
                  write_file.puts name + "|" + current_version.to_s + "|" + gems_latest_info["version"].to_s + "|" + 
                                  (latest_build).to_s + "|" + days_complete.to_i.to_s + "|" + 
                                  gems_latest_info["homepage_uri"].to_s + "|" + gems_latest_info["changelog_uri"].to_s    
                end
              end
              
            end
          rescue Exception => e

          end
        end
      end
      file.close
    }
  end
end
