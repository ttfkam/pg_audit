-- ===========================================================================
-- audit PostgreSQL extension
-- Miles Elam <miles@geekspeak.org>
--
-- No dependencies
-- ---------------------------------------------------------------------------

-- complain if script is sourced in psql, rather than via CREATE EXTENSION
\echo Use "CREATE EXTENSION content_utils" to load this file. \quit

CREATE OR REPLACE VIEW oid_metadata AS
  SELECT c.oid, n.nspname AS schema_name, c.relname AS table_name
    FROM pg_class c
    JOIN pg_namespace n ON c.relnamespace = n.oid
    WHERE c.relkind = 'r'::"char" AND c.relhaspkey;

CREATE TYPE operation AS ENUM ('INSERT', 'UPDATE', 'DELETE');

CREATE TABLE audit(
    id bigserial NOT NULL PRIMARY KEY,
    row_data jsonb NOT NULL,
    archived timestamp without time zone NOT NULL DEFAULT now(),
    relation oid NOT NULL,
    op operation NOT NULL)

CREATE INDEX rel_id_idx ON audit USING btree(relation, ((row_data ->> 'id'::text)::integer));

CREATE OR REPLACE FUNCTION audit_id(row_data jsonb) RETURNS integer
LANGUAGE 'sql' IMMUTABLE LEAKPROOF STRICT AS $$
  SELECT (row_data->>'id')::integer;
$$;

COMMENT ON FUNCTION audit_id(jsonb) IS
'For use with audit table to retrieve ids and also to help query planner by using this as a'
|| 'function index part.';

CREATE OR REPLACE FUNCTION audit_oid(schema_name name, table_name name) RETURNS oid
LANGUAGE 'sql' STABLE LEAKPROOF STRICT AS $$
  SELECT oid
    FROM oid_metadata
    WHERE schema_name = schema_name AND table_name = table_name;
$$;

COMMENT ON FUNCTION audit_id(jsonb) IS
'For use with audit table to get the oid of a provided schema/table pair.';

CREATE FUNCTION audit() RETURNS trigger
LANGUAGE 'plpgsql' VOLATILE NOT LEAKPROOF SECURITY DEFINER AS $$
  BEGIN
  IF (TG_OP = 'INSERT') THEN
    INSERT INTO audit(row_data, relation, operation)
      VALUES (row_to_json(NEW), TG_RELID, TG_OP::operation);
    RETURN NEW;
  ELSIF (TG_OP = 'UPDATE') THEN
    INSERT INTO audit(row_data, relation, operation)
      VALUES (row_to_json(OLD), TG_RELID, TG_OP::operation);
    RETURN NEW;
  ELSIF (TG_OP = 'DELETE') THEN
    INSERT INTO audit(row_data, relation, operation)
      VALUES (row_to_json(OLD), TG_RELID, TG_OP::operation);
    RETURN OLD;
  ELSE
    RAISE WARNING '[AUDIT] - Other action occurred: %, at %', TG_OP, now();
    RETURN NULL;
  END IF;

  EXCEPTION
    WHEN data_exception THEN
      RAISE WARNING '[AUDIT] - UDF ERROR [DATA EXCEPTION] - SQLSTATE: %, SQLERRM: %',
                    SQLSTATE, SQLERRM;
      RETURN NULL;
    WHEN unique_violation THEN
      RAISE WARNING '[AUDIT] - UDF ERROR [UNIQUE] - SQLSTATE: %, SQLERRM: %', SQLSTATE, SQLERRM;
      RETURN NULL;
    WHEN OTHERS THEN
      RAISE WARNING '[AUDIT] - UDF ERROR [OTHER] - SQLSTATE: %, SQLERRM: %', SQLSTATE, SQLERRM;
      RETURN NULL;
  END;
$$;

COMMENT ON FUNCTION audit() IS
'For use with audit table for adding modification auditing to a table.';
