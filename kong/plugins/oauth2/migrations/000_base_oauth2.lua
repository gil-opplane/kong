return {
  postgres = {
    up = [[
      CREATE TABLE IF NOT EXISTS "oauth2_credentials" (
        "id"             UUID                         PRIMARY KEY,
        "created_at"     TIMESTAMP WITH TIME ZONE     DEFAULT (CURRENT_TIMESTAMP(0) AT TIME ZONE 'UTC'),
        "name"           TEXT,
        "consumer_id"    UUID                         REFERENCES "consumers" ("id") ON DELETE CASCADE,
        "client_id"      TEXT                         UNIQUE,
        "client_secret"  TEXT,
        "redirect_uris"  TEXT[]
      );

      DO $$
      BEGIN
        CREATE INDEX IF NOT EXISTS "oauth2_credentials_consumer_id_idx" ON "oauth2_credentials" ("consumer_id");
      EXCEPTION WHEN UNDEFINED_COLUMN THEN
        -- Do nothing, accept existing state
      END$$;

      DO $$
      BEGIN
        CREATE INDEX IF NOT EXISTS "oauth2_credentials_secret_idx" ON "oauth2_credentials" ("client_secret");
      EXCEPTION WHEN UNDEFINED_COLUMN THEN
        -- Do nothing, accept existing state
      END$$;



      CREATE TABLE IF NOT EXISTS "oauth2_authorization_codes" (
        "id"                    UUID                         PRIMARY KEY,
        "created_at"            TIMESTAMP WITH TIME ZONE     DEFAULT (CURRENT_TIMESTAMP(0) AT TIME ZONE 'UTC'),
        "credential_id"         UUID                         REFERENCES "oauth2_credentials" ("id") ON DELETE CASCADE,
        "service_id"            UUID                         REFERENCES "services" ("id") ON DELETE CASCADE,
        "code"                  TEXT                         UNIQUE,
        "authenticated_userid"  TEXT,
        "scope"                 TEXT,
        "ttl"                   TIMESTAMP WITH TIME ZONE
      );

      DO $$
      BEGIN
        CREATE INDEX IF NOT EXISTS "oauth2_authorization_codes_authenticated_userid_idx" ON "oauth2_authorization_codes" ("authenticated_userid");
      EXCEPTION WHEN UNDEFINED_COLUMN THEN
        -- Do nothing, accept existing state
      END$$;

      DO $$
      BEGIN
        CREATE INDEX IF NOT EXISTS "oauth2_authorization_credential_id_idx"
                                ON "oauth2_authorization_codes" ("credential_id");
      EXCEPTION WHEN UNDEFINED_COLUMN THEN
        -- Do nothing, accept existing state
      END$$;

      DO $$
      BEGIN
        CREATE INDEX IF NOT EXISTS "oauth2_authorization_service_id_idx"
                                ON "oauth2_authorization_codes" ("service_id");
      EXCEPTION WHEN UNDEFINED_COLUMN THEN
        -- Do nothing, accept existing state
      END$$;



      CREATE TABLE IF NOT EXISTS "oauth2_tokens" (
        "id"                    UUID                         PRIMARY KEY,
        "created_at"            TIMESTAMP WITH TIME ZONE     DEFAULT (CURRENT_TIMESTAMP(0) AT TIME ZONE 'UTC'),
        "credential_id"         UUID                         REFERENCES "oauth2_credentials" ("id") ON DELETE CASCADE,
        "service_id"            UUID                         REFERENCES "services" ("id") ON DELETE CASCADE,
        "access_token"          TEXT                         UNIQUE,
        "refresh_token"         TEXT                         UNIQUE,
        "token_type"            TEXT,
        "expires_in"            INTEGER,
        "authenticated_userid"  TEXT,
        "scope"                 TEXT,
        "ttl"                   TIMESTAMP WITH TIME ZONE
      );

      DO $$
      BEGIN
        CREATE INDEX IF NOT EXISTS "oauth2_tokens_authenticated_userid_idx" ON "oauth2_tokens" ("authenticated_userid");
      EXCEPTION WHEN UNDEFINED_COLUMN THEN
        -- Do nothing, accept existing state
      END$$;

      DO $$
      BEGIN
        CREATE INDEX IF NOT EXISTS "oauth2_tokens_credential_id_idx"
                                ON "oauth2_tokens" ("credential_id");
      EXCEPTION WHEN UNDEFINED_COLUMN THEN
        -- Do nothing, accept existing state
      END$$;

      DO $$
      BEGIN
        CREATE INDEX IF NOT EXISTS "oauth2_tokens_service_id_idx"
                                ON "oauth2_tokens" ("service_id");
      EXCEPTION WHEN UNDEFINED_COLUMN THEN
        -- Do nothing, accept existing state
      END$$;
    ]],
  },

  cassandra = {
    up = [[
      CREATE TABLE IF NOT EXISTS oauth2_credentials(
        id            uuid PRIMARY KEY,
        created_at    timestamp,
        consumer_id   uuid,
        client_id     text,
        client_secret text,
        name          text,
        redirect_uris set<text>
      );
      CREATE INDEX IF NOT EXISTS ON oauth2_credentials(client_id);
      CREATE INDEX IF NOT EXISTS ON oauth2_credentials(consumer_id);
      CREATE INDEX IF NOT EXISTS ON oauth2_credentials(client_secret);



      CREATE TABLE IF NOT EXISTS oauth2_authorization_codes(
        id                   uuid PRIMARY KEY,
        created_at           timestamp,
        service_id           uuid,
        credential_id        uuid,
        authenticated_userid text,
        code                 text,
        scope                text
      ) WITH default_time_to_live = 300;
      CREATE INDEX IF NOT EXISTS ON oauth2_authorization_codes(code);
      CREATE INDEX IF NOT EXISTS ON oauth2_authorization_codes(service_id);
      CREATE INDEX IF NOT EXISTS ON oauth2_authorization_codes(credential_id);
      CREATE INDEX IF NOT EXISTS ON oauth2_authorization_codes(authenticated_userid);



      CREATE TABLE IF NOT EXISTS oauth2_tokens(
        id                   uuid PRIMARY KEY,
        created_at           timestamp,
        service_id           uuid,
        credential_id        uuid,
        access_token         text,
        authenticated_userid text,
        refresh_token        text,
        scope                text,
        token_type           text,
        expires_in           int
      );
      CREATE INDEX IF NOT EXISTS ON oauth2_tokens(service_id);
      CREATE INDEX IF NOT EXISTS ON oauth2_tokens(access_token);
      CREATE INDEX IF NOT EXISTS ON oauth2_tokens(refresh_token);
      CREATE INDEX IF NOT EXISTS ON oauth2_tokens(credential_id);
      CREATE INDEX IF NOT EXISTS ON oauth2_tokens(authenticated_userid);
    ]],
  },

  mongo = {
    up = [[
      @name#oauth2_credentials
      @querytype#create
      @validator#{
        "bsonType": "object",
        "required": ["id"],
        "properties": {
          "id": { "bsonType": "string", "pattern": "^.{8}[-].{4}[-].{4}[-].{4}[-].{12}$" },
          "created_at": { "bsonType": "number", "pattern": "^[0-9]{13}$" },
          "consumer_id": { "bsonType": "string", "pattern": "^.{8}[-].{4}[-].{4}[-].{4}[-].{12}$" },
          "client_id": { "bsonType": "string" },
          "client_secret": { "bsonType": "string" },
          "name": { "bsonType": "string" },
          "redirect_uris": { "bsonType": "string" }
        }
      }
      @index#[
        { "key": { "id": 1 }, "name": "primary_key", "unique": true },
        { "key": { "consumer_id": 1 }, "name": "oauth2_credentials_consumer_id_idx" },
        { "key": { "client_id": 1 }, "name": "oauth2_credentials_client_id_idx" },
        { "key": { "client_secret": 1 }, "name": "oauth2_credentials_client_secret_idx" }
      ]
      %
      @name#oauth2_authorization_codes
      @querytype#create
      @validator#{
        "bsonType": "object",
        "required": ["id"],
        "properties": {
          "id": { "bsonType": "string", "pattern": "^.{8}[-].{4}[-].{4}[-].{4}[-].{12}$" },
          "created_at": { "bsonType": "number", "pattern": "^[0-9]{13}$" },
          "service_id": { "bsonType": "string", "pattern": "^.{8}[-].{4}[-].{4}[-].{4}[-].{12}$" },
          "credential_id": { "bsonType": "string", "pattern": "^.{8}[-].{4}[-].{4}[-].{4}[-].{12}$" },
          "authenticated_userid": { "bsonType": "string" },
          "code": { "bsonType": "string" },
          "scope": { "bsonType": "string" }
        }
      }
      @index#[
        { "key": { "id": 1 }, "name": "primary_key", "unique": true },
        { "key": { "code": 1 }, "name": "oauth2_authorization_codes_code_idx" },
        { "key": { "service_id": 1 }, "name": "oauth2_authorization_codes_service_id_idx" },
        { "key": { "credential_id": 1 }, "name": "oauth2_authorization_codes_credential_id_idx" },
        { "key": { "authenticated_userid": 1 }, "name": "oauth2_authorization_codes_authenticated_userid_idx" },
        { "key": { "created_at": 1 }, "name": "ttl", "expireAfterSeconds": 300 }
      ]
      %
      @name#oauth2_tokens
      @querytype#create
      @validator#{
        "bsonType": "object",
        "required": ["id"],
        "properties": {
          "id": { "bsonType": "string", "pattern": "^.{8}[-].{4}[-].{4}[-].{4}[-].{12}$" },
          "created_at": { "bsonType": "number", "pattern": "^[0-9]{13}$" },
          "service_id": { "bsonType": "string", "pattern": "^.{8}[-].{4}[-].{4}[-].{4}[-].{12}$" },
          "credential_id": { "bsonType": "string", "pattern": "^.{8}[-].{4}[-].{4}[-].{4}[-].{12}$" },
          "access_token": { "bsonType": "string" },
          "authenticated_userid": { "bsonType": "string" },
          "refresh_token": { "bsonType": "string" },
          "scope": { "bsonType": "string" },
          "token_type": { "bsonType": "string" },
          "expires_in": { "bsonType": "int" }
        }
      }
      @index#[
        { "key": { "id": 1 }, "name": "primary_key", "unique": true },
        { "key": { "access_token": 1 }, "name": "oauth2_tokens_access_tokens_idx" },
        { "key": { "service_id": 1 }, "name": "oauth2_tokens_service_id_idx" },
        { "key": { "refresh_token": 1 }, "name": "oauth2_tokens_refresh_token_idx" },
        { "key": { "authenticated_userid": 1 }, "name": "oauth2_tokens_authenticated_userid_idx" },
        { "key": { "credential_id": 1 }, "name": "oauth2_tokens_credential_id_idx" }
      ]
      %
      ]]
  }
}
