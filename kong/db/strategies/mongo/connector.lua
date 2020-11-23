local log         = require "kong.cmd.utils.log"
local mongo       = require "mongo"
local stringx     = require "pl.stringx"
local cjson       = require "cjson"

local fmt         = string.format
local concat      = table.concat
local insert      = table.insert


local MongoConnector   = {}
MongoConnector.__index = MongoConnector

local function dump(o)
  if type(o) == 'table' then
    local s = '{ '
    for k,v in pairs(o) do
      if type(k) ~= 'number' then k = '"'..k..'"' end
      s = s .. k ..' = ' .. dump(v) .. ','
    end
    return s .. '} '
  else
    return tostring(o)
  end
end

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

local function get_collection_validator(client, database, collection)
  local cursor, err = client:command(database, '{"listCollections": 1}')
  if not cursor then
    return nil, err
  end

  local validator = {}
  for coll, err in cursor:iterator() do
    if coll.name ~= collection then
      goto continue
    end

    validator = coll.options.validator
    break

    ::continue::
  end
  return validator
end

-- removes all keys that match 'key' on 'table'
local function remove_deep_key (table, key)
  for k in pairs(table) do
    if type(table[k]) == 'table' then
      remove_deep_key(table[k], key)
    elseif table[key] then
      table[key] = nil
    end
  end
  return table
end

local function update_validator(current, changes)
  -- bugfix: required array comes with a '__array' key, which is not parseable.
  -- need to search for '__array' at any depth, since arrays might have a required property
  remove_deep_key(current, '__array')

  for op, _ in pairs(changes) do
    if op == 'set' then

      local updates = changes.set
      for name, upd in pairs(updates) do
        current["$jsonSchema"].properties[name] = upd
      end

    elseif op == 'del' then

      local deletions = changes.del
      for _, name in ipairs(deletions) do
        current["$jsonSchema"].properties[name] = nil
      end

    end
  end
  --log.debug(dump(current["$jsonSchema"]))
  return current
end

-- specific to 'schema_meta' records
local function convert_schema_meta(userdata)
  local record, records = {}
  for rec in userdata:iterator() do
    record.key = rec.key
    record.subsystem = rec.subsystem
    record.last_executed = rec.last_executed
    record.executed = rec.executed
    record.pending = rec.pending
    table.insert(records, record)
  end
  return not records and {} or records
end

local function split(str, pattern)
  local lines = {}
  for match in str:gmatch(pattern) do
    local trimmed = stringx.strip(match)
    table.insert(lines, trimmed)
  end
  return lines
end

local function removeFirst(tbl, val)
  for i, v in ipairs(tbl) do
    if v == val then
      return table.remove(tbl, i)
    end
  end
end
local remove = removeFirst

-- bugfix: when an empty table is converted to JSON, even if it's supposed to
--  be an array, it will always convert to '{}'. manual fix here
local function fix_arrays(json, keys)
  local new_json = json
  for _, key in ipairs(keys) do
    new_json = new_json:gsub(fmt('"%s":{}', key), fmt('"%s":[]', key))
  end
  return new_json
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
  self.major_minor_version = self.server_info.version

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
    return conn.client
  end

  local client, err = assert(mongo.Client(self.server_url))
  if err then
    return nil, err
  end

  local connection = {
    client = client,
    database = self.config.database
  }

  self:store_connection(connection)

  return client, self.config.database
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

function MongoConnector:setup_locks(default_locks_ttl,_)
  local connection = self:get_stored_connection()
  --print(string.format("setup_locks connection: %s", dump(connection)))
  if not connection then
    error("no connection")
  end

  local client      = connection.client
  local database    = connection.database

  local db = client:getDatabase(database)

  log.debug("creating 'locks' table if not existing...")

  local val = {
    validator = {}
  }
  val.validator["$jsonSchema"] = {
    bsonType = "object",
    required = {"key"},
    properties = {
      key = { bsonType = "string" },
      owner = { bsonType = "string" },
      ttl = { bsonType = "number", pattern = "^[0-9]{13}$" }
    }
  }
  local index = {
    createIndexes = 'locks',
    indexes = { { key = { ttl = 1 }, name = "locks_ttl_idx", expireAfterSeconds = default_locks_ttl } }
  }

  local coll, err = db:createCollection('locks', mongo.BSON(cjson.encode(val)))
  if not coll then
    return nil, err
  end

  local idx, err = client:command(database, mongo.BSON(cjson.encode(index)))
  if not idx then
    return nil, err
  end

  log.verbose("successfully created 'locks' table")

  return true
