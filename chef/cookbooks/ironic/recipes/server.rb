# Copyright 2016 SUSE, Inc.
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
#

db_settings = fetch_database_settings

include_recipe "database::client"
include_recipe "#{db_settings[:backend_name]}::client"
include_recipe "#{db_settings[:backend_name]}::python-client"

# Create the Ironic Database
database "create #{node[:ironic][:db][:database]} database" do
  connection db_settings[:connection]
  database_name node[:ironic][:db][:database]
  provider db_settings[:provider]
  action :create
end

database_user "create ironic database user" do
  host "%"
  connection db_settings[:connection]
  username node[:ironic][:db][:user]
  password node[:ironic][:db][:password]
  provider db_settings[:user_provider]
  action :create
end

database_user "grant database access for ironic database user" do
  connection db_settings[:connection]
  username node[:ironic][:db][:user]
  password node[:ironic][:db][:password]
  database_name node[:ironic][:db][:database]
  host "%"
  privileges db_settings[:privs]
  provider db_settings[:user_provider]
  action :grant
end

node[:ironic][:platform][:packages].each do |p|
  package p
end

ironic_net_ip = Chef::Recipe::Barclamp::Inventory.get_network_by_type(node, "ironic").address

keystone_settings = KeystoneHelper.keystone_settings(node, @cookbook_name)

auth_version = "v2.0"

glance = search(:node, "roles:glance-server").first
glance_settings = { protocol: glance[:glance][:api][:protocol],
                    host: CrowbarHelper.get_host_for_admin_url(glance, glance[:glance][:ha][:enabled]),
                    port: glance[:glance][:api][:bind_port] }

neutron = search(:node, "roles:neutron-server").first
neutron_settings = { protocol: neutron[:neutron][:api][:protocol],
                     host: CrowbarHelper.get_host_for_admin_url(neutron, neutron[:neutron][:ha][:server][:enabled]),
                     port: neutron[:neutron][:api][:service_port] }

api_port = node[:ironic][:api][:port]
api_protocol = node[:ironic][:api][:protocol]

my_admin_host = CrowbarHelper.get_host_for_admin_url(node)
my_public_host = CrowbarHelper.get_host_for_public_url(node, false)

db_connection = "#{db_settings[:url_scheme]}://#{node[:ironic][:db][:user]}:#{node[:ironic][:db][:password]}@#{db_settings[:address]}/#{node[:ironic][:db][:database]}"

register_auth_hash = { user: keystone_settings["admin_user"],
                       password: keystone_settings["admin_password"],
                       tenant: keystone_settings["admin_tenant"] }

keystone_register "ironic wakeup keystone" do
  protocol keystone_settings["protocol"]
  insecure keystone_settings["insecure"]
  host keystone_settings["internal_url_host"]
  port keystone_settings["admin_port"]
  auth register_auth_hash
  action :wakeup
end

keystone_register "register ironic service" do
  protocol keystone_settings["protocol"]
  insecure keystone_settings["insecure"]
  host keystone_settings["internal_url_host"]
  port keystone_settings["admin_port"]
  auth register_auth_hash
  service_name "ironic"
  service_type "baremetal"
  service_description "Ironic baremetal provisioning service"
  action :add_service
end

public_endpoint = "#{api_protocol}://#{my_public_host}:#{api_port}"
admin_endpoint = "#{api_protocol}://#{my_admin_host}:#{api_port}"
internal_endpoint = admin_endpoint

keystone_register "register ironic endpoint" do
  protocol keystone_settings["protocol"]
  insecure keystone_settings["insecure"]
  host keystone_settings["internal_url_host"]
  port keystone_settings["admin_port"]
  auth register_auth_hash
  endpoint_service "ironic"
  endpoint_region keystone_settings["endpoint_region"]
  endpoint_publicURL public_endpoint
  endpoint_adminURL admin_endpoint
  endpoint_internalURL internal_endpoint
  action :add_endpoint_template
end

keystone_register "register ironic user" do
  protocol keystone_settings["protocol"]
  insecure keystone_settings["insecure"]
  host keystone_settings["internal_url_host"]
  port keystone_settings["admin_port"]
  auth register_auth_hash
  user_name keystone_settings["service_user"]
  user_password keystone_settings["service_password"]
  tenant_name keystone_settings["service_tenant"]
  action :add_user
end

keystone_register "give ironic user admin role in service tenant" do
  protocol keystone_settings["protocol"]
  insecure keystone_settings["insecure"]
  host keystone_settings["internal_url_host"]
  port keystone_settings["admin_port"]
  auth register_auth_hash
  user_name keystone_settings["service_user"]
  tenant_name keystone_settings["service_tenant"]
  role_name "admin"
  action :add_access
end

keystone_register "give ironic user _member_ role in service tenant" do
  protocol keystone_settings["protocol"]
  insecure keystone_settings["insecure"]
  host keystone_settings["internal_url_host"]
  port keystone_settings["admin_port"]
  auth register_auth_hash
  user_name keystone_settings["service_user"]
  tenant_name keystone_settings["service_tenant"]
  role_name "_member_"
  action :add_access
end

template "/etc/ironic/ironic.conf" do
  source "ironic.conf.erb"
  owner "root"
  group node[:ironic][:group]
  mode "0640"
  variables(
    debug: node[:ironic][:debug],
    verbose: node[:ironic][:verbose],
    rabbit_settings: fetch_rabbitmq_settings,
    keystone_settings: keystone_settings,
    glance_settings: glance_settings,
    neutron_settings: neutron_settings,
    database_connection: db_connection,
    ironic_ip: node.ipaddress,
    tftp_ip: ironic_net_ip,
    public_endpoint: public_endpoint,
    api_port: api_port,
    auth_version: auth_version
  )
end

service "ironic-api" do
  service_name node[:ironic][:api][:service_name]
  supports status: true, restart: true
  action [:enable, :start]
  subscribes :restart, resources("template[/etc/ironic/ironic.conf]")
end

service "ironic-conductor" do
  service_name node[:ironic][:conductor][:service_name]
  supports status: true, restart: true
  action [:enable, :start]
  subscribes :restart, resources("template[/etc/ironic/ironic.conf]")
end

execute "ironic-dbsync" do
  user node[:ironic][:user]
  group node[:ironic][:group]
  command "ironic-dbsync"
  # We only do the sync the first time
  only_if { !node[:ironic][:db_synced] }
end

# We want to keep a note that we've done db_sync, so we don't do it again.
# If we were doing that outside a ruby_block, we would add the note in the
# compile phase, before the actual db_sync is done (which is wrong, since it
# could possibly not be reached in case of errors).
ruby_block "mark node for ironic-dbsync" do
  block do
    node.set[:ironic][:db_synced] = true
    node.save
  end
  action :nothing
  subscribes :create, "execute[ironic-dbsync]", :immediately
end

node.save
