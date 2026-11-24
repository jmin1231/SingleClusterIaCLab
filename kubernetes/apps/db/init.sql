CREATE SCHEMA todo;

CREATE TABLE todo.items (
    id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    name text NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now()
);

-- Role PostgREST switches to for requests without a login token.
CREATE ROLE api_anon NOLOGIN;

GRANT USAGE ON SCHEMA todo TO api_anon;
GRANT SELECT, INSERT, UPDATE, DELETE ON todo.items TO api_anon;
GRANT USAGE ON ALL SEQUENCES IN SCHEMA todo TO api_anon;
