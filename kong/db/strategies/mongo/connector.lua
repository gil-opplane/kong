local log   = require "kong.cmd.utils.log"
local mongo = require "mongo"

local fmt          = string.format


local MongoConnector   = {}
MongoConnector.__index = MongoConnector

local function build_url(config)
  local url = "mongodb://"
  if config.user and config.password then
    url = url .. fmt("%s:%s@", config.user, config.password)
  end

  local size = #config.endpoints
  if size > 1 then
    for i, ep in config.endpoints do
      url = url .. fmt("%s:%s%s", ep, config.port,  i ~= size and "," or "/")
    end
  else
    url = url .. fmt("%s:%s/", config.endpoints[0], config.port)
  end

  url = url .. fmt ("?authSource=%s", config.auth_db)
  if not config.type == "shard" and config.replica_set then
    url = url .. fmt ("&replicaSet=%s", config.replica_set)
  end

  log.debug("Mongo connection string resolved as '%s'", url)
  return url
end

local function get_server_info(client, database)
  return assert(client:command(database, '{"buildInfo":1}')):value()
end

local function get_collection_names(connection, database)
  local db, err = assert(connection:getDatabase(database))
  if not db then
    return nil, err
  end
  return assert(db:getCollectionNames())
end

local function get_collection(connection, name)
  local query = mongo.BSON '{}'
  local collection, err = assert(connection:getCollection(name))
  if not collection then
    return nil, err
  end
  return assert(collection:find(query))
end

local function create_collection(connection, database, name, opts)
  local db = connection:getDatabase(database)
  return assert(db:createCollection(name, opts))
end

local function create_index(connection, database, index_query)
  return assert(connection:command(database, mongo.BSON(index_query)))
end

function MongoConnector.new(kong_config)
  local resolved_endpoints = {}
  local dns_tools = require "kong.tools.dns"
  local dns = dns_tools(kong_config)

  local hosts = kong_config.mongo_shard_hosts and kong_config.mongo_shard_hosts or kong_config.mongo_hosts
  local host_type = kong_config.mongo_shard_hosts and 'shard' or 'standalone'

  if (type(hosts) == 'table') then
    for i, endpoint in ipairs(hosts) do
      local ip, err, try_list = dns.toip(cp)
      if not ip then
        log.error("[mongo] DNS resolution failed for endpoint '%s': %s. Tried: %s", endpoint, err, tostring(try_list))
      else
        log.debug("resolved Mongo endpoint '%s' to: %s", endpoint, host)
        resolved_endpoints[i] = ip
      end
    end
    if #resolved_endpoints == 0 then
      return nil, "could not resolve any of the provided Mongo " ..
        "endpoints (hosts = '" ..
        table.concat(hosts, ", ") .. "')"
    end
  else
    local ip, err, try_list = dns.toip(hosts)
    if not ip then
      log.error("[mongo] DNS resolution failed for endpoint '%s': %s. Tried: %s", hosts, err, tostring(try_list))
      return nil, "could not resolve any of the provided Mongo " ..
        "endpoints (hosts = '" .. hosts .. "')"
    else
      log.debug("resolved Mongo endpoint '%s' to: %s", hosts, ip)
      resolved_endpoints[0] = ip
    end
  end

  local config = {
    endpoints         = resolved_endpoints,
    port              = kong_config.mongo_port,
    type              = host_type,
    user              = kong_config.mongo_user,
    password          = kong_config.mongo_password,
    auth_db           = kong_config.mongo_auth_database,
    database          = kong_config.mongo_database,
    replica_set       = kong_config.mongo_replica_set,
  }

  if kong_config.mongo_password == 'NONE' then
    log.error("[mongo] could not authenticate against the database - missing password.")
    return nil
  end


  local url = build_url(config)

  local self = {
    config      = config,
    server_url  = url,
  }

  return setmetatable(self, MongoConnector)
end

function MongoConnector:init()
  local client, err = assert(mongo.Client(self.server_url))
  if err then
    return nil, err
  end

  local info = get_server_info(client, self.config.database)
  self.server_info = info

  return true
end

function MongoConnector:init_worker(_)
  -- still have to understand wtf this does
  print('(MongoConnector.init_worker) To Do')
end

function MongoConnector:infos()
  local db_ver
  if self.server_info then
    db_ver = self.server_info.version
  end

  return {
    strategy    = "MongoDB",
    db_name     = self.config.database,
    db_desc     = "database",
    db_ver      = db_ver or "unknown",
  }