end

function MongoConnector:insert_lock(key, ttl, owner)
  local connection = self:get_stored_connection()
  --print(string.format("insert_lock connection: %s", dump(connection)))
  if not connection then
    local client, database = self:connect()
    connection = {
      client = client,
      database = database
    }
  end

  local client      = connection.client
  local database    = connection.database
  local coll_name   = 'locks'

  local collection = client:getCollection(database, coll_name)
  local res, err = collection:insert{
    key = key,
    owner = owner,
    ttl = ttl
  }
  if not res then
    return nil, err
  end

  return true
end

function MongoConnector:read_lock(key)
  local connection = self:get_stored_connection()
  --print(string.format("read_lock connection: %s", dump(connection)))
  if not connection then
    local client, database = self:connect()
    connection = {
      client = client,
      database = database
    }
  end

  local client      = connection.client
  local database    = connection.database
  local coll_name   = 'locks'

  local collection = client:getCollection(database, coll_name)
  local cursor, err = collection:find{key = key}
  if err then
    return nil, err
  end

  local res, err = cursor:value()
  if not res then
    return nil, err
  end

  return res[1] ~= nil
end

function MongoConnector:remove_lock(key, owner)
  local connection = self:get_stored_connection()
  --print(string.format("remove_lock connection: %s", dump(connection)))
  if not connection then
    local client, database = self:connect()
    connection = {
      client = client,
      database = database
    }
  end

  local client      = connection.client
  local database    = connection.database
  local coll_name   = 'locks'

  local collection = client:getCollection(database, coll_name)
  local res, err = collection:removeMany({
    key = key,
    owner = owner
  })

  if not res then
    return nil, err
  end

  return true
end

