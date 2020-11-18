return {
  postgres = {
    up = [[
      CREATE TABLE IF NOT EXISTS "cluster_events" (
        "id"         UUID                       PRIMARY KEY,
        "node_id"    UUID                       NOT NULL,
        "at"         TIMESTAMP WITH TIME ZONE   NOT NULL,
        "nbf"        TIMESTAMP WITH TIME ZONE,
        "expire_at"  TIMESTAMP WITH TIME ZONE   NOT NULL,
        "channel"    TEXT,
        "data"       TEXT
      );

      DO $$
      BEGIN
        CREATE INDEX IF NOT EXISTS "cluster_events_at_idx" ON "cluster_events" ("at");
      EXCEPTION WHEN UNDEFINED_COLUMN THEN
        -- Do nothing, accept existing state
      END$$;

      DO $$
      BEGIN
        CREATE INDEX IF NOT EXISTS "cluster_events_channel_idx" ON "cluster_events" ("channel");
      EXCEPTION WHEN UNDEFINED_COLUMN THEN
        -- Do nothing, accept existing state
      END$$;

      CREATE OR REPLACE FUNCTION "delete_expired_cluster_events" () RETURNS TRIGGER
      LANGUAGE plpgsql
      AS $$
        BEGIN
          DELETE FROM "cluster_events"
                WHERE "expire_at" <= CURRENT_TIMESTAMP AT TIME ZONE 'UTC';
          RETURN NEW;
        END;
      $$;

      DROP TRIGGER IF EXISTS "delete_expired_cluster_events_trigger" ON "cluster_events";
      CREATE TRIGGER "delete_expired_cluster_events_trigger"
        AFTER INSERT ON "cluster_events"
        FOR EACH STATEMENT
        EXECUTE PROCEDURE delete_expired_cluster_events();



      CREATE TABLE IF NOT EXISTS "services" (
        "id"               UUID                       PRIMARY KEY,
        "created_at"       TIMESTAMP WITH TIME ZONE,
        "updated_at"       TIMESTAMP WITH TIME ZONE,
        "name"             TEXT                       UNIQUE,
        "retries"          BIGINT,
        "protocol"         TEXT,
        "host"             TEXT,
        "port"             BIGINT,
        "path"             TEXT,
        "connect_timeout"  BIGINT,
        "write_timeout"    BIGINT,
        "read_timeout"     BIGINT
      );



      CREATE TABLE IF NOT EXISTS "routes" (
        "id"              UUID                       PRIMARY KEY,
        "created_at"      TIMESTAMP WITH TIME ZONE,
        "updated_at"      TIMESTAMP WITH TIME ZONE,
        "name"            TEXT                       UNIQUE,
        "service_id"      UUID                       REFERENCES "services" ("id"),
        "protocols"       TEXT[],
        "methods"         TEXT[],
        "hosts"           TEXT[],
        "paths"           TEXT[],
        "snis"            TEXT[],
        "sources"         JSONB[],
        "destinations"    JSONB[],
        "regex_priority"  BIGINT,
        "strip_path"      BOOLEAN,
        "preserve_host"   BOOLEAN
      );

      DO $$
      BEGIN
        CREATE INDEX IF NOT EXISTS "routes_service_id_idx" ON "routes" ("service_id");
      EXCEPTION WHEN UNDEFINED_COLUMN THEN
        -- Do nothing, accept existing state
      END$$;



      CREATE TABLE IF NOT EXISTS "certificates" (
        "id"          UUID                       PRIMARY KEY,
        "created_at"  TIMESTAMP WITH TIME ZONE   DEFAULT (CURRENT_TIMESTAMP(0) AT TIME ZONE 'UTC'),
        "cert"        TEXT,
        "key"         TEXT
      );



      CREATE TABLE IF NOT EXISTS "snis" (
        "id"              UUID                       PRIMARY KEY,
        "created_at"      TIMESTAMP WITH TIME ZONE   DEFAULT (CURRENT_TIMESTAMP(0) AT TIME ZONE 'UTC'),
        "name"            TEXT                       NOT NULL UNIQUE,
        "certificate_id"  UUID                       REFERENCES "certificates" ("id")
      );

      DO $$
      BEGIN
        CREATE INDEX IF NOT EXISTS "snis_certificate_id_idx" ON "snis" ("certificate_id");
      EXCEPTION WHEN UNDEFINED_COLUMN THEN
        -- Do nothing, accept existing state
      END$$;



      CREATE TABLE IF NOT EXISTS "consumers" (
        "id"          UUID                         PRIMARY KEY,
        "created_at"  TIMESTAMP WITH TIME ZONE     DEFAULT (CURRENT_TIMESTAMP(0) AT TIME ZONE 'UTC'),
        "username"    TEXT                         UNIQUE,
        "custom_id"   TEXT                         UNIQUE
      );

      DO $$
      BEGIN
        CREATE INDEX IF NOT EXISTS "consumers_username_idx" ON "consumers" (LOWER("username"));
      EXCEPTION WHEN UNDEFINED_COLUMN THEN
        -- Do nothing, accept existing state
      END$$;



      CREATE TABLE IF NOT EXISTS "plugins" (
        "id"           UUID                         UNIQUE,
        "created_at"   TIMESTAMP WITH TIME ZONE     DEFAULT (CURRENT_TIMESTAMP(0) AT TIME ZONE 'UTC'),
        "name"         TEXT                         NOT NULL,
        "consumer_id"  UUID                         REFERENCES "consumers" ("id") ON DELETE CASCADE,
        "service_id"   UUID                         REFERENCES "services"  ("id") ON DELETE CASCADE,
        "route_id"     UUID                         REFERENCES "routes"    ("id") ON DELETE CASCADE,
        "config"       JSONB                        NOT NULL,
        "enabled"      BOOLEAN                      NOT NULL,
        "cache_key"    TEXT                         UNIQUE,
        "run_on"       TEXT,

        PRIMARY KEY ("id")
      );

      DO $$
      BEGIN
        CREATE INDEX IF NOT EXISTS "plugins_name_idx" ON "plugins" ("name");
      EXCEPTION WHEN UNDEFINED_COLUMN THEN
        -- Do nothing, accept existing state
      END$$;

      DO $$
      BEGIN
        CREATE INDEX IF NOT EXISTS "plugins_consumer_id_idx" ON "plugins" ("consumer_id");
      EXCEPTION WHEN UNDEFINED_COLUMN THEN
        -- Do nothing, accept existing state
      END$$;

      DO $$
      BEGIN
        CREATE INDEX IF NOT EXISTS "plugins_service_id_idx" ON "plugins" ("service_id");
      EXCEPTION WHEN UNDEFINED_COLUMN THEN
        -- Do nothing, accept existing state
      END$$;

      DO $$
      BEGIN
        CREATE INDEX IF NOT EXISTS "plugins_route_id_idx" ON "plugins" ("route_id");
      EXCEPTION WHEN UNDEFINED_COLUMN THEN
        -- Do nothing, accept existing state
      END$$;

      DO $$
      BEGIN
        CREATE INDEX IF NOT EXISTS "plugins_run_on_idx" ON "plugins" ("run_on");
      EXCEPTION WHEN UNDEFINED_COLUMN THEN
        -- Do nothing, accept existing state
      END$$;



      CREATE TABLE IF NOT EXISTS "upstreams" (
        "id"                    UUID                         PRIMARY KEY,
        "created_at"            TIMESTAMP WITH TIME ZONE     DEFAULT (CURRENT_TIMESTAMP(3) AT TIME ZONE 'UTC'),
        "name"                  TEXT                         UNIQUE,
        "hash_on"               TEXT,
        "hash_fallback"         TEXT,
        "hash_on_header"        TEXT,
        "hash_fallback_header"  TEXT,
        "hash_on_cookie"        TEXT,
        "hash_on_cookie_path"   TEXT,
        "slots"                 INTEGER                      NOT NULL,
        "healthchecks"          JSONB
      );



      CREATE TABLE IF NOT EXISTS "targets" (
        "id"           UUID                         PRIMARY KEY,
        "created_at"   TIMESTAMP WITH TIME ZONE     DEFAULT (CURRENT_TIMESTAMP(3) AT TIME ZONE 'UTC'),
        "upstream_id"  UUID                         REFERENCES "upstreams" ("id") ON DELETE CASCADE,
        "target"       TEXT                         NOT NULL,
        "weight"       INTEGER                      NOT NULL
      );

      DO $$
      BEGIN
        CREATE INDEX IF NOT EXISTS "targets_target_idx" ON "targets" ("target");
      EXCEPTION WHEN UNDEFINED_COLUMN THEN
        -- Do nothing, accept existing state
      END$$;

      DO $$
      BEGIN
        CREATE INDEX IF NOT EXISTS "targets_upstream_id_idx" ON "targets" ("upstream_id");
      EXCEPTION WHEN UNDEFINED_COLUMN THEN
        -- Do nothing, accept existing state
      END$$;



      CREATE TABLE IF NOT EXISTS "cluster_ca" (
        "pk"    BOOLEAN  NOT NULL  PRIMARY KEY CHECK(pk=true),
        "key"   TEXT     NOT NULL,
        "cert"  TEXT     NOT NULL
      );


      -- TODO: delete on 1.0.0 migrations
      CREATE TABLE IF NOT EXISTS "ttls" (
        "primary_key_value"  TEXT                         NOT NULL,
        "primary_uuid_value" UUID,
        "table_name"         TEXT                         NOT NULL,
        "primary_key_name"   TEXT                         NOT NULL,
        "expire_at"          TIMESTAMP WITHOUT TIME ZONE  NOT NULL,

        PRIMARY KEY ("primary_key_value", "table_name")
      );

      DO $$
      BEGIN
        CREATE INDEX IF NOT EXISTS "ttls_primary_uuid_value_idx" ON "ttls" ("primary_uuid_value");
      EXCEPTION WHEN UNDEFINED_COLUMN THEN
        -- Do nothing, accept existing state
      END$$;

      CREATE OR REPLACE FUNCTION "upsert_ttl" (v_primary_key_value TEXT, v_primary_uuid_value UUID, v_primary_key_name TEXT, v_table_name TEXT, v_expire_at TIMESTAMP WITHOUT TIME ZONE) RETURNS void
      LANGUAGE plpgsql
      AS $$
        BEGIN
          LOOP
            UPDATE ttls
               SET expire_at = v_expire_at
             WHERE primary_key_value = v_primary_key_value
               AND table_name = v_table_name;

            IF FOUND then
              RETURN;
            END IF;

            BEGIN
              INSERT INTO ttls (primary_key_value, primary_uuid_value, primary_key_name, table_name, expire_at)
                   VALUES (v_primary_key_value, v_primary_uuid_value, v_primary_key_name, v_table_name, v_expire_at);
              RETURN;
            EXCEPTION WHEN unique_violation THEN

            END;
          END LOOP;
        END;
        $$;
    ]]
  },

  cassandra = {
    up = [[
      CREATE TABLE IF NOT EXISTS cluster_events(
        channel text,
        at      timestamp,
        node_id uuid,
        id      uuid,
        data    text,
        nbf     timestamp,
        PRIMARY KEY (channel, at, node_id, id)
      ) WITH default_time_to_live = 86400;



      CREATE TABLE IF NOT EXISTS services(
        partition       text,
        id              uuid,
        created_at      timestamp,
        updated_at      timestamp,
        name            text,
        host            text,
        path            text,
        port            int,
        protocol        text,
        connect_timeout int,
        read_timeout    int,
        write_timeout   int,
        retries         int,
        PRIMARY KEY     (partition, id)
      );
      CREATE INDEX IF NOT EXISTS services_name_idx ON services(name);



      CREATE TABLE IF NOT EXISTS routes(
        partition      text,
        id             uuid,
        created_at     timestamp,
        updated_at     timestamp,
        name           text,
        hosts          list<text>,
        paths          list<text>,
        methods        set<text>,
        protocols      set<text>,
        snis           set<text>,
        sources        set<text>,
        destinations   set<text>,
        preserve_host  boolean,
        strip_path     boolean,
        service_id     uuid,
        regex_priority int,
        PRIMARY KEY    (partition, id)
      );
      CREATE INDEX IF NOT EXISTS routes_service_id_idx ON routes(service_id);
      CREATE INDEX IF NOT EXISTS routes_name_idx ON routes(name);



      CREATE TABLE IF NOT EXISTS snis(
        partition          text,
        id                 uuid,
        name               text,
        certificate_id     uuid,
        created_at         timestamp,
        PRIMARY KEY        (partition, id)
      );
      CREATE INDEX IF NOT EXISTS snis_name_idx ON snis(name);
      CREATE INDEX IF NOT EXISTS snis_certificate_id_idx
        ON snis(certificate_id);



      CREATE TABLE IF NOT EXISTS certificates(
        partition text,
        id uuid,
        cert text,
        key text,
        created_at timestamp,
        PRIMARY KEY (partition, id)
      );



      CREATE TABLE IF NOT EXISTS consumers(
        id uuid    PRIMARY KEY,
        created_at timestamp,
        username   text,
        custom_id  text
      );
      CREATE INDEX IF NOT EXISTS consumers_username_idx ON consumers(username);
      CREATE INDEX IF NOT EXISTS consumers_custom_id_idx ON consumers(custom_id);



      CREATE TABLE IF NOT EXISTS plugins(
        id          uuid,
        created_at  timestamp,
        route_id    uuid,
        service_id  uuid,
        consumer_id uuid,
        name        text,
        config      text,
        enabled     boolean,
        cache_key   text,
        run_on      text,
        PRIMARY KEY (id)
      );
      CREATE INDEX IF NOT EXISTS plugins_name_idx ON plugins(name);
      CREATE INDEX IF NOT EXISTS plugins_route_id_idx ON plugins(route_id);
      CREATE INDEX IF NOT EXISTS plugins_service_id_idx ON plugins(service_id);
      CREATE INDEX IF NOT EXISTS plugins_consumer_id_idx ON plugins(consumer_id);
      CREATE INDEX IF NOT EXISTS plugins_cache_key_idx ON plugins(cache_key);
      CREATE INDEX IF NOT EXISTS plugins_run_on_idx ON plugins(run_on);


      CREATE TABLE IF NOT EXISTS upstreams(
        id                   uuid PRIMARY KEY,
        created_at           timestamp,
        hash_fallback        text,
        hash_fallback_header text,
        hash_on              text,
        hash_on_cookie       text,
        hash_on_cookie_path  text,
        hash_on_header       text,
        healthchecks         text,
        name                 text,
        slots                int
      );
      CREATE INDEX IF NOT EXISTS upstreams_name_idx ON upstreams(name);



      CREATE TABLE IF NOT EXISTS targets(
        id          uuid PRIMARY KEY,
        created_at  timestamp,
        target      text,
        upstream_id uuid,
        weight      int
      );
      CREATE INDEX IF NOT EXISTS targets_upstream_id_idx ON targets(upstream_id);
      CREATE INDEX IF NOT EXISTS targets_target_idx ON targets(target);


      CREATE TABLE IF NOT EXISTS cluster_ca(
        pk boolean PRIMARY KEY,
        key text,
        cert text
      );
    ]],
  },

  mongo = {
    up = [[
      @name#cluster_events
      @querytype#create
      @validator#{
        "bsonType": "object",
        "required": ["channel","at", "node_id", "id"],
        "properties": {
          "channel": { "bsonType": "string" },
          "at": { "bsonType": "timestamp" },
          "node_id": { "bsonType": "string", "format": "uri", "pattern": "^urn:uuid" },
          "id": { "bsonType": "string", "format": "uri", "pattern": "^urn:uuid" },
          "data": { "bsonType": "string" },
          "nbf": { "bsonType": "timestamp" },
          "expire_at": { "bsonType": "timestamp" }
      }
      @index#[
        { "key": { "channel": 1, "at": 1, "node_id": 1, "id": 1 }, "name": "primary_key", "unique": true },
        { "key": { "expire_at": 1 }, "name": "ttl", "expireAfterSeconds": 86400 }
      ]
      %
      @name#services
      @querytype#create
      @validator#{
        "bsonType": "object",
        "required": ["partition", "id"],
        "properties": {
          "partition": { "bsonType": "string" },
          "id": { "bsonType": "string", "format": "uri", "pattern": "^urn:uuid" },
          "created_at": { "bsonType": "timestamp" },
          "updated_at": { "bsonType": "timestamp" },
          "name": { "bsonType": "string" },
          "host": { "bsonType": "string" },
          "path": { "bsonType": "string" },
          "port": { "bsonType": "int" },
          "protocol": { "bsonType": "string" },
          "connect_timeout": { "bsonType": "int" },
          "read_timeout": { "bsonType": "int" },
          "write_timeout": { "bsonType": "int" },
          "retries": { "bsonType": "int" }
        }
      }
      @index#[
        { "key": { "partition": 1, "id": 1 }, "name": "primary_key", "unique": true },
        { "key": { "name": 1 }, "name": "services_name_idx" }
      ]
      %
      @name#routes
      @querytype#create
      @validator#{
        "bsonType": "object",
        "required": ["partition", "id"],
        "properties": {
          "partition": { "bsonType": "string" },
          "id": { "bsonType": "string", "format": "uri", "pattern": "^urn:uuid" },
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
          "service_id": { "bsonType": "string", "format": "uri", "pattern": "^urn:uuid" },
          "regex_priority": { "bsonType": "int" }
        }
      }
      @index#[
        { "key": { "partition": 1, "id": 1 }, "name": "primary_key", "unique": true },
        { "key": { "service_id": 1 }, "name": "routes_service_id_idx" },
        { "key": { "name": 1 }, "name": "routes_name_idx" }
      ]
      %
      @name#snis
      @querytype#create
      @validator#{
        "bsonType": "object",
        "required": ["partition", "id"],
        "properties": {
          "partition": { "bsonType": "string" },
          "id": { "bsonType": "string", "format": "uri", "pattern": "^urn:uuid" },
          "name": { "bsonType": "string" },
          "certificate_id": { "bsonType": "string", "format": "uri", "pattern": "^urn:uuid" },
          "created_at": { "bsonType": "timestamp" }
        }
      }
      @index#[
        { "key": { "partition": 1, "id": 1 }, "name": "primary_key", "unique": true },
        { "key": { "certificate_id": 1 }, "name": "snis_certificate_id_idx" },
        { "key": { "name": 1 }, "name": "snis_name_idx" }
      ]
      %
      @name#certificates
      @querytype#create
      @validator#{
        "bsonType": "object",
        "required": ["partition", "id"],
        "properties": {
          "partition": { "bsonType": "string" },
          "id": { "bsonType": "string", "format": "uri", "pattern": "^urn:uuid" },
          "cert": { "bsonType": "string" },
          "key": { "bsonType": "string" },
          "created_at": { "bsonType": "timestamp" }
        }
      }
      @index#[
        { "key": { "partition": 1, "id": 1 }, "name": "primary_key", "unique": true }
      ]
      %
      @name#consumers
      @querytype#create
      @validator#{
        "bsonType": "object",
        "required": ["id"],
        "properties": {
          "id": { "bsonType": "string", "format": "uri", "pattern": "^urn:uuid" },
          "created_at": { "bsonType": "timestamp" },
          "username": { "bsonType": "string" },
          "custom_id": { "bsonType": "string" }
        }
      }
      @index#[
        { "key": { "id": 1 }, "name": "primary_key", "unique": true },
        { "key": { "custom_id": 1 }, "name": "consumers_custom_id_idx" },
        { "key": { "username": 1 }, "name": "consumers_username_idx" }
      ]
      %
      @name#plugins
      @querytype#create
      @validator#{
        "bsonType": "object",
        "required": ["id"],
        "properties": {
          "id": { "bsonType": "string", "format": "uri", "pattern": "^urn:uuid" },
          "created_at": { "bsonType": "timestamp" },
          "route_id": { "bsonType": "string", "format": "uri", "pattern": "^urn:uuid" },
          "service_id": { "bsonType": "string", "format": "uri", "pattern": "^urn:uuid" },
          "consumer_id": { "bsonType": "string", "format": "uri", "pattern": "^urn:uuid" },
          "name": { "bsonType": "string" },
          "config": { "bsonType": "string" },
          "enabled": { "bsonType": "bool" },
          "cache_key": { "bsonType": "string" },
          "run_on": { "bsonType": "string" }
        }
      }
      @index#[
        { "key": { "id": 1 }, "name": "primary_key", "unique": true },
        { "key": { "name": 1 }, "name": "plugins_name_idx" },
        { "key": { "route_id": 1 }, "name": "plugins_route_id_idx" },
        { "key": { "service_id": 1 }, "name": "plugins_service_id_idx" },
        { "key": { "consumer_id": 1 }, "name": "plugins_consumer_id_idx" },
        { "key": { "cache_key": 1 }, "name": "plugins_cache_key_idx" },
        { "key": { "run_on": 1 }, "name": "plugins_run_on_idx" }
      ]
      %
      @name#upstreams
      @querytype#create
      @validator#{
        "bsonType": "object",
        "required": ["id"],
        "properties": {
          "id": { "bsonType": "string", "format": "uri", "pattern": "^urn:uuid" },
          "created_at": { "bsonType": "timestamp" },
          "hash_fallback": { "bsonType": "string" },
          "hash_fallback_header": { "bsonType": "string" },
          "hash_on": { "bsonType": "string" },
          "hash_on_cookie": { "bsonType": "string" },
          "hash_on_cookie_path": { "bsonType": "string" },
          "hash_on_header": { "bsonType": "string" },
          "healthchecks": { "bsonType": "string" },
          "name": { "bsonType": "string" },
          "slots": { "bsonType": "int" }
        }
      }
      @index#[
        { "key": { "id": 1 }, "name": "primary_key", "unique": true },
        { "key": { "name": 1 }, "name": "upstreams_name_idx" }
      ]
      %
      @name#targets
      @querytype#create
      @validator#{
        "bsonType": "object",
        "required": ["id"],
        "properties": {
          "id": { "bsonType": "string", "format": "uri", "pattern": "^urn:uuid" },
          "created_at": { "bsonType": "timestamp" },
          "target": { "bsonType": "string" },
          "upstream_id": { "bsonType": "string", "format": "uri", "pattern": "^urn:uuid" },
          "weight": { "bsonType": "int" }
        }
      }
      @index#[
        { "key": { "id": 1 }, "name": "primary_key", "unique": true },
        { "key": { "target": 1 }, "name": "targets_target_idx" },
        { "key": { "upstream_id": 1 }, "name": "targets_upstream_id_idx" }
      ]
      %
      @name#cluster_ca
      @querytype#create
      @validator#{
        "bsonType": "object",
        "required": ["id"],
        "properties": {
          "pk": { "bsonType": "bool" },
          "key": { "bsonType": "string" },
          "cert": { "bsonType": "string" }
        }
      }
      @index#[
        { "key": { "pk": 1 }, "name": "primary_key", "unique": true }
      ]
      %
    ]],
  },
}
