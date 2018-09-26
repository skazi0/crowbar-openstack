#
# Copyright 2014, SUSE
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

class Chef
  class Recipe
    # Helpers wrapping CrowbarOpenStackHelper, provided for convenience for
    # direct calls from recipes.
    # We prefix the method names with "fetch_" because the return value should
    # still be put in a local variable (to avoid spamming the logs).
    def fetch_database_settings(barclamp=@cookbook_name)
      CrowbarOpenStackHelper.database_settings(node, barclamp)
    end

    def fetch_database_connection_string(db_auth, barclamp = @cookbook_name)
      db_settings = CrowbarOpenStackHelper.database_settings(node, barclamp)
      CrowbarOpenStackHelper.database_connection_string(db_settings, db_auth)
    end

    def fetch_rabbitmq_settings(barclamp=@cookbook_name)
      CrowbarOpenStackHelper.rabbitmq_settings(node, barclamp)
    end
  end
end

# Helpers wrapping CrowbarOpenStackHelper, provided for convenience for direct
# calls from templates.
# We prefix the method names with "fetch_" because the return value should
# still be put in a local variable (to avoid spamming the logs).
class Chef
  class Resource
    class Template
      def fetch_database_settings(barclamp=@cookbook_name)
        CrowbarOpenStackHelper.database_settings(node, barclamp)
      end

      def fetch_database_connection_string(db_auth, barclamp = @cookbook_name)
        db_settings = CrowbarOpenStackHelper.database_settings(node, barclamp)
        CrowbarOpenStackHelper.database_connection_string(db_settings, db_auth)
      end

      def fetch_rabbitmq_settings(barclamp=@cookbook_name)
        CrowbarOpenStackHelper.rabbitmq_settings(node, barclamp)
      end
    end
  end
end

