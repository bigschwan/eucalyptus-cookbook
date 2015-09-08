#
# Cookbook Name:: eucalyptus
# Recipe:: default
#
#Copyright [2014] [Eucalyptus Systems]
##
##Licensed under the Apache License, Version 2.0 (the "License");
##you may not use this file except in compliance with the License.
##You may obtain a copy of the License at
##
##    http://www.apache.org/licenses/LICENSE-2.0
##
##    Unless required by applicable law or agreed to in writing, software
##    distributed under the License is distributed on an "AS IS" BASIS,
##    WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
##    See the License for the specific language governing permissions and
##    limitations under the License.
##

include_recipe "eucalyptus::default"

## Install packages for the NC
if node["eucalyptus"]["install-type"] == "packages"
  yum_package "eucalyptus-nc" do
    action :upgrade
    options node['eucalyptus']['yum-options']
    flush_cache [:before]
  end
else
  include_recipe "eucalyptus::install-source"
end

if node["eucalyptus"]["network"]["mode"] != "VPCMIDO"
  # make sure libvirt is started
  # when we want to delete its networks
  service 'libvirtd' do
    action [ :enable, :start ]
  end
  # Remove default virsh network which runs its own dhcp server
  execute 'virsh net-destroy default' do
    ignore_failure true
  end
  execute 'virsh net-autostart default --disable' do
    ignore_failure true
  end
  include_recipe "eucalyptus::eucanetd"
end

## Setup Bridge
network_script_directory = '/etc/sysconfig/network-scripts'
bridged_nic = node["eucalyptus"]["network"]["bridged-nic"]
bridge_interface = node["eucalyptus"]["network"]["bridge-interface"]
bridged_nic_file = "#{network_script_directory}/ifcfg-" + bridged_nic
bridge_file = "#{network_script_directory}/ifcfg-" + bridge_interface

execute "Copy existing interface config to bridge config" do
  command "cp #{bridged_nic_file} #{bridge_file}"
  not_if "ls #{bridge_file}"
end

execute "Add BRIDGE type to bridge file" do
  command "echo 'TYPE=Bridge' >> #{bridge_file}"
  not_if "grep 'TYPE=Bridge' #{bridge_file}"
end

execute "Set device name in bridge file" do
  command "sed -i 's/DEVICE.*/DEVICE=#{bridge_interface}/g' #{bridge_file}"
  not_if "grep 'DEVICE=#{bridge_interface}' #{bridge_file}"
end

template bridged_nic_file do
  source "ifcfg-eth.erb"
  mode 0644
  owner "root"
  group "root"
end

execute "network-restart" do
  command "service network restart"
  action :nothing
end

execute "Set ip_forward sysctl values on NC" do
  command "sed -i 's/net.ipv4.ip_forward.*/net.ipv4.ip_forward = 1/' /etc/sysctl.conf"
end

execute "Set bridge-nf-call-iptables sysctl values on NC" do
  command "sed -i 's/net.bridge.bridge-nf-call-iptables.*/net.bridge.bridge-nf-call-iptables = 1/' /etc/sysctl.conf"
end

execute "Ensure bridge modules loaded into the kernel on NC" do
  command "modprobe bridge"
end

execute "Reload sysctl values" do
  command "sysctl -p"
end

service "messagebus" do
  supports :status => true, :restart => true, :reload => true
  action [ :enable, :start ]
end

## Setup bridge to allow instances to dhcp properly and early on
execute "brctl setfd #{node["eucalyptus"]["network"]["bridge-interface"]} 2"
execute "brctl sethello #{node["eucalyptus"]["network"]["bridge-interface"]} 2"
execute "brctl stp #{node["eucalyptus"]["network"]["bridge-interface"]} off"

### Ensure hostname resolves
execute "echo \"#{node[:ipaddress]} \`hostname --fqdn\` \`hostname\`\" >> /etc/hosts" do
  not_if "ping -c \`hostname --fqdn\`"
end

ruby_block "Sync keys for NC" do
  block do
    Eucalyptus::KeySync.get_node_keys(node)
  end
  only_if { not Chef::Config[:solo] and node['eucalyptus']['sync-keys'] }
end

template "#{node["eucalyptus"]["home-directory"]}/etc/eucalyptus/eucalyptus.conf" do
  source "eucalyptus.conf.erb"
  action :create
end

if CephHelper::SetCephRbd.is_ceph?(node)
  directory "/etc/ceph" do
    owner 'root'
    group 'root'
    mode '0755'
    action :create
  end
end

ruby_block "Set Ceph Credentials" do
  block do
    CephHelper::SetCephRbd.set_ceph_credentials(node)
  end
  only_if { CephHelper::SetCephRbd.is_ceph?(node) }
end

service "eucalyptus-nc" do
  action [ :enable, :start ]
  supports :status => true, :start => true, :stop => true, :restart => true
end
