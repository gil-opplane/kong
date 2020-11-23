return {
  postgres = {
    up = [[
      CREATE TABLE IF NOT EXISTS "acls" (
        "id"           UUID                         PRIMARY KEY,
        "created_at"   TIMESTAMP WITH TIME ZONE     DEFAULT (CURRENT_TIMESTAMP(0) AT TIME ZONE 'UTC'),
        "consumer_id"  UUID                         REFERENCES "consumers" ("id") ON DELETE CASCADE,
        "group"        TEXT,
        "cache_key"    TEXT                         UNIQUE
      );

      DO $$
      BEGIN
        CREATE INDEX IF NOT EXISTS "acls_consumer_id_idx" ON "acls" ("consumer_id");
      EXCEPTION WHEN UNDEFINED_COLUMN THEN
        -- Do nothing, accept existing state
      END$$;

      DO $$
      BEGIN
        CREATE INDEX IF NOT EXISTS "acls_group_idx" ON "acls" ("group");
      EXCEPTION WHEN UNDEFINED_COLUMN THEN
        -- Do nothing, accept existing state
      END$$;
    ]],
  },

  cassandra = {
    up = [[
      CREATE TABLE IF NOT EXISTS acls(
        id          uuid PRIMARY KEY,
        created_at  timestamp,
        consumer_id uuid,
        group       text,
        cache_key   text
      );
      CREATE INDEX IF NOT EXISTS ON acls(group);
      CREATE INDEX IF NOT EXISTS ON acls(consumer_id);
      CREATE INDEX IF NOT EXISTS ON acls(cache_key);
    ]],
  },

  mongo = {
    up = [[
      @name#acls
      @querytype#create
      @validator#{
        "bsonType": "object",
        "required": ["id"],
        "properties": {
          "id": { "bsonType": "string", "pattern": "^.{8}[-].{4}[-].{4}[-].{4}[-].{12}$" },
          "created_at": { "bsonType": "number", "pattern": "^[0-9]{13}$" },
          "consumer_id": { "bsonType": "string", "pattern": "^.{8}[-].{4}[-].{4}[-].{4}[-].{12}$" },
          "group": { "bsonType": "string" },
          "cache_key": { "bsonType": "string" }
        }
      }
      @index#[
        { "key": { "id": 1 }, "name": "primary_key", "unique": true },
        { "key": { "group": 1 }, "name": "acls_group_idx" },
        { "key": { "consumer_id": 1 }, "name": "acls_consumer_id_idx" },
        { "key": { "cache_key": 1 }, "name": "acls_cache_key_idx" }
      ]
      %]],
  },
}
