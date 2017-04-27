require 'gems'
require 'date'

class MyPrecious
  def self.update
    gem_lines = {}
    gem_name_pos = 0
    gem_version_pos = 1
    gem_latest_pos = 2
    gem_date_pos = 3
    gem_age_pos = 4
    gem_license_pos = 5
    gem_change_pos = 6
    default_length = 7
    if File.file?('myprecious.md')
      File.open("myprecious.md", "r").each_with_index do |line, line_number|
        #puts line + " dds " + line_number.to_s
        word_array = line.split('|')
        if line_number == 0
          default_length = word_array.size
          word_array.each_with_index do |word, index|
            if word.strip == 'Gem'
              gem_name_pos = index
            elsif word.strip == 'Our Version'
              gem_version_pos = index
            elsif word.strip == 'Latest Version'
              gem_latest_pos = index
            elsif word.strip == 'Date available'
              gem_date_pos = index
            elsif word.strip == 'Age (in days)'
              gem_age_pos = index              
            elsif word.strip == 'License Type'
              gem_change_pos = index              
            elsif word.strip == 'Change Log'
              gem_change_pos = index
            end
          end
        elsif line_number > 1
          gem_name_index = word_array[gem_name_pos].strip
          #extract just the name of the gem from the first column
          #since that column contains a markdown-formatted hyperlink  
          gem_name_index = gem_name_index[/\[(.*?)\]/,1]
          gem_lines[gem_name_index] = line_number
        end
        
      end
      #puts gem_lines
    else
      File.open('myprecious.md', 'w') { |write_file|
        write_file.puts "Gem | Our Version | Latest Version | Date available | Age (in days) | License Type | Change Log"
        write_file.puts "--- | --- | --- | --- | --- | --- | ---"
      }
    end

    file = File.new("Gemfile", "r")

    final_write = File.readlines('myprecious.md')

    while (line = file.gets)
      gem_line = line.strip
      if (gem_line.include? 'gem') && !gem_line.start_with?('#') && !gem_line.start_with?('source')
        begin
          name = gem_line.split(' ')[1].split(',')[0].tr(" '\"", "")
          a = require name
          if a
            current_version = Gem::Specification.find_all_by_name(name).max.version
            
            gems_info = Gems.versions name
            gems_latest_info = Gems.info name
            latest_build = ''
            gems_info.each do |gem_info|
              if gem_info["number"].to_s == gems_latest_info["version"].to_s
                latest_build = Date.parse gem_info["built_at"]
              end
              if gem_info["number"].to_s == current_version.to_s
                current_build = Date.parse gem_info["built_at"]

                days_complete = latest_build - current_build
                if gem_lines[name].nil?
                  array_to_write = Array.new(default_length) { |i| "" }
                else
                  array_to_write = final_write[gem_lines[name]].split('|')
                end
                array_to_write[gem_name_pos] = "[" + name + "]" + "(" + gems_latest_info["homepage_uri"].to_s  + ")"
                array_to_write[gem_version_pos] = current_version.to_s
                array_to_write[gem_latest_pos] = gems_latest_info["version"].to_s
                array_to_write[gem_date_pos] = (latest_build).to_s
                array_to_write[gem_age_pos] = days_complete.to_i.to_s
                if !gem_info["licenses"].nil?
                  array_to_write[gem_license_pos] = gem_info["licenses"][0]
                else
                  array_to_write[gem_license_pos] = "N/A"
                end
                array_to_write[gem_change_pos] = gems_latest_info["changelog_uri"].to_s + "\n"
                if !gem_lines[name].nil?
                  final_write[gem_lines[name]] = array_to_write.join("|")
                else                 
                  final_write << array_to_write.join("|")
                end
              end
            end
          end
        rescue Exception => e
          puts e
        end
      end
    end
    File.open('myprecious.md', 'w') { |f| f.write(final_write.join) }
    file.close
  end
end