do

  local SCHEMA_META_KEY = "schema_meta"

  function MongoConnector:schema_migrations()
    local connection = self:get_stored_connection()
    if not connection then
      error("no connection")
    end

    local client      = connection.client
    local database    = connection.database

    local db = client:getDatabase(database)

    local table_names, err = db:getCollectionNames()
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


    local collection
    collection, err = assert(db:getCollection(SCHEMA_META_KEY))
    if not collection then
      return nil, err
    end

    local userdata
    userdata, err = collection:find(mongo.BSON '{}')
    if not userdata then
      return nil, err
    end

    local records = convert_schema_meta(userdata)
    for _, record in ipairs(records) do
      if record.pending == null then
        record.pending = nil
      end
    end

    return records
  end

  function MongoConnector:schema_bootstrap(_, default_locks_ttl)
    local connection = self:get_stored_connection()
    if not connection then
      error("no connection")
    end

    local client      = connection.client
    local database    = connection.database

    local val = {
      validator = {}
    }
    val.validator["$jsonSchema"] = {
      bsonType = "object",
      required = {"key","subsystem"},
      properties = {
        key = { bsonType = "string" },
        subsystem = { bsonType = "string" },
        last_executed = { bsonType = "string" },
        executed = { bsonType = "array", items = { bsonType = "string" } },
        pending = { bsonType = "array", items = { bsonType = "string" } }
      }
    }
    local val_json = cjson.encode(val)
    local db = client:getDatabase(database)
    local coll, err = db:createCollection(SCHEMA_META_KEY, mongo.BSON(val_json))
    if not coll then
      return nil, err
    end

    log.debug(fmt("successfully created %s collection", SCHEMA_META_KEY))

    -- TODO can't put 'unique' otherwise it fails on '003' by duplication
    local index = {
      createIndexes = SCHEMA_META_KEY,
      indexes = { { key = { key = 1, subsystem = 1 }, name = "primary_key" } }
    }
    local index_json = cjson.encode(index)
    local idx, err = client:command(database, mongo.BSON(index_json))
    if not idx then
      return nil, err
    end

    log.debug(fmt("set 'key' and 'subsystem' as primary key for %s", SCHEMA_META_KEY))

    local ok, err = self:setup_locks(default_locks_ttl, true)
    if not ok then
      return nil, err
    end

    return true
  end

  function MongoConnector:run_up_migration(name, up)
    if type(name) ~= "string" then
      error("name must be a string", 2)
    end

    if type(up) ~= "string" then
      error("up_sql must be a string", 2)
    end

    local connection = self:get_stored_connection()
    if not connection then
      error("no connection")
    end

    local client      = connection.client
    local database    = connection.database
    local script      = stringx.strip(up)

    local db = client:getDatabase(database)

    local tables = split(script, "([^%%]+)")
    for _, table in ipairs(tables) do
      local fields = split(table, "([^@]+)")
      local table_struct = {}
      for _, data in ipairs(fields) do
        local keyval = split(data, "([^#]+)")
        -- insert key-value pairs for 'name', 'validator' and 'index'
        table_struct[keyval[1]] = keyval[2]
      end

      local qt        = table_struct.querytype
      local val       = {}
      local idx       = {}
      if qt == 'create' then

        -- collection & validator
        do
          val = { validator = {}}
          val.validator["$jsonSchema"] = cjson.decode(table_struct.validator or '{}')
          local _, err = db:createCollection(table_struct.name, mongo.BSON(cjson.encode(val)))
          if err then
            return nil, err
          end

        end

        -- indexes
        do
          idx = {
            createIndexes = table_struct.name,
            indexes = {}
          }
          idx.indexes = cjson.decode(table_struct.index or '{}')
          local _, err = client:command(database, mongo.BSON(cjson.encode(idx)))
          if err then
            return nil, err
          end
        end

      elseif qt == 'update' then

        -- validator
        do
          local current_validator = get_collection_validator(client, database, table_struct.name)
          local new_validator = update_validator(current_validator, cjson.decode(table_struct.validator or '{}'))
          local query = {
            collMod = table_struct.name,
            validator = new_validator,
          }
          -- https://docs.mongodb.com/manual/reference/command/collMod/
          local _, err = client:command(database, mongo.BSON(cjson.encode(query)))
          if err then
            return nil, err
          end

        end

        -- indexes
        do
          local index_changes = cjson.decode(table_struct.index or '{}')
          if index_changes.set then
            idx = {
              createIndexes = table_struct.name,
              indexes = index_changes.set
            }
            local index, err = client:command(database, mongo.BSON(cjson.encode(idx)))

            if not index then
              return nil, err
            end
          elseif index_changes.del then
            -- TODO for now only hiding indexes, but must drop them
            for _, name in ipairs(index_changes.del) do
              local query = {
                collMod = table_struct.name,
                index = {
                  name = name,
                  hidden = true
                }
              }
              local _, err = client:command(database, mongo.BSON(cjson.encode(query)))
              if err then
                return nil, err
              end
            end
          end

        end

      end
    end

    return true
  end

  function MongoConnector:record_migration(subsystem, name, state)
    if type(subsystem) ~= "string" then
      error("subsystem must be a string", 2)
    end

    if type(name) ~= "string" then
      error("name must be a string", 2)
    end

    local connection = self:get_stored_connection()
    if not connection then
      error("no connection")
    end

    local client      = connection.client
    local database    = connection.database
    local collection  = client:getCollection(database, SCHEMA_META_KEY)
    local where = { key = SCHEMA_META_KEY, subsystem = subsystem }

    local cursor, err = collection:find(where)
    if err then
      return nil, err
    end
    local migration = cursor:value()
    local executed
    local pending

    if not migration then
      executed = {}
      pending = {}
    else
       executed = migration.executed and remove_deep_key(migration.executed, '__array') or {}
       pending = migration.pending and remove_deep_key(migration.pending, '__array') or {}
    end

    local set = where

    if state == 'executed' then
      insert(executed,  name )
      set.last_executed = name
      set.executed = executed
    elseif state == 'pending' then
      insert(pending,  name )
      set.pending = pending
    elseif state == 'teardown' then
      remove(pending,  name )
      insert(executed,  name )
      set.pending = pending
      set.executed = executed
    else
      error("unknown 'state' argument: " .. tostring(state))
    end

    local res
    -- bugfix: converting empty tables to empty arrays is not possible
    set = fix_arrays(cjson.encode(set), { "executed", "pending" })
    where = cjson.encode(where)
    --print(string.format("\n\n\nwhere: %s \n\n\n set: %s \n\n\n", where, set))
    res, err = collection:update(where, set, { upsert = true })
    if not res then
      return nil, err
    end

    return true
  end
end

return MongoConnector
