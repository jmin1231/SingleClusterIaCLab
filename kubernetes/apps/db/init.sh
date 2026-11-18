#!/usr/bin/env bash
set -e

: "${AUTHENTICATOR_PASSWORD:?AUTHENTICATOR_PASSWORD is required}"

psql \
  --username "${POSTGRES_USER:-postgres}" \
  --dbname "${POSTGRES_DB:-postgres}" \
  --set ON_ERROR_STOP=1 <<'SQL'

-- Read the password from the container environment.
\getenv auth_password AUTHENTICATOR_PASSWORD

BEGIN;

CREATE SCHEMA api;

CREATE TABLE api.items (
    id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    name text NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now()
);

-- Permissions used by anonymous API requests.
CREATE ROLE web_anon NOLOGIN;

GRANT USAGE ON SCHEMA api TO web_anon;
GRANT SELECT, INSERT, UPDATE, DELETE ON api.items TO web_anon;
GRANT USAGE ON ALL SEQUENCES IN SCHEMA api TO web_anon;

-- PostgREST connects with this account, then switches to web_anon.
CREATE ROLE authenticator LOGIN NOINHERIT
    PASSWORD :'auth_password';

GRANT web_anon TO authenticator;

COMMIT;
SQL