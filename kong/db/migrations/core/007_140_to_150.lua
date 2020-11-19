return {
  postgres = {
    up = [[
      -- If migrating from 1.x, the "path_handling" column does not exist yet.
      -- Create it with a default of 'v1' to fill existing rows.
      DO $$
      BEGIN
        ALTER TABLE IF EXISTS ONLY "routes" ADD "path_handling" TEXT DEFAULT 'v1';
      EXCEPTION WHEN DUPLICATE_COLUMN THEN
        -- Do nothing, accept existing state
      END;
      $$;
    ]],
  },

  cassandra = {
    up = [[
      ALTER TABLE routes ADD path_handling text;
    ]],

    teardown = function(connector)
      local coordinator = assert(connector:get_stored_connection())
      local cassandra = require "cassandra"
      for rows, err in coordinator:iterate("SELECT id, path_handling FROM routes") do
        if err then
          return nil, err
        end

        for i = 1, #rows do
          local route = rows[i]
          if route.path_handling ~= "v0" and route.path_handling ~= "v1" then
            local _, err = coordinator:execute(
              "UPDATE routes SET path_handling = 'v1' WHERE partition = 'routes' AND id = ?",
              { cassandra.uuid(route.id) }
            )
            if err then
              return nil, err
            end
          end
        end
      end

      return true
    end,
  },

  mongo = {
    up = [[
      @name#routes
      @querytype#update
      @validator#{
        "bsonType": "object",
        "required": ["partition", "id"],
        "properties": {
          "partition": { "bsonType": "string" },
          "id": { "bsonType": "string", "pattern": "^urn:uuid" },
          "created_at": { "bsonType": "timestamp" },
          "updated_at": { "bsonType": "timestamp" },
          "name": { "bsonType": "string" },
          "hosts": { "bsonType": "array", "items": { "bsonType": "string" } },
          "paths": { "bsonType": "array", "items": { "bsonType": "string" } },
          "methods": { "bsonType": "array", "items": { "bsonType": "string" } },
          "protocols": { "bsonType": "array", "items": { "bsonType": "string" } },
          "snis": { "bsonType": "array", "items": { "bsonType": "string" } },
          "sources": { "bsonType": "array", "items": { "bsonType": "string" } },
          "destinations": { "bsonType": "array", "items": { "bsonType": "string" } },
          "preserve_host": { "bsonType": "bool" },
          "strip_path": { "bsonType": "bool" },
          "service_id": { "bsonType": "string", "pattern": "^urn:uuid" },
          "regex_priority": { "bsonType": "int" },
          "tags": { "bsonType": "array", "items": { "bsonType": "string" } },
          "https_redirect_status_code": { "bsonType": "int" },
          "headers": { "bsonType": "array",
            "items": {
              "bsonType": "object",
              "required": ["key"],
              "properties": {
                "key": { "bsonType": "string" },
                "value": { "bsonType": "string" }
              }
            }
          },
          "path_handling": { "bsonType": "string" }
        }
      }
      %
      ]],
    teardown = function(connector)
      local coordinator = assert(connector:get_stored_connection())
      local client      = coordinator.client
      local database    = coordinator.database
      local coll_name   = 'routes'

      local collection = client:getCollection(database, coll_name)
      local cursor = collection:find{}

      for route, err in cursor:iterator() do
        if err then
          return nil, err
        end

        if route.path_handling ~= "v0" and route.path_handling ~= "v1" then
          local _, err = collection:update(
            { id = route.id, partition = 'routes' },
            { path_handling = 'v1' },
            { upsert = false }
          )
          if err then
            return nil, err
          end
        end

      end
      return true
    end
  }
}
