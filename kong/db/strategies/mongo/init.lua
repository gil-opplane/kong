local iteration = require "kong.db.iteration"
local cjson     = require "cjson"
local mongo       = require "mongo"

local fmt           = string.format
local rep           = string.rep
local sub           = string.sub
local byte          = string.byte
local null          = ngx.null
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

local function chain(obj, f_table)
  for _, fn in ipairs(f_table) do
    if type(fn) ~= 'table' then
      obj = fn(obj)
    else
      local args = fn
      fn = table.remove(args, 1)
      obj = fn(obj, args)
    end
  end
  return obj
end

local function to_bson(tbl)
  return chain(tbl, {cjson.encode, mongo.BSON})
end

local function serialize_arg(field, arg, ws_id)
  local serialized_arg

  if arg == null then
    serialized_arg = null

  elseif field.type == "string" then
    local _arg = arg
    if field.unique and ws_id and not field.unique_across_ws then
      _arg = ws_id .. ":" .. arg
    end
    serialized_arg = _arg

  elseif field.type == "array" then
    local t = {}
    for i = 1, #arg do
      t[i] = serialize_arg(field.elements, arg[i], ws_id)
    end
    serialized_arg = #t == 0 and null or t

  elseif field.type == "set" then
    local t = {}
    for i = 1, #arg do
      t[i] = serialize_arg(field.elements, arg[i], ws_id)
    end

    serialized_arg = #t == 0 and null or t

  elseif field.type == "map" then
    local t = {}
    for k, v in pairs(arg) do
      t[k] = serialize_arg(field.values, arg[k], ws_id)
    end
    serialized_arg = #t == 0 and null or t

  elseif field.type == "record" then
    serialized_arg = arg

  elseif field.type == "foreign" then
    local fk_pk = field.schema.primary_key[1]
    local fk_field = field.schema.fields[fk_pk]
    serialized_arg = serialize_arg(fk_field, arg[fk_pk], ws_id)

  else
    serialized_arg = arg

  end

  return serialized_arg
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
  local client, err = assert(mongo.Client(connector.server_url))
  if err then
    return nil, err
  end
  local database = connector.config.database

  local connection = {
    client = client,
    database = database
  }

  local self = {
    connection = connection,
    connector = connector, -- instance of kong.db.strategies.mongo.init
    schema = schema,
    errors = errors,
    foreign_keys_db_columns = {},
  }


  -- foreign keys constraints and page_for_ selector methods

  for field_name, field in schema:each_field() do
    if field.type == "foreign" then
      local foreign_schema = field.schema
      local foreign_pk     = foreign_schema.primary_key
      local foreign_pk_len = #foreign_pk
      local db_columns     = {}

      for i = 1, foreign_pk_len do
        for foreign_field_name, foreign_field in foreign_schema:each_field() do
          if foreign_field_name == foreign_pk[i] then
            table.insert(db_columns, {
              col_name           = field_name .. "_" .. foreign_pk[i],
              foreign_field      = foreign_field,
              foreign_field_name = foreign_field_name,
            })
          end
        end
      end

      local db_columns_args_names = {}

      for i = 1, #db_columns do
        -- keep args_names for 'page_for_*' methods
        db_columns_args_names[i] = db_columns[i].col_name .. " = ?"
      end

      db_columns.args_names = concat(db_columns_args_names, " AND ")

      self.foreign_keys_db_columns[field_name] = db_columns
    end
  end

  -- generate page_for_ method for inverse selection
  -- e.g. routes:page_for_service(service_pk)
  for field_name, field in schema:each_field() do
    if field.type == "foreign" then

      local method_name = "page_for_" .. field_name
      local db_columns = self.foreign_keys_db_columns[field_name]

      local select_foreign_bind_args = {}
      for _, foreign_key_column in ipairs(db_columns) do
        table.insert(select_foreign_bind_args, foreign_key_column.col_name .. " = ?")
      end

      self[method_name] = function(self, foreign_key, size, offset, options)
        return self:page(size, offset, options, foreign_key, db_columns)
      end
    end
  end
  return setmetatable(self, _mt)
end

-- insertion
do
  function _mt:insert(entity, options)
    local schema = self.schema
    local ttl = schema.ttl and options and options.ttl
    local collection_name = self.schema.name
    local client = self.connection.client
    local database = self.connection.database

    local collection = client:getCollection(database, collection_name)

    local has_ws_id, ws_id, err = check_workspace(self, options, false)
    if err then
      return nil, err
    end

    -- TODO [M] missing tag logic (l.870)

    -- TODO [M] ttl logic? (l.887)

    -- TODO [M] create query (with composite key?) (l.904)
    local query = {
      partition = collection_name
    }
    -- TODO [M] check uniqueness and fkeys (l.904)
    for field_name, field in schema:each_field() do
      if field.type ~= 'foreign' then
        local value = serialize_arg(field, entity[field_name], ws_id)
        if value ~= null then
          query[field_name] = value
        end
      end
    end
    local res, err = collection:insert(query)
    if not res then
      return nil, err
    end

    local _res = query
    if has_ws_id then
      _res.ws_id = ws_id
    end
    return _res
  end
end