class CrowbarOpenStackHelper
  def self.database_settings(node, barclamp)
    instance = node[barclamp][:database_instance] || "default"

    # Cache the result for each cookbook in an instance variable hash. This
    # cache needs to be invalidated for each chef-client run from chef-client
    # daemon (which are all in the same process); so use the ohai time as a
    # marker for that.
    if @database_settings_cache_time != node[:ohai_time]
      if @database_settings
        Chef::Log.info("Invalidating database settings cache " \
                       "on behalf of #{barclamp}")
      end
      @database_settings = nil
      @sql_engine_cache = nil
      @database_settings_cache_time = node[:ohai_time]
    end

    if ["mysql", "postgresql"].include? barclamp
      sql_engine = barclamp
    elsif @sql_engine_cache && @sql_engine_cache.include?(instance)
      sql_engine = @sql_engine_cache[instance]
    else
      db_roles, = Chef::Search::Query.new.search(
        :role,
        "name:database-config-#{instance}"
      )
      db_proposal_role = db_roles.first unless db_roles.empty?
      # TODO(jhesketh): What if db_roles is empty here?
      sql_engine = db_proposal_role.default_attributes["database"]["sql_engine"]

      @sql_engine_cache ||= {}
      @sql_engine_cache[instance] = sql_engine
    end

    if @database_settings && @database_settings.include?(instance) && @database_settings[instance].include?(sql_engine)
      Chef::Log.info("Database server found at #{@database_settings[instance][sql_engine][:address]} [cached]")
    else
      @database_settings ||= Hash.new
      db_role = if sql_engine == "postgresql"
        "database-server"
      else
        "mysql-server"
      end
      database = get_node(node, db_role, "database", instance)

      if database.nil?
        Chef::Log.warn("No database server found!")
      else
        address = CrowbarDatabaseHelper.get_listen_address(database, sql_engine)

        ssl_opts = {}
        if sql_engine == "mysql"
          ssl_opts = {
            enabled: database["database"]["mysql"]["ssl"]["enabled"],
            ca_certs: database["database"]["mysql"]["ssl"]["ca_certs"],
            insecure: database["database"]["mysql"]["ssl"]["generate_certs"] ||
              database["database"]["mysql"]["ssl"]["insecure"]
          }
        end
        @database_settings[instance] ||= {}
        @database_settings[instance][sql_engine] = {
          address: address,
          url_scheme: sql_engine,
          backend_name: sql_engine,
          provider: DatabaseLibrary::Database::Util.get_database_provider(database, sql_engine),
          user_provider: DatabaseLibrary::Database::Util.get_user_provider(database, sql_engine),
          privs: DatabaseLibrary::Database::Util.get_default_priviledges(database, sql_engine),
          connection: {
            host: address,
            username: "db_maker",
            password: database["database"][:db_maker_password],
            ssl: ssl_opts
          }
        }

        Chef::Log.info("Database server found at #{@database_settings[instance][:address]}")
      end
    end

    @database_settings[instance][sql_engine]
  end

  def self.database_connection_string(db_settings, db_auth_attr)
    db_auth = db_auth_attr.to_hash
    db_conn_scheme = db_settings[:url_scheme]
    db_charset = ""
    ssl_suffix = ""

    if db_conn_scheme == "mysql"
      db_conn_scheme = "mysql+pymysql"
      db_charset = "?charset=utf8"
      ssl = db_settings[:connection][:ssl]
      if ssl[:enabled]
        # For insecure (e.g. generated) configuration, we want to start SSL connection without
        # certificate verification.
        # This is relying on a part of sqlalchemy/pymysql code that starts SSL when just any ssl_key
        # value is present, not checking for its content.
        ssl_suffix = ssl[:insecure] ? "&ssl_key=generated" : "&ssl_ca=#{ssl[:ca_certs]}"
      end
    end

    "#{db_conn_scheme}://" \
    "#{db_auth['user']}:#{db_auth['password']}@#{db_settings[:address]}/" \
    "#{db_auth['database']}" \
    "#{db_charset}" \
    "#{ssl_suffix}"
  end

  def self.rabbitmq_settings(node, barclamp)
    instance = node[barclamp][:rabbitmq_instance] || "default"

    # Cache the result for each cookbook in an instance variable hash. This
    # cache needs to be invalidated for each chef-client run from chef-client
    # daemon (which are all in the same process); so use the ohai time as a
    # marker for that.
    if @rabbitmq_settings_cache_time != node[:ohai_time]
      if @rabbitmq_settings
        Chef::Log.info("Invalidating rabbitmq settings cache on behalf of #{barclamp}")
      end
      @rabbitmq_settings = nil
      @rabbitmq_settings_cache_time = node[:ohai_time]
    end

    if @rabbitmq_settings && @rabbitmq_settings.include?(instance)
      Chef::Log.info("RabbitMQ settings found [cached]")
    else
      @rabbitmq_settings ||= Hash.new
      rabbits = get_nodes(node, "rabbitmq-server", "rabbitmq", instance)

      if rabbits.empty?
        Chef::Log.warn("No RabbitMQ server found!")
      else
        rabbit = rabbits.first

        port = if rabbit[:rabbitmq][:ssl][:enabled]
          rabbit[:rabbitmq][:ssl][:port]
        else
          rabbit[:rabbitmq][:port]
        end

        client_ca_certs = if rabbit[:rabbitmq][:ssl][:enabled] && \
            !rabbit[:rabbitmq][:ssl][:insecure]
          rabbit[:rabbitmq][:ssl][:client_ca_certs]
        end

        single_rabbit_settings = {
          # backwards compatible attributes, remove in cloud8?
          address: rabbit[:rabbitmq][:address],
          port: port,
          user: rabbit[:rabbitmq][:user],
          password: rabbit[:rabbitmq][:password],
          vhost: rabbit[:rabbitmq][:vhost],
          # end backwards comatible attrs
          use_ssl: rabbit[:rabbitmq][:ssl][:enabled],
          client_ca_certs: client_ca_certs,
          url: "rabbit://#{rabbit[:rabbitmq][:user]}:" \
            "#{rabbit[:rabbitmq][:password]}@" \
            "#{rabbit[:rabbitmq][:address]}:#{port}/" \
            "#{rabbit[:rabbitmq][:vhost]}",
          trove_url: "rabbit://#{rabbit[:rabbitmq][:trove][:user]}:" \
            "#{rabbit[:rabbitmq][:trove][:password]}@" \
            "#{rabbit[:rabbitmq][:address]}:#{port}/" \
            "#{rabbit[:rabbitmq][:trove][:vhost]}",
          cluster: false,
          durable_queues: false,
          ha_queues: false,
          heartbeat_timeout: rabbit[:rabbitmq][:client][:heartbeat_timeout],
          pacemaker_resource: "rabbitmq"
        }

        if !rabbit[:rabbitmq][:cluster]
          @rabbitmq_settings[instance] = single_rabbit_settings
          Chef::Log.info("RabbitMQ server found")
        else
          # transport_url format:
          # https://docs.openstack.org/oslo.messaging/latest/reference/transport.html#oslo_messaging.TransportURL
          rabbit_hosts = rabbits.map do |rabbit|
            port = if rabbit[:rabbitmq][:ssl][:enabled]
              rabbit[:rabbitmq][:ssl][:port]
            else
              rabbit[:rabbitmq][:port]
            end
            url = "#{rabbit[:rabbitmq][:user]}:"
            url << "#{rabbit[:rabbitmq][:password]}@"
            url << "#{rabbit[:rabbitmq][:address]}:#{port}"
            url << "/#{rabbit[:rabbitmq][:vhost]}" if rabbit.equal? rabbits.last
            url.prepend("rabbit://") if rabbit.equal? rabbits.first

            url
          end

          trove_rabbit_hosts = rabbits.map do |rabbit|
            port = if rabbit[:rabbitmq][:ssl][:enabled]
              rabbit[:rabbitmq][:ssl][:port]
            else
              rabbit[:rabbitmq][:port]
            end

            url = "#{rabbit[:rabbitmq][:trove][:user]}:"
            url << "#{rabbit[:rabbitmq][:trove][:password]}@"
            url << "#{rabbit[:rabbitmq][:address]}:#{port}"
            url << "/#{rabbit[:rabbitmq][:trove][:vhost]}" unless rabbit.equal? rabbits.first
            url.prepend("rabbit://") if rabbit.equal? rabbits.first

            url
          end

          @rabbitmq_settings[instance] = {
            use_ssl: rabbit[:rabbitmq][:ssl][:enabled],
            client_ca_certs: client_ca_certs,
            url: rabbit_hosts.join(","),
            trove_url: trove_rabbit_hosts.join(","),
            cluster: true,
            durable_queues: true,
            ha_queues: true,
            heartbeat_timeout: rabbit[:rabbitmq][:client][:heartbeat_timeout],
            pacemaker_resource: "ms-rabbitmq"
          }
          Chef::Log.info("RabbitMQ cluster found")
        end
      end
    end

    @rabbitmq_settings[instance]
  end

  def self.insecure(attributes)
    use_ssl = if attributes.key?("api") && attributes["api"].key?("protocol")
      # aodh, cinder, glance, heat, keystone, manila, neutron
      attributes["api"]["protocol"] == "https"
    elsif attributes.key?("api") && attributes["api"].key?("ssl")
      # barbican
      attributes["api"]["ssl"]
    elsif attributes.key?("ssl") && attributes["ssl"].key?("enabled")
      # nova
      attributes["ssl"]["enabled"]
    else
      # magnum, sahara, trove
      false
    end

    use_ssl && attributes["ssl"]["insecure"]
  end

  def self.get_node(node, role, barclamp, instance)
    result = nil

    if node.roles.include?(role) && \
        node.key?(barclamp) && \
        node[barclamp].key?("config") && \
        node[barclamp]["config"]["environment"] == "#{barclamp}-config-#{instance}"
      result = node
    else
      nodes, = Chef::Search::Query.new.search(:node, "roles:#{role} AND " \
      "#{barclamp}_config_environment:#{barclamp}-config-#{instance}")
      result = nodes.first unless nodes.empty?
    end

    result
  end

  private

  def self.get_nodes(node, role, barclamp, instance)
    nodes, = Chef::Search::Query.new.search(:node, "roles:#{role} AND " \
    "#{barclamp}_config_environment:#{barclamp}-config-#{instance}")
    nodes
  end

  private_class_method :get_nodes
end
