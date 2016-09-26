# Author:: IBM Corporation
# Cookbook Name:: aix
# Provider:: nim
#
# Copyright:: 2016, Atos
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

property :desc, String, name_property: true
property :lpp_source, String
property :targets, String
property :async, [true, false], default: false

class OhaiNimPluginNotFound < StandardError
end

class InvalidLppSourceProperty < StandardError
end

class InvalidTargetsProperty < StandardError
end

class NimCustError < StandardError
end

load_current_value do
end

def check_ohai
  # get list of all NIM machines from Ohai
  begin
    all_machines=node.fetch('nim', {}).fetch('clients').keys
    Chef::Log.debug("Ohai client machine's list is #{all_machines}")
  rescue Exception => e
    raise OhaiNimPluginNotFound, "NIM-NIM-NIM error: cannot find nim info from Ohai output"
  end
end

def expand_targets
  selected_machines=Array.new
  # compute list of machines based on targets property
  if property_is_set?(:targets)
    if !targets.empty?
      targets.split(',').each do |machine|
        # expand wildcard
        machine.gsub!(/\*/,'.*?')
        node['nim']['clients'].keys.collect do |m|
          if m =~ /^#{machine}$/
            selected_machines.concat(m.split)
          end
        end
      end
      selected_machines=selected_machines.sort.uniq
    else
      selected_machines=node['nim']['clients'].keys.sort
      Chef::Log.warn("No targets specified, consider all nim standalone machines as targets")
    end
  else
    selected_machines=node['nim']['clients'].keys.sort
    Chef::Log.warn("No targets specified, consider all nim standalone machines as targets!")
  end
  Chef::Log.debug("List of targets expanded to #{selected_machines}")
  
  if selected_machines.empty?
    raise InvalidTargetsProperty, "NIM-NIM-NIM error: cannot contact any machines"
  end
  selected_machines
end

def check_lpp_source_name (lpp_source)
  oslevel=''
  begin
    if node['nim']['lpp_sources'].fetch(lpp_source)
      Chef::Log.debug("Found lpp source #{lpp_source}")
      oslevel=lpp_source.match(/^([0-9]{4}-[0-9]{2}-[0-9]{2}-[0-9]{4})-lpp_source$/)[1]
    end
  rescue Exception => e
    raise InvalidLppSourceProperty, "NIM-NIM-NIM error: cannot find lpp_source \'#{lpp_source}\' from Ohai output"
  end
  oslevel
end

class OsLevel
  include Comparable
  attr :str
  def <=>(oslevel)
    if str.delete('-').to_i < oslevel.str.delete('-').to_i
      -1
    elsif str.delete('-').to_i > oslevel.str.delete('-').to_i
      1
    else
      0
    end
  end
  def initialize(str)
    @str = str
  end
end

action :update do

  # inputs
  puts ""
  Chef::Log.debug("desc=\"#{desc}\"")
  Chef::Log.debug("lpp_source=#{lpp_source}")
  Chef::Log.debug("targets=#{targets}")

  check_ohai

  # get targetted oslevel
  os_level=check_lpp_source_name(lpp_source)
  Chef::Log.debug("os_level: #{os_level}")

  # build list of targets
  target_list=expand_targets
  Chef::Log.debug("target_list: #{target_list}")

  # nim install
  if async
    str=target_list.join(' ')
    nim_s="nim -o cust -a lpp_source=#{lpp_source} -a accept_licenses=yes -a fixes=update_all -a async=yes #{str}"
    Chef::Log.warn("Start updating machines \'#{str}\' to #{lpp_source}.")
    converge_by("nim custom operation: \"#{nim_s}\"") do
      so=shell_out!(nim_s)
      if so.error?
        unless so.stdout =~ /Either the software is already at the same level as on the media, or/m
          raise NimCustError, "NIM-NIM-NIM error: cannot update"
        end
      end 
    end
  else
    target_list.each do |m|
	  current_os_level=node['nim']['clients'][m]['oslevel']
	  if OsLevel(current_os_level) >= OsLevel(os_level)
        Chef::Log.warn("Machine #{m} is already at same or higher level than #{os_level}")
      else
        nim_s="nim -o cust -a lpp_source=#{lpp_source} -a accept_licenses=yes -a fixes=update_all #{m}"
        Chef::Log.warn("Start updating machine #{m} from #{current_os_level} to #{lpp_source}.")
        converge_by("nim custom operation: \"#{nim_s}\"") do
	      do_not_error=false
	      exit_status=Open3.popen3(nim_s) do |stdin, stdout, stderr, wait_thr|
            stdin.close
            stdout.each_line do |line|
              if line =~ /^Filesets processed:.*?[0-9]+ of [0-9]+/
                print "\r#{line.chomp}"
              elsif line =~ /^Finished processing all filesets./
                print "\r#{line.chomp}"
              end
            end
            puts ""
            stdout.close
            stderr.each_line do |line|
              if line =~ /Either the software is already at the same level as on the media, or/
                do_not_error=true
		      end
		      puts line
            end
            stderr.close
            wait_thr.value # Process::Status object returned.
          end
          Chef::Log.warn("Finish updating #{m}.")
          unless exit_status.success? or do_not_error
            raise NimCustError, "NIM-NIM-NIM error: cannot update"
          end
        end
      end
    end
  end

end

action :check do

end
