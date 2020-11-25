local iteration = require "kong.db.iteration"
local cjson     = require "cjson"

local fmt           = string.format
local rep           = string.rep
local sub           = string.sub
local byte          = string.byte
local null          = ngx.null
local type          = type
local error         = error
local pairs         = pairs
local ipairs        = ipairs
local insert        = table.insert
local concat        = table.concat
local get_phase     = ngx.get_phase
local setmetatable  = setmetatable
local encode_base64 = ngx.encode_base64
local decode_base64 = ngx.decode_base64
local workspaces_strategy

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


local _M  = {}

local _mt = {}
_mt.__index = _mt

local function get_ws_id()
  local phase = get_phase()
  if phase ~= "init" and phase ~= "init_worker" then
    return ngx.ctx.workspace or kong.default_workspace
  end
end

-- Determine if a workspace is to be used, and if so, which one.
-- If a workspace is given in `options.workspace` and the entity is
-- workspaceable, it will use it.
-- If `use_null` is false (indicating the query calling this function
-- does not accept global queries) or `options.workspace` is not given,
-- then this function will obtain the current workspace UUID from
-- the execution context.
-- @tparam table schema The schema definition table
-- @tparam table option The DAO request options table
-- @tparam boolean use_null If true, accept ngx.null as a possible
-- value of options.workspace and use it to signal a global query
-- @treturn boolean,string?,table? One of the following:
--  * false, nil,  nil = entity is not workspaceable
--  * true,  uuid, nil = entity is workspaceable, this is the workspace to use
--  * true,  nil,  nil = entity is workspaceable, but a global query was requested
--  * nil,   nil,  err = database error or selected workspace does not exist
local function check_workspace(self, options, use_null)
  local workspace = options and options.workspace
  local schema = self.schema

  local ws_id
  local has_ws_id = schema.workspaceable
  if has_ws_id then
    if use_null and workspace == null then
      ws_id = nil

    elseif workspace ~= nil and workspace ~= null then
      ws_id = workspace

    else
      ws_id = get_ws_id()
    end
  end

  -- check that workspace actually exists
  if ws_id then
    if not workspaces_strategy then
      local Entity = require("kong.db.schema.entity")
      local schema = Entity.new(require("kong.db.schema.entities.workspaces"))
      workspaces_strategy = _M.new(self.connector, schema, self.errors)
    end
    local row, err_t = workspaces_strategy:select({ id = ws_id })
    if err_t then
      return nil, nil, err_t
    end

    if not row then
      return nil, nil, self.errors:invalid_workspace(ws_id)
    end
  end

  return has_ws_id, ws_id
end

function _M.new(connector, schema, errors)
  local self = {
    connector = connector, -- instance of kong.db.strategies.mongo.init
    schema = schema,
    errors = errors,
  }
  return setmetatable(self, _mt)
end

function _mt:insert(entity, options)
  local schema = self.schema
  local ttl = schema.ttl and options and options.ttl
  local collection = self.schema.name

  local has_ws_id, ws_id, err = check_workspace(self, options, false)
  if err then
    return nil, err
  end

  print(fmt("\n\n\nentity: %s\n\noptions: %s\n\n\n", dump(entity), dump(options)))
  print(fmt("\n\n\nconnector: %s\n\nschema: %s\n\n\n", dump(self.connector), dump(self.schema)))
  print(fmt("\n\n\nschema name: %s\n\n\n", self.schema.name))
  return {}
end

function _mt:select(primary_key, options)
  return {}
end

function _mt:page(size, offset, options)
  print(fmt("\n\nsize: %s\n\noffset: %s\n\noptions: %s\n\n", size, offset, dump(options)))
  return {}, nil, nil
end

function _mt:select_by_field(field_name, field_value, options)
  print(fmt("\n\nfield_name: %s\n\nfield_value: %s\n\noptions: %s\n\n", field_name, field_value, dump(options)))
  return {}
end

return _M
