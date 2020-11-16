local log = require "kong.cmd.utils.log"
local mongo = require "mongo"

local ngx = ngx
local fmt           = string.format


local MongoConnector   = {}
MongoConnector.__index = MongoConnector

function build_url(config)
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
    db                = kong_config.mongo_database,
    collection        = kong_config.mongo_collection,
    replica_set       = kong_config.mongo_replica_set,
  }

  if kong_config.mongo_password == 'NONE' then
    log.error("[mongo] could not authenticate against the database - missing password.")
    return nil
  end


  local url = build_url(config)
  local client = mongo.Client(url)

  local database = client:getDatabase(kong_config.mongo_database)
  local collection = database:getCollection(kong_config.mongo_collection)

  --TEST INSERT
  --local insert = fmt('{ "correlationHandle": "%s" }', math.random(10))
  --collection:insert(insert)

  --TEST SELECT
  local query = mongo.BSON '{}'
  for document in collection:find(query):iterator() do
      print(fmt('cH: %s', document.correlationHandle))
  end

  local self = {
    config    = config,
  }

  return setmetatable(self, MongoConnector)
end

function MongoConnector:infos()
  --local db_ver
  --if self.major_minor_version then
  --  db_ver = match(self.major_minor_version, "^(%d+%.%d+)")
  --end

  return {
    strategy    = "MongoDB",
    db_name     = self.config.database,
    db_schema   = self.config.collection,
    db_desc     = "database",
    db_ver      = db_ver or "unknown",
  }
end


return MongoConnector
