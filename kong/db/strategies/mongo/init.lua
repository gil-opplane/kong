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
local new_tab
local clear_tab


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

function _M.new(connector, schema, errors)
  --print(fmt("\n\nconnector: %s\n\nschema: %s\n\nerrors: %s\n\n", dump(connector), dump(schema), dump(errors)))
  local self = {
    connector = connector, -- instance of kong.db.strategies.mongo.init
    schema = schema,
    errors = errors,
  }
  return setmetatable(self, _mt)
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
