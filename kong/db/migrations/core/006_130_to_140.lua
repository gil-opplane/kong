return {
  postgres = {
    up = [[
      DO $$
      BEGIN
        ALTER TABLE IF EXISTS ONLY "upstreams" ADD "host_header" TEXT;
      EXCEPTION WHEN DUPLICATE_COLUMN THEN
        -- Do nothing, accept existing state
      END;
      $$;


      DROP TRIGGER IF EXISTS "delete_expired_cluster_events_trigger" ON "cluster_events";
      DROP FUNCTION IF EXISTS "delete_expired_cluster_events" ();
    ]],
  },

  cassandra = {
    up = [[
      ALTER TABLE upstreams ADD host_header text;
    ]],
  },

  mongo = {
    up = [[
      @name#upstreams
      @querytype#update
      @validator#{
        "bsonType": "object",
        "required": ["id"],
        "properties": {
          "id": { "bsonType": "string", "pattern": "^urn:uuid" },
          "created_at": { "bsonType": "timestamp" },
          "hash_fallback": { "bsonType": "string" },
          "hash_fallback_header": { "bsonType": "string" },
          "hash_on": { "bsonType": "string" },
          "hash_on_cookie": { "bsonType": "string" },
          "hash_on_cookie_path": { "bsonType": "string" },
          "hash_on_header": { "bsonType": "string" },
          "healthchecks": { "bsonType": "string" },
          "name": { "bsonType": "string" },
          "slots": { "bsonType": "int" },
          "tags": { "bsonType": "array", "items": { "bsonType": "string" } },
          "algorithm": { "bsonType": "string" },
          "host_header": { "bsonType": "string" }
        }
      }
      %
      ]],
  }
}
