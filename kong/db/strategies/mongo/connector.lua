local log = require "kong.cmd.utils.log"
local mongo = require "mongo"

local ngx = ngx
local fmt           = string.format


local MongoConnector   = {}
MongoConnector.__index = MongoConnector

function build_url(config)
  local url = "mongodb://"
  if config.mongo_user and config.mongo_password then
    url = url .. fmt("%s:%s@", config.mongo_user, config.mongo_password)
  end
  url = url .. fmt("%s:%s/?authSource=%s",
    config.mongo_host,
    config.mongo_port,
    config.mongo_database
  )
  print('url: %s', url)
  return url
end

function MongoConnector.new(kong_config)
  local dns_tools = require "kong.tools.dns"
  local dns = dns_tools(kong_config)

  local config = {
    database          = kong_config.mongo_database
  }

  -- check if endpoint is reachable
  local endpoint = kong_config.mongo_host
  local host, err, try_list = dns.toip(endpoint)
  if not host then
    log.error("[mongo] DNS resolution failed for endpoint '%s': %s. Tried: %s", endpoint, err, tostring(try_list))
    return nil
  else
    log.debug("resolved Mongo endpoint '%s' to: %s", endpoint, host)
  end

  if kong_config.mongo_password == 'NONE' then
    log.error("[mongo] could not authenticate against the database - missing password.")
    return nil
  end


  local url = build_url(kong_config)
  local client = mongo.Client(url)

  local database = client:getDatabase('mtasDB')
  local collection = database:getCollection('magprofiles')

  --TEST INSERT
  --local insert = fmt('{ "correlationHandle": "%s" }', math.random(10))
  --collection:insert(insert)

  --TEST SELECT
  --local query = mongo.BSON '{}'
  --for document in collection:find(query):iterator() do
  --    print(fmt('cH: %s', document.correlationHandle))
  --end

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
    db_desc     = "database",
    db_ver      = db_ver or "unknown",
  }
end


return MongoConnector