-- selection
do
  function _mt:select(primary_key, options)
    local schema = self.schema
    local collection_name = self.schema.name
    local client = self.connection.client
    local database = self.connection.database


    local _, ws_id, err = check_workspace(self, options, false)
    if err then
      return nil, err
    end

    --print(fmt("\n\n\nprimary_key: %s\n\n\n", dump(primary_key)))
    local where = {}
    for field_name, field in pairs(primary_key) do
      where[field_name] = serialize_arg(field, primary_key[field_name], ws_id)
    end

    local collection = client:getCollection(database, collection_name)
    local cursor, err = collection:find(where)
    if not cursor then
      return nil, self.errors:database_error("could not execute selection query: " .. err)
    end

    local rows = {}
    for record in cursor:iterator() do
      table.insert(rows, record)
    end
    --print(fmt("\n\n\nrows: %s\n\n\n", dump(rows)))

    local row = rows[1]
    if not row then
      return nil
    end

    if row.ws_id and ws_id and row.ws_id ~= ws_id then
      return nil
    end
    return row
  end

  function _mt:select_by_field(field_name, field_value, options)
    print(fmt("\n\nfield_name: %s\n\nfield_value: %s\n\noptions: %s\n\n", field_name, field_value, dump(options)))
    return {}
  end
end

-- deletion
do
  function _mt:delete(primary_key, options)
    --print(fmt("\n\n\n\nprimarykey: %s\n\n\n\n", dump(primary_key)))
    local schema = self.schema
    local ttl = schema.ttl and options and options.ttl
    local collection_name = self.schema.name
    local client = self.connection.client
    local database = self.connection.database


    local _, ws_id, err = check_workspace(self, options, false)
    if err then
      return nil, err
    end

    if collection_name == "workspaces" then
      ws_id = primary_key.id
    end

    local constraints = schema:get_constraints()
    --print(fmt("\n\n\n\nconstraints: %s\n\n\n\n", dump(constraints)))
    for i = 1, #constraints do
      -- TODO [M] check fkeys
    end

    local where = {}
    for field_name, field in pairs(primary_key) do
      where[field_name] = serialize_arg(field, primary_key[field_name], ws_id)
    end

    local collection = client:getCollection(database, collection_name)
    local deleted, err = collection:removeMany(where)
    if not deleted then
      return nil, self.errors:database_error("could not execute selection query: " .. err)
    end

    return true

  end
end

-- update
do

  local function update(self, primary_key, entity, mode, options)
    local schema = self.schema
    local ttl = schema.ttl and options and options.ttl
    local collection_name = self.schema.name
    local client = self.connection.client
    local database = self.connection.database

    local collection = client:getCollection(database, collection_name)

    local _, ws_id, err = check_workspace(self, options, false)
    if err then
      return nil, err
    end

    local where = { partition = schema.name }
    for field_name, field in pairs(primary_key) do
      where[field_name] = serialize_arg(field, primary_key[field_name], ws_id)
    end

    local set = {}
    set["$set"] = {}
    -- TODO [M] check uniqueness and fkeys
    for field_name, field in schema:each_field() do
      if field.type ~= 'foreign' then
        local value = serialize_arg(field, entity[field_name], ws_id)
        if value ~= null then
          set["$set"][field_name] = value
        end
      end
    end

    set["$set"].id = nil

    local res, err = collection:update(where, set, { upsert = mode == "upsert" })
    if not res then
      return nil, self.errors:database_error("could not execute update query: "
        .. err)
    end

    local row, err_t = self:select(primary_key, { workspace = ws_id or null })
    if err_t then
      return nil, err_t
    end

    if not row then
      return nil, self.errors:not_found(primary_key)
    end

    return row
  end

  function _mt:update(primary_key, entity, options)
    return update(self, primary_key, entity, "update", options)
  end

  function _mt:upsert(primary_key, entity, options)
    return update(self, primary_key, entity, "upsert", options)
  end
end

-- pagination
do
  local function execute_page(self, collection, where, offset, opts)
    local cursor, err = collection:find(where, {
      limit = opts.page_size,
      skip = tonumber(offset) or 0
    })

    if not cursor then
      if err:match("Invalid value for the paging state") then
        return nil, self.errors:invalid_offset(offset, err)
      end
      return nil, self.errors:database_error("could not execute page query: " .. err)
    end

    local next_offset = opts.paging_state

    return cursor, nil, next_offset
  end

  local function query_page(self, offset, foreign_key, foreign_key_db_columns, opts)
    local client      = self.connection.client
    local database    = self.connection.database

    local _, ws_id, err = check_workspace(self, opts, true)
    if err then
      return nil, err
    end

    local collection  = client:getCollection(database, self.schema.name)

    local where = {}
    local rows = {}

    if ws_id then
      where = { ws_id = ws_id }
    end

    local cursor, err_t, next_offset = execute_page(self, collection, where, offset, opts)
    if err_t then
      return nil, err_t
    end

    for record in cursor:iterator() do
      table.insert(rows, record)
    end

    --print(fmt("rows: %s\n\n", dump(rows)))
    return rows, nil, next_offset and encode_base64(next_offset)
  end

  function _mt:page(size, offset, options, foreign_key, foreign_key_db_columns)
    --print(fmt("\n\nsize: %s\n\noffset: %s\n\noptions: %s\n\nfk: %s\n\nfkdbc: %s\n\n", size, offset, dump(options), foreign_key, dump(foreign_key_db_columns)))
    local opts = {}
    if not size then
      size = self.connector:get_page_size(options)
    end

    if offset then
      local offset_decoded = decode_base64(offset)
      if not offset_decoded then
        return nil, self.errors:invalid_offset(offset, "bad base64 encoding")
      end

      offset = offset_decoded
    end

    opts.page_size = size
    opts.paging_state = offset
    opts.workspace = options and options.workspace

    --if options and options.tags then
    --  return query_page_for_tags(self, size, offset, options.tags, options.tags_cond, opts)
    --end

    return query_page(self, offset, foreign_key, foreign_key_db_columns, opts)
  end

end

return _M
