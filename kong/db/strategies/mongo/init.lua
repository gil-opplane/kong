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

local cache_key_field = { type = "string" }
local ws_id_field = { type = "string", uuid = true }

local _M  = {}

local _mt = {}
_mt.__index = _mt

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

local function chain(o, f_table)
  for _, fn in ipairs(f_table) do
    if type(fn) ~= 'table' then
      o = fn(o)
    else
      local args = fn
      fn = table.remove(args, 1)
      o = fn(o, args)
    end
  end
  return o
end

local function clear_nulls(o)
  for k, v in pairs(o) do
    if v == null then
      o[k] = nil
    end
  end
  return o
end

local function to_bson(tbl, opts)
  local function empty() return tbl end
  return chain(tbl, {
    opts and opts.clear and clear_nulls or empty,
    cjson.encode,
    mongo.BSON
  })
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
      table.insert(t, serialize_arg(field.elements, arg[i], ws_id))
    end
    serialized_arg = #t == 0 and null or t

  elseif field.type == "set" then
    local t = {}
    for i = 1, #arg do
      table.insert(t, serialize_arg(field.elements, arg[i], ws_id))
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

local function deserialize_aggregates(value, field)
  if field.type == "record" then
    if type(value) == "string" then
      value = cjson.decode(value)
    end

  elseif field.type == "set" or field.type == "array" then
    if type(value) == "table" then
      value["__array"] = nil
      for i = 1, #value do
        value[i] = deserialize_aggregates(value[i], field.elements)
      end
    end
  end

  if value == nil then
    return null
  end

  return value
end

function _mt:deserialize_row(row)
  if not row then
    error("row must be a table", 2)
  end

  -- deserialize rows
  -- replace `nil` fields with `ngx.null`
  -- replace `foreign_key` with `foreign = { key = "" }`
  -- return timestamps in seconds instead of ms
  -- remove __array key from arrays

  for field_name, field in self.schema:each_field() do
    local ws_unique = field.unique and not field.unique_across_ws

    if field.type == "foreign" then
      local db_columns = self.foreign_keys_db_columns[field_name]

      local has_fk
      row[field_name] = {}

      for i = 1, #db_columns do
        local col_name = db_columns[i].col_name

        if row[col_name] ~= nil then
          row[field_name][db_columns[i].foreign_field_name] = row[col_name]
          row[col_name] = nil

          has_fk = true
        end
      end

      if not has_fk then
        row[field_name] = null
      end

    elseif field.timestamp and row[field_name] ~= nil then
      row[field_name] = row[field_name] / 1000

    elseif field.type == "string" and ws_unique and row[field_name] ~= nil then
      local value = row[field_name]
      -- for regular 'unique' values (that are *not* 'unique_across_ws')
      -- value is of the form "<uuid>:<value>" in the DB: strip the "<uuid>:"
      if byte(value, 37) == byte(":") then
        row[field_name] = sub(value, 38)
      end

    else
      row[field_name] = deserialize_aggregates(row[field_name], field)
    end
  end

  return row
end

local function get_ws_id()
  local phase = get_phase()
  if phase ~= "init" and phase ~= "init_worker" then
    return ngx.ctx.workspace or kong.default_workspace
  end
end

local function foreign_pk_exists(self, field_name, field, foreign_pk, ws_id)
  local foreign_schema = field.schema
  local foreign_strategy = _M.new(self.connector, foreign_schema,
    self.errors)

  local foreign_row, err_t = foreign_strategy:select(foreign_pk, { workspace = ws_id or null })
  if err_t then
    return nil, err_t
  end

  if not foreign_row then
    return nil, self.errors:foreign_key_violation_invalid_reference(foreign_pk,
      field_name,
      foreign_schema.name)
  end

  if ws_id and foreign_row.ws_id and foreign_row.ws_id ~= ws_id then
    return nil, self.errors:invalid_workspace(foreign_row.ws_id or "null")
  end

  return true
end

local function serialize_foreign_pk(db_columns, args, args_names, foreign_pk, ws_id)
  for _, db_column in ipairs(db_columns) do
    local to_serialize

    if foreign_pk == null then
      to_serialize = null

    else
      to_serialize = foreign_pk[db_column.foreign_field_name]
    end

    args[db_column.foreign_field_name] = serialize_arg(db_column.foreign_field, to_serialize, ws_id)

    if args_names then
      table.insert(args_names, db_column.col_name)
    end
  end
end