end

function MongoConnector:connect()
  local conn = self:get_stored_connection()
  if conn then
    return conn
  end

  local client, err = assert(mongo.Client(self.server_url))
  if err then
    return nil, err
  end

  self:store_connection(client)

  return client
end

function MongoConnector:connect_migrations()
  -- here we should have in consideration replica sets and shards (check cassandra)
  return self:connect()
end

function MongoConnector:close()
  local conn = self:get_stored_connection()
  if conn then
    self:store_connection(nil)
    if err then
      return nil, err
    end
  end

  return true
end

function MongoConnector:setup_locks(_,_)
  local conn = self:get_stored_connection()
  if not conn then
    error("no connection")
  end

  log.debug("creating 'locks' table if not existing...")
  local coll, err = create_collection(conn, self.config.database, 'locks', [[{
      "validator": {
        "$jsonSchema": {
          "bsonType": "object",
          "required": ["key"],
          "properties": {
            "key": { "bsonType": "string" },
            "owner": { "bsonType": "string" },
            "ttl": { "bsonType": "timestamp" }
          }
        }
      }
    }]])
  if not coll then
    return nil, err
  end

  local query = fmt([[{
      "createIndexes": "locks",
      "indexes": [
        { "key": { "ttl": 1 }, "name": "locks_ttl_idx" }
      ]
    }]], SCHEMA_META_KEY)
  local idx
  idx, err = create_index(conn, self.config.database, query)
  if not idx then
    return nil, err
  end

  logger.debug("successfully created 'locks' table")

  return true
end

function MongoConnector:insert_lock(key, ttl, owner)
  -- TODO

  return true
end

function MongoConnector:read_lock(key)
  -- TODO

  return true
end

function MongoConnector:remove_lock(key, owner)
  -- TODO

  return true
end

do

  local SCHEMA_META_KEY = "schema_meta"

  function MongoConnector:schema_migrations()
    local conn = self:get_stored_connection()
    if not conn then
      error("no connection")
    end

    local table_names, err = get_collection_names(conn, self.config.database)
    if not table_names then
      return nil, err
    end

    local schema_meta_table_exists
    for _, name in ipairs(table_names) do
      if name == SCHEMA_META_KEY then
        schema_meta_table_exists = true
        break
      end
    end

    if not schema_meta_table_exists then
      -- no 'schema_meta' table available, needs bootstrap
      return nil
    end

    local db = conn:getDatabase(self.config.database)

    local records
    records, err = get_collection(db, SCHEMA_META_KEY)
    if not records then
      return nil, err
    end

    --local it = records:iterator()
    --for record in it do
    --  print(fmt('record: %s', record.correlationHandle))
    --end

    for record in records:iterator() do
      if record.pending == null then
        record.pending = nil
      end
    end

    return records
  end

  function MongoConnector:schema_bootstrap(_, default_locks_ttl)
    local conn = self:get_stored_connection()
    if not conn then
      error("no connection")
    end

    -- TODO add authz - postgres/connector.lua l.759

    local coll, err = create_collection(conn, self.config.database, SCHEMA_META_KEY, [[{
      "validator": {
        "$jsonSchema": {
          "bsonType": "object",
          "required": ["key","subsystem"],
          "properties": {
            "key": { "bsonType": "string" },
            "subsystem": { "bsonType": "string" },
            "last_executed": { "bsonType": "string" },
            "executed": { "bsonType": "array", "items": { "bsonType": "string" } },
            "pending": { "bsonType": "array", "items": { "bsonType": "string" } }
          }
        }
      }
    }]])
    if not coll then
      return nil, err
    end

    log.debug(fmt("successfully created %s collection", SCHEMA_META_KEY))

    local query = fmt([[{
      "createIndexes": "%s",
      "indexes": [
        { "key": { "key": 1, "subsystem": 1 }, "name": "primary_key", "unique": true }
      ]
    }]], SCHEMA_META_KEY)
    local idx
    idx, err = create_index(conn, self.config.database, query)
    if not idx then
      return nil, err
    end

    log.debug(fmt("set 'key' and 'subsystem' as primary key for %s", SCHEMA_META_KEY))

    local ok
    ok, err = self:setup_locks(default_locks_ttl, true)
    if not ok then
      return nil, err
    end

    return true
  end

end

return MongoConnector
