# Copyright 2019, SUSE LLC.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#   http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#

define :octavia_conf do
  octavia_net = \
    if Chef::Recipe::Barclamp::Inventory.get_network_by_type(node, "octavia")
      "octavia"
    else
      "admin"
    end

  conf_files = OctaviaHelper.conf_file(params[:name])
  conf_files.each do |conf_file|
    template conf_file do
      source "#{File.basename(conf_file)}.erb"
      owner node[:octavia][:user]
      group node[:octavia][:group]
      mode 0o640
      variables(
        lazy do
          {
            bind_host: OctaviaHelper.bind_host(node, params[:name]),
            bind_port: OctaviaHelper.bind_port(node, params[:name]),
            octavia_db_connection: fetch_database_connection_string(node[:octavia][:db]),
            neutron_endpoint: OctaviaHelper.get_neutron_endpoint(node),
            nova_endpoint: OctaviaHelper.get_nova_endpoint(node),
            barbican_endpoint: OctaviaHelper.get_barbican_endpoint(node),
            octavia_keystone_settings: KeystoneHelper.keystone_settings(node, "octavia"),
            rabbit_settings: fetch_rabbitmq_settings,
            octavia_healthmanager_hosts: OctaviaHelper.get_healthmanager_nodes(node, octavia_net),
            memcached_servers: MemcachedHelper.get_memcached_servers(node,
                CrowbarPacemakerHelper.cluster_nodes(node, "octavia-api"))
          }
        end
      )
    end
  end
end
