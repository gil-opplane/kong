return {
  postgres = {
    up = [[
      CREATE TABLE IF NOT EXISTS "jwt_secrets" (
        "id"              UUID                         PRIMARY KEY,
        "created_at"      TIMESTAMP WITH TIME ZONE     DEFAULT (CURRENT_TIMESTAMP(0) AT TIME ZONE 'UTC'),
        "consumer_id"     UUID                         REFERENCES "consumers" ("id") ON DELETE CASCADE,
        "key"             TEXT                         UNIQUE,
        "secret"          TEXT,
        "algorithm"       TEXT,
        "rsa_public_key"  TEXT
      );

      DO $$
      BEGIN
        CREATE INDEX IF NOT EXISTS "jwt_secrets_consumer_id_idx" ON "jwt_secrets" ("consumer_id");
      EXCEPTION WHEN UNDEFINED_COLUMN THEN
        -- Do nothing, accept existing state
      END$$;

      DO $$
      BEGIN
        CREATE INDEX IF NOT EXISTS "jwt_secrets_secret_idx" ON "jwt_secrets" ("secret");
      EXCEPTION WHEN UNDEFINED_COLUMN THEN
        -- Do nothing, accept existing state
      END$$;
    ]],
  },

  cassandra = {
    up = [[
      CREATE TABLE IF NOT EXISTS jwt_secrets(
        id             uuid PRIMARY KEY,
        created_at     timestamp,
        consumer_id    uuid,
        algorithm      text,
        rsa_public_key text,
        key            text,
        secret         text
      );
      CREATE INDEX IF NOT EXISTS ON jwt_secrets(key);
      CREATE INDEX IF NOT EXISTS ON jwt_secrets(secret);
      CREATE INDEX IF NOT EXISTS ON jwt_secrets(consumer_id);
    ]],
  },

  mongo = {
    up = [[
      @name#jwt_secrets
      @querytype#create
      @validator#{
        "bsonType": "object",
        "required": ["id"],
        "properties": {
          "id": { "bsonType": "string", "pattern": "^.{8}[-].{4}[-].{4}[-].{4}[-].{12}$" },
          "created_at": { "bsonType": "number", "pattern": "^[0-9]{13}$" },
          "consumer_id": { "bsonType": "string", "pattern": "^.{8}[-].{4}[-].{4}[-].{4}[-].{12}$" },
          "algorithm": { "bsonType": "string" },
          "rsa_public_key": { "bsonType": "string" },
          "key": { "bsonType": "string" },
          "secret": { "bsonType": "string" }
        }
      }
      @index#[
        { "key": { "id": 1 }, "name": "primary_key", "unique": true },
        { "key": { "key": 1 }, "name": "jwt_secrets_key_idx" },
        { "key": { "secret": 1 }, "name": "jwt_secrets_secret_idx" },
        { "key": { "consumer_id": 1 }, "name": "jwt_secrets_consumer_id_idx" }
      ]
      %]]
  }
}
