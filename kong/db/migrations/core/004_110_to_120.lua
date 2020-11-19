return {
  postgres = {
    up = [[
      DO $$
      BEGIN
        CREATE INDEX IF NOT EXISTS cluster_events_expire_at_idx ON cluster_events(expire_at);
      EXCEPTION WHEN UNDEFINED_COLUMN THEN
        -- Do nothing, accept existing state
      END$$;

      DO $$
      BEGIN
        ALTER TABLE IF EXISTS ONLY "routes" ADD "https_redirect_status_code" INTEGER;
      EXCEPTION WHEN DUPLICATE_COLUMN THEN
        -- Do nothing, accept existing state
      END;
      $$;
    ]],
  },

  cassandra = {
    up = [[
      ALTER TABLE routes ADD https_redirect_status_code int;
    ]],
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
          "https_redirect_status_code": { "bsonType": "int" }
        }
      }
      %]]
  }
}
