return {
  postgres = {
    up = [[
      CREATE TABLE IF NOT EXISTS "hmacauth_credentials" (
        "id"           UUID                         PRIMARY KEY,
        "created_at"   TIMESTAMP WITH TIME ZONE     DEFAULT (CURRENT_TIMESTAMP(0) AT TIME ZONE 'UTC'),
        "consumer_id"  UUID                         REFERENCES "consumers" ("id") ON DELETE CASCADE,
        "username"     TEXT                         UNIQUE,
        "secret"       TEXT
      );

      DO $$
      BEGIN
        CREATE INDEX IF NOT EXISTS "hmacauth_credentials_consumer_id_idx" ON "hmacauth_credentials" ("consumer_id");
      EXCEPTION WHEN UNDEFINED_COLUMN THEN
        -- Do nothing, accept existing state
      END$$;
    ]],
  },

  cassandra = {
    up = [[
      CREATE TABLE IF NOT EXISTS hmacauth_credentials(
        id          uuid PRIMARY KEY,
        created_at  timestamp,
        consumer_id uuid,
        username    text,
        secret      text
      );
      CREATE INDEX IF NOT EXISTS ON hmacauth_credentials(username);
      CREATE INDEX IF NOT EXISTS ON hmacauth_credentials(consumer_id);
    ]],
  },

  mongo = {
    up = [[
      @name#hmacauth_credentials
      @querytype#create
      @validator#{
        "bsonType": "object",
        "required": ["id"],
        "properties": {
          "id": { "bsonType": "string", "pattern": "^.{8}[-].{4}[-].{4}[-].{4}[-].{12}$" },
          "created_at": { "bsonType": "number", "pattern": "^[0-9]{13}$" },
          "consumer_id": { "bsonType": "string", "pattern": "^.{8}[-].{4}[-].{4}[-].{4}[-].{12}$" },
          "username": { "bsonType": "string" },
          "secret": { "bsonType": "string" }
        }
      }
      @index#[
        { "key": { "id": 1 }, "name": "primary_key", "unique": true },
        { "key": { "consumer_id": 1 }, "name": "hmacauth_consumer_id_idx" },
        { "key": { "username": 1 }, "name": "hmacauth_username_idx" }
      ]
      %]],
  },
}
