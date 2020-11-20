return {
  postgres = {
    up = [[
      ALTER TABLE IF EXISTS ONLY "routes" ALTER COLUMN "path_handling" SET DEFAULT 'v0';
    ]],

    teardown = function(connector)
      local _, err = connector:query([[
        DO $$
        BEGIN
          ALTER TABLE IF EXISTS ONLY "plugins" DROP COLUMN "run_on";
        EXCEPTION WHEN UNDEFINED_COLUMN THEN
          -- Do nothing, accept existing state
        END;
        $$;


        DO $$
        BEGIN
          DROP TABLE IF EXISTS "cluster_ca";
        END;
        $$;
      ]])

      if err then
        return nil, err
      end

      return true
    end,
  },

  cassandra = {
    up = [[
    ]],

    teardown = function(connector)
      local coordinator = assert(connector:get_stored_connection())
      local _, err = coordinator:execute("DROP INDEX IF EXISTS plugins_run_on_idx")
      if err then
        return nil, err
      end

      _, err = coordinator:execute("DROP TABLE IF EXISTS cluster_ca")
      if err then
        return nil, err
      end

      -- no need to drop the actual column from the database
      -- (this operation is not reentrant in Cassandra)
      --[===[
      assert(coordinator:execute("ALTER TABLE plugins DROP run_on"))
      ]===]

      return true
    end,
  },

  mongo = {
    up = [[]],
    teardown = function(connector)
      local cjson       = require 'cjson'
      local coordinator = assert(connector:get_stored_connection())
      local client      = coordinator.client
      local database    = coordinator.database
      local coll_name   = 'plugins'

      -- TODO can't delete index
      --local drop_index = {
      --  dropIndexes = coll_name,
      --  index = { "plugins_run_on_idx" }
      --}
      --local collection = client:getCollection(database, coll_name)
      --local _, err = client:command(database, cjson.encode(drop_index))
      --if err then
      --  return nil, err
      --end

      coll_name   = 'cluster_ca'
      collection = client:getCollection(database, coll_name)
      _, err = collection:drop()
      if err then
        return nil, err
      end
      return true
    end
  }
}