local function set_difference(old_set, new_set)
  local new_set_hash = {}
  for _, elem in ipairs(new_set) do
    new_set_hash[elem] = true
  end

  local old_set_hash = {}
  for _, elem in ipairs(old_set) do
    old_set_hash[elem] = true
  end

  local elem_to_add = {}
  local elem_to_delete = {}
  local elem_not_changed = {}

  for _, elem in ipairs(new_set) do
    if not old_set_hash[elem] then
      table.insert(elem_to_add, elem)
    end
  end

  for _, elem in ipairs(old_set) do
    if not new_set_hash[elem] then
      table.insert(elem_to_delete, elem)
    else
      table.insert(elem_not_changed, elem)
    end
  end

  return elem_to_add, elem_to_delete, elem_not_changed
end

local function build_tags(primary_key, schema, new_tags, rbw_entity)
  local tags_to_add, tags_to_remove, tags_not_changed

  new_tags = (not new_tags or new_tags == null) and {} or new_tags

  if rbw_entity then
    if rbw_entity and rbw_entity['tags'] and rbw_entity['tags'] ~= null then
      tags_to_add, tags_to_remove, tags_not_changed = set_difference(rbw_entity['tags'], new_tags)
    else
      tags_to_add = new_tags
      tags_to_remove = {}
      tags_not_changed = {}
    end
  else
    tags_to_add = new_tags
    tags_to_remove = {}
    tags_not_changed = {}
  end

  if #tags_to_add == 0 and #tags_to_remove == 0 then
    return nil, nil
  end
  -- Note: here we assume tags column only exists
  -- with those entities use id as their primary key
  local entity_id = primary_key['id']
  local ops = {}
  for _, tag in ipairs(tags_not_changed) do
    table.insert(ops, {
      type = 'update',
      set = { other_tags = new_tags },
      where = {tag = tag, entity_name = schema.name, entity_id = entity_id }
    })
  end
  for _, tag in ipairs(tags_to_add) do
    table.insert(ops, {
      type = 'insert',
      values = { tag = tag, entity_name = schema.name, entity_id = entity_id, other_tags = new_tags }
    })
  end
  for _, tag in ipairs(tags_to_remove) do
    table.insert(ops, {
      type = 'remove',
      where = { tag = tag, entity_name = schema.name, entity_id = entity_id }
    })
  end

  return ops, nil
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

local function check_unique(self, primary_key, entity, field_name, ws_id)
  -- a UNIQUE constaint is set on this field.
  -- We unfortunately follow a read-before-write pattern in this case,
  -- but this is made necessary for Kong to behave in a
  -- database-agnostic fashion between its supported RDBMs and
  -- Cassandra.
  local opts = { workspace = ws_id or null }
  local row, err_t = self:select_by_field(field_name, entity[field_name], opts)
  if err_t then
    return nil, err_t
  end

  if row then
    for _, pk_field_name in self.each_pk_field() do
      if primary_key[pk_field_name] ~= row[pk_field_name] then
        -- already exists
        if field_name == "cache_key" then
          local keys = {}
          local schema = self.schema
          for _, k in ipairs(schema.cache_key) do
            local field = schema.fields[k]
            if field.type == "foreign" and entity[k] ~= null then
              keys[k] = field.schema:extract_pk_values(entity[k])
            else
              keys[k] = entity[k]
            end
          end
          return nil, self.errors:unique_violation(keys)
        end

        return nil, self.errors:unique_violation {
          [field_name] = entity[field_name],
        }
      end
    end
  end

  return true
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
  --print(fmt("\n\n\nschema: %s", dump(schema)))
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

