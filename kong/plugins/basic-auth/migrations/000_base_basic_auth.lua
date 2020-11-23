return {
  postgres = {
    up = [[
      CREATE TABLE IF NOT EXISTS "basicauth_credentials" (
        "id"           UUID                         PRIMARY KEY,
        "created_at"   TIMESTAMP WITH TIME ZONE     DEFAULT (CURRENT_TIMESTAMP(0) AT TIME ZONE 'UTC'),
        "consumer_id"  UUID                         REFERENCES "consumers" ("id") ON DELETE CASCADE,
        "username"     TEXT                         UNIQUE,
        "password"     TEXT
      );

      DO $$
      BEGIN
        CREATE INDEX IF NOT EXISTS "basicauth_consumer_id_idx" ON "basicauth_credentials" ("consumer_id");
      EXCEPTION WHEN UNDEFINED_COLUMN THEN
        -- Do nothing, accept existing state
      END$$;
    ]],
  },

  cassandra = {
    up = [[
      CREATE TABLE IF NOT EXISTS basicauth_credentials (
        id          uuid PRIMARY KEY,
        created_at  timestamp,
        consumer_id uuid,
        password    text,
        username    text
      );
      CREATE INDEX IF NOT EXISTS ON basicauth_credentials(username);
      CREATE INDEX IF NOT EXISTS ON basicauth_credentials(consumer_id);
    ]],
  },

  mongo = {
    up = [[
      @name#basicauth_credentials
      @querytype#create
      @validator#{
        "bsonType": "object",
        "required": ["id"],
        "properties": {
          "id": { "bsonType": "string", "pattern": "^.{8}[-].{4}[-].{4}[-].{4}[-].{12}$" },
          "created_at": { "bsonType": "number", "pattern": "^[0-9]{13}$" },
          "consumer_id": { "bsonType": "string", "pattern": "^.{8}[-].{4}[-].{4}[-].{4}[-].{12}$" },
          "password": { "bsonType": "string" },
          "username": { "bsonType": "string" }
        }
      }
      @index#[
        { "key": { "id": 1 }, "name": "primary_key", "unique": true },
        { "key": { "username": 1 }, "name": "basicauth_username_idx" },
        { "key": { "consumer_id": 1 }, "name": "basicauth_consumer_id_idx" }
      ]
      %
      ]],
  },
}
