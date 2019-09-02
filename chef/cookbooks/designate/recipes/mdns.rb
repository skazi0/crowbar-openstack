# Copyright 2018 SUSE Linux GmbH
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
# Cookbook Name:: designate
# Recipe:: api
#

require "yaml"

dns_all = node_search_with_cache("roles:dns-server")
dns = dns_all.first
dnsmaster = dns[:dns][:master_ip]
dnsslaves = dns[:dns][:slave_ips].to_a
dnsservers = [dnsmaster] + dnsslaves

network_settings = DesignateHelper.network_settings(node)

# One could have multiple pools in designate. And
# designate needs to have a default pool, this pools
# id is hardcoded in the designate conf. By reusing that
# id we let designate know how crowbar's deployement of
# dns servers looks like.
# This pool id can be generated by in proposal, but this will change
# with every delete/create cycle of proposal. This might mess
# up the designate configuration. So the advantage of having
# non-hardcoded is high enough

ns_records = dns_all.map { |dnss| { "hostname" => "public-#{dnss[:fqdn]}.", "priority" => 1 } }
pools = [{
  "name" => "default-bind",
  "description" => "Default BIND9 Pool",
  "id" => "794ccc2c-d751-44fe-b57f-8894c9f5c842",
  "attributes" => {},
  "ns_records" => ns_records,
  "nameservers" => dnsservers.map { |ip| { "host" => ip, "port" => 53 } },
  "also_notifies" => dnsslaves.map { |ip| { "host" => ip, "port" => 53 } },
  "targets" => [{
    "type" => "bind9",
    "description" => "BIND9 Server 1",
    "masters" => [{ "host" => network_settings[:mdns_bind_host], "port" => 5354 }],
    "options" => {
      "host" => dnsmaster,
      "port" => 53,
      "rndc_host" => dnsmaster,
      "rndc_port" => 953,
      "rndc_key_file" => "/etc/designate/rndc.key"
    }
  }]
}]

file "/etc/designate/pools.crowbar.yaml" do
  owner "root"
  group node[:designate][:group]
  mode "0640"
  content pools.to_yaml
  not_if { ::File.exist?("/etc/designate/pools.crowbar.yaml") }
end

template "/etc/designate/rndc.key" do
  source "rndc.key.erb"
  owner "root"
  group node[:designate][:group]
  mode "0640"
  variables(rndc_key: dns[:dns][:designate_rndc_key])
end

ha_enabled = node[:designate][:ha][:enabled]

execute "designate-manage pool update" do
  command "designate-manage pool update --file /etc/designate/pools.crowbar.yaml"
  user node[:designate][:user]
  group node[:designate][:group]
  # We only do the pool update the first time, and only if we're not doing HA or if we
  # are the founder of the HA cluster (so that it's really only done once).
  only_if do
    !node[:designate][:pool_updated] &&
      (!ha_enabled || CrowbarPacemakerHelper.is_cluster_founder?(node))
  end
end

# We want to keep a note that we've done a pool update, so we don't do it again.
# If we were doing that outside a ruby_block, we would add the note in the
# compile phase, before the actual pool update is done (which is wrong, since it
# could possibly not be reached in case of errors).
ruby_block "mark node for designate-manage pool update" do
  block do
    node.set[:designate][:pool_updated] = true
    node.save
  end
  action :nothing
  subscribes :create, "execute[designate-manage pool update]", :immediately
end

designate_service "mdns"