-- insert
do
  function _mt:insert(entity, options)
    local schema = self.schema
    local ttl = schema.ttl and options and options.ttl
    local has_composite_cache_key = schema.cache_key and #schema.cache_key > 1
    local collection_name = self.schema.name
    local client = self.connection.client
    local database = self.connection.database

    local collection = client:getCollection(database, collection_name)
    local tags = client:getCollection(database, "tags")

    local has_ws_id, ws_id, err = check_workspace(self, options, false)
    if err then
      return nil, err
    end

    -- tags
    local bulk_ops = {}
    local bulk_mode
    local bulk = tags:createBulkOperation{ordered = true}
    local primary_key
    if schema.fields.tags then
      primary_key = schema:extract_pk_values(entity)
      local err_t
      bulk_ops, err_t = build_tags(primary_key, schema, entity["tags"])
      if err_t then
        return nil, err_t
      end
      if bulk_ops then
        bulk_mode = true
      end
    end

    local query = {
      partition = collection_name
    }

    -- query fields
    for field_name, field in schema:each_field() do
      if field.type == "foreign" then
        local foreign_pk = entity[field_name]

        if foreign_pk ~= null then
          -- if given, check if this foreign entity exists
          local exists, err_t = foreign_pk_exists(self, field_name, field, foreign_pk, ws_id)
          if not exists then
            return nil, err_t
          end
        end

        local db_columns = self.foreign_keys_db_columns[field_name]
        serialize_foreign_pk(db_columns, query, nil, foreign_pk, ws_id)

      else
        if field.unique
          and entity[field_name] ~= null
          and entity[field_name] ~= nil
        then
          -- a UNIQUE constaint is set on this field.
          primary_key = primary_key or schema:extract_pk_values(entity)
          local _, err_t = check_unique(self, primary_key, entity, field_name, ws_id)
          if err_t then
            return nil, err_t
          end
        end
        query[field_name] = serialize_arg(field, entity[field_name], ws_id)
      end
    end
    -- TODO [M] some issue with serialize_arg - id turns to null somewhere...
    query.id = entity.id
    print(fmt("\n\n\n\nquery: %s\n\n\n\n", to_bson(query)))

    -- if composite key
    if has_composite_cache_key then
      primary_key = primary_key or schema:extract_pk_values(entity)
      local _, err_t = check_unique(self, primary_key, entity, "cache_key", ws_id)
      if err_t then
        return nil, err_t
      end
      query["cache_key"] = serialize_arg(cache_key_field, entity["cache_key"], ws_id)
    end

    -- if workspace
    if has_ws_id then
      query["ws_id"] = serialize_arg(ws_id_field, ws_id, ws_id)
    end

    -- update/create/delete tags if needed
    if bulk_mode then
      for _, op in ipairs(bulk_ops) do
        if op.type == 'update' then
          bulk:updateOne(to_bson(op.where), to_bson(op.set))
        elseif op.type == 'insert' then
          bulk:insert(to_bson(op.values))
        elseif op.type == 'remove' then
          bulk:removeOne(to_bson(op.where))
        end
      end

      local _, err = bulk:execute()
      if err then
        return nil, err
      end
    end

    -- execute insert query
    local res, err = collection:insert(to_bson(query, { clear = true }))
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

-- select
do

  local function select(self, where, ws_id)
    local collection_name = self.schema.name
    local client = self.connection.client
    local database = self.connection.database

    local collection = client:getCollection(database, collection_name)
    local cursor, err = collection:find(to_bson(where))
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

    return self:deserialize_row(row)
  end

  function _mt:select(primary_key, options)
    --print(fmt("\nSELECT:\nprimary_key: %s\noptions: %s\n\n", dump(primary_key), dump(options)))

    local _, ws_id, err = check_workspace(self, options, false)
    if err then
      return nil, err
    end

    --print(fmt("\n\n\nprimary_key: %s\n\n\n", dump(primary_key)))
    local where = {}
    for field_name, field in pairs(primary_key) do
      where[field_name] = serialize_arg(field, primary_key[field_name], ws_id)
    end

    return select(self, where, ws_id)
  end

  function _mt:select_by_field(field_name, field_value, options)
    --print(fmt("\nSELECTBYFIELD:\nfield_name: %s\nfield_value: %s\noptions: %s\n\n", field_name, field_value, dump(options)))

    local has_ws_id, ws_id, err = check_workspace(self, options, false)
    if err then
      return nil, err
    end

    if has_ws_id and ws_id == nil
      and not self.schema.fields[field_name].unique_across_ws then
      -- fail with error: this is not a database failure, this is programmer error
      error("cannot select on field " .. field_name .. "without a workspace " ..
        "because it is not marked unique_across_ws")
    end

    local field
    if field_name == "cache_key" then
      field = cache_key_field
    else
      field = self.schema.fields[field_name]
      if field
        and field.reference
        and self.foreign_keys_db_columns[field_name]
        and self.foreign_keys_db_columns[field_name][1]
      then
        field_name = self.foreign_keys_db_columns[field_name][1].col_name
      end
    end

    local where = {}
    where[field_name] = serialize_arg(field, field_value, ws_id)

    return select(self, where, ws_id)
  end
end

-- delete
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
    local deleted, err = collection:removeMany(to_bson(where))
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

    --print(fmt("\n\n\n\nset: %s\n\n\n\n", to_bson(set, { clear = true })))
    local res, err = collection:update(
      to_bson(where),
      to_bson(set, { clear = true }),
      { upsert = mode == "upsert" }
    )
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
    --print(fmt("\n\n\nwhere clause: %s\n\n\n", dump(to_bson(where))))
    local cursor, err = collection:find(to_bson(where), {
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
      table.insert(rows, self:deserialize_row(record))
    end

    --print(fmt("\n\n\nrows: %s\n\n", dump(rows)))
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
