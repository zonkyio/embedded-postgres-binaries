-- Copyright (c) 2016-2018  Timescale, Inc. All Rights Reserved.
--
-- This file is licensed under the Apache License, see LICENSE-APACHE
-- at the top level directory of the TimescaleDB distribution.

-- This file is always prepended to all upgrade scripts.

-- Disable parallel execution for the duration of the update process.
-- This avoids version mismatch errors that would have beeen triggered by the
-- parallel workers in ts_extension_check_version().
SET LOCAL max_parallel_workers = 0;

-- Triggers should be disabled during upgrades to avoid having them
-- invoke functions that might load an old version of the shared
-- library before those functions have been updated.
DROP EVENT TRIGGER IF EXISTS timescaledb_ddl_command_end;
DROP EVENT TRIGGER IF EXISTS timescaledb_ddl_sql_drop;

-- These are legacy triggers. They need to be disabled here even
-- though they don't exist in newer versions, because they might still
-- exist when upgrading from older versions. Thus we need to DROP all
-- triggers here that have ever been created.
DROP TRIGGER IF EXISTS "0_cache_inval" ON _timescaledb_catalog.hypertable;
DROP TRIGGER IF EXISTS "0_cache_inval" ON _timescaledb_catalog.chunk;
DROP TRIGGER IF EXISTS "0_cache_inval" ON _timescaledb_catalog.chunk_constraint;
DROP TRIGGER IF EXISTS "0_cache_inval" ON _timescaledb_catalog.dimension_slice;
DROP TRIGGER IF EXISTS "0_cache_inval" ON _timescaledb_catalog.dimension;

CREATE OR REPLACE FUNCTION _timescaledb_internal.restart_background_workers()
RETURNS BOOL
AS '$libdir/timescaledb', 'ts_bgw_db_workers_restart'
LANGUAGE C VOLATILE;

SELECT _timescaledb_internal.restart_background_workers();

-- Table for ACL and initprivs of tables.
CREATE TABLE saved_privs(
       tmpnsp name,
       tmpname name,
       tmpacl aclitem[],
       tmpini aclitem[],
       UNIQUE (tmpnsp, tmpname));

-- We save away both the ACL and the initprivs for all tables and
-- views in the extension (but not for chunks and internal objects) so
-- that we can restore them to the proper state after the update.
INSERT INTO saved_privs
SELECT nspname, relname, relacl, initprivs
  FROM pg_class cl JOIN pg_namespace ns ON ns.oid = relnamespace
                   JOIN pg_init_privs ip ON ip.objoid = cl.oid AND ip.objsubid = 0
WHERE classoid = 'pg_class'::regclass
  AND nspname IN ('_timescaledb_catalog', '_timescaledb_config')
   OR nspname = '_timescaledb_internal'
  AND relname IN ('hypertable_chunk_local_size', 'compressed_chunk_stats',
                  'bgw_job_stat', 'bgw_policy_chunk_stats');

DROP FUNCTION IF EXISTS add_data_node;
DROP VIEW IF EXISTS timescaledb_information.continuous_aggregates;
DROP VIEW IF EXISTS timescaledb_information.job_stats;
DROP FUNCTION IF EXISTS _timescaledb_internal.get_git_commit;

-- Begin Modify hypertable table
-- we make a copy of the data, remove dependencies, drop the table
DROP VIEW IF EXISTS timescaledb_information.hypertables;
DROP VIEW IF EXISTS timescaledb_information.chunks;
DROP VIEW IF EXISTS timescaledb_information.dimensions;
DROP VIEW IF EXISTS timescaledb_information.jobs;
DROP VIEW IF EXISTS timescaledb_information.compression_settings;
DROP VIEW IF EXISTS _timescaledb_internal.compressed_chunk_stats;
DROP VIEW IF EXISTS _timescaledb_internal.hypertable_chunk_local_size;
DROP FUNCTION IF EXISTS _timescaledb_internal.hypertable_from_main_table;

CREATE TABLE _timescaledb_catalog.hypertable_tmp
AS SELECT * from _timescaledb_catalog.hypertable;

--drop foreign keys on hypertable 
ALTER TABLE _timescaledb_catalog.hypertable DROP CONSTRAINT hypertable_compressed_hypertable_id_fkey ; 
ALTER TABLE _timescaledb_catalog.hypertable_data_node DROP CONSTRAINT hypertable_data_node_hypertable_id_fkey ; 
ALTER TABLE _timescaledb_catalog.tablespace DROP CONSTRAINT tablespace_hypertable_id_fkey ; 
ALTER TABLE _timescaledb_catalog.dimension DROP CONSTRAINT dimension_hypertable_id_fkey ; 
ALTER TABLE _timescaledb_catalog.chunk DROP CONSTRAINT chunk_hypertable_id_fkey ; 
ALTER TABLE _timescaledb_catalog.chunk_index DROP CONSTRAINT chunk_index_hypertable_id_fkey ; 
ALTER TABLE _timescaledb_config.bgw_job DROP CONSTRAINT bgw_job_hypertable_id_fkey ; 
ALTER TABLE _timescaledb_catalog.continuous_agg DROP CONSTRAINT continuous_agg_mat_hypertable_id_fkey ; 
ALTER TABLE _timescaledb_catalog.continuous_agg DROP CONSTRAINT continuous_agg_raw_hypertable_id_fkey ; 
ALTER TABLE _timescaledb_catalog.continuous_aggs_invalidation_threshold DROP CONSTRAINT continuous_aggs_invalidation_threshold_hypertable_id_fkey ; 
ALTER TABLE _timescaledb_catalog.hypertable_compression DROP CONSTRAINT hypertable_compression_hypertable_id_fkey ;

CREATE TABLE tmp_hypertable_seq_value AS 
SELECT last_value, is_called FROM _timescaledb_catalog.hypertable_id_seq;
ALTER EXTENSION timescaledb DROP TABLE _timescaledb_catalog.hypertable;
ALTER EXTENSION timescaledb DROP SEQUENCE _timescaledb_catalog.hypertable_id_seq;
DROP TABLE _timescaledb_catalog.hypertable;

CREATE SEQUENCE IF NOT EXISTS _timescaledb_catalog.hypertable_id_seq MINVALUE 1;

-- now create table without self referential foreign key
CREATE TABLE IF NOT EXISTS _timescaledb_catalog.hypertable(
  id INTEGER PRIMARY KEY DEFAULT nextval('_timescaledb_catalog.hypertable_id_seq'),
  schema_name name NOT NULL CHECK (schema_name != '_timescaledb_catalog'),
  table_name name NOT NULL,
  associated_schema_name name NOT NULL,
  associated_table_prefix name NOT NULL,
  num_dimensions smallint NOT NULL,
  chunk_sizing_func_schema name NOT NULL,
  chunk_sizing_func_name name NOT NULL,
  chunk_target_size bigint NOT NULL CHECK (chunk_target_size >= 0), -- size in bytes
  compression_state smallint NOT NULL DEFAULT 0,
  compressed_hypertable_id integer ,
  replication_factor smallint NULL,
  UNIQUE (associated_schema_name, associated_table_prefix),
  CONSTRAINT hypertable_table_name_schema_name_key UNIQUE (table_name, schema_name),
  -- internal compressed hypertables have compression state = 2
  CONSTRAINT hypertable_dim_compress_check CHECK (num_dimensions > 0 OR compression_state = 2),
  CONSTRAINT hypertable_compress_check CHECK ( (compression_state = 0 OR compression_state = 1 )  OR (compression_state = 2 AND compressed_hypertable_id IS NULL)),
  -- replication_factor NULL: regular hypertable
  -- replication_factor > 0: distributed hypertable on access node
  -- replication_factor -1: distributed hypertable on data node, which is part of a larger table
  CONSTRAINT hypertable_replication_factor_check CHECK (replication_factor > 0 OR replication_factor = -1)
);
ALTER SEQUENCE _timescaledb_catalog.hypertable_id_seq OWNED BY _timescaledb_catalog.hypertable.id;
SELECT pg_catalog.pg_extension_config_dump('_timescaledb_catalog.hypertable_id_seq', '');
SELECT setval('_timescaledb_catalog.hypertable_id_seq', last_value, is_called) FROM tmp_hypertable_seq_value;

INSERT INTO _timescaledb_catalog.hypertable
( id, schema_name, table_name, associated_schema_name, associated_table_prefix,
       num_dimensions, chunk_sizing_func_schema, chunk_sizing_func_name,
       chunk_target_size, compression_state, compressed_hypertable_id,
       replication_factor)
SELECT id, schema_name, table_name, associated_schema_name, associated_table_prefix,
       num_dimensions, chunk_sizing_func_schema, chunk_sizing_func_name,
       chunk_target_size,
       CASE WHEN compressed is FALSE  AND compressed_hypertable_id IS NOT NULL THEN 1
            WHEN compressed is TRUE THEN 2
            ELSE 0 
       END,
       compressed_hypertable_id,
       replication_factor
FROM _timescaledb_catalog.hypertable_tmp;
 
-- add self referential foreign key
ALTER TABLE _timescaledb_catalog.hypertable ADD CONSTRAINT hypertable_compressed_hypertable_id_fkey FOREIGN KEY ( compressed_hypertable_id )
 REFERENCES _timescaledb_catalog.hypertable( id );
SELECT pg_catalog.pg_extension_config_dump('_timescaledb_catalog.hypertable', '');
--cleanup
DROP TABLE _timescaledb_catalog.hypertable_tmp;
DROP TABLE tmp_hypertable_seq_value;

-- add all the other foreign keys
ALTER TABLE _timescaledb_catalog.hypertable_data_node 
ADD CONSTRAINT hypertable_data_node_hypertable_id_fkey
FOREIGN KEY ( hypertable_id ) REFERENCES _timescaledb_catalog.hypertable( id ); 
ALTER TABLE _timescaledb_catalog.tablespace ADD CONSTRAINT tablespace_hypertable_id_fkey 
FOREIGN KEY ( hypertable_id ) REFERENCES _timescaledb_catalog.hypertable( id ) 
ON DELETE CASCADE; 
ALTER TABLE _timescaledb_catalog.dimension ADD CONSTRAINT dimension_hypertable_id_fkey 
FOREIGN KEY ( hypertable_id ) REFERENCES _timescaledb_catalog.hypertable( id ) 
ON DELETE CASCADE; 
ALTER TABLE _timescaledb_catalog.chunk ADD CONSTRAINT chunk_hypertable_id_fkey 
FOREIGN KEY ( hypertable_id ) REFERENCES _timescaledb_catalog.hypertable( id ); 
ALTER TABLE _timescaledb_catalog.chunk_index ADD CONSTRAINT chunk_index_hypertable_id_fkey 
FOREIGN KEY ( hypertable_id ) REFERENCES _timescaledb_catalog.hypertable( id ) 
ON DELETE CASCADE; 
ALTER TABLE _timescaledb_config.bgw_job ADD CONSTRAINT bgw_job_hypertable_id_fkey 
FOREIGN KEY ( hypertable_id ) REFERENCES _timescaledb_catalog.hypertable( id )
ON DELETE CASCADE; 
ALTER TABLE _timescaledb_catalog.continuous_agg ADD CONSTRAINT 
continuous_agg_mat_hypertable_id_fkey FOREIGN KEY ( mat_hypertable_id ) 
REFERENCES _timescaledb_catalog.hypertable( id ) 
ON DELETE CASCADE; 
ALTER TABLE _timescaledb_catalog.continuous_agg ADD CONSTRAINT 
continuous_agg_raw_hypertable_id_fkey FOREIGN KEY ( raw_hypertable_id ) 
REFERENCES _timescaledb_catalog.hypertable( id ) 
ON DELETE CASCADE; 
ALTER TABLE _timescaledb_catalog.continuous_aggs_invalidation_threshold 
ADD CONSTRAINT continuous_aggs_invalidation_threshold_hypertable_id_fkey 
FOREIGN KEY (hypertable_id) REFERENCES _timescaledb_catalog.hypertable( id ) 
ON DELETE CASCADE; 
ALTER TABLE _timescaledb_catalog.hypertable_compression ADD CONSTRAINT 
hypertable_compression_hypertable_id_fkey FOREIGN KEY ( hypertable_id ) 
REFERENCES _timescaledb_catalog.hypertable( id )
ON DELETE CASCADE; 

GRANT SELECT ON _timescaledb_catalog.hypertable_id_seq TO PUBLIC;
GRANT SELECT ON _timescaledb_catalog.hypertable TO PUBLIC;
--End Modify hypertable table
ALTER TABLE _timescaledb_catalog.hypertable
  DROP CONSTRAINT hypertable_replication_factor_check,
  ADD CONSTRAINT hypertable_replication_factor_check CHECK (replication_factor > 0 OR replication_factor = -1);
-- For continuous aggregates: Copy ACL privileges (grants) from the
-- query view (user-facing object) to the internal objects (e.g.,
-- materialized hypertable, direct, and partial views). We want to
-- maintain the abstraction that a continuous aggregates is similar to
-- a materialized view (which is one object), so privileges on the
-- user-facing object should apply also to the internal objects that
-- implement the continuous aggregate. Having the right permissions on
-- internal objects is necessary for the watermark function used by
-- real-time aggregation since it queries the materialized hypertable
-- directly.

WITH rels_and_acl AS (
    -- For each cagg, collect an array of all relations (including
    -- chunks) to copy the ACL to
    SELECT array_cat(ARRAY[format('%I.%I', h.schema_name, h.table_name)::regclass,
	                       format('%I.%I', direct_view_schema, direct_view_name)::regclass,
                           format('%I.%I', partial_view_schema, partial_view_name)::regclass],
                     (SELECT array_agg(inhrelid::regclass)
                      FROM pg_inherits
                      WHERE inhparent = format('%I.%I', h.schema_name, h.table_name)::regclass)) AS relarr,
           relacl AS user_view_acl
    FROM _timescaledb_catalog.continuous_agg ca
    LEFT JOIN pg_class cl
    ON (cl.oid = format('%I.%I', user_view_schema, user_view_name)::regclass)
    LEFT JOIN _timescaledb_catalog.hypertable h
    ON (ca.mat_hypertable_id = h.id)
    WHERE relacl IS NOT NULL
)
-- Set the ACL on all internal cagg relations, including
-- chunks. Note that we cannot use GRANT statements because
-- such statements are recorded as privileges on extension
-- objects when run in an update script. The result is that
-- the privileges will become init privileges, which will then
-- be ignored by, e.g., pg_dump.
UPDATE pg_class
SET relacl = user_view_acl
FROM rels_and_acl
WHERE oid = ANY (relarr);
-- set compressed_chunk_id to NULL for dropped chunks
UPDATE _timescaledb_catalog.chunk SET compressed_chunk_id = NULL WHERE dropped = true AND compressed_chunk_id IS NOT NULL;
DROP VIEW IF EXISTS _timescaledb_internal.hypertable_chunk_local_size;
DROP VIEW IF EXISTS _timescaledb_internal.compressed_chunk_stats;
-- Recreate _timescaledb_catalog.chunk table --
CREATE TABLE _timescaledb_catalog.chunk_tmp
AS SELECT * from _timescaledb_catalog.chunk;

CREATE TABLE tmp_chunk_seq_value AS
SELECT last_value, is_called FROM _timescaledb_catalog.chunk_id_seq;

--drop foreign keys on chunk table
ALTER TABLE _timescaledb_catalog.chunk_constraint DROP CONSTRAINT 
chunk_constraint_chunk_id_fkey;
ALTER TABLE _timescaledb_catalog.chunk_index DROP CONSTRAINT 
chunk_index_chunk_id_fkey;
ALTER TABLE _timescaledb_catalog.chunk_data_node DROP CONSTRAINT 
chunk_data_node_chunk_id_fkey;
ALTER TABLE _timescaledb_internal.bgw_policy_chunk_stats DROP CONSTRAINT 
bgw_policy_chunk_stats_chunk_id_fkey;
ALTER TABLE _timescaledb_catalog.compression_chunk_size DROP CONSTRAINT 
compression_chunk_size_chunk_id_fkey;
ALTER TABLE _timescaledb_catalog.compression_chunk_size DROP CONSTRAINT 
compression_chunk_size_compressed_chunk_id_fkey;

--drop dependent views
DROP VIEW IF EXISTS timescaledb_information.hypertables;
DROP VIEW IF EXISTS timescaledb_information.chunks;
DROP VIEW IF EXISTS _timescaledb_internal.hypertable_chunk_local_size;
DROP VIEW IF EXISTS _timescaledb_internal.compressed_chunk_stats;

ALTER EXTENSION timescaledb DROP TABLE _timescaledb_catalog.chunk;
ALTER EXTENSION timescaledb DROP SEQUENCE _timescaledb_catalog.chunk_id_seq;
DROP TABLE _timescaledb_catalog.chunk;

CREATE SEQUENCE IF NOT EXISTS _timescaledb_catalog.chunk_id_seq MINVALUE 1;

-- now create table without self referential foreign key
CREATE TABLE IF NOT EXISTS _timescaledb_catalog.chunk (
  id integer PRIMARY KEY DEFAULT nextval('_timescaledb_catalog.chunk_id_seq'),
  hypertable_id int NOT NULL REFERENCES _timescaledb_catalog.hypertable (id),
  schema_name name NOT NULL,
  table_name name NOT NULL,
  compressed_chunk_id integer ,
  dropped boolean NOT NULL DEFAULT FALSE,
  status integer NOT NULL DEFAULT 0,
  UNIQUE (schema_name, table_name)
);

INSERT INTO _timescaledb_catalog.chunk
( id, hypertable_id, schema_name, table_name,
  compressed_chunk_id, dropped, status)
SELECT id, hypertable_id, schema_name, table_name,
  compressed_chunk_id, dropped, (
    CASE
      WHEN compressed_chunk_id IS NULL THEN 0
      ELSE 1
    END
  )
FROM _timescaledb_catalog.chunk_tmp;

--add indexes to the chunk table
CREATE INDEX IF NOT EXISTS chunk_hypertable_id_idx ON _timescaledb_catalog.chunk (hypertable_id);
CREATE INDEX IF NOT EXISTS chunk_compressed_chunk_id_idx ON _timescaledb_catalog.chunk (compressed_chunk_id);

ALTER SEQUENCE _timescaledb_catalog.chunk_id_seq OWNED BY _timescaledb_catalog.chunk.id;
SELECT setval('_timescaledb_catalog.chunk_id_seq', last_value, is_called) FROM tmp_chunk_seq_value;

-- add self referential foreign key
ALTER TABLE _timescaledb_catalog.chunk ADD CONSTRAINT chunk_compressed_chunk_id_fkey FOREIGN KEY ( compressed_chunk_id )
 REFERENCES _timescaledb_catalog.chunk( id );
SELECT pg_catalog.pg_extension_config_dump('_timescaledb_catalog.chunk', '');
SELECT pg_catalog.pg_extension_config_dump('_timescaledb_catalog.chunk_id_seq', '');

--add the foreign key constraints
ALTER TABLE _timescaledb_catalog.chunk_constraint ADD CONSTRAINT 
chunk_constraint_chunk_id_fkey FOREIGN KEY (chunk_id) REFERENCES _timescaledb_catalog.chunk(id); 
ALTER TABLE _timescaledb_catalog.chunk_index ADD CONSTRAINT
chunk_index_chunk_id_fkey FOREIGN KEY (chunk_id) 
REFERENCES _timescaledb_catalog.chunk(id) ON DELETE CASCADE;
ALTER TABLE _timescaledb_catalog.chunk_data_node ADD CONSTRAINT
chunk_data_node_chunk_id_fkey FOREIGN KEY (chunk_id) REFERENCES _timescaledb_catalog.chunk(id);  
ALTER TABLE _timescaledb_internal.bgw_policy_chunk_stats ADD CONSTRAINT
bgw_policy_chunk_stats_chunk_id_fkey FOREIGN KEY (chunk_id) 
REFERENCES _timescaledb_catalog.chunk(id) ON DELETE CASCADE; 
ALTER TABLE _timescaledb_catalog.compression_chunk_size ADD CONSTRAINT
compression_chunk_size_chunk_id_fkey FOREIGN KEY (chunk_id) 
REFERENCES _timescaledb_catalog.chunk(id) ON DELETE CASCADE; 
ALTER TABLE _timescaledb_catalog.compression_chunk_size ADD CONSTRAINT
compression_chunk_size_compressed_chunk_id_fkey FOREIGN KEY (compressed_chunk_id) 
REFERENCES _timescaledb_catalog.chunk(id) ON DELETE CASCADE; 

--cleanup
DROP TABLE _timescaledb_catalog.chunk_tmp;
DROP TABLE tmp_chunk_seq_value;

GRANT SELECT ON _timescaledb_catalog.chunk_id_seq TO PUBLIC;
GRANT SELECT ON _timescaledb_catalog.chunk TO PUBLIC;

-- end recreate _timescaledb_catalog.chunk table --

-- First we update the permissions of the compressed hypertables to
-- match the associated hypertable.
WITH
    hypertables AS (
	SELECT format('%I.%I', ht.schema_name, ht.table_name)::regclass AS hypertable_oid,
	       format('%I.%I', ct.schema_name, ct.table_name)::regclass AS compressed_hypertable_oid
	FROM _timescaledb_catalog.hypertable ht
	JOIN _timescaledb_catalog.hypertable ct ON ht.compressed_hypertable_id = ct.id
    )
UPDATE pg_class
   SET relacl = (SELECT relacl FROM pg_class WHERE oid = hypertable_oid)
  FROM hypertables
 WHERE oid = compressed_hypertable_oid;

-- Now we update the permissions of chunks of both compressed and
-- uncompressed hypertables to match the permissions of the associated
-- hypertable.
WITH
    chunks AS (
        SELECT format('%I.%I', ht.schema_name, ht.table_name)::regclass AS hypertable_oid,
               format('%I.%I', ch.schema_name, ch.table_name)::regclass AS chunk_oid
          FROM _timescaledb_catalog.hypertable ht
	  JOIN _timescaledb_catalog.chunk ch ON ht.id = ch.hypertable_id
	  WHERE NOT ch.dropped
    )
UPDATE pg_class
   SET relacl = (SELECT relacl FROM pg_class WHERE oid = hypertable_oid)
  FROM chunks
 WHERE oid = chunk_oid;

DROP FUNCTION IF EXISTS _timescaledb_internal.chunk_dml_blocker CASCADE;

-- drop the view as view definition changed
DROP VIEW IF EXISTS _timescaledb_internal.hypertable_chunk_local_size;
DROP FUNCTION IF EXISTS _timescaledb_internal.refresh_continuous_aggregate;
CREATE SCHEMA IF NOT EXISTS timescaledb_experimental;
GRANT USAGE ON SCHEMA timescaledb_experimental TO PUBLIC;
DROP FUNCTION IF EXISTS _timescaledb_internal.block_new_chunks;
DROP FUNCTION IF EXISTS _timescaledb_internal.allow_new_chunks;
DROP FUNCTION IF EXISTS _timescaledb_internal.refresh_continuous_aggregate;
DROP FUNCTION IF EXISTS _timescaledb_internal.create_chunk;

CREATE SEQUENCE IF NOT EXISTS _timescaledb_catalog.chunk_copy_operation_id_seq MINVALUE 1;

CREATE TABLE IF NOT EXISTS _timescaledb_catalog.chunk_copy_operation (
  operation_id name PRIMARY KEY, -- the publisher/subscriber identifier used
  backend_pid integer NOT NULL, -- the pid of the backend running this activity
  completed_stage name NOT NULL, -- the completed stage/step
  time_start timestamptz NOT NULL DEFAULT NOW(), -- start time of the activity
  chunk_id integer NOT NULL REFERENCES _timescaledb_catalog.chunk (id) ON DELETE CASCADE,
  source_node_name name NOT NULL,
  dest_node_name name NOT NULL,
  delete_on_source_node bool NOT NULL -- is a move or copy activity
);

GRANT SELECT ON _timescaledb_catalog.chunk_copy_operation_id_seq TO PUBLIC;
GRANT SELECT ON _timescaledb_catalog.chunk_copy_operation TO PUBLIC;
DROP FUNCTION IF EXISTS _timescaledb_internal.time_col_name_for_chunk(name,name);
DROP FUNCTION IF EXISTS _timescaledb_internal.time_col_type_for_chunk(name,name);

-- Handle column renames for continuous aggregates that were not
-- handled correctly and fix it in the update. We save the information
-- in a table.
CREATE UNLOGGED TABLE rename_tables (
       user_view regclass,
       new_name text,
       old_name text,
       partial_view regclass,
       direct_view regclass,
       mat_table regclass,
       hypertable_id int
);

-- Compare the user view and the direct view of each continuous
-- aggregate to figure out what columns that were renamed on the user
-- view but which did not propagate to the other objects of the
-- continuous aggregate since this did not work in previous versions.
WITH
  objs AS (
        SELECT format('%I.%I', user_view_schema, user_view_name)::regclass AS user_view,
               format('%I.%I', direct_view_schema, direct_view_name)::regclass AS direct_view,
               format('%I.%I', partial_view_schema, partial_view_name)::regclass AS partial_view,
               format('%I.%I', schema_name, table_name)::regclass AS mat_table,
               mat_hypertable_id AS mat_id
          FROM _timescaledb_catalog.continuous_agg
          JOIN _timescaledb_catalog.hypertable ON mat_hypertable_id = id),
  user_view AS (
        SELECT attrelid, attname, attnum, mat_id
          FROM objs, pg_attribute
         WHERE attrelid = objs.user_view),
  direct_view AS (
        SELECT attrelid, attname, attnum, mat_id
          FROM objs, pg_attribute
         WHERE attrelid = objs.direct_view)
INSERT INTO rename_tables
SELECT (SELECT user_view FROM objs WHERE uv.attrelid = user_view),
       uv.attname AS new_name,
       dv.attname AS old_name,
       (SELECT partial_view FROM objs WHERE uv.attrelid = user_view),
       (SELECT direct_view FROM objs WHERE uv.attrelid = user_view),
       (SELECT mat_table FROM objs WHERE uv.attrelid = user_view),
       (SELECT mat_id FROM objs WHERE uv.attrelid = user_view)
  FROM user_view uv JOIN direct_view dv USING (mat_id, attnum)
 WHERE uv.attname != dv.attname;

CREATE PROCEDURE alter_table_column(cagg regclass, relation regclass, old_column_name name, new_column_name name) AS $$
BEGIN
    EXECUTE format('ALTER TABLE %s RENAME COLUMN %I TO %I', relation, old_column_name, new_column_name);
END;
$$ LANGUAGE plpgsql;

-- Rename the columns for all the associated objects for continuous
-- aggregates that have renamed columns. Also rename the column in the
-- dimension table.
DO
$$
DECLARE
    user_view regclass;
    new_name name;
    old_name name;
    partial_view regclass;
    direct_view regclass;
    mat_table regclass;
    ht_id int;
BEGIN
  FOR user_view, new_name, old_name, partial_view, direct_view, mat_table, ht_id IN
  SELECT * FROM rename_tables
  LOOP
    -- There is no RENAME COLUMN for views, but we can use ALTER TABLE
    -- to rename a column in a view.
    CALL alter_table_column(user_view, partial_view, old_name, new_name);
    CALL alter_table_column(user_view, direct_view, old_name, new_name);
    CALL alter_table_column(user_view, mat_table, old_name, new_name);
    UPDATE _timescaledb_catalog.dimension SET column_name = new_name
     WHERE hypertable_id = ht_id AND column_name = old_name;
  END LOOP;
END
$$;

DROP PROCEDURE alter_table_column;
DROP TABLE rename_tables;
DROP FUNCTION IF EXISTS _timescaledb_internal.time_col_name_for_chunk(name,name);
DROP FUNCTION IF EXISTS _timescaledb_internal.time_col_type_for_chunk(name,name);
-- Remove old compression policy procedures
DROP PROCEDURE IF EXISTS _timescaledb_internal.policy_compression_interval(INTEGER, INTEGER, INTERVAL, INTEGER, BOOLEAN, BOOLEAN);
DROP PROCEDURE IF EXISTS _timescaledb_internal.policy_compression_integer(INTEGER, INTEGER, BIGINT, INTEGER, BOOLEAN, BOOLEAN);
-- This file and its contents are licensed under the Apache License 2.0.
-- Please see the included NOTICE for copyright information and
-- LICENSE-APACHE for a copy of the license.


-- Functions have to be run in 2 places:
-- 1) In pre-install between types.pre.sql and types.post.sql to set up the types.
-- 2) On every update to make sure the function points to the correct versioned.so


-- PostgreSQL composite types do not support constraint checks. That is why any table having a ts_interval column must use the following
-- function for constraint validation.
-- This function needs to be defined before executing pre_install/tables.sql because it is used as
-- validation constraint for columns of type ts_interval.

--the textual input/output is simply base64 encoding of the binary representation
CREATE OR REPLACE FUNCTION _timescaledb_internal.compressed_data_in(CSTRING)
   RETURNS _timescaledb_internal.compressed_data
   AS '$libdir/timescaledb-2.5.1', 'ts_compressed_data_in'
   LANGUAGE C IMMUTABLE STRICT;

CREATE OR REPLACE FUNCTION _timescaledb_internal.compressed_data_out(_timescaledb_internal.compressed_data)
   RETURNS CSTRING
   AS '$libdir/timescaledb-2.5.1', 'ts_compressed_data_out'
   LANGUAGE C IMMUTABLE STRICT;

CREATE OR REPLACE FUNCTION _timescaledb_internal.compressed_data_send(_timescaledb_internal.compressed_data)
   RETURNS BYTEA
   AS '$libdir/timescaledb-2.5.1', 'ts_compressed_data_send'
   LANGUAGE C IMMUTABLE STRICT;

CREATE OR REPLACE FUNCTION _timescaledb_internal.compressed_data_recv(internal)
   RETURNS _timescaledb_internal.compressed_data
   AS '$libdir/timescaledb-2.5.1', 'ts_compressed_data_recv'
   LANGUAGE C IMMUTABLE STRICT;

-- Remote transation ID implementation
CREATE OR REPLACE FUNCTION _timescaledb_internal.rxid_in(cstring) RETURNS rxid
    AS '$libdir/timescaledb-2.5.1', 'ts_remote_txn_id_in' LANGUAGE C IMMUTABLE STRICT PARALLEL SAFE;

CREATE OR REPLACE FUNCTION _timescaledb_internal.rxid_out(rxid) RETURNS cstring
    AS '$libdir/timescaledb-2.5.1', 'ts_remote_txn_id_out' LANGUAGE C IMMUTABLE STRICT PARALLEL SAFE;
-- This file and its contents are licensed under the Apache License 2.0.
-- Please see the included NOTICE for copyright information and
-- LICENSE-APACHE for a copy of the license.

CREATE OR REPLACE FUNCTION timescaledb_fdw_handler()
RETURNS fdw_handler
AS '$libdir/timescaledb-2.5.1', 'ts_timescaledb_fdw_handler'
LANGUAGE C STRICT;

CREATE OR REPLACE FUNCTION timescaledb_fdw_validator(text[], oid)
RETURNS void
AS '$libdir/timescaledb-2.5.1', 'ts_timescaledb_fdw_validator'
LANGUAGE C STRICT;

-- This file and its contents are licensed under the Apache License 2.0.
-- Please see the included NOTICE for copyright information and
-- LICENSE-APACHE for a copy of the license.

-- Trigger that blocks INSERTs on the hypertable's root table
CREATE OR REPLACE FUNCTION _timescaledb_internal.insert_blocker() RETURNS trigger
AS '$libdir/timescaledb-2.5.1', 'ts_hypertable_insert_blocker' LANGUAGE C;

-- Records mutations or INSERTs which would invalidate a continuous aggregate
CREATE OR REPLACE FUNCTION _timescaledb_internal.continuous_agg_invalidation_trigger() RETURNS TRIGGER
AS '$libdir/timescaledb-2.5.1', 'ts_continuous_agg_invalidation_trigger' LANGUAGE C;

CREATE OR REPLACE FUNCTION set_integer_now_func(hypertable REGCLASS, integer_now_func REGPROC, replace_if_exists BOOL = false) RETURNS VOID
AS '$libdir/timescaledb-2.5.1', 'ts_hypertable_set_integer_now_func'
LANGUAGE C VOLATILE STRICT;
-- This file and its contents are licensed under the Apache License 2.0.
-- Please see the included NOTICE for copyright information and
-- LICENSE-APACHE for a copy of the license.

-- Built-in function for calculating the next chunk interval when
-- using adaptive chunking. The function can be replaced by a
-- user-defined function with the same signature.
--
-- The parameters passed to the function are as follows:
--
-- dimension_id: the ID of the dimension to calculate the interval for
-- dimension_coord: the coordinate / point on the dimensional axis
-- where the tuple that triggered this chunk creation falls.
-- chunk_target_size: the target size in bytes that the chunk should have.
--
-- The function should return the new interval in dimension-specific
-- time (ususally microseconds).
CREATE OR REPLACE FUNCTION _timescaledb_internal.calculate_chunk_interval(
        dimension_id INTEGER,
        dimension_coord BIGINT,
        chunk_target_size BIGINT
) RETURNS BIGINT AS '$libdir/timescaledb-2.5.1', 'ts_calculate_chunk_interval' LANGUAGE C;

-- Function for explicit chunk exclusion. Supply a record and an array
-- of chunk ids as input.
-- Intended to be used in WHERE clause.
-- An example: SELECT * FROM hypertable WHERE _timescaledb_internal.chunks_in(hypertable, ARRAY[1,2]);
--
-- Use it with care as this function directly affects what chunks are being scanned for data.
-- This is a marker function and should never be executed (we remove it from the plan)
CREATE OR REPLACE FUNCTION _timescaledb_internal.chunks_in(record RECORD, chunks INTEGER[]) RETURNS BOOL
AS '$libdir/timescaledb-2.5.1', 'ts_chunks_in' LANGUAGE C STABLE STRICT PARALLEL SAFE;

--given a chunk's relid, return the id. Error out if not a chunk relid.
CREATE OR REPLACE FUNCTION _timescaledb_internal.chunk_id_from_relid(relid OID) RETURNS INTEGER
AS '$libdir/timescaledb-2.5.1', 'ts_chunk_id_from_relid' LANGUAGE C STABLE STRICT PARALLEL SAFE;

-- Show the definition of a chunk.
CREATE OR REPLACE FUNCTION _timescaledb_internal.show_chunk(chunk REGCLASS)
RETURNS TABLE(chunk_id INTEGER, hypertable_id INTEGER, schema_name NAME, table_name NAME, relkind "char", slices JSONB)
AS '$libdir/timescaledb-2.5.1', 'ts_chunk_show' LANGUAGE C VOLATILE;

-- Create a chunk with the given dimensional constraints (slices) as
-- given in the JSONB. If chunk_table is a valid relation, it will be
-- attached to the hypertable and used as the data table for the new
-- chunk. Note that schema_name and table_name need not be the same as
-- the existing schema and name for chunk_table. The provided chunk
-- table will be renamed and/or moved as necessary.
CREATE OR REPLACE FUNCTION _timescaledb_internal.create_chunk(
       hypertable REGCLASS,
       slices JSONB,	   
       schema_name NAME = NULL,
       table_name NAME = NULL,
	   chunk_table REGCLASS = NULL)
RETURNS TABLE(chunk_id INTEGER, hypertable_id INTEGER, schema_name NAME, table_name NAME, relkind "char", slices JSONB, created BOOLEAN)
AS '$libdir/timescaledb-2.5.1', 'ts_chunk_create' LANGUAGE C VOLATILE;

-- change default data node for a chunk
CREATE OR REPLACE FUNCTION _timescaledb_internal.set_chunk_default_data_node(chunk REGCLASS, node_name NAME) RETURNS BOOLEAN
AS '$libdir/timescaledb-2.5.1', 'ts_chunk_set_default_data_node' LANGUAGE C VOLATILE;

-- Get chunk stats.
CREATE OR REPLACE FUNCTION _timescaledb_internal.get_chunk_relstats(relid REGCLASS)
RETURNS TABLE(chunk_id INTEGER, hypertable_id INTEGER, num_pages INTEGER, num_tuples REAL, num_allvisible INTEGER)
AS '$libdir/timescaledb-2.5.1', 'ts_chunk_get_relstats' LANGUAGE C VOLATILE;

CREATE OR REPLACE FUNCTION _timescaledb_internal.get_chunk_colstats(relid REGCLASS)
RETURNS TABLE(chunk_id INTEGER, hypertable_id INTEGER, att_num INTEGER, nullfrac REAL, width INTEGER, distinctval REAL, slotkind INTEGER[], slotopstrings CSTRING[], slotcollations OID[],
slot1numbers FLOAT4[], slot2numbers FLOAT4[], slot3numbers FLOAT4[], slot4numbers FLOAT4[], slot5numbers FLOAT4[],
slotvaluetypetrings CSTRING[], slot1values CSTRING[], slot2values CSTRING[], slot3values CSTRING[], slot4values CSTRING[], slot5values CSTRING[])
AS '$libdir/timescaledb-2.5.1', 'ts_chunk_get_colstats' LANGUAGE C VOLATILE;

CREATE OR REPLACE FUNCTION _timescaledb_internal.create_chunk_table(
       hypertable REGCLASS,
       slices JSONB,
       schema_name NAME,
       table_name NAME)
RETURNS BOOL AS '$libdir/timescaledb-2.5.1', 'ts_chunk_create_empty_table' LANGUAGE C VOLATILE;
-- This file and its contents are licensed under the Apache License 2.0.
-- Please see the included NOTICE for copyright information and
-- LICENSE-APACHE for a copy of the license.

-- Check if a data node is up
CREATE OR REPLACE FUNCTION _timescaledb_internal.ping_data_node(node_name NAME) RETURNS BOOLEAN
AS '$libdir/timescaledb-2.5.1', 'ts_data_node_ping' LANGUAGE C VOLATILE;

CREATE OR REPLACE FUNCTION _timescaledb_internal.remote_txn_heal_data_node(foreign_server_oid oid)
RETURNS INT
AS '$libdir/timescaledb-2.5.1', 'ts_remote_txn_heal_data_node'
LANGUAGE C STRICT;
-- This file and its contents are licensed under the Apache License 2.0.
-- Please see the included NOTICE for copyright information and
-- LICENSE-APACHE for a copy of the license.

--documentation of these function located in chunk_index.h
CREATE OR REPLACE FUNCTION _timescaledb_internal.chunk_index_clone(chunk_index_oid OID) RETURNS OID
AS '$libdir/timescaledb-2.5.1', 'ts_chunk_index_clone' LANGUAGE C VOLATILE STRICT;

CREATE OR REPLACE FUNCTION _timescaledb_internal.chunk_index_replace(chunk_index_oid_old OID, chunk_index_oid_new OID) RETURNS VOID
AS '$libdir/timescaledb-2.5.1', 'ts_chunk_index_replace' LANGUAGE C VOLATILE STRICT;

CREATE OR REPLACE FUNCTION _timescaledb_internal.create_chunk_replica_table(
    chunk REGCLASS,
    data_node_name NAME
) RETURNS VOID AS '$libdir/timescaledb-2.5.1', 'ts_chunk_create_replica_table' LANGUAGE C VOLATILE;

-- Drop the specified chunk replica on the specified data node
CREATE OR REPLACE FUNCTION  _timescaledb_internal.chunk_drop_replica(
    chunk                   REGCLASS,
    node_name               NAME
) RETURNS VOID
AS '$libdir/timescaledb-2.5.1', 'ts_chunk_drop_replica' LANGUAGE C VOLATILE;

CREATE OR REPLACE PROCEDURE _timescaledb_internal.wait_subscription_sync(
    schema_name    NAME,
    table_name     NAME,
    retry_count    INT DEFAULT 18000,
    retry_delay_ms NUMERIC DEFAULT 0.200
)
LANGUAGE PLPGSQL AS
$BODY$
DECLARE
    in_sync BOOLEAN;
BEGIN
    FOR i in 1 .. retry_count
    LOOP
        SELECT pgs.srsubstate = 'r'
        INTO in_sync
        FROM pg_subscription_rel pgs
        JOIN pg_class pgc ON relname = table_name
        JOIN pg_namespace n ON (n.OID = pgc.relnamespace)
        WHERE pgs.srrelid = pgc.oid AND schema_name = n.nspname;

        if (in_sync IS NULL OR NOT in_sync) THEN
          PERFORM pg_sleep(retry_delay_ms);
        ELSE
          RETURN;
        END IF;
    END LOOP;
    RAISE 'subscription sync wait timedout';
END
$BODY$;
-- This file and its contents are licensed under the Apache License 2.0.
-- Please see the included NOTICE for copyright information and
-- LICENSE-APACHE for a copy of the license.

------------------------------------------------------------------------
-- Experimental DDL functions and APIs.
-- 
-- Users should not rely on these functions unless they accept that
-- they can change and/or be removed at any time.
------------------------------------------------------------------------

-- Block new chunk creation on a data node for a distributed
-- hypertable. NULL hypertable means it will block chunks for all
-- distributed hypertables
CREATE OR REPLACE FUNCTION timescaledb_experimental.block_new_chunks(data_node_name NAME, hypertable REGCLASS = NULL, force BOOLEAN = FALSE) RETURNS INTEGER
AS '$libdir/timescaledb-2.5.1', 'ts_data_node_block_new_chunks' LANGUAGE C VOLATILE;

-- Allow chunk creation on a blocked data node for a distributed
-- hypertable. NULL hypertable means it will allow chunks for all
-- distributed hypertables
CREATE OR REPLACE FUNCTION timescaledb_experimental.allow_new_chunks(data_node_name NAME, hypertable REGCLASS = NULL) RETURNS INTEGER
AS '$libdir/timescaledb-2.5.1', 'ts_data_node_allow_new_chunks' LANGUAGE C VOLATILE;

CREATE OR REPLACE FUNCTION timescaledb_experimental.refresh_continuous_aggregate(
    continuous_aggregate     REGCLASS,
    hypertable_chunk         REGCLASS
) RETURNS VOID AS '$libdir/timescaledb-2.5.1', 'ts_continuous_agg_refresh_chunk' LANGUAGE C VOLATILE;

CREATE OR REPLACE PROCEDURE timescaledb_experimental.move_chunk(
    chunk REGCLASS,
    source_node NAME = NULL,
    destination_node NAME = NULL)
AS '$libdir/timescaledb-2.5.1', 'ts_move_chunk_proc' LANGUAGE C;

CREATE OR REPLACE PROCEDURE timescaledb_experimental.copy_chunk(
    chunk REGCLASS,
    source_node NAME = NULL,
    destination_node NAME = NULL)
AS '$libdir/timescaledb-2.5.1', 'ts_copy_chunk_proc' LANGUAGE C;

-- A copy_chunk or move_chunk procedure call involves multiple nodes and
-- depending on the data size can take a long time. Failures are possible
-- when this long running activity is ongoing. We need to be able to recover
-- and cleanup such failed chunk copy/move activities and it's done via this
-- procedure
CREATE OR REPLACE PROCEDURE timescaledb_experimental.cleanup_copy_chunk_operation(
    operation_id NAME)
AS '$libdir/timescaledb-2.5.1', 'ts_copy_chunk_cleanup_proc' LANGUAGE C;
-- This file and its contents are licensed under the Apache License 2.0.
-- Please see the included NOTICE for copyright information and
-- LICENSE-APACHE for a copy of the license.

-- This file contains utilities for time conversion.
CREATE OR REPLACE FUNCTION _timescaledb_internal.to_unix_microseconds(ts TIMESTAMPTZ) RETURNS BIGINT
    AS '$libdir/timescaledb-2.5.1', 'ts_pg_timestamp_to_unix_microseconds' LANGUAGE C IMMUTABLE STRICT PARALLEL SAFE;

CREATE OR REPLACE FUNCTION _timescaledb_internal.to_timestamp(unixtime_us BIGINT) RETURNS TIMESTAMPTZ
    AS '$libdir/timescaledb-2.5.1', 'ts_pg_unix_microseconds_to_timestamp' LANGUAGE C IMMUTABLE STRICT PARALLEL SAFE;

CREATE OR REPLACE FUNCTION _timescaledb_internal.to_timestamp_without_timezone(unixtime_us BIGINT)
  RETURNS TIMESTAMP
  AS '$libdir/timescaledb-2.5.1', 'ts_pg_unix_microseconds_to_timestamp'
  LANGUAGE C IMMUTABLE STRICT PARALLEL SAFE;

CREATE OR REPLACE FUNCTION _timescaledb_internal.to_date(unixtime_us BIGINT)
  RETURNS DATE
  AS '$libdir/timescaledb-2.5.1', 'ts_pg_unix_microseconds_to_date'
  LANGUAGE C IMMUTABLE STRICT PARALLEL SAFE;

CREATE OR REPLACE FUNCTION _timescaledb_internal.to_interval(unixtime_us BIGINT) RETURNS INTERVAL
    AS '$libdir/timescaledb-2.5.1', 'ts_pg_unix_microseconds_to_interval' LANGUAGE C IMMUTABLE STRICT PARALLEL SAFE;

-- Time can be represented in a hypertable as an int* (bigint/integer/smallint) or as a timestamp type (
-- with or without timezones). In metatables and other internal systems all time values are stored as bigint.
-- Converting from int* columns to internal representation is a cast to bigint.
-- Converting from timestamps to internal representation is conversion to epoch (in microseconds).

-- Gets the sql code for representing the literal for the given time value (in the internal representation) as the column_type.
CREATE OR REPLACE FUNCTION _timescaledb_internal.time_literal_sql(
    time_value      BIGINT,
    column_type     REGTYPE
)
    RETURNS text LANGUAGE PLPGSQL STABLE AS
$BODY$
DECLARE
    ret text;
BEGIN
    IF time_value IS NULL THEN
        RETURN format('%L', NULL);
    END IF;
    CASE column_type
      WHEN 'BIGINT'::regtype, 'INTEGER'::regtype, 'SMALLINT'::regtype THEN
        RETURN format('%L', time_value); -- scale determined by user.
      WHEN 'TIMESTAMP'::regtype THEN
        --the time_value for timestamps w/o tz does not depend on local timezones. So perform at UTC.
        RETURN format('TIMESTAMP %1$L', timezone('UTC',_timescaledb_internal.to_timestamp(time_value))); -- microseconds
      WHEN 'TIMESTAMPTZ'::regtype THEN
        -- assume time_value is in microsec
        RETURN format('TIMESTAMPTZ %1$L', _timescaledb_internal.to_timestamp(time_value)); -- microseconds
      WHEN 'DATE'::regtype THEN
        RETURN format('%L', timezone('UTC',_timescaledb_internal.to_timestamp(time_value))::date);
      ELSE
         EXECUTE 'SELECT format(''%L'', $1::' || column_type::text || ')' into ret using time_value;
         RETURN ret;
    END CASE;
END
$BODY$;

CREATE OR REPLACE FUNCTION _timescaledb_internal.interval_to_usec(
       chunk_interval INTERVAL
)
RETURNS BIGINT LANGUAGE SQL IMMUTABLE PARALLEL SAFE AS
$BODY$
    SELECT (int_sec * 1000000)::bigint from extract(epoch from chunk_interval) as int_sec;
$BODY$;

CREATE OR REPLACE FUNCTION _timescaledb_internal.time_to_internal(time_val ANYELEMENT)
RETURNS BIGINT AS '$libdir/timescaledb-2.5.1', 'ts_time_to_internal' LANGUAGE C VOLATILE STRICT;

CREATE OR REPLACE FUNCTION _timescaledb_internal.cagg_watermark(hypertable_id INTEGER)
RETURNS INT8 AS '$libdir/timescaledb-2.5.1', 'ts_continuous_agg_watermark' LANGUAGE C STABLE STRICT;

CREATE OR REPLACE FUNCTION _timescaledb_internal.subtract_integer_from_now( hypertable_relid REGCLASS, lag INT8 )
RETURNS INT8 AS '$libdir/timescaledb-2.5.1', 'ts_subtract_integer_from_now' LANGUAGE C STABLE STRICT;
-- This file and its contents are licensed under the Apache License 2.0.
-- Please see the included NOTICE for copyright information and
-- LICENSE-APACHE for a copy of the license.

-- This file contains functions associated with creating new
-- hypertables.

CREATE OR REPLACE FUNCTION _timescaledb_internal.dimension_is_finite(
    val      BIGINT
)
    RETURNS BOOLEAN LANGUAGE SQL IMMUTABLE PARALLEL SAFE AS
$BODY$
    --end values of bigint reserved for infinite
    SELECT val > (-9223372036854775808)::bigint AND val < 9223372036854775807::bigint
$BODY$;


CREATE OR REPLACE FUNCTION _timescaledb_internal.dimension_slice_get_constraint_sql(
    dimension_slice_id  INTEGER
)
    RETURNS TEXT LANGUAGE PLPGSQL VOLATILE AS
$BODY$
DECLARE
    dimension_slice_row _timescaledb_catalog.dimension_slice;
    dimension_row _timescaledb_catalog.dimension;
    dimension_def TEXT;
    dimtype REGTYPE;
    parts TEXT[];
BEGIN
    SELECT * INTO STRICT dimension_slice_row
    FROM _timescaledb_catalog.dimension_slice
    WHERE id = dimension_slice_id;

    SELECT * INTO STRICT dimension_row
    FROM _timescaledb_catalog.dimension
    WHERE id = dimension_slice_row.dimension_id;

    IF dimension_row.partitioning_func_schema IS NOT NULL AND
       dimension_row.partitioning_func IS NOT NULL THEN
        SELECT prorettype INTO STRICT dimtype
        FROM pg_catalog.pg_proc pro
        WHERE pro.oid = format('%I.%I', dimension_row.partitioning_func_schema, dimension_row.partitioning_func)::regproc::oid;

        dimension_def := format('%1$I.%2$I(%3$I)',
             dimension_row.partitioning_func_schema,
             dimension_row.partitioning_func,
             dimension_row.column_name);
    ELSE
        dimension_def := format('%1$I', dimension_row.column_name);
        dimtype := dimension_row.column_type;
    END IF;

    IF dimension_row.num_slices IS NOT NULL THEN

        IF  _timescaledb_internal.dimension_is_finite(dimension_slice_row.range_start) THEN
            parts = parts || format(' %1$s >= %2$L ', dimension_def, dimension_slice_row.range_start);
        END IF;

        IF _timescaledb_internal.dimension_is_finite(dimension_slice_row.range_end) THEN
            parts = parts || format(' %1$s < %2$L ', dimension_def, dimension_slice_row.range_end);
        END IF;

        IF array_length(parts, 1) = 0 THEN
            RETURN NULL;
        END IF;
        return array_to_string(parts, 'AND');
    ELSE
        -- only works with time for now
        IF _timescaledb_internal.time_literal_sql(dimension_slice_row.range_start, dimtype) =
           _timescaledb_internal.time_literal_sql(dimension_slice_row.range_end, dimtype) THEN
            RAISE 'time-based constraints have the same start and end values for column "%": %',
                    dimension_row.column_name,
                    _timescaledb_internal.time_literal_sql(dimension_slice_row.range_end, dimtype);
        END IF;

        parts = ARRAY[]::text[];

        IF _timescaledb_internal.dimension_is_finite(dimension_slice_row.range_start) THEN
            parts = parts || format(' %1$s >= %2$s ',
            dimension_def,
            _timescaledb_internal.time_literal_sql(dimension_slice_row.range_start, dimtype));
        END IF;

        IF _timescaledb_internal.dimension_is_finite(dimension_slice_row.range_end) THEN
            parts = parts || format(' %1$s < %2$s ',
            dimension_def,
            _timescaledb_internal.time_literal_sql(dimension_slice_row.range_end, dimtype));
        END IF;

        return array_to_string(parts, 'AND');
    END IF;
END
$BODY$;

-- Outputs the create_hypertable command to recreate the given hypertable.
--
-- This is currently used internally for our single hypertable backup tool
-- so that it knows how to restore the hypertable without user intervention.
--
-- It only works for hypertables with up to 2 dimensions.
CREATE OR REPLACE FUNCTION _timescaledb_internal.get_create_command(
    table_name NAME
)
    RETURNS TEXT LANGUAGE PLPGSQL VOLATILE AS
$BODY$
DECLARE
    h_id             INTEGER;
    schema_name      NAME;
    time_column      NAME;
    time_interval    BIGINT;
    space_column     NAME;
    space_partitions INTEGER;
    dimension_cnt    INTEGER;
    dimension_row    record;
    ret              TEXT;
BEGIN
    SELECT h.id, h.schema_name
    FROM _timescaledb_catalog.hypertable AS h
    WHERE h.table_name = get_create_command.table_name
    INTO h_id, schema_name;

    IF h_id IS NULL THEN
        RAISE EXCEPTION 'hypertable "%" not found', table_name
        USING ERRCODE = 'TS101';
    END IF;

    SELECT COUNT(*)
    FROM _timescaledb_catalog.dimension d
    WHERE d.hypertable_id = h_id
    INTO STRICT dimension_cnt;

    IF dimension_cnt > 2 THEN
        RAISE EXCEPTION 'get_create_command only supports hypertables with up to 2 dimensions'
        USING ERRCODE = 'TS101';
    END IF;

    FOR dimension_row IN
        SELECT *
        FROM _timescaledb_catalog.dimension d
        WHERE d.hypertable_id = h_id
        LOOP
        IF dimension_row.interval_length IS NOT NULL THEN
            time_column := dimension_row.column_name;
            time_interval := dimension_row.interval_length;
        ELSIF dimension_row.num_slices IS NOT NULL THEN
            space_column := dimension_row.column_name;
            space_partitions := dimension_row.num_slices;
        END IF;
    END LOOP;

    ret := format($$SELECT create_hypertable('%I.%I', '%s'$$, schema_name, table_name, time_column);
    IF space_column IS NOT NULL THEN
        ret := ret || format($$, '%I', %s$$, space_column, space_partitions);
    END IF;
    ret := ret || format($$, chunk_time_interval => %s, create_default_indexes=>FALSE);$$, time_interval);

    RETURN ret;
END
$BODY$;
-- This file and its contents are licensed under the Apache License 2.0.
-- Please see the included NOTICE for copyright information and
-- LICENSE-APACHE for a copy of the license.

-- create constraint on newly created chunk based on hypertable constraint
CREATE OR REPLACE FUNCTION _timescaledb_internal.chunk_constraint_add_table_constraint(
    chunk_constraint_row  _timescaledb_catalog.chunk_constraint
)
    RETURNS VOID LANGUAGE PLPGSQL AS
$BODY$
DECLARE
    chunk_row _timescaledb_catalog.chunk;
    hypertable_row _timescaledb_catalog.hypertable;
    constraint_oid OID;
    constraint_type CHAR;
    check_sql TEXT;
    def TEXT;
    indx_tablespace NAME;
    tablespace_def TEXT;
BEGIN
    SELECT * INTO STRICT chunk_row FROM _timescaledb_catalog.chunk c WHERE c.id = chunk_constraint_row.chunk_id;
    SELECT * INTO STRICT hypertable_row FROM _timescaledb_catalog.hypertable h WHERE h.id = chunk_row.hypertable_id;

    IF chunk_constraint_row.dimension_slice_id IS NOT NULL THEN
        check_sql = _timescaledb_internal.dimension_slice_get_constraint_sql(chunk_constraint_row.dimension_slice_id);
        IF check_sql IS NOT NULL THEN
            def := format('CHECK (%s)',  check_sql);
        ELSE
            def := NULL;
        END IF;
    ELSIF chunk_constraint_row.hypertable_constraint_name IS NOT NULL THEN

        SELECT oid, contype INTO STRICT constraint_oid, constraint_type FROM pg_constraint
        WHERE conname=chunk_constraint_row.hypertable_constraint_name AND
              conrelid = format('%I.%I', hypertable_row.schema_name, hypertable_row.table_name)::regclass::oid;

        IF constraint_type IN ('p','u') THEN
          -- since primary keys and unique constraints are backed by an index
          -- they might have an index tablespace assigned
          -- the tablspace is not part of the constraint definition so
          -- we have to append it explicitly to preserve it
          SELECT T.spcname INTO indx_tablespace
          FROM pg_constraint C, pg_class I, pg_tablespace T
          WHERE C.oid = constraint_oid AND C.contype IN ('p', 'u') AND I.oid = C.conindid AND I.reltablespace = T.oid;

          def := pg_get_constraintdef(constraint_oid);

          IF indx_tablespace IS NOT NULL THEN
            def := format('%s USING INDEX TABLESPACE %I', def, indx_tablespace);
          END IF;

        ELSIF constraint_type = 't' THEN
          -- constraint triggers are copied separately with normal triggers
          def := NULL;
        ELSE
          def := pg_get_constraintdef(constraint_oid);
        END IF;

    ELSE
        RAISE 'unknown constraint type';
    END IF;

    IF def IS NOT NULL THEN
        EXECUTE format(
            $$ ALTER TABLE %I.%I ADD CONSTRAINT %I %s $$,
            chunk_row.schema_name, chunk_row.table_name, chunk_constraint_row.constraint_name, def
        );
    END IF;
END
$BODY$;
-- This file and its contents are licensed under the Apache License 2.0.
-- Please see the included NOTICE for copyright information and
-- LICENSE-APACHE for a copy of the license.

-- Clone fk constraint from a hypertable
CREATE OR REPLACE FUNCTION _timescaledb_internal.hypertable_constraint_add_table_fk_constraint(
    user_ht_constraint_name NAME,
    user_ht_schema_name NAME,
    user_ht_table_name NAME,
    compress_ht_id INTEGER
)
    RETURNS VOID LANGUAGE PLPGSQL AS
$BODY$
DECLARE
    compressed_ht_row _timescaledb_catalog.hypertable;
    constraint_oid OID;
    check_sql TEXT;
    def TEXT;
BEGIN
    SELECT * INTO STRICT compressed_ht_row FROM _timescaledb_catalog.hypertable h
    WHERE h.id = compress_ht_id;
    IF user_ht_constraint_name IS NOT NULL THEN
        SELECT oid INTO STRICT constraint_oid FROM pg_constraint
        WHERE conname=user_ht_constraint_name AND contype = 'f' AND
              conrelid = format('%I.%I', user_ht_schema_name, user_ht_table_name)::regclass::oid;
        def := pg_get_constraintdef(constraint_oid);
    ELSE
        RAISE 'unknown constraint type';
    END IF;
    IF def IS NOT NULL THEN
        EXECUTE format(
            $$ ALTER TABLE %I.%I ADD CONSTRAINT %I %s $$,
            compressed_ht_row.schema_name, compressed_ht_row.table_name, user_ht_constraint_name, def
        );
    END IF;

END
$BODY$;
-- This file and its contents are licensed under the Apache License 2.0.
-- Please see the included NOTICE for copyright information and
-- LICENSE-APACHE for a copy of the license.

-- Deprecated partition hash function
CREATE OR REPLACE FUNCTION _timescaledb_internal.get_partition_for_key(val anyelement)
    RETURNS int
    AS '$libdir/timescaledb-2.5.1', 'ts_get_partition_for_key' LANGUAGE C IMMUTABLE STRICT PARALLEL SAFE;

CREATE OR REPLACE FUNCTION _timescaledb_internal.get_partition_hash(val anyelement)
    RETURNS int
    AS '$libdir/timescaledb-2.5.1', 'ts_get_partition_hash' LANGUAGE C IMMUTABLE STRICT PARALLEL SAFE;

CREATE OR REPLACE FUNCTION _timescaledb_internal.get_time_type(hypertable_id INTEGER)
    RETURNS OID
    AS '$libdir/timescaledb-2.5.1', 'ts_hypertable_get_time_type' LANGUAGE C STABLE STRICT;
-- This file and its contents are licensed under the Apache License 2.0.
-- Please see the included NOTICE for copyright information and
-- LICENSE-APACHE for a copy of the license.

-- This file contains functions related to getting information about the
-- schema of a hypertable, including columns, their types, etc.


-- Check if a given table OID is a main table (i.e. the table a user
-- targets for SQL operations) for a hypertable
CREATE OR REPLACE FUNCTION _timescaledb_internal.is_main_table(
    table_oid regclass
)
    RETURNS bool LANGUAGE SQL STABLE AS
$BODY$
    SELECT EXISTS(SELECT 1 FROM _timescaledb_catalog.hypertable WHERE table_name = relname AND schema_name = nspname)
    FROM pg_class c
    INNER JOIN pg_namespace n ON (n.OID = c.relnamespace)
    WHERE c.OID = table_oid;
$BODY$;

-- Check if given table is a hypertable's main table
CREATE OR REPLACE FUNCTION _timescaledb_internal.is_main_table(
    schema_name NAME,
    table_name  NAME
)
    RETURNS BOOLEAN LANGUAGE SQL STABLE AS
$BODY$
     SELECT EXISTS(
         SELECT 1 FROM _timescaledb_catalog.hypertable h
         WHERE h.schema_name = is_main_table.schema_name AND 
               h.table_name = is_main_table.table_name
     );
$BODY$;

-- Get a hypertable given its main table OID
CREATE OR REPLACE FUNCTION _timescaledb_internal.hypertable_from_main_table(
    table_oid regclass
)
    RETURNS _timescaledb_catalog.hypertable LANGUAGE SQL STABLE AS
$BODY$
    SELECT h.*
    FROM pg_class c
    INNER JOIN pg_namespace n ON (n.OID = c.relnamespace)
    INNER JOIN _timescaledb_catalog.hypertable h ON (h.table_name = c.relname AND h.schema_name = n.nspname)
    WHERE c.OID = table_oid;
$BODY$;

CREATE OR REPLACE FUNCTION _timescaledb_internal.main_table_from_hypertable(
    hypertable_id int
)
    RETURNS regclass LANGUAGE SQL STABLE AS
$BODY$
    SELECT format('%I.%I',h.schema_name, h.table_name)::regclass
    FROM _timescaledb_catalog.hypertable h
    WHERE id = hypertable_id;
$BODY$;
-- This file and its contents are licensed under the Apache License 2.0.
-- Please see the included NOTICE for copyright information and
-- LICENSE-APACHE for a copy of the license.

-- This file defines DDL functions for adding and manipulating hypertables.

-- Converts a regular postgres table to a hypertable.
--
-- relation - The OID of the table to be converted
-- time_column_name - Name of the column that contains time for a given record
-- partitioning_column - Name of the column to partition data by
-- number_partitions - (Optional) Number of partitions for data
-- associated_schema_name - (Optional) Schema for internal hypertable tables
-- associated_table_prefix - (Optional) Prefix for internal hypertable table names
-- chunk_time_interval - (Optional) Initial time interval for a chunk
-- create_default_indexes - (Optional) Whether or not to create the default indexes
-- if_not_exists - (Optional) Do not fail if table is already a hypertable
-- partitioning_func - (Optional) The partitioning function to use for spatial partitioning
-- migrate_data - (Optional) Set to true to migrate any existing data in the table to chunks
-- chunk_target_size - (Optional) The target size for chunks (e.g., '1000MB', 'estimate', or 'off')
-- chunk_sizing_func - (Optional) A function to calculate the chunk time interval for new chunks
-- time_partitioning_func - (Optional) The partitioning function to use for "time" partitioning
-- replication_factor - (Optional) A value of 1 or greater makes this hypertable distributed
-- data_nodes - (Optional) The specific data nodes to distribute this hypertable across
CREATE OR REPLACE FUNCTION  create_hypertable(
    relation                REGCLASS,
    time_column_name        NAME,
    partitioning_column     NAME = NULL,
    number_partitions       INTEGER = NULL,
    associated_schema_name  NAME = NULL,
    associated_table_prefix NAME = NULL,
    chunk_time_interval     ANYELEMENT = NULL::bigint,
    create_default_indexes  BOOLEAN = TRUE,
    if_not_exists           BOOLEAN = FALSE,
    partitioning_func       REGPROC = NULL,
    migrate_data            BOOLEAN = FALSE,
    chunk_target_size       TEXT = NULL,
    chunk_sizing_func       REGPROC = '_timescaledb_internal.calculate_chunk_interval'::regproc,
    time_partitioning_func  REGPROC = NULL,
    replication_factor      INTEGER = NULL,
    data_nodes              NAME[] = NULL
) RETURNS TABLE(hypertable_id INT, schema_name NAME, table_name NAME, created BOOL) AS '$libdir/timescaledb-2.5.1', 'ts_hypertable_create' LANGUAGE C VOLATILE;

-- Same functionality as create_hypertable, only must have a replication factor > 0 (defaults to 1)
CREATE OR REPLACE FUNCTION  create_distributed_hypertable(
    relation                REGCLASS,
    time_column_name        NAME,
    partitioning_column     NAME = NULL,
    number_partitions       INTEGER = NULL,
    associated_schema_name  NAME = NULL,
    associated_table_prefix NAME = NULL,
    chunk_time_interval     ANYELEMENT = NULL::bigint,
    create_default_indexes  BOOLEAN = TRUE,
    if_not_exists           BOOLEAN = FALSE,
    partitioning_func       REGPROC = NULL,
    migrate_data            BOOLEAN = FALSE,
    chunk_target_size       TEXT = NULL,
    chunk_sizing_func       REGPROC = '_timescaledb_internal.calculate_chunk_interval'::regproc,
    time_partitioning_func  REGPROC = NULL,
    replication_factor      INTEGER = 1,
    data_nodes              NAME[] = NULL
) RETURNS TABLE(hypertable_id INT, schema_name NAME, table_name NAME, created BOOL) AS '$libdir/timescaledb-2.5.1', 'ts_hypertable_distributed_create' LANGUAGE C VOLATILE;

-- Set adaptive chunking. To disable, set chunk_target_size => 'off'.
CREATE OR REPLACE FUNCTION  set_adaptive_chunking(
    hypertable                     REGCLASS,
    chunk_target_size              TEXT,
    INOUT chunk_sizing_func        REGPROC = '_timescaledb_internal.calculate_chunk_interval'::regproc,
    OUT chunk_target_size          BIGINT
) RETURNS RECORD AS '$libdir/timescaledb-2.5.1', 'ts_chunk_adaptive_set' LANGUAGE C VOLATILE;

-- Update chunk_time_interval for a hypertable.
--
-- hypertable - The OID of the table corresponding to a hypertable whose time
--     interval should be updated
-- chunk_time_interval - The new time interval. For hypertables with integral
--     time columns, this must be an integral type. For hypertables with a
--     TIMESTAMP/TIMESTAMPTZ/DATE type, it can be integral which is treated as
--     microseconds, or an INTERVAL type.
CREATE OR REPLACE FUNCTION  set_chunk_time_interval(
    hypertable              REGCLASS,
    chunk_time_interval     ANYELEMENT,
    dimension_name          NAME = NULL
) RETURNS VOID AS '$libdir/timescaledb-2.5.1', 'ts_dimension_set_interval' LANGUAGE C VOLATILE;

CREATE OR REPLACE FUNCTION  set_number_partitions(
    hypertable              REGCLASS,
    number_partitions       INTEGER,
    dimension_name          NAME = NULL
) RETURNS VOID AS '$libdir/timescaledb-2.5.1', 'ts_dimension_set_num_slices' LANGUAGE C VOLATILE;

-- Drop chunks older than the given timestamp for the specific
-- hypertable or continuous aggregate.
CREATE OR REPLACE FUNCTION drop_chunks(
    relation               REGCLASS,
    older_than             "any" = NULL,
    newer_than             "any" = NULL,
    verbose                BOOLEAN = FALSE
) RETURNS SETOF TEXT AS '$libdir/timescaledb-2.5.1', 'ts_chunk_drop_chunks'
LANGUAGE C VOLATILE PARALLEL UNSAFE;

-- show chunks older than or newer than a specific time.
-- `relation` must be a valid hypertable or continuous aggregate.
CREATE OR REPLACE FUNCTION show_chunks(
    relation               REGCLASS,
    older_than             "any" = NULL,
    newer_than             "any" = NULL
) RETURNS SETOF REGCLASS AS '$libdir/timescaledb-2.5.1', 'ts_chunk_show_chunks'
LANGUAGE C STABLE PARALLEL SAFE;

-- Add a dimension (of partitioning) to a hypertable
--
-- hypertable - OID of the table to add a dimension to
-- column_name - NAME of the column to use in partitioning for this dimension
-- number_partitions - Number of partitions, for non-time dimensions
-- interval_length - Size of intervals for time dimensions (can be integral or INTERVAL)
-- partitioning_func - Function used to partition the column
-- if_not_exists - If set, and the dimension already exists, generate a notice instead of an error
CREATE OR REPLACE FUNCTION  add_dimension(
    hypertable              REGCLASS,
    column_name             NAME,
    number_partitions       INTEGER = NULL,
    chunk_time_interval     ANYELEMENT = NULL::BIGINT,
    partitioning_func       REGPROC = NULL,
    if_not_exists           BOOLEAN = FALSE
) RETURNS TABLE(dimension_id INT, schema_name NAME, table_name NAME, column_name NAME, created BOOL)
AS '$libdir/timescaledb-2.5.1', 'ts_dimension_add' LANGUAGE C VOLATILE;

CREATE OR REPLACE FUNCTION attach_tablespace(
    tablespace NAME,
    hypertable REGCLASS,
    if_not_attached BOOLEAN = false
) RETURNS VOID
AS '$libdir/timescaledb-2.5.1', 'ts_tablespace_attach' LANGUAGE C VOLATILE;

CREATE OR REPLACE FUNCTION detach_tablespace(
    tablespace NAME,
    hypertable REGCLASS = NULL,
    if_attached BOOLEAN = false
) RETURNS INTEGER
AS '$libdir/timescaledb-2.5.1', 'ts_tablespace_detach' LANGUAGE C VOLATILE;

CREATE OR REPLACE FUNCTION detach_tablespaces(hypertable REGCLASS) RETURNS INTEGER
AS '$libdir/timescaledb-2.5.1', 'ts_tablespace_detach_all_from_hypertable' LANGUAGE C VOLATILE;

CREATE OR REPLACE FUNCTION show_tablespaces(hypertable REGCLASS) RETURNS SETOF NAME
AS '$libdir/timescaledb-2.5.1', 'ts_tablespace_show' LANGUAGE C VOLATILE STRICT;

-- Add a data node to a TimescaleDB distributed database.
CREATE OR REPLACE FUNCTION add_data_node(
    node_name              NAME,
    host                   TEXT,
    database               NAME = NULL,
    port                   INTEGER = NULL,
    if_not_exists          BOOLEAN = FALSE,
    bootstrap              BOOLEAN = TRUE,
    password               TEXT = NULL
) RETURNS TABLE(node_name NAME, host TEXT, port INTEGER, database NAME,
                node_created BOOL, database_created BOOL, extension_created BOOL)
AS '$libdir/timescaledb-2.5.1', 'ts_data_node_add' LANGUAGE C VOLATILE;

-- Delete a data node from a distributed database
CREATE OR REPLACE FUNCTION delete_data_node(
    node_name              NAME,
    if_exists              BOOLEAN = FALSE,
    force                  BOOLEAN = FALSE,
    repartition            BOOLEAN = TRUE
) RETURNS BOOLEAN AS '$libdir/timescaledb-2.5.1', 'ts_data_node_delete' LANGUAGE C VOLATILE;

-- Attach a data node to a distributed hypertable
CREATE OR REPLACE FUNCTION attach_data_node(
    node_name              NAME,
    hypertable             REGCLASS,
    if_not_attached        BOOLEAN = FALSE,
    repartition            BOOLEAN = TRUE
) RETURNS TABLE(hypertable_id INTEGER, node_hypertable_id INTEGER, node_name NAME)
AS '$libdir/timescaledb-2.5.1', 'ts_data_node_attach' LANGUAGE C VOLATILE;

-- Detach a data node from a distributed hypertable. NULL hypertable means it will detach from all distributed hypertables
CREATE OR REPLACE FUNCTION detach_data_node(
    node_name              NAME,
    hypertable             REGCLASS = NULL,
    if_attached            BOOLEAN = FALSE,
    force                  BOOLEAN = FALSE,
    repartition            BOOLEAN = TRUE
) RETURNS INTEGER
AS '$libdir/timescaledb-2.5.1', 'ts_data_node_detach' LANGUAGE C VOLATILE;

-- Execute query on a specified list of data nodes. By default node_list is NULL, which means
-- to execute the query on every data node
CREATE OR REPLACE PROCEDURE distributed_exec(
       query TEXT,
       node_list name[] = NULL,
       transactional BOOLEAN = TRUE)
AS '$libdir/timescaledb-2.5.1', 'ts_distributed_exec' LANGUAGE C;

-- Execute pg_create_restore_point() on each data node
CREATE OR REPLACE FUNCTION create_distributed_restore_point(
    name                   TEXT
) RETURNS TABLE(node_name NAME, node_type TEXT, restore_point pg_lsn)
AS '$libdir/timescaledb-2.5.1', 'ts_create_distributed_restore_point' LANGUAGE C VOLATILE STRICT;

-- Sets new replication factor for distributed hypertable
CREATE OR REPLACE FUNCTION  set_replication_factor(
    hypertable              REGCLASS,
    replication_factor      INTEGER
) RETURNS VOID
AS '$libdir/timescaledb-2.5.1', 'ts_hypertable_distributed_set_replication_factor' LANGUAGE C VOLATILE;

-- Refresh a continuous aggregate across the given window.
CREATE OR REPLACE PROCEDURE refresh_continuous_aggregate(
    continuous_aggregate     REGCLASS,
    window_start             "any",
    window_end               "any"
) LANGUAGE C AS '$libdir/timescaledb-2.5.1', 'ts_continuous_agg_refresh';
-- This file and its contents are licensed under the Apache License 2.0.
-- Please see the included NOTICE for copyright information and
-- LICENSE-APACHE for a copy of the license.

DROP EVENT TRIGGER IF EXISTS timescaledb_ddl_command_end;

CREATE OR REPLACE FUNCTION _timescaledb_internal.process_ddl_event() RETURNS event_trigger
AS '$libdir/timescaledb-2.5.1', 'ts_timescaledb_process_ddl_event' LANGUAGE C;

--EVENT TRIGGER MUST exclude the ALTER EXTENSION tag.
CREATE EVENT TRIGGER timescaledb_ddl_command_end ON ddl_command_end
WHEN TAG IN ('ALTER TABLE','CREATE TRIGGER','CREATE TABLE','CREATE INDEX','ALTER INDEX', 'DROP TABLE', 'DROP INDEX', 'DROP SCHEMA')
EXECUTE FUNCTION _timescaledb_internal.process_ddl_event();

DROP EVENT TRIGGER IF EXISTS timescaledb_ddl_sql_drop;
CREATE EVENT TRIGGER timescaledb_ddl_sql_drop ON sql_drop
EXECUTE FUNCTION _timescaledb_internal.process_ddl_event();
-- This file and its contents are licensed under the Apache License 2.0.
-- Please see the included NOTICE for copyright information and
-- LICENSE-APACHE for a copy of the license.

CREATE OR REPLACE FUNCTION _timescaledb_internal.first_sfunc(internal, anyelement, "any")
RETURNS internal
AS '$libdir/timescaledb-2.5.1', 'ts_first_sfunc'
LANGUAGE C IMMUTABLE PARALLEL SAFE;

CREATE OR REPLACE FUNCTION _timescaledb_internal.first_combinefunc(internal, internal)
RETURNS internal
AS '$libdir/timescaledb-2.5.1', 'ts_first_combinefunc'
LANGUAGE C IMMUTABLE PARALLEL SAFE;

CREATE OR REPLACE FUNCTION _timescaledb_internal.last_sfunc(internal, anyelement, "any")
RETURNS internal
AS '$libdir/timescaledb-2.5.1', 'ts_last_sfunc'
LANGUAGE C IMMUTABLE PARALLEL SAFE;

CREATE OR REPLACE FUNCTION _timescaledb_internal.last_combinefunc(internal, internal)
RETURNS internal
AS '$libdir/timescaledb-2.5.1', 'ts_last_combinefunc'
LANGUAGE C IMMUTABLE PARALLEL SAFE;

CREATE OR REPLACE FUNCTION _timescaledb_internal.bookend_finalfunc(internal, anyelement, "any")
RETURNS anyelement
AS '$libdir/timescaledb-2.5.1', 'ts_bookend_finalfunc'
LANGUAGE C IMMUTABLE PARALLEL SAFE;

CREATE OR REPLACE FUNCTION _timescaledb_internal.bookend_serializefunc(internal)
RETURNS bytea
AS '$libdir/timescaledb-2.5.1', 'ts_bookend_serializefunc'
LANGUAGE C IMMUTABLE STRICT PARALLEL SAFE;

CREATE OR REPLACE FUNCTION _timescaledb_internal.bookend_deserializefunc(bytea, internal)
RETURNS internal
AS '$libdir/timescaledb-2.5.1', 'ts_bookend_deserializefunc'
LANGUAGE C IMMUTABLE STRICT PARALLEL SAFE;


-- We started using CREATE OR REPLACE AGGREGATE for aggregate creation once the syntax was fully supported
-- as it is easier to support idempotent changes this way. This will allow for changes to functions supporting
-- the aggregate, and, for instance, the definition and inclusion of inverse functions for window function
-- support. However, it should still be noted that changes to the data structures used for the internal
-- state of the aggregate must be backwards compatible and the old format must be accepted by any new functions
-- in order for them to continue working with Continuous Aggregates, where old states may have been materialized.

--This aggregate returns the "first" value of the first argument when ordered by the second argument.
--Ex. first(temp, time) returns the temp value for the row with the lowest time
CREATE OR REPLACE AGGREGATE first(anyelement, "any") (
    SFUNC = _timescaledb_internal.first_sfunc,
    STYPE = internal,
    COMBINEFUNC = _timescaledb_internal.first_combinefunc,
    SERIALFUNC = _timescaledb_internal.bookend_serializefunc,
    DESERIALFUNC = _timescaledb_internal.bookend_deserializefunc,
    PARALLEL = SAFE,
    FINALFUNC = _timescaledb_internal.bookend_finalfunc,
    FINALFUNC_EXTRA
);

--This aggregate returns the "last" value of the first argument when ordered by the second argument.
--Ex. last(temp, time) returns the temp value for the row with highest time
CREATE OR REPLACE AGGREGATE last(anyelement, "any") (
    SFUNC = _timescaledb_internal.last_sfunc,
    STYPE = internal,
    COMBINEFUNC = _timescaledb_internal.last_combinefunc,
    SERIALFUNC = _timescaledb_internal.bookend_serializefunc,
    DESERIALFUNC = _timescaledb_internal.bookend_deserializefunc,
    PARALLEL = SAFE,
    FINALFUNC = _timescaledb_internal.bookend_finalfunc,
    FINALFUNC_EXTRA
);
-- This file and its contents are licensed under the Apache License 2.0.
-- Please see the included NOTICE for copyright information and
-- LICENSE-APACHE for a copy of the license.

-- time_bucket returns the left edge of the bucket where ts falls into.
-- Buckets span an interval of time equal to the bucket_width and are aligned with the epoch.
CREATE OR REPLACE FUNCTION time_bucket(bucket_width INTERVAL, ts TIMESTAMP) RETURNS TIMESTAMP
	AS '$libdir/timescaledb-2.5.1', 'ts_timestamp_bucket' LANGUAGE C IMMUTABLE PARALLEL SAFE STRICT;

-- bucketing of timestamptz happens at UTC time
CREATE OR REPLACE FUNCTION time_bucket(bucket_width INTERVAL, ts TIMESTAMPTZ) RETURNS TIMESTAMPTZ
	AS '$libdir/timescaledb-2.5.1', 'ts_timestamptz_bucket' LANGUAGE C IMMUTABLE PARALLEL SAFE STRICT;

--bucketing on date should not do any timezone conversion
CREATE OR REPLACE FUNCTION time_bucket(bucket_width INTERVAL, ts DATE) RETURNS DATE
	AS '$libdir/timescaledb-2.5.1', 'ts_date_bucket' LANGUAGE C IMMUTABLE PARALLEL SAFE STRICT;

--bucketing with origin
CREATE OR REPLACE FUNCTION time_bucket(bucket_width INTERVAL, ts TIMESTAMP, origin TIMESTAMP) RETURNS TIMESTAMP
	AS '$libdir/timescaledb-2.5.1', 'ts_timestamp_bucket' LANGUAGE C IMMUTABLE PARALLEL SAFE STRICT;
CREATE OR REPLACE FUNCTION time_bucket(bucket_width INTERVAL, ts TIMESTAMPTZ, origin TIMESTAMPTZ) RETURNS TIMESTAMPTZ
	AS '$libdir/timescaledb-2.5.1', 'ts_timestamptz_bucket' LANGUAGE C IMMUTABLE PARALLEL SAFE STRICT;
CREATE OR REPLACE FUNCTION time_bucket(bucket_width INTERVAL, ts DATE, origin DATE) RETURNS DATE
	AS '$libdir/timescaledb-2.5.1', 'ts_date_bucket' LANGUAGE C IMMUTABLE PARALLEL SAFE STRICT;

-- bucketing of int
CREATE OR REPLACE FUNCTION time_bucket(bucket_width SMALLINT, ts SMALLINT) RETURNS SMALLINT
	AS '$libdir/timescaledb-2.5.1', 'ts_int16_bucket' LANGUAGE C IMMUTABLE PARALLEL SAFE STRICT;
CREATE OR REPLACE FUNCTION time_bucket(bucket_width INT, ts INT) RETURNS INT
	AS '$libdir/timescaledb-2.5.1', 'ts_int32_bucket' LANGUAGE C IMMUTABLE PARALLEL SAFE STRICT;
CREATE OR REPLACE FUNCTION time_bucket(bucket_width BIGINT, ts BIGINT) RETURNS BIGINT
	AS '$libdir/timescaledb-2.5.1', 'ts_int64_bucket' LANGUAGE C IMMUTABLE PARALLEL SAFE STRICT;

-- bucketing of int with offset
CREATE OR REPLACE FUNCTION time_bucket(bucket_width SMALLINT, ts SMALLINT, "offset" SMALLINT) RETURNS SMALLINT
	AS '$libdir/timescaledb-2.5.1', 'ts_int16_bucket' LANGUAGE C IMMUTABLE PARALLEL SAFE STRICT;
CREATE OR REPLACE FUNCTION time_bucket(bucket_width INT, ts INT, "offset" INT) RETURNS INT
	AS '$libdir/timescaledb-2.5.1', 'ts_int32_bucket' LANGUAGE C IMMUTABLE PARALLEL SAFE STRICT;
CREATE OR REPLACE FUNCTION time_bucket(bucket_width BIGINT, ts BIGINT, "offset" BIGINT) RETURNS BIGINT
	AS '$libdir/timescaledb-2.5.1', 'ts_int64_bucket' LANGUAGE C IMMUTABLE PARALLEL SAFE STRICT;

-- If an interval is given as the third argument, the bucket alignment is offset by the interval.
CREATE OR REPLACE FUNCTION time_bucket(bucket_width INTERVAL, ts TIMESTAMP, "offset" INTERVAL)
    RETURNS TIMESTAMP LANGUAGE SQL IMMUTABLE PARALLEL SAFE STRICT AS
$BODY$
    SELECT @extschema@.time_bucket(bucket_width, ts-"offset")+"offset";
$BODY$;

CREATE OR REPLACE FUNCTION time_bucket(bucket_width INTERVAL, ts TIMESTAMPTZ, "offset" INTERVAL)
    RETURNS TIMESTAMPTZ LANGUAGE SQL IMMUTABLE PARALLEL SAFE STRICT AS
$BODY$
    SELECT @extschema@.time_bucket(bucket_width, ts-"offset")+"offset";
$BODY$;

CREATE OR REPLACE FUNCTION time_bucket(bucket_width INTERVAL, ts DATE, "offset" INTERVAL)
    RETURNS DATE LANGUAGE SQL IMMUTABLE PARALLEL SAFE STRICT AS
$BODY$
    SELECT (@extschema@.time_bucket(bucket_width, ts-"offset")+"offset")::date;
$BODY$;

-- This file and its contents are licensed under the Apache License 2.0.
-- Please see the included NOTICE for copyright information and
-- LICENSE-APACHE for a copy of the license.

-- time_bucket_ng() is an _experimental_ new version of time_bucket().
--
-- Unlike time_bucket(), time_bucket_ng() supports variable-sized buckets,
-- such as months and years, and also timezones. Note that the behavior
-- and the interface of this function are subjects to change. There could
-- be bugs, and the implementation doesn't claim to be complete. Use at
-- your own risk.
--
-- This function may return different results for the same arguments depending
-- on the version of local timezone database. Despite this fact, function is
-- marked as IMMUTABLE. This is consistent with the volatility [1] of the
-- functions provided by PostgreSQL. See discussion [2] for more details.
--
-- We don't forbid users to work with timestamptz's from the future, nor warn
-- about this corner case. This behavior is consistent with PostgreSQL
-- behavior [3].
--
-- [1]: https://www.postgresql.org/docs/current/xfunc-volatility.html
-- [2]: https://postgr.es/m/CAJ7c6TOMG8zSNEZtCn5SPe+cCk3Lfxb71ZaQwT2F4T7PJ_t=KA@mail.gmail.com
-- [3]: https://www.postgresql.org/docs/current/datatype-datetime.html#DATATYPE-TIMEZONES

-- DATE versions of time_bucket_ng().
CREATE OR REPLACE FUNCTION timescaledb_experimental.time_bucket_ng(bucket_width INTERVAL, ts DATE) RETURNS DATE
    AS '$libdir/timescaledb-2.5.1', 'ts_time_bucket_ng_date' LANGUAGE C IMMUTABLE PARALLEL SAFE STRICT;

CREATE OR REPLACE FUNCTION timescaledb_experimental.time_bucket_ng(bucket_width INTERVAL, ts DATE, origin DATE) RETURNS DATE
    AS '$libdir/timescaledb-2.5.1', 'ts_time_bucket_ng_date' LANGUAGE C IMMUTABLE PARALLEL SAFE STRICT;

-- TIMESTAMP versions of time_bucket_ng().
CREATE OR REPLACE FUNCTION timescaledb_experimental.time_bucket_ng(bucket_width INTERVAL, ts TIMESTAMP) RETURNS TIMESTAMP
    AS '$libdir/timescaledb-2.5.1', 'ts_time_bucket_ng_timestamp' LANGUAGE C IMMUTABLE PARALLEL SAFE STRICT;

CREATE OR REPLACE FUNCTION timescaledb_experimental.time_bucket_ng(bucket_width INTERVAL, ts TIMESTAMP, origin TIMESTAMP) RETURNS TIMESTAMP
    AS '$libdir/timescaledb-2.5.1', 'ts_time_bucket_ng_timestamp' LANGUAGE C IMMUTABLE PARALLEL SAFE STRICT;

-- TIMESTAMPTZ versions of time_bucket_ng().
CREATE OR REPLACE FUNCTION timescaledb_experimental.time_bucket_ng(bucket_width INTERVAL, ts TIMESTAMPTZ, timezone TEXT) RETURNS TIMESTAMPTZ
    AS '$libdir/timescaledb-2.5.1', 'ts_time_bucket_ng_timezone' LANGUAGE C IMMUTABLE PARALLEL SAFE STRICT;
CREATE OR REPLACE FUNCTION timescaledb_experimental.time_bucket_ng(bucket_width INTERVAL, ts TIMESTAMPTZ, origin TIMESTAMPTZ, timezone TEXT) RETURNS TIMESTAMPTZ
    AS '$libdir/timescaledb-2.5.1', 'ts_time_bucket_ng_timezone_origin' LANGUAGE C IMMUTABLE PARALLEL SAFE STRICT;


-- The following two versions of time_bucket_ng() are kept only for the backward
-- compatibility with time_bucket(). They convert 'ts' to UTC instead of treating
-- it in the given timezone, which is almost certainly not something you want.
-- Future versions may WARN you about this fact, and be completely removed
-- eventually.
--
-- These functions are STABLE because their implementation relies on the STABLE
-- function timestamptz_date(). The latest is STABLE because it accounts for the
-- session parameters.
CREATE OR REPLACE FUNCTION timescaledb_experimental.time_bucket_ng(bucket_width INTERVAL, ts TIMESTAMPTZ) RETURNS TIMESTAMPTZ
    AS '$libdir/timescaledb-2.5.1', 'ts_time_bucket_ng_timestamptz' LANGUAGE C STABLE PARALLEL SAFE STRICT;

CREATE OR REPLACE FUNCTION timescaledb_experimental.time_bucket_ng(bucket_width INTERVAL, ts TIMESTAMPTZ, origin TIMESTAMPTZ) RETURNS TIMESTAMPTZ
    AS '$libdir/timescaledb-2.5.1', 'ts_time_bucket_ng_timestamptz' LANGUAGE C STABLE PARALLEL SAFE STRICT;
-- This file and its contents are licensed under the Apache License 2.0.
-- Please see the included NOTICE for copyright information and
-- LICENSE-APACHE for a copy of the license.

CREATE OR REPLACE FUNCTION _timescaledb_internal.get_git_commit()
    RETURNS TABLE(commit_tag TEXT, commit_hash TEXT, commit_time TIMESTAMPTZ)
    AS '$libdir/timescaledb-2.5.1', 'ts_get_git_commit' LANGUAGE C IMMUTABLE STRICT PARALLEL SAFE;

CREATE OR REPLACE FUNCTION _timescaledb_internal.get_os_info()
    RETURNS TABLE(sysname TEXT, version TEXT, release TEXT, version_pretty TEXT)
    AS '$libdir/timescaledb-2.5.1', 'ts_get_os_info' LANGUAGE C IMMUTABLE STRICT PARALLEL SAFE;

CREATE OR REPLACE FUNCTION get_telemetry_report(always_display_report boolean DEFAULT false) RETURNS TEXT
    AS '$libdir/timescaledb-2.5.1', 'ts_get_telemetry_report' LANGUAGE C STABLE PARALLEL SAFE;

CREATE OR REPLACE FUNCTION _timescaledb_internal.tsl_loaded() RETURNS BOOLEAN
AS '$libdir/timescaledb-2.5.1', 'ts_tsl_loaded' LANGUAGE C;
-- This file and its contents are licensed under the Apache License 2.0.
-- Please see the included NOTICE for copyright information and
-- LICENSE-APACHE for a copy of the license.

-- This file contains utility functions to get the relation size
-- of hypertables, chunks, and indexes on hypertables.

CREATE OR REPLACE VIEW _timescaledb_internal.hypertable_chunk_local_size AS 
SELECT *, 
   compressed_total_size - COALESCE(compressed_index_size, 0) - COALESCE(compressed_toast_size, 0) as compressed_heap_size
FROM
( SELECT
   h.schema_name AS hypertable_schema,
   h.table_name AS hypertable_name,
   h.id as hypertable_id,
   c.id as chunk_id,
   c.schema_name as chunk_schema,
   c.table_name as chunk_name,
   pg_total_relation_size(format('%I.%I', c.schema_name, c.table_name))::bigint AS total_bytes,
   pg_indexes_size(format('%I.%I', c.schema_name, c.table_name))::bigint AS index_bytes,
   pg_total_relation_size(pgc.reltoastrelid)::bigint AS toast_bytes,
   CASE WHEN map.table_name IS NOT NULL 
        THEN pg_total_relation_size(format('%I.%I', map.schema_name, map.table_name))::bigint 
        ELSE 0
   END AS compressed_total_size,
   CASE WHEN map.table_name IS NOT NULL 
        THEN pg_indexes_size(format('%I.%I', map.schema_name, map.table_name))::bigint 
        ELSE 0
   END AS compressed_index_size,
   CASE WHEN map.reltoastrelid IS NOT NULL 
        THEN pg_total_relation_size(map.reltoastrelid)::bigint 
        ELSE 0
   END AS compressed_toast_size
FROM
   _timescaledb_catalog.hypertable h 
   INNER JOIN
      _timescaledb_catalog.chunk c 
      ON h.id = c.hypertable_id 
      and c.dropped = false 
   INNER JOIN
      pg_class pgc 
      ON pgc.relname = c.table_name 
   INNER JOIN
      pg_namespace pns 
      ON pns.oid = pgc.relnamespace 
      AND pns.nspname = c.schema_name 
   LEFT OUTER JOIN
      ( SELECT comp.id, comp.schema_name, comp.table_name, reltoastrelid
        FROM _timescaledb_catalog.chunk comp, pg_class, pg_namespace
        WHERE comp.table_name = pg_class.relname
        AND comp.schema_name = pg_namespace.nspname
        AND pg_namespace.oid = pg_class.relnamespace ) map
  ON map.id = c.compressed_chunk_id ) subq;

GRANT SELECT ON  _timescaledb_internal.hypertable_chunk_local_size TO PUBLIC;
 
CREATE OR REPLACE FUNCTION _timescaledb_internal.data_node_hypertable_info(
    node_name              NAME,
    schema_name_in name,
    table_name_in name
)
RETURNS TABLE (
    table_bytes     bigint,
    index_bytes     bigint,
    toast_bytes     bigint,
    total_bytes     bigint)
AS '$libdir/timescaledb-2.5.1', 'ts_dist_remote_hypertable_info' LANGUAGE C VOLATILE STRICT;

CREATE OR REPLACE FUNCTION _timescaledb_internal.data_node_chunk_info(
    node_name              NAME,
    schema_name_in name,
    table_name_in name
)
RETURNS TABLE (
    chunk_id        integer,
    chunk_schema    name,
    chunk_name      name,
    table_bytes     bigint,
    index_bytes     bigint,
    toast_bytes     bigint,
    total_bytes     bigint)
AS '$libdir/timescaledb-2.5.1', 'ts_dist_remote_chunk_info' LANGUAGE C VOLATILE STRICT;

CREATE OR REPLACE FUNCTION _timescaledb_internal.hypertable_local_size(
	schema_name_in name,
	table_name_in name)
RETURNS TABLE (
	table_bytes bigint,
	index_bytes bigint,
	toast_bytes bigint,
	total_bytes bigint)
LANGUAGE SQL VOLATILE STRICT AS
$BODY$
	SELECT
		(COALESCE(sum(ch.total_bytes), 0) - COALESCE(sum(ch.index_bytes), 0) - COALESCE(sum(ch.toast_bytes), 0) + COALESCE(sum(ch.compressed_heap_size), 0))::bigint + pg_relation_size(format('%I.%I', schema_name_in, table_name_in)::regclass)::bigint AS heap_bytes,
		(COALESCE(sum(ch.index_bytes), 0) + COALESCE(sum(ch.compressed_index_size), 0))::bigint + pg_indexes_size(format('%I.%I', schema_name_in, table_name_in)::regclass)::bigint AS index_bytes,
		(COALESCE(sum(ch.toast_bytes), 0) + COALESCE(sum(ch.compressed_toast_size), 0))::bigint AS toast_bytes,
		(COALESCE(sum(ch.total_bytes), 0) + COALESCE(sum(ch.compressed_total_size), 0))::bigint + pg_total_relation_size(format('%I.%I', schema_name_in, table_name_in)::regclass)::bigint AS total_bytes
	FROM
		_timescaledb_internal.hypertable_chunk_local_size ch
	WHERE
		hypertable_schema = schema_name_in
		AND hypertable_name = table_name_in
$BODY$;

CREATE OR REPLACE FUNCTION _timescaledb_internal.hypertable_remote_size(
    schema_name_in name,
    table_name_in name)
RETURNS TABLE (
    table_bytes bigint,
    index_bytes bigint,
    toast_bytes bigint,
    total_bytes bigint,
    node_name   NAME)
LANGUAGE SQL VOLATILE STRICT AS
$BODY$
    SELECT
        sum(entry.table_bytes)::bigint AS table_bytes,
        sum(entry.index_bytes)::bigint AS index_bytes,
        sum(entry.toast_bytes)::bigint AS toast_bytes,
        sum(entry.total_bytes)::bigint AS total_bytes,
        srv.node_name
    FROM (
        SELECT
            s.node_name
        FROM
            _timescaledb_catalog.hypertable AS ht,
            _timescaledb_catalog.hypertable_data_node AS s
        WHERE
            ht.schema_name = schema_name_in
            AND ht.table_name = table_name_in
            AND s.hypertable_id = ht.id
         ) AS srv
    LEFT OUTER JOIN LATERAL _timescaledb_internal.data_node_hypertable_info(
        srv.node_name, schema_name_in, table_name_in) entry ON TRUE
    GROUP BY srv.node_name;
$BODY$;

-- Get relation size of hypertable
-- like pg_relation_size(hypertable)
--
-- hypertable - hypertable to get size of
--
-- Returns:
-- table_bytes        - Disk space used by hypertable (like pg_relation_size(hypertable))
-- index_bytes        - Disk space used by indexes
-- toast_bytes        - Disk space of toast tables
-- total_bytes        - Total disk space used by the specified table, including all indexes and TOAST data

CREATE OR REPLACE FUNCTION hypertable_detailed_size(
    hypertable              REGCLASS)
RETURNS TABLE (table_bytes BIGINT,
               index_bytes BIGINT,
               toast_bytes BIGINT,
               total_bytes BIGINT,
               node_name   NAME)
LANGUAGE PLPGSQL VOLATILE STRICT AS
$BODY$
DECLARE
        table_name       NAME = NULL;
        schema_name      NAME = NULL;
        is_distributed   BOOL = FALSE;
BEGIN
        SELECT relname, nspname, replication_factor > 0
        INTO table_name, schema_name, is_distributed
        FROM pg_class c
        INNER JOIN pg_namespace n ON (n.OID = c.relnamespace)
        INNER JOIN _timescaledb_catalog.hypertable ht ON (ht.schema_name = n.nspname AND ht.table_name = c.relname)
        WHERE c.OID = hypertable;

		IF table_name IS NULL THEN
		    RETURN;
		END IF;

        CASE WHEN is_distributed THEN
			RETURN QUERY
			SELECT *, NULL::name
			FROM _timescaledb_internal.hypertable_local_size(schema_name, table_name)
			UNION
			SELECT *
			FROM _timescaledb_internal.hypertable_remote_size(schema_name, table_name);
        ELSE
			RETURN QUERY
			SELECT *, NULL::name
			FROM _timescaledb_internal.hypertable_local_size(schema_name, table_name);
        END CASE;
END;
$BODY$;

--- returns total-bytes for a hypertable (includes table + index)
CREATE OR REPLACE FUNCTION hypertable_size(
    hypertable              REGCLASS)
RETURNS BIGINT 
LANGUAGE SQL VOLATILE STRICT AS
$BODY$
   -- One row per data node is returned (in case of a distributed
   -- hypertable), so sum them up:
   SELECT sum(total_bytes)::bigint
   FROM hypertable_detailed_size(hypertable);
$BODY$;

CREATE OR REPLACE FUNCTION _timescaledb_internal.chunks_local_size(
    schema_name_in name,
    table_name_in name)
RETURNS TABLE (
    chunk_id    integer,
    chunk_schema NAME,
    chunk_name  NAME,
    table_bytes bigint,
    index_bytes bigint,
    toast_bytes bigint,
    total_bytes bigint)
LANGUAGE SQL VOLATILE STRICT AS
$BODY$
   SELECT
      ch.chunk_id,
      ch.chunk_schema,
      ch.chunk_name,
      (ch.total_bytes - COALESCE( ch.index_bytes , 0 ) - COALESCE( ch.toast_bytes, 0 ) + COALESCE( ch.compressed_heap_size , 0 ))::bigint  as heap_bytes,
      (COALESCE( ch.index_bytes, 0 ) + COALESCE( ch.compressed_index_size , 0) )::bigint as index_bytes,
      (COALESCE( ch.toast_bytes, 0 ) + COALESCE( ch.compressed_toast_size, 0 ))::bigint as toast_bytes,
      (ch.total_bytes + COALESCE( ch.compressed_total_size, 0 ))::bigint as total_bytes 
   FROM
	  _timescaledb_internal.hypertable_chunk_local_size ch
   WHERE
      ch.hypertable_schema = schema_name_in
      AND ch.hypertable_name = table_name_in;
$BODY$;

---should return same information as chunks_local_size--
CREATE OR REPLACE FUNCTION _timescaledb_internal.chunks_remote_size(
    schema_name_in name,
    table_name_in name)
RETURNS TABLE (
    chunk_id    integer,
    chunk_schema NAME,
    chunk_name  NAME,
    table_bytes bigint,
    index_bytes bigint,
    toast_bytes bigint,
    total_bytes bigint,
    node_name NAME)
LANGUAGE SQL VOLATILE STRICT AS
$BODY$
    SELECT
        entry.chunk_id,
        entry.chunk_schema,
        entry.chunk_name,
        entry.table_bytes AS table_bytes,
        entry.index_bytes AS index_bytes,
        entry.toast_bytes AS toast_bytes,
        entry.total_bytes AS total_bytes,
        srv.node_name
    FROM (
        SELECT
            s.node_name
        FROM
            _timescaledb_catalog.hypertable AS ht,
            _timescaledb_catalog.hypertable_data_node AS s
        WHERE
            ht.schema_name = schema_name_in
            AND ht.table_name = table_name_in
            AND s.hypertable_id = ht.id
         ) AS srv
    LEFT OUTER JOIN LATERAL _timescaledb_internal.data_node_chunk_info(
        srv.node_name, schema_name_in, table_name_in) entry ON TRUE
	WHERE
	    entry.chunk_name IS NOT NULL;
$BODY$;

-- Get relation size of the chunks of an hypertable
-- hypertable - hypertable to get size of
--
-- Returns:
-- chunk_schema                  - schema name for chunk
-- chunk_name                    - chunk table name
-- table_bytes                   - Disk space used by chunk table 
-- index_bytes                   - Disk space used by indexes
-- toast_bytes                   - Disk space of toast tables
-- total_bytes                   - Disk space used in total
-- node_name                     - node on which chunk lives if this is
--                              a distributed hypertable.
CREATE OR REPLACE FUNCTION chunks_detailed_size(
    hypertable              REGCLASS
)
RETURNS TABLE (
               chunk_schema NAME,
               chunk_name NAME,
               table_bytes BIGINT,
               index_bytes BIGINT,
               toast_bytes BIGINT,
               total_bytes BIGINT,
               node_name   NAME)
LANGUAGE PLPGSQL VOLATILE STRICT AS
$BODY$
DECLARE
        table_name       NAME;
        schema_name      NAME;
        is_distributed   BOOL;
BEGIN
        SELECT relname, nspname, replication_factor > 0
        INTO table_name, schema_name, is_distributed
        FROM pg_class c
        INNER JOIN pg_namespace n ON (n.OID = c.relnamespace)
        INNER JOIN _timescaledb_catalog.hypertable ht ON (ht.schema_name = n.nspname AND ht.table_name = c.relname)
        WHERE c.OID = hypertable;

		IF table_name IS NULL THEN
		    RETURN;
		END IF;

        CASE WHEN is_distributed THEN
            RETURN QUERY SELECT ch.chunk_schema, ch.chunk_name, ch.table_bytes, ch.index_bytes, 
                        ch.toast_bytes, ch.total_bytes, ch.node_name   
            FROM _timescaledb_internal.chunks_remote_size(schema_name, table_name) ch;
        ELSE
            RETURN QUERY SELECT chl.chunk_schema, chl.chunk_name, chl.table_bytes, chl.index_bytes, 
                        chl.toast_bytes, chl.total_bytes, NULL::NAME   
            FROM _timescaledb_internal.chunks_local_size(schema_name, table_name) chl;
        END CASE;
END;
$BODY$;
---------- end of detailed size functions ------

CREATE OR REPLACE FUNCTION _timescaledb_internal.range_value_to_pretty(
    time_value      BIGINT,
    column_type     REGTYPE
)
    RETURNS TEXT LANGUAGE PLPGSQL STABLE AS
$BODY$
DECLARE
BEGIN
    IF NOT _timescaledb_internal.dimension_is_finite(time_value) THEN
        RETURN '';
    END IF;
    IF time_value IS NULL THEN
        RETURN format('%L', NULL);
    END IF;
    CASE column_type
      WHEN 'BIGINT'::regtype, 'INTEGER'::regtype, 'SMALLINT'::regtype THEN
        RETURN format('%L', time_value); -- scale determined by user.
      WHEN 'TIMESTAMP'::regtype, 'TIMESTAMPTZ'::regtype THEN
        -- assume time_value is in microsec
        RETURN format('%1$L', _timescaledb_internal.to_timestamp(time_value)); -- microseconds
      WHEN 'DATE'::regtype THEN
        RETURN format('%L', timezone('UTC',_timescaledb_internal.to_timestamp(time_value))::date);
      ELSE
        RETURN time_value;
    END CASE;
END
$BODY$;

-- Convenience function to return approximate row count
--
-- relation - table or hypertable to get approximate row count for
--
-- Returns:
-- Estimated number of rows according to catalog tables
CREATE OR REPLACE FUNCTION approximate_row_count(relation REGCLASS)
RETURNS BIGINT
LANGUAGE SQL VOLATILE STRICT AS
$BODY$
  WITH RECURSIVE inherited_id(oid) AS
  (
    SELECT relation
    UNION ALL
    SELECT i.inhrelid
    FROM pg_inherits i
    JOIN inherited_id b ON i.inhparent = b.oid
  )
  -- reltuples for partitioned tables is the sum of it's children in pg14 so we need to filter those out
  SELECT COALESCE((SUM(reltuples) FILTER (WHERE reltuples > 0 AND relkind <> 'p')), 0)::BIGINT
  FROM inherited_id
  JOIN pg_class USING (oid);
$BODY$;

-------- stats related to compression ------
CREATE OR REPLACE VIEW _timescaledb_internal.compressed_chunk_stats AS
SELECT
    srcht.schema_name AS hypertable_schema,
    srcht.table_name AS hypertable_name,
    srcch.schema_name AS chunk_schema,
    srcch.table_name AS chunk_name,
    CASE WHEN srcch.compressed_chunk_id IS NULL THEN
        'Uncompressed'::text
    ELSE
        'Compressed'::text
    END AS compression_status,
    map.uncompressed_heap_size,
    map.uncompressed_index_size,
    map.uncompressed_toast_size,
    map.uncompressed_heap_size + map.uncompressed_toast_size + map.uncompressed_index_size AS uncompressed_total_size,
    map.compressed_heap_size,
    map.compressed_index_size,
    map.compressed_toast_size,
    map.compressed_heap_size + map.compressed_toast_size + map.compressed_index_size AS compressed_total_size
FROM
    _timescaledb_catalog.hypertable AS srcht
    JOIN _timescaledb_catalog.chunk AS srcch ON srcht.id = srcch.hypertable_id
        AND srcht.compressed_hypertable_id IS NOT NULL
        AND srcch.dropped = FALSE
    LEFT JOIN _timescaledb_catalog.compression_chunk_size map ON srcch.id = map.chunk_id;

GRANT SELECT ON _timescaledb_internal.compressed_chunk_stats TO PUBLIC;

CREATE OR REPLACE FUNCTION _timescaledb_internal.data_node_compressed_chunk_stats (node_name name, schema_name_in name, table_name_in name)
    RETURNS TABLE (
        chunk_schema name,
        chunk_name name,
        compression_status text,
        before_compression_table_bytes bigint,
        before_compression_index_bytes bigint,
        before_compression_toast_bytes bigint,
        before_compression_total_bytes bigint,
        after_compression_table_bytes bigint,
        after_compression_index_bytes bigint,
        after_compression_toast_bytes bigint,
        after_compression_total_bytes bigint
    )
AS '$libdir/timescaledb-2.5.1' , 'ts_dist_remote_compressed_chunk_info' LANGUAGE C VOLATILE STRICT;

CREATE OR REPLACE FUNCTION _timescaledb_internal.compressed_chunk_local_stats (schema_name_in name, table_name_in name)
    RETURNS TABLE (
        chunk_schema name,
        chunk_name name,
        compression_status text,
        before_compression_table_bytes bigint,
        before_compression_index_bytes bigint,
        before_compression_toast_bytes bigint,
        before_compression_total_bytes bigint,
        after_compression_table_bytes bigint,
        after_compression_index_bytes bigint,
        after_compression_toast_bytes bigint,
        after_compression_total_bytes bigint)
    LANGUAGE SQL
    STABLE STRICT
    AS
$BODY$
    SELECT
        ch.chunk_schema,
        ch.chunk_name,
        ch.compression_status,
        ch.uncompressed_heap_size,
        ch.uncompressed_index_size,
        ch.uncompressed_toast_size,
        ch.uncompressed_total_size,
        ch.compressed_heap_size,
        ch.compressed_index_size,
        ch.compressed_toast_size,
        ch.compressed_total_size
    FROM
        _timescaledb_internal.compressed_chunk_stats ch
    WHERE
        ch.hypertable_schema = schema_name_in
        AND ch.hypertable_name = table_name_in;
$BODY$;

CREATE OR REPLACE FUNCTION _timescaledb_internal.compressed_chunk_remote_stats (schema_name_in name, table_name_in name)
    RETURNS TABLE (
        chunk_schema name,
        chunk_name name,
        compression_status text,
        before_compression_table_bytes bigint,
        before_compression_index_bytes bigint,
        before_compression_toast_bytes bigint,
        before_compression_total_bytes bigint,
        after_compression_table_bytes bigint,
        after_compression_index_bytes bigint,
        after_compression_toast_bytes bigint,
        after_compression_total_bytes bigint,
        node_name name)
    LANGUAGE SQL
    STABLE STRICT
    AS
$BODY$
    SELECT
        ch.*,
        srv.node_name
    FROM (
        SELECT
            s.node_name
        FROM
            _timescaledb_catalog.hypertable AS ht,
            _timescaledb_catalog.hypertable_data_node AS s
        WHERE
            ht.schema_name = schema_name_in
            AND ht.table_name = table_name_in
            AND s.hypertable_id = ht.id) AS srv
    LEFT OUTER JOIN LATERAL _timescaledb_internal.data_node_compressed_chunk_stats (
        srv.node_name, schema_name_in, table_name_in) ch ON TRUE
	WHERE ch.chunk_name IS NOT NULL;
$BODY$;

-- Get per chunk compression statistics for a hypertable that has
-- compression enabled
CREATE OR REPLACE FUNCTION chunk_compression_stats (hypertable REGCLASS)
    RETURNS TABLE (
        chunk_schema name,
        chunk_name name,
        compression_status text,
        before_compression_table_bytes bigint,
        before_compression_index_bytes bigint,
        before_compression_toast_bytes bigint,
        before_compression_total_bytes bigint,
        after_compression_table_bytes bigint,
        after_compression_index_bytes bigint,
        after_compression_toast_bytes bigint,
        after_compression_total_bytes bigint,
        node_name name)
    LANGUAGE PLPGSQL
    STABLE STRICT
    AS $BODY$
DECLARE
    table_name name;
    schema_name name;
    is_distributed bool;
BEGIN
    SELECT
        relname,
        nspname,
        replication_factor > 0
    INTO
	    table_name,
        schema_name,
        is_distributed
    FROM
        pg_class c
        INNER JOIN pg_namespace n ON (n.OID = c.relnamespace)
        INNER JOIN _timescaledb_catalog.hypertable ht ON (ht.schema_name = n.nspname
                AND ht.table_name = c.relname)
    WHERE
        c.OID = hypertable;

    IF table_name IS NULL THEN
	    RETURN;
	END IF;

    CASE WHEN is_distributed THEN
        RETURN QUERY
        SELECT
            *
        FROM
            _timescaledb_internal.compressed_chunk_remote_stats (schema_name, table_name);
    ELSE
        RETURN QUERY
        SELECT
            *,
            NULL::name
        FROM
            _timescaledb_internal.compressed_chunk_local_stats (schema_name, table_name);
    END CASE;
END;
$BODY$;

-- Get compression statistics for a hypertable that has
-- compression enabled
CREATE OR REPLACE FUNCTION hypertable_compression_stats (hypertable REGCLASS)
    RETURNS TABLE (
        total_chunks bigint,
        number_compressed_chunks bigint,
        before_compression_table_bytes bigint,
        before_compression_index_bytes bigint,
        before_compression_toast_bytes bigint,
        before_compression_total_bytes bigint,
        after_compression_table_bytes bigint,
        after_compression_index_bytes bigint,
        after_compression_toast_bytes bigint,
        after_compression_total_bytes bigint,
        node_name name)
    LANGUAGE SQL
    STABLE STRICT
    AS	
$BODY$
	SELECT
        count(*)::bigint AS total_chunks,
        (count(*) FILTER (WHERE ch.compression_status = 'Compressed'))::bigint AS number_compressed_chunks,
        sum(ch.before_compression_table_bytes)::bigint AS before_compression_table_bytes,
        sum(ch.before_compression_index_bytes)::bigint AS before_compression_index_bytes,
        sum(ch.before_compression_toast_bytes)::bigint AS before_compression_toast_bytes,
        sum(ch.before_compression_total_bytes)::bigint AS before_compression_total_bytes,
        sum(ch.after_compression_table_bytes)::bigint AS after_compression_table_bytes,
        sum(ch.after_compression_index_bytes)::bigint AS after_compression_index_bytes,
        sum(ch.after_compression_toast_bytes)::bigint AS after_compression_toast_bytes,
        sum(ch.after_compression_total_bytes)::bigint AS after_compression_total_bytes,
        ch.node_name
    FROM
	    chunk_compression_stats(hypertable) ch
    GROUP BY
        ch.node_name;
$BODY$;

-------------Get index size for hypertables -------
--schema_name      - schema_name for hypertable index
-- index_name      - index on hyper table
---note that the query matches against the hypertable's schema name as
-- the input is on the hypertable index and not the chunk index.
CREATE OR REPLACE FUNCTION _timescaledb_internal.indexes_local_size(
    schema_name_in             NAME,
    index_name_in              NAME
)
RETURNS TABLE ( hypertable_id INTEGER,
                total_bytes BIGINT ) 
LANGUAGE SQL VOLATILE STRICT AS
$BODY$
    WITH chunk_index_size (num_bytes) AS (
        SELECT
		    COALESCE(sum(pg_relation_size(c.oid)), 0)::bigint
        FROM                                      
            pg_class c,
            pg_namespace n,
            _timescaledb_catalog.chunk ch,
            _timescaledb_catalog.chunk_index ci,
			_timescaledb_catalog.hypertable h
         WHERE ch.schema_name = n.nspname
             AND c.relnamespace = n.oid
             AND c.relname = ci.index_name
             AND ch.id = ci.chunk_id
             AND h.id = ci.hypertable_id
             AND h.schema_name = schema_name_in 
             AND ci.hypertable_index_name = index_name_in
    ) SELECT
	      h.id,
		  -- Add size of index on all chunks + index size on root table
		  (SELECT num_bytes FROM chunk_index_size) + pg_relation_size(format('%I.%I', schema_name_in, index_name_in)::regclass)::bigint
	  FROM
	      pg_class c, pg_index i, _timescaledb_catalog.hypertable h
	  WHERE
	     i.indexrelid = format('%I.%I', schema_name_in, index_name_in)::regclass
		 AND c.oid = i.indrelid
		 AND h.schema_name = schema_name_in
		 AND h.table_name = c.relname;
$BODY$;

CREATE OR REPLACE FUNCTION _timescaledb_internal.data_node_index_size (node_name name, schema_name_in name, index_name_in name)
RETURNS TABLE ( hypertable_id INTEGER, total_bytes BIGINT)
AS '$libdir/timescaledb-2.5.1' , 'ts_dist_remote_hypertable_index_info' LANGUAGE C VOLATILE STRICT;

CREATE OR REPLACE FUNCTION _timescaledb_internal.indexes_remote_size(
    schema_name_in             NAME,
    table_name_in              NAME,
    index_name_in              NAME
)
RETURNS BIGINT
LANGUAGE SQL VOLATILE STRICT AS
$BODY$
    SELECT
        sum(entry.total_bytes)::bigint AS total_bytes
    FROM (
        SELECT
            s.node_name
        FROM
            _timescaledb_catalog.hypertable AS ht,
            _timescaledb_catalog.hypertable_data_node AS s
        WHERE
            ht.schema_name = schema_name_in
            AND ht.table_name = table_name_in
            AND s.hypertable_id = ht.id
         ) AS srv
    JOIN LATERAL _timescaledb_internal.data_node_index_size(
        srv.node_name, schema_name_in, index_name_in) entry ON TRUE;
$BODY$;

-- Get sizes of indexes on a hypertable
--
-- index_name           - index on hyper table
--
-- Returns:
-- total_bytes          - size of index on disk

CREATE OR REPLACE FUNCTION  hypertable_index_size(
    index_name              REGCLASS
)
RETURNS BIGINT
LANGUAGE PLPGSQL VOLATILE STRICT AS
$BODY$
DECLARE
        ht_index_name       NAME;
        ht_schema_name      NAME;
        ht_name      NAME;
        is_distributed   BOOL;
        ht_id INTEGER;
        index_bytes BIGINT;
BEGIN
   SELECT c.relname, cl.relname, nsp.nspname, ht.replication_factor > 0
   INTO ht_index_name, ht_name, ht_schema_name, is_distributed
   FROM pg_class c, pg_index cind, pg_class cl,
        pg_namespace nsp, _timescaledb_catalog.hypertable ht
   WHERE c.oid = cind.indexrelid AND cind.indrelid = cl.oid
         AND cl.relnamespace = nsp.oid AND c.oid = index_name
		 AND ht.schema_name = nsp.nspname ANd ht.table_name = cl.relname;

   IF ht_index_name IS NULL THEN
       RETURN NULL;
   END IF;

   -- get the local size or size of access node indexes
   SELECT il.total_bytes
   INTO index_bytes
   FROM _timescaledb_internal.indexes_local_size(ht_schema_name, ht_index_name) il;

   IF index_bytes IS NULL THEN
       index_bytes = 0;
   END IF;

   -- Add size from data nodes
   IF is_distributed THEN
       index_bytes = index_bytes + _timescaledb_internal.indexes_remote_size(ht_schema_name, ht_name, ht_index_name);
   END IF;

   RETURN index_bytes;
END;
$BODY$;

-------------End index size for hypertables -------
-- This file and its contents are licensed under the Apache License 2.0.
-- Please see the included NOTICE for copyright information and
-- LICENSE-APACHE for a copy of the license.

CREATE OR REPLACE FUNCTION _timescaledb_internal.hist_sfunc (state INTERNAL, val DOUBLE PRECISION, MIN DOUBLE PRECISION, MAX DOUBLE PRECISION, nbuckets INTEGER)
RETURNS INTERNAL
AS '$libdir/timescaledb-2.5.1', 'ts_hist_sfunc'
LANGUAGE C IMMUTABLE PARALLEL SAFE;

CREATE OR REPLACE FUNCTION _timescaledb_internal.hist_combinefunc(state1 INTERNAL, state2 INTERNAL)
RETURNS INTERNAL
AS '$libdir/timescaledb-2.5.1', 'ts_hist_combinefunc'
LANGUAGE C IMMUTABLE PARALLEL SAFE;

CREATE OR REPLACE FUNCTION _timescaledb_internal.hist_serializefunc(INTERNAL)
RETURNS bytea
AS '$libdir/timescaledb-2.5.1', 'ts_hist_serializefunc'
LANGUAGE C IMMUTABLE STRICT PARALLEL SAFE;

CREATE OR REPLACE FUNCTION _timescaledb_internal.hist_deserializefunc(bytea, INTERNAL)
RETURNS INTERNAL
AS '$libdir/timescaledb-2.5.1', 'ts_hist_deserializefunc'
LANGUAGE C IMMUTABLE STRICT PARALLEL SAFE;

CREATE OR REPLACE FUNCTION _timescaledb_internal.hist_finalfunc(state INTERNAL, val DOUBLE PRECISION, MIN DOUBLE PRECISION, MAX DOUBLE PRECISION, nbuckets INTEGER)
RETURNS INTEGER[]
AS '$libdir/timescaledb-2.5.1', 'ts_hist_finalfunc'
LANGUAGE C IMMUTABLE PARALLEL SAFE;

-- We started using CREATE OR REPLACE AGGREGATE for aggregate creation once the syntax was fully supported
-- as it is easier to support idempotent changes this way. This will allow for changes to functions supporting
-- the aggregate, and, for instance, the definition and inclusion of inverse functions for window function
-- support. However, it should still be noted that changes to the data structures used for the internal
-- state of the aggregate must be backwards compatible and the old format must be accepted by any new functions
-- in order for them to continue working with Continuous Aggregates, where old states may have been materialized.

-- This aggregate partitions the dataset into a specified number of buckets (nbuckets) ranging
-- from the inputted min to max values.
CREATE OR REPLACE AGGREGATE histogram (DOUBLE PRECISION, DOUBLE PRECISION, DOUBLE PRECISION, INTEGER) (
    SFUNC = _timescaledb_internal.hist_sfunc,
    STYPE = INTERNAL,
    COMBINEFUNC = _timescaledb_internal.hist_combinefunc,
    SERIALFUNC = _timescaledb_internal.hist_serializefunc,
    DESERIALFUNC = _timescaledb_internal.hist_deserializefunc,
    PARALLEL = SAFE,
    FINALFUNC = _timescaledb_internal.hist_finalfunc,
    FINALFUNC_EXTRA
);
-- This file and its contents are licensed under the Apache License 2.0.
-- Please see the included NOTICE for copyright information and
-- LICENSE-APACHE for a copy of the license.

-- This file contains infrastructure for cache invalidation of TimescaleDB
-- metadata caches kept in C. Please look at cache_invalidate.c for a
-- description of how this works.
CREATE TABLE IF NOT EXISTS  _timescaledb_cache.cache_inval_hypertable();

-- For notifying the scheduler of changes to the bgw_job table.
CREATE TABLE IF NOT EXISTS  _timescaledb_cache.cache_inval_bgw_job();

-- This is pretty subtle. We create this dummy cache_inval_extension table
-- solely for the purpose of getting a relcache invalidation event when it is
-- deleted on DROP extension. It has no related triggers. When the table is
-- invalidated, all backends will be notified and will know that they must
-- invalidate all cached information, including catalog table and index OIDs,
-- etc.
CREATE TABLE IF NOT EXISTS  _timescaledb_cache.cache_inval_extension();

-- not actually strictly needed but good for sanity as all tables should be dumped.
SELECT pg_catalog.pg_extension_config_dump('_timescaledb_cache.cache_inval_hypertable', '');
SELECT pg_catalog.pg_extension_config_dump('_timescaledb_cache.cache_inval_extension', '');
SELECT pg_catalog.pg_extension_config_dump('_timescaledb_cache.cache_inval_bgw_job', '');

GRANT SELECT ON ALL TABLES IN SCHEMA _timescaledb_cache TO PUBLIC;

-- This file and its contents are licensed under the Apache License 2.0.
-- Please see the included NOTICE for copyright information and
-- LICENSE-APACHE for a copy of the license.

CREATE OR REPLACE FUNCTION _timescaledb_internal.restart_background_workers()
RETURNS BOOL
AS '$libdir/timescaledb', 'ts_bgw_db_workers_restart'
LANGUAGE C VOLATILE;

CREATE OR REPLACE FUNCTION _timescaledb_internal.stop_background_workers()
RETURNS BOOL
AS '$libdir/timescaledb', 'ts_bgw_db_workers_stop'
LANGUAGE C VOLATILE;

CREATE OR REPLACE FUNCTION _timescaledb_internal.start_background_workers()
RETURNS BOOL
AS '$libdir/timescaledb', 'ts_bgw_db_workers_start'
LANGUAGE C VOLATILE;

INSERT INTO _timescaledb_config.bgw_job (id, application_name, schedule_interval, max_runtime, max_retries, retry_period, proc_schema, proc_name, owner, scheduled) VALUES
(1, 'Telemetry Reporter [1]', INTERVAL '24h', INTERVAL '100s', -1, INTERVAL '1h', '_timescaledb_internal', 'policy_telemetry', CURRENT_ROLE, true)
ON CONFLICT (id) DO NOTHING;
-- This file and its contents are licensed under the Apache License 2.0.
-- Please see the included NOTICE for copyright information and
-- LICENSE-APACHE for a copy of the license.

CREATE OR REPLACE FUNCTION _timescaledb_internal.generate_uuid() RETURNS UUID
AS '$libdir/timescaledb-2.5.1', 'ts_uuid_generate' LANGUAGE C VOLATILE STRICT;

-- Insert uuid and install_timestamp on database creation. Don't
-- create exported_uuid because it gets exported and installed during
-- pg_dump, which would cause a conflict.
INSERT INTO _timescaledb_catalog.metadata
SELECT 'uuid', _timescaledb_internal.generate_uuid(), TRUE ON CONFLICT DO NOTHING;
INSERT INTO _timescaledb_catalog.metadata
SELECT 'install_timestamp', now(), TRUE ON CONFLICT DO NOTHING;
-- This file and its contents are licensed under the Apache License 2.0.
-- Please see the included NOTICE for copyright information and
-- LICENSE-APACHE for a copy of the license.

CREATE OR REPLACE FUNCTION _timescaledb_internal.set_dist_id(dist_id UUID) RETURNS BOOL
AS '$libdir/timescaledb-2.5.1', 'ts_dist_set_id' LANGUAGE C VOLATILE STRICT;

CREATE OR REPLACE FUNCTION _timescaledb_internal.set_peer_dist_id(dist_id UUID) RETURNS BOOL
AS '$libdir/timescaledb-2.5.1', 'ts_dist_set_peer_id' LANGUAGE C VOLATILE STRICT;

-- Function to validate that a node has local settings to function as
-- a data node. Throws error if validation fails.
CREATE OR REPLACE FUNCTION _timescaledb_internal.validate_as_data_node() RETURNS void
AS '$libdir/timescaledb-2.5.1', 'ts_dist_validate_as_data_node' LANGUAGE C VOLATILE STRICT;

CREATE OR REPLACE FUNCTION _timescaledb_internal.show_connection_cache()
RETURNS TABLE (
    node_name           name,
    user_name           name,
    host                text,
    port                int,
    database            name,
    backend_pid         int,
    connection_status   text,
    transaction_status  text,
    transaction_depth   int,
    processing          boolean,
    invalidated         boolean)
AS '$libdir/timescaledb-2.5.1', 'ts_remote_connection_cache_show' LANGUAGE C VOLATILE STRICT;
-- This file and its contents are licensed under the Apache License 2.0.
-- Please see the included NOTICE for copyright information and
-- LICENSE-APACHE for a copy of the license.

CREATE SCHEMA IF NOT EXISTS timescaledb_information;

-- Convenience view to list all hypertables
CREATE OR REPLACE VIEW timescaledb_information.hypertables AS
SELECT ht.schema_name AS hypertable_schema,
  ht.table_name AS hypertable_name,
  t.tableowner AS owner,
  ht.num_dimensions,
  (
    SELECT count(1)
    FROM _timescaledb_catalog.chunk ch
    WHERE ch.hypertable_id = ht.id) AS num_chunks,
  (
    CASE WHEN compression_state = 1 THEN
      TRUE 
    ELSE
      FALSE 
    END) AS compression_enabled,
  (
    CASE WHEN ht.replication_factor > 0 THEN
      TRUE
    ELSE
      FALSE
    END) AS is_distributed,
  ht.replication_factor,
  dn.node_list AS data_nodes,
  srchtbs.tablespace_list AS tablespaces
FROM _timescaledb_catalog.hypertable ht
  INNER JOIN pg_tables t ON ht.table_name = t.tablename
    AND ht.schema_name = t.schemaname
  LEFT OUTER JOIN _timescaledb_catalog.continuous_agg ca ON ca.mat_hypertable_id = ht.id
  LEFT OUTER JOIN (
    SELECT hypertable_id,
      array_agg(tablespace_name ORDER BY id) AS tablespace_list
    FROM _timescaledb_catalog.tablespace
    GROUP BY hypertable_id) srchtbs ON ht.id = srchtbs.hypertable_id
  LEFT OUTER JOIN (
  SELECT hypertable_id,
    array_agg(node_name ORDER BY node_name) AS node_list
  FROM _timescaledb_catalog.hypertable_data_node
  GROUP BY hypertable_id) dn ON ht.id = dn.hypertable_id
WHERE ht.compression_state != 2 --> no internal compression tables
  AND ca.mat_hypertable_id IS NULL;

CREATE OR REPLACE VIEW timescaledb_information.job_stats AS
SELECT ht.schema_name AS hypertable_schema,
  ht.table_name AS hypertable_name,
  j.id AS job_id,
  js.last_start AS last_run_started_at,
  js.last_successful_finish AS last_successful_finish,
  CASE WHEN js.last_finish < '4714-11-24 00:00:00+00 BC' THEN
    NULL
  WHEN js.last_finish IS NOT NULL THEN
    CASE WHEN js.last_run_success = 't' THEN
      'Success'
    WHEN js.last_run_success = 'f' THEN
      'Failed'
    END
  END AS last_run_status,
  CASE WHEN pgs.state = 'active' THEN
    'Running'
  WHEN j.scheduled = FALSE THEN
    'Paused'
  ELSE
    'Scheduled'
  END AS job_status,
  CASE WHEN js.last_finish > js.last_start THEN
  (js.last_finish - js.last_start)
  END AS last_run_duration,
  CASE WHEN j.scheduled THEN
    js.next_start
  END AS next_start,
  js.total_runs,
  js.total_successes,
  js.total_failures
FROM _timescaledb_config.bgw_job j
  INNER JOIN _timescaledb_internal.bgw_job_stat js ON j.id = js.job_id
  LEFT JOIN _timescaledb_catalog.hypertable ht ON j.hypertable_id = ht.id
  LEFT JOIN pg_stat_activity pgs ON pgs.datname = current_database()
    AND pgs.application_name = j.application_name
  ORDER BY ht.schema_name,
    ht.table_name;

-- view for background worker jobs
CREATE OR REPLACE VIEW timescaledb_information.jobs AS
SELECT j.id AS job_id,
  j.application_name,
  j.schedule_interval,
  j.max_runtime,
  j.max_retries,
  j.retry_period,
  j.proc_schema,
  j.proc_name,
  j.owner,
  j.scheduled,
  j.config,
  js.next_start,
  ht.schema_name AS hypertable_schema,
  ht.table_name AS hypertable_name
FROM _timescaledb_config.bgw_job j
  LEFT JOIN _timescaledb_catalog.hypertable ht ON ht.id = j.hypertable_id
  LEFT JOIN _timescaledb_internal.bgw_job_stat js ON js.job_id = j.id;

-- views for continuous aggregate queries ---
CREATE OR REPLACE VIEW timescaledb_information.continuous_aggregates AS
SELECT ht.schema_name AS hypertable_schema,
  ht.table_name AS hypertable_name,
  cagg.user_view_schema AS view_schema,
  cagg.user_view_name AS view_name,
  viewinfo.viewowner AS view_owner,
  cagg.materialized_only,
  mat_ht.schema_name AS materialization_hypertable_schema,
  mat_ht.table_name AS materialization_hypertable_name,
  directview.viewdefinition AS view_definition
FROM _timescaledb_catalog.continuous_agg cagg,
  _timescaledb_catalog.hypertable ht,
  LATERAL (
    SELECT C.oid,
      pg_get_userbyid(C.relowner) AS viewowner
    FROM pg_class C
      LEFT JOIN pg_namespace N ON (N.oid = C.relnamespace)
    WHERE C.relkind = 'v'
      AND C.relname = cagg.user_view_name
      AND N.nspname = cagg.user_view_schema) viewinfo,
  LATERAL (
    SELECT pg_get_viewdef(C.oid) AS viewdefinition
    FROM pg_class C
    LEFT JOIN pg_namespace N ON (N.oid = C.relnamespace)
  WHERE C.relkind = 'v'
    AND C.relname = cagg.direct_view_name
    AND N.nspname = cagg.direct_view_schema) directview,
  LATERAL (
    SELECT schema_name, table_name
    FROM _timescaledb_catalog.hypertable
    WHERE cagg.mat_hypertable_id = id) mat_ht
WHERE cagg.raw_hypertable_id = ht.id;

CREATE OR REPLACE VIEW timescaledb_information.data_nodes AS
SELECT s.node_name,
  s.owner,
  s.options
FROM (
  SELECT srvname AS node_name,
    srvowner::regrole::name AS owner,
    srvoptions AS options
  FROM pg_catalog.pg_foreign_server AS srv,
    pg_catalog.pg_foreign_data_wrapper AS fdw
  WHERE srv.srvfdw = fdw.oid
    AND fdw.fdwname = 'timescaledb_fdw') AS s;

-- chunks metadata view, shows information about the primary dimension column
-- query plans with CTEs are not always optimized by PG. So use in-line
-- tables.

CREATE OR REPLACE VIEW timescaledb_information.chunks AS
SELECT hypertable_schema,
  hypertable_name,
  schema_name AS chunk_schema,
  chunk_name,
  primary_dimension,
  primary_dimension_type,
  range_start,
  range_end,
  integer_range_start AS range_start_integer,
  integer_range_end AS range_end_integer,
  is_compressed,
  chunk_table_space AS chunk_tablespace,
  node_list AS data_nodes
FROM (
  SELECT ht.schema_name AS hypertable_schema,
    ht.table_name AS hypertable_name,
    srcch.schema_name AS schema_name,
    srcch.table_name AS chunk_name,
    dim.column_name AS primary_dimension,
    dim.column_type AS primary_dimension_type,
    row_number() OVER (PARTITION BY chcons.chunk_id ORDER BY dim.id) AS chunk_dimension_num,
    CASE WHEN (dim.column_type = 'TIMESTAMP'::regtype
      OR dim.column_type = 'TIMESTAMPTZ'::regtype
      OR dim.column_type = 'DATE'::regtype) THEN
      _timescaledb_internal.to_timestamp(dimsl.range_start)
    ELSE
      NULL
    END AS range_start,
    CASE WHEN (dim.column_type = 'TIMESTAMP'::regtype
      OR dim.column_type = 'TIMESTAMPTZ'::regtype
      OR dim.column_type = 'DATE'::regtype) THEN
      _timescaledb_internal.to_timestamp(dimsl.range_end)
    ELSE
      NULL
    END AS range_end,
    CASE WHEN (dim.column_type = 'TIMESTAMP'::regtype
      OR dim.column_type = 'TIMESTAMPTZ'::regtype
      OR dim.column_type = 'DATE'::regtype) THEN
      NULL
    ELSE
      dimsl.range_start
    END AS integer_range_start,
    CASE WHEN (dim.column_type = 'TIMESTAMP'::regtype
      OR dim.column_type = 'TIMESTAMPTZ'::regtype
      OR dim.column_type = 'DATE'::regtype) THEN
      NULL
    ELSE
      dimsl.range_end
    END AS integer_range_end,
    CASE WHEN (srcch.status & 1 = 1) THEN --distributed compress_chunk() has definitely been called
                                          --remote chunk compression status still uncertain
        TRUE
    ELSE FALSE --remote chunk compression status uncertain
    END AS is_compressed,
    pgtab.spcname AS chunk_table_space,
    chdn.node_list
  FROM _timescaledb_catalog.chunk srcch
    INNER JOIN _timescaledb_catalog.hypertable ht ON ht.id = srcch.hypertable_id
    INNER JOIN _timescaledb_catalog.chunk_constraint chcons ON srcch.id = chcons.chunk_id
    INNER JOIN _timescaledb_catalog.dimension dim ON srcch.hypertable_id = dim.hypertable_id
    INNER JOIN _timescaledb_catalog.dimension_slice dimsl ON dim.id = dimsl.dimension_id
      AND chcons.dimension_slice_id = dimsl.id
    INNER JOIN (
      SELECT relname,
        reltablespace,
        nspname AS schema_name
      FROM pg_class,
        pg_namespace
      WHERE pg_class.relnamespace = pg_namespace.oid) cl ON srcch.table_name = cl.relname
      AND srcch.schema_name = cl.schema_name
    LEFT OUTER JOIN pg_tablespace pgtab ON pgtab.oid = reltablespace
  LEFT OUTER JOIN (
    SELECT chunk_id,
      array_agg(node_name ORDER BY node_name) AS node_list
    FROM _timescaledb_catalog.chunk_data_node
    GROUP BY chunk_id) chdn ON srcch.id = chdn.chunk_id
  WHERE srcch.dropped IS FALSE
    AND ht.compression_state != 2 ) finalq
WHERE chunk_dimension_num = 1;

-- hypertable's dimension information
-- CTEs aren't used in the query as PG does not always optimize them
-- as expected.

CREATE OR REPLACE VIEW timescaledb_information.dimensions AS
SELECT ht.schema_name AS hypertable_schema,
  ht.table_name AS hypertable_name,
  rank() OVER (PARTITION BY hypertable_id ORDER BY dim.id) AS dimension_number,
  dim.column_name,
  dim.column_type,
  CASE WHEN dim.interval_length IS NULL THEN
    'Space'
  ELSE
    'Time'
  END AS dimension_type,
  CASE WHEN dim.interval_length IS NOT NULL THEN
    CASE WHEN dim.column_type = 'TIMESTAMP'::regtype
      OR dim.column_type = 'TIMESTAMPTZ'::regtype
      OR dim.column_type = 'DATE'::regtype THEN
      _timescaledb_internal.to_interval (dim.interval_length)
    ELSE
      NULL
    END
  END AS time_interval,
  CASE WHEN dim.interval_length IS NOT NULL THEN
    CASE WHEN dim.column_type = 'TIMESTAMP'::regtype
      OR dim.column_type = 'TIMESTAMPTZ'::regtype
      OR dim.column_type = 'DATE'::regtype THEN
      NULL
    ELSE
      dim.interval_length
    END
  END AS integer_interval,
  dim.integer_now_func,
  dim.num_slices AS num_partitions
FROM _timescaledb_catalog.hypertable ht,
  _timescaledb_catalog.dimension dim
WHERE dim.hypertable_id = ht.id;

---compression parameters information ---
CREATE OR REPLACE VIEW timescaledb_information.compression_settings AS
SELECT ht.schema_name AS hypertable_schema,
  ht.table_name AS hypertable_name,
  segq.attname,
  segq.segmentby_column_index,
  segq.orderby_column_index,
  segq.orderby_asc,
  segq.orderby_nullsfirst
FROM _timescaledb_catalog.hypertable_compression segq,
  _timescaledb_catalog.hypertable ht
WHERE segq.hypertable_id = ht.id
  AND (segq.segmentby_column_index IS NOT NULL
    OR segq.orderby_column_index IS NOT NULL)
ORDER BY table_name,
  segmentby_column_index,
  orderby_column_index;

GRANT USAGE ON SCHEMA timescaledb_information TO PUBLIC;

GRANT SELECT ON ALL TABLES IN SCHEMA timescaledb_information TO PUBLIC;
-- This file and its contents are licensed under the Apache License 2.0.
-- Please see the included NOTICE for copyright information and
-- LICENSE-APACHE for a copy of the license.

CREATE OR REPLACE VIEW timescaledb_experimental.chunk_replication_status AS
SELECT
    h.schema_name AS hypertable_schema,
    h.table_name AS hypertable_name,
    c.schema_name AS chunk_schema,
    c.table_name AS chunk_name,
    h.replication_factor AS desired_num_replicas,
    count(cdn.chunk_id) AS num_replicas,
    array_agg(cdn.node_name) AS replica_nodes,
    -- compute the set of data nodes that doesn't have the chunk
    (SELECT array_agg(node_name) FROM
            (SELECT node_name FROM _timescaledb_catalog.hypertable_data_node hdn
             WHERE hdn.hypertable_id = h.id
             EXCEPT
             SELECT node_name FROM _timescaledb_catalog.chunk_data_node cdn
             WHERE cdn.chunk_id = c.id
             ORDER BY node_name) nodes) AS non_replica_nodes
FROM _timescaledb_catalog.chunk c
INNER JOIN _timescaledb_catalog.chunk_data_node cdn ON (cdn.chunk_id = c.id)
INNER JOIN _timescaledb_catalog.hypertable h ON (h.id = c.hypertable_id)
GROUP BY h.id, c.id, hypertable_schema, hypertable_name, chunk_schema, chunk_name
ORDER BY h.id, c.id, hypertable_schema, hypertable_name, chunk_schema, chunk_name;

GRANT SELECT ON ALL TABLES IN SCHEMA timescaledb_experimental TO PUBLIC;
-- This file and its contents are licensed under the Apache License 2.0.
-- Please see the included NOTICE for copyright information and
-- LICENSE-APACHE for a copy of the license.

CREATE OR REPLACE FUNCTION time_bucket_gapfill(bucket_width SMALLINT, ts SMALLINT, start SMALLINT=NULL, finish SMALLINT=NULL) RETURNS SMALLINT
	AS '$libdir/timescaledb-2.5.1', 'ts_gapfill_int16_bucket' LANGUAGE C VOLATILE PARALLEL SAFE;

CREATE OR REPLACE FUNCTION time_bucket_gapfill(bucket_width INT, ts INT, start INT=NULL, finish INT=NULL) RETURNS INT
	AS '$libdir/timescaledb-2.5.1', 'ts_gapfill_int32_bucket' LANGUAGE C VOLATILE PARALLEL SAFE;

CREATE OR REPLACE FUNCTION time_bucket_gapfill(bucket_width BIGINT, ts BIGINT, start BIGINT=NULL, finish BIGINT=NULL) RETURNS BIGINT
	AS '$libdir/timescaledb-2.5.1', 'ts_gapfill_int64_bucket' LANGUAGE C VOLATILE PARALLEL SAFE;

CREATE OR REPLACE FUNCTION time_bucket_gapfill(bucket_width INTERVAL, ts DATE, start DATE=NULL, finish DATE=NULL) RETURNS DATE
	AS '$libdir/timescaledb-2.5.1', 'ts_gapfill_date_bucket' LANGUAGE C VOLATILE PARALLEL SAFE;

CREATE OR REPLACE FUNCTION time_bucket_gapfill(bucket_width INTERVAL, ts TIMESTAMP, start TIMESTAMP=NULL, finish TIMESTAMP=NULL) RETURNS TIMESTAMP
	AS '$libdir/timescaledb-2.5.1', 'ts_gapfill_timestamp_bucket' LANGUAGE C VOLATILE PARALLEL SAFE;

CREATE OR REPLACE FUNCTION time_bucket_gapfill(bucket_width INTERVAL, ts TIMESTAMPTZ, start TIMESTAMPTZ=NULL, finish TIMESTAMPTZ=NULL) RETURNS TIMESTAMPTZ
	AS '$libdir/timescaledb-2.5.1', 'ts_gapfill_timestamptz_bucket' LANGUAGE C VOLATILE PARALLEL SAFE;

-- locf function
CREATE OR REPLACE FUNCTION locf(value ANYELEMENT, prev ANYELEMENT=NULL, treat_null_as_missing BOOL=false) RETURNS ANYELEMENT
	AS '$libdir/timescaledb-2.5.1', 'ts_gapfill_marker' LANGUAGE C VOLATILE PARALLEL SAFE;

-- interpolate functions
CREATE OR REPLACE FUNCTION interpolate(value SMALLINT,prev RECORD=NULL,next RECORD=NULL) RETURNS SMALLINT
	AS '$libdir/timescaledb-2.5.1', 'ts_gapfill_marker' LANGUAGE C VOLATILE PARALLEL SAFE;

CREATE OR REPLACE FUNCTION interpolate(value INT,prev RECORD=NULL,next RECORD=NULL) RETURNS INT
	AS '$libdir/timescaledb-2.5.1', 'ts_gapfill_marker' LANGUAGE C VOLATILE PARALLEL SAFE;

CREATE OR REPLACE FUNCTION interpolate(value BIGINT,prev RECORD=NULL,next RECORD=NULL) RETURNS BIGINT
	AS '$libdir/timescaledb-2.5.1', 'ts_gapfill_marker' LANGUAGE C VOLATILE PARALLEL SAFE;

CREATE OR REPLACE FUNCTION interpolate(value REAL,prev RECORD=NULL,next RECORD=NULL) RETURNS REAL
	AS '$libdir/timescaledb-2.5.1', 'ts_gapfill_marker' LANGUAGE C VOLATILE PARALLEL SAFE;

CREATE OR REPLACE FUNCTION interpolate(value FLOAT,prev RECORD=NULL,next RECORD=NULL) RETURNS FLOAT
	AS '$libdir/timescaledb-2.5.1', 'ts_gapfill_marker' LANGUAGE C VOLATILE PARALLEL SAFE;

-- This file and its contents are licensed under the Apache License 2.0.
-- Please see the included NOTICE for copyright information and
-- LICENSE-APACHE for a copy of the license.

-- chunk - the OID of the chunk to be CLUSTERed
-- index - the OID of the index to be CLUSTERed on, or NULL to use the index
--         last used
CREATE OR REPLACE FUNCTION reorder_chunk(
    chunk REGCLASS,
    index REGCLASS=NULL,
    verbose BOOLEAN=FALSE
) RETURNS VOID AS '$libdir/timescaledb-2.5.1', 'ts_reorder_chunk' LANGUAGE C VOLATILE;

CREATE OR REPLACE FUNCTION move_chunk(
    chunk REGCLASS,
    destination_tablespace Name,
    index_destination_tablespace Name=NULL,
    reorder_index REGCLASS=NULL,
    verbose BOOLEAN=FALSE
) RETURNS VOID AS '$libdir/timescaledb-2.5.1', 'ts_move_chunk' LANGUAGE C VOLATILE;

CREATE OR REPLACE FUNCTION compress_chunk(
    uncompressed_chunk REGCLASS,
    if_not_compressed BOOLEAN = false
) RETURNS REGCLASS AS '$libdir/timescaledb-2.5.1', 'ts_compress_chunk' LANGUAGE C STRICT VOLATILE;

CREATE OR REPLACE FUNCTION decompress_chunk(
    uncompressed_chunk REGCLASS,
    if_compressed BOOLEAN = false
) RETURNS REGCLASS AS '$libdir/timescaledb-2.5.1', 'ts_decompress_chunk' LANGUAGE C STRICT VOLATILE;

CREATE OR REPLACE FUNCTION recompress_chunk(
    chunk REGCLASS,
    if_not_compressed BOOLEAN = false
) RETURNS REGCLASS AS '$libdir/timescaledb-2.5.1', 'ts_recompress_chunk' LANGUAGE C STRICT VOLATILE;
-- This file and its contents are licensed under the Apache License 2.0.
-- Please see the included NOTICE for copyright information and
-- LICENSE-APACHE for a copy of the license.

CREATE OR REPLACE FUNCTION _timescaledb_internal.partialize_agg(arg ANYELEMENT)
RETURNS BYTEA AS '$libdir/timescaledb-2.5.1', 'ts_partialize_agg' LANGUAGE C VOLATILE;

CREATE OR REPLACE FUNCTION _timescaledb_internal.finalize_agg_sfunc(
tstate internal, aggfn TEXT, inner_agg_collation_schema NAME, inner_agg_collation_name NAME, inner_agg_input_types NAME[][], inner_agg_serialized_state BYTEA, return_type_dummy_val ANYELEMENT)
RETURNS internal
AS '$libdir/timescaledb-2.5.1', 'ts_finalize_agg_sfunc'
LANGUAGE C IMMUTABLE ;

CREATE OR REPLACE FUNCTION _timescaledb_internal.finalize_agg_ffunc(
tstate internal, aggfn TEXT, inner_agg_collation_schema NAME, inner_agg_collation_name NAME, inner_agg_input_types NAME[][], inner_agg_serialized_state BYTEA, return_type_dummy_val ANYELEMENT)
RETURNS anyelement
AS '$libdir/timescaledb-2.5.1', 'ts_finalize_agg_ffunc'
LANGUAGE C IMMUTABLE ;

CREATE OR REPLACE AGGREGATE _timescaledb_internal.finalize_agg(agg_name TEXT,  inner_agg_collation_schema NAME,  inner_agg_collation_name NAME, inner_agg_input_types NAME[][], inner_agg_serialized_state BYTEA, return_type_dummy_val anyelement) (
    SFUNC = _timescaledb_internal.finalize_agg_sfunc,
    STYPE = internal,
    FINALFUNC = _timescaledb_internal.finalize_agg_ffunc,
    FINALFUNC_EXTRA
);
-- This file and its contents are licensed under the Apache License 2.0.
-- Please see the included NOTICE for copyright information and
-- LICENSE-APACHE for a copy of the license.

CREATE OR REPLACE FUNCTION timescaledb_pre_restore() RETURNS BOOL AS
$BODY$
DECLARE
    db text;
BEGIN
    SELECT current_database() INTO db;
    EXECUTE format($$ALTER DATABASE %I SET timescaledb.restoring ='on'$$, db);
    SET SESSION timescaledb.restoring = 'on';
    PERFORM _timescaledb_internal.stop_background_workers();
    --exported uuid may be included in the dump so backup the version
    UPDATE _timescaledb_catalog.metadata SET key='exported_uuid_bak' WHERE key='exported_uuid';
    RETURN true;
END
$BODY$
LANGUAGE PLPGSQL;


CREATE OR REPLACE FUNCTION timescaledb_post_restore() RETURNS BOOL AS
$BODY$
DECLARE
    db text;
BEGIN
    SELECT current_database() INTO db;
    EXECUTE format($$ALTER DATABASE %I RESET timescaledb.restoring $$, db);
    RESET timescaledb.restoring;
    PERFORM _timescaledb_internal.restart_background_workers();

    --try to restore the backed up uuid, if the restore did not set one
    INSERT INTO _timescaledb_catalog.metadata
       SELECT 'exported_uuid', value, include_in_telemetry FROM _timescaledb_catalog.metadata WHERE key='exported_uuid_bak'
       ON CONFLICT DO NOTHING;
    DELETE FROM _timescaledb_catalog.metadata WHERE key='exported_uuid_bak';

    RETURN true;
END
$BODY$
LANGUAGE PLPGSQL;
-- This file and its contents are licensed under the Apache License 2.0.
-- Please see the included NOTICE for copyright information and
-- LICENSE-APACHE for a copy of the license.

CREATE OR REPLACE FUNCTION add_job(
  proc REGPROC,
  schedule_interval INTERVAL,
  config JSONB DEFAULT NULL,
  initial_start TIMESTAMPTZ DEFAULT NULL,
  scheduled BOOL DEFAULT true
) RETURNS INTEGER AS '$libdir/timescaledb-2.5.1', 'ts_job_add' LANGUAGE C VOLATILE;

CREATE OR REPLACE FUNCTION delete_job(job_id INTEGER) RETURNS VOID AS '$libdir/timescaledb-2.5.1', 'ts_job_delete' LANGUAGE C VOLATILE STRICT;
CREATE OR REPLACE PROCEDURE run_job(job_id INTEGER) AS '$libdir/timescaledb-2.5.1', 'ts_job_run' LANGUAGE C;

-- Returns the updated job schedule values
CREATE OR REPLACE FUNCTION alter_job(
    job_id INTEGER,
    schedule_interval INTERVAL = NULL,
    max_runtime INTERVAL = NULL,
    max_retries INTEGER = NULL,
    retry_period INTERVAL = NULL,
    scheduled BOOL = NULL,
    config JSONB = NULL,
    next_start TIMESTAMPTZ = NULL,
    if_exists BOOL = FALSE
)
RETURNS TABLE (job_id INTEGER, schedule_interval INTERVAL, max_runtime INTERVAL, max_retries INTEGER, retry_period INTERVAL, scheduled BOOL, config JSONB, next_start TIMESTAMPTZ)
AS '$libdir/timescaledb-2.5.1', 'ts_job_alter'
LANGUAGE C VOLATILE;
-- This file and its contents are licensed under the Apache License 2.0.
-- Please see the included NOTICE for copyright information and
-- LICENSE-APACHE for a copy of the license.

-- Add a retention policy to a hypertable or continuous aggregate.
-- The retention_window (typically an INTERVAL) determines the
-- window beyond which data is dropped at the time
-- of execution of the policy (e.g., '1 week'). Note that the retention
-- window will always align with chunk boundaries, thus the window
-- might be larger than the given one, but never smaller. In other
-- words, some data beyond the retention window
-- might be kept, but data within the window will never be deleted.
CREATE OR REPLACE FUNCTION add_retention_policy(
       relation REGCLASS,
       drop_after "any",
       if_not_exists BOOL = false
)
RETURNS INTEGER AS '$libdir/timescaledb-2.5.1', 'ts_policy_retention_add'
LANGUAGE C VOLATILE STRICT;

CREATE OR REPLACE FUNCTION remove_retention_policy(
    relation REGCLASS,
    if_exists BOOL = false
) RETURNS VOID
AS '$libdir/timescaledb-2.5.1', 'ts_policy_retention_remove'
LANGUAGE C VOLATILE STRICT;

/* reorder policy */
CREATE OR REPLACE FUNCTION add_reorder_policy(hypertable REGCLASS, index_name NAME, if_not_exists BOOL = false) RETURNS INTEGER
AS '$libdir/timescaledb-2.5.1', 'ts_policy_reorder_add'
LANGUAGE C VOLATILE STRICT;

CREATE OR REPLACE FUNCTION remove_reorder_policy(hypertable REGCLASS, if_exists BOOL = false) RETURNS VOID
AS '$libdir/timescaledb-2.5.1', 'ts_policy_reorder_remove'
LANGUAGE C VOLATILE STRICT;

/* compression policy */
CREATE OR REPLACE FUNCTION add_compression_policy(hypertable REGCLASS, compress_after "any", if_not_exists BOOL = false)
RETURNS INTEGER
AS '$libdir/timescaledb-2.5.1', 'ts_policy_compression_add'
LANGUAGE C VOLATILE STRICT;

CREATE OR REPLACE FUNCTION remove_compression_policy(hypertable REGCLASS, if_exists BOOL = false) RETURNS BOOL
AS '$libdir/timescaledb-2.5.1', 'ts_policy_compression_remove'
LANGUAGE C VOLATILE STRICT;

/* continuous aggregates policy */
CREATE OR REPLACE FUNCTION add_continuous_aggregate_policy(continuous_aggregate REGCLASS, start_offset "any", end_offset "any", schedule_interval INTERVAL, if_not_exists BOOL = false)
RETURNS INTEGER
AS '$libdir/timescaledb-2.5.1', 'ts_policy_refresh_cagg_add'
LANGUAGE C VOLATILE;

CREATE OR REPLACE FUNCTION remove_continuous_aggregate_policy(continuous_aggregate REGCLASS, if_not_exists BOOL = false)
RETURNS VOID
AS '$libdir/timescaledb-2.5.1', 'ts_policy_refresh_cagg_remove'
LANGUAGE C VOLATILE STRICT;
-- This file and its contents are licensed under the Apache License 2.0.
-- Please see the included NOTICE for copyright information and
-- LICENSE-APACHE for a copy of the license.

CREATE OR REPLACE PROCEDURE _timescaledb_internal.policy_retention(job_id INTEGER, config JSONB)
AS '$libdir/timescaledb-2.5.1', 'ts_policy_retention_proc'
LANGUAGE C;

CREATE OR REPLACE PROCEDURE _timescaledb_internal.policy_reorder(job_id INTEGER, config JSONB)
AS '$libdir/timescaledb-2.5.1', 'ts_policy_reorder_proc'
LANGUAGE C;

CREATE OR REPLACE PROCEDURE _timescaledb_internal.policy_recompression(job_id INTEGER, config JSONB)
AS '$libdir/timescaledb-2.5.1', 'ts_policy_recompression_proc'
LANGUAGE C;

CREATE OR REPLACE PROCEDURE _timescaledb_internal.policy_refresh_continuous_aggregate(job_id INTEGER, config JSONB)
AS '$libdir/timescaledb-2.5.1', 'ts_policy_refresh_cagg_proc'
LANGUAGE C;

CREATE OR REPLACE PROCEDURE
_timescaledb_internal.policy_compression_execute(
  job_id              INTEGER,
  htid                INTEGER,
  lag                 ANYELEMENT,
  maxchunks           INTEGER,
  verbose_log         BOOLEAN,
  recompress_enabled  BOOLEAN)
AS $$
DECLARE
  htoid       REGCLASS;
  chunk_rec   RECORD;
  numchunks   INTEGER := 1;
BEGIN

  SELECT format('%I.%I', schema_name, table_name) INTO htoid
  FROM _timescaledb_catalog.hypertable
  WHERE id = htid;

  -- for the integer cases, we have to compute the lag w.r.t
  -- the integer_now function and then pass on to show_chunks
  IF pg_typeof(lag) IN ('BIGINT'::regtype, 'INTEGER'::regtype, 'SMALLINT'::regtype) THEN
    lag := _timescaledb_internal.subtract_integer_from_now(htoid, lag::BIGINT);
  END IF;

  FOR chunk_rec IN
    SELECT
      show.oid, ch.schema_name, ch.table_name, ch.status
    FROM
      show_chunks(htoid, older_than => lag) AS show(oid)
      INNER JOIN pg_class pgc ON pgc.oid = show.oid
      INNER JOIN pg_namespace pgns ON pgc.relnamespace = pgns.oid
      INNER JOIN _timescaledb_catalog.chunk ch ON ch.table_name = pgc.relname AND ch.schema_name = pgns.nspname AND ch.hypertable_id = htid
    WHERE
      ch.dropped IS FALSE
      AND (ch.status = 0 OR ch.status = 3)
  LOOP
    IF chunk_rec.status = 0 THEN
       PERFORM compress_chunk( chunk_rec.oid );
    ELSIF chunk_rec.status = 3 AND recompress_enabled IS TRUE THEN
       PERFORM decompress_chunk(chunk_rec.oid, if_compressed => true);
       COMMIT;
       PERFORM compress_chunk(chunk_rec.oid);
    END IF;
    COMMIT;
    IF verbose_log THEN
       RAISE LOG 'job % completed processing chunk %.%', job_id, chunk_rec.schema_name, chunk_rec.table_name;
    END IF;
    numchunks := numchunks + 1;
    IF maxchunks > 0 AND numchunks >= maxchunks THEN
         EXIT;
    END IF;
  END LOOP;
END;
$$ LANGUAGE PLPGSQL;

CREATE OR REPLACE PROCEDURE
_timescaledb_internal.policy_compression(job_id INTEGER, config JSONB)
AS $$
DECLARE
  dimtype             REGTYPE;
  dimtypeinput        REGPROC;
  compress_after      TEXT;
  lag_value           TEXT;
  htid                INTEGER;
  htoid               REGCLASS;
  chunk_rec           RECORD;
  verbose_log         BOOL;
  maxchunks           INTEGER := 0;
  numchunks           INTEGER := 1;
  recompress_enabled  BOOL;
BEGIN
  IF config IS NULL THEN
    RAISE EXCEPTION 'job % has null config', job_id;
  END IF;

  htid := jsonb_object_field_text(config, 'hypertable_id')::INTEGER;
  IF htid is NULL THEN
    RAISE EXCEPTION 'job % config must have hypertable_id', job_id;
  END IF;

  verbose_log         := COALESCE(jsonb_object_field_text(config, 'verbose_log')::BOOLEAN, FALSE);
  maxchunks           := COALESCE(jsonb_object_field_text(config, 'maxchunks_to_compress')::INTEGER, 0);
  recompress_enabled  := COALESCE(jsonb_object_field_text(config, 'recompress')::BOOLEAN, TRUE);
  compress_after      := jsonb_object_field_text(config, 'compress_after');

  IF compress_after IS NULL THEN
    RAISE EXCEPTION 'job % config must have compress_after', job_id;
  END IF;

  -- find primary dimension type --
  SELECT dim.column_type INTO dimtype
  FROM  _timescaledb_catalog.hypertable ht
        JOIN _timescaledb_catalog.dimension dim ON ht.id = dim.hypertable_id
  WHERE ht.id = htid
  ORDER BY dim.id
  LIMIT 1;

  lag_value := jsonb_object_field_text(config, 'compress_after');

  -- execute the properly type casts for the lag value
  CASE dimtype
    WHEN 'TIMESTAMP'::regtype, 'TIMESTAMPTZ'::regtype, 'DATE'::regtype THEN
      CALL _timescaledb_internal.policy_compression_execute(
        job_id, htid, lag_value::INTERVAL,
        maxchunks, verbose_log, recompress_enabled
      );
    WHEN 'BIGINT'::regtype THEN
      CALL _timescaledb_internal.policy_compression_execute(
        job_id, htid, lag_value::BIGINT,
        maxchunks, verbose_log, recompress_enabled
      );
    WHEN 'INTEGER'::regtype THEN
      CALL _timescaledb_internal.policy_compression_execute(
        job_id, htid, lag_value::INTEGER,
        maxchunks, verbose_log, recompress_enabled
      );
    WHEN 'SMALLINT'::regtype THEN
      CALL _timescaledb_internal.policy_compression_execute(
        job_id, htid, lag_value::SMALLINT,
        maxchunks, verbose_log, recompress_enabled
      );
  END CASE;
END;
$$ LANGUAGE PLPGSQL;
-- This file and its contents are licensed under the Apache License 2.0.
-- Please see the included NOTICE for copyright information and
-- LICENSE-APACHE for a copy of the license.

-- Adds a materialization invalidation log entry to the local data node
--
-- mat_hypertable_id - The hypertable ID of the CAGG materialized hypertable in the Access Node
-- start_time - The starting time of the materialization invalidation log entry
-- end_time - The ending time of the materialization invalidation log entry
CREATE OR REPLACE FUNCTION _timescaledb_internal.invalidation_cagg_log_add_entry(
    mat_hypertable_id INTEGER,
    start_time BIGINT,
    end_time BIGINT
) RETURNS VOID AS '$libdir/timescaledb-2.5.1', 'ts_invalidation_cagg_log_add_entry' LANGUAGE C STRICT VOLATILE;

-- Adds a materialization invalidation log entry to the local data node
--
-- raw_hypertable_id - The hypertable ID of the original distributed hypertable in the Access Node
-- start_time - The starting time of the materialization invalidation log entry
-- end_time - The ending time of the materialization invalidation log entry
CREATE OR REPLACE FUNCTION _timescaledb_internal.invalidation_hyper_log_add_entry(
    raw_hypertable_id INTEGER,
    start_time BIGINT,
    end_time BIGINT
) RETURNS VOID AS '$libdir/timescaledb-2.5.1', 'ts_invalidation_hyper_log_add_entry' LANGUAGE C STRICT VOLATILE;

-- raw_hypertable_id - The hypertable ID of the original distributed hypertable in the Access Node
CREATE OR REPLACE FUNCTION _timescaledb_internal.hypertable_invalidation_log_delete(
    raw_hypertable_id INTEGER
) RETURNS VOID AS '$libdir/timescaledb-2.5.1', 'ts_hypertable_invalidation_log_delete' LANGUAGE C STRICT VOLATILE;

-- mat_hypertable_id - The hypertable ID of the CAGG materialized hypertable in the Access Node
CREATE OR REPLACE FUNCTION _timescaledb_internal.materialization_invalidation_log_delete(
    mat_hypertable_id INTEGER
) RETURNS VOID AS '$libdir/timescaledb-2.5.1', 'ts_materialization_invalidation_log_delete' LANGUAGE C STRICT VOLATILE;

-- raw_hypertable_id - The hypertable ID of the original distributed hypertable in the Access Node
CREATE OR REPLACE FUNCTION _timescaledb_internal.drop_dist_ht_invalidation_trigger(
    raw_hypertable_id INTEGER
) RETURNS VOID AS '$libdir/timescaledb-2.5.1', 'ts_drop_dist_ht_invalidation_trigger' LANGUAGE C STRICT VOLATILE;

-- Processes the hypertable invalidation log in a data node for all the CAGGs that belong to the
-- distributed hypertable with hypertable ID 'raw_hypertable_id' in the Access Node. The
-- invalidations are cut, merged and moved to the materialization invalidation log.
--
-- mat_hypertable_id - The hypertable ID of the CAGG materialized hypertable in the Access Node
--                     that is currently being refreshed
-- raw_hypertable_id - The hypertable ID of the original distributed hypertable in the Access Node
-- dimtype - The OID of the type of the time dimension for this CAGG
-- mat_hypertable_ids - The array of hypertable IDs for all CAGG materialized hypertables in the
--                      Access Node that belong to 'raw_hypertable_id'
-- bucket_widths - The array of time bucket widths for all the CAGGs that belong to
--                 'raw_hypertable_id'
-- max_bucket_widths - The array of the maximum time bucket widths for all the CAGGs that belong
--                     to 'raw_hypertable_id'
CREATE OR REPLACE FUNCTION _timescaledb_internal.invalidation_process_hypertable_log(
    mat_hypertable_id INTEGER,
    raw_hypertable_id INTEGER,
    dimtype REGTYPE,
    mat_hypertable_ids INTEGER[],
    bucket_widths BIGINT[],
    max_bucket_widths BIGINT[]
) RETURNS VOID AS '$libdir/timescaledb-2.5.1', 'ts_invalidation_process_hypertable_log' LANGUAGE C STRICT VOLATILE;

-- Processes the materialization invalidation log in a data node for the CAGG being refreshed that
-- belongs to the distributed hypertable with hypertable ID 'raw_hypertable_id' in the Access Node.
-- The invalidations are cut, merged and returned as a single refresh window.
--
-- mat_hypertable_id - The hypertable ID of the CAGG materialized hypertable in the Access Node
--                     that is currently being refreshed.
-- raw_hypertable_id - The hypertable ID of the original distributed hypertable in the Access Node
-- dimtype - The OID of the type of the time dimension for this CAGG
-- window_start - The starting time of the CAGG refresh window
-- window_end - The ending time of the CAGG refresh window
-- mat_hypertable_ids - The array of hypertable IDs for all CAGG materialized hypertables in the
--                      Access Node that belong to 'raw_hypertable_id'
-- bucket_widths - The array of time bucket widths for all the CAGGs that belong to
--                 'raw_hypertable_id'
-- max_bucket_widths - The array of the maximum time bucket widths for all the CAGGs that belong
--                     to 'raw_hypertable_id'
--
-- Returns a tuple of:
-- ret_window_start - The merged refresh window starting time
-- ret_window_end - The merged refresh window ending time
CREATE OR REPLACE FUNCTION _timescaledb_internal.invalidation_process_cagg_log(
    mat_hypertable_id INTEGER,
    raw_hypertable_id INTEGER,
    dimtype REGTYPE,
    window_start BIGINT,
    window_end BIGINT,
    mat_hypertable_ids INTEGER[],
    bucket_widths BIGINT[],
    max_bucket_widths BIGINT[],
    OUT ret_window_start BIGINT,
    OUT ret_window_end BIGINT
) RETURNS RECORD AS '$libdir/timescaledb-2.5.1', 'ts_invalidation_process_cagg_log' LANGUAGE C STRICT VOLATILE;
set timescaledb.update_script_stage = 'post';
-- needed post 1.7.0 to fixup continuous aggregates created in 1.7.0 ---
DO $$
DECLARE
 vname regclass;
 materialized_only bool;
 ts_version TEXT;
BEGIN
    SELECT extversion INTO ts_version FROM pg_extension WHERE extname = 'timescaledb';

    FOR vname, materialized_only IN select format('%I.%I', cagg.user_view_schema, cagg.user_view_name)::regclass, cagg.materialized_only from _timescaledb_catalog.continuous_agg cagg
    LOOP
        -- the cast from oid to text returns
        -- quote_qualified_identifier (see regclassout).
        --
        -- We use the if statement to handle pre-2.0 as well as
        -- post-2.0.  This could be turned into a procedure if we want
        -- to have something more generic, but right now it is just
        -- this case.
        IF ts_version < '2.0.0' THEN
            EXECUTE format('ALTER VIEW %s SET (timescaledb.materialized_only=%L) ', vname::text, materialized_only);
        ELSE
            EXECUTE format('ALTER MATERIALIZED VIEW %s SET (timescaledb.materialized_only=%L) ', vname::text, materialized_only);
        END IF;
    END LOOP;
    EXCEPTION WHEN OTHERS THEN RAISE;
END
$$;

-- can only be dropped after views have been rebuilt
DROP FUNCTION IF EXISTS _timescaledb_internal.cagg_watermark(oid);

-- For objects that are newly created, we need to set the initprivs to
-- the initprivs for some table that was created in the installation
-- of the TimescaleDB extension and not as part of any update.
--
-- We chose the "chunk" catalog table for this since that is created
-- in the first version of TimescaleDB and should have the correct
-- initprivs, but we could use any other table that existed in the
-- first installation.
INSERT INTO saved_privs
     SELECT nspname, relname, relacl,
       (SELECT tmpini FROM saved_privs
        WHERE tmpnsp = '_timescaledb_catalog' AND tmpname = 'chunk')
       FROM pg_class JOIN pg_namespace ns ON ns.oid = relnamespace
         LEFT JOIN saved_privs ON tmpnsp = nspname AND tmpname = relname
      WHERE relkind IN ('r', 'v') AND nspname IN ('_timescaledb_catalog', '_timescaledb_config')
        OR nspname = '_timescaledb_internal'
        AND relname IN ('hypertable_chunk_local_size', 'compressed_chunk_stats',
                        'bgw_job_stat', 'bgw_policy_chunk_stats')
ON CONFLICT DO NOTHING;

-- The above is good enough for tables and views. However sequences need to
-- use the "chunk_id_seq" catalog sequence as a template
INSERT INTO saved_privs
     SELECT nspname, relname, relacl,
        (SELECT tmpini FROM saved_privs
	     WHERE tmpnsp = '_timescaledb_catalog' AND tmpname = 'chunk_id_seq')
        FROM pg_class JOIN pg_namespace ns ON ns.oid = relnamespace
		    LEFT JOIN saved_privs ON tmpnsp = nspname AND tmpname = relname
      WHERE relkind IN ('S') AND nspname IN ('_timescaledb_catalog', '_timescaledb_config')
        OR nspname = '_timescaledb_internal'
        AND relname IN ('hypertable_chunk_local_size', 'compressed_chunk_stats',
                        'bgw_job_stat', 'bgw_policy_chunk_stats')
ON CONFLICT DO NOTHING;

-- We can now copy back saved initprivs.
WITH to_update AS (
     SELECT objoid, tmpini
     FROM pg_class cl JOIN pg_namespace ns ON ns.oid = relnamespace
        JOIN pg_init_privs ip ON ip.objoid = cl.oid AND ip.objsubid = 0
        JOIN saved_privs ON tmpnsp = nspname AND tmpname = relname)
UPDATE pg_init_privs
   SET initprivs = tmpini
  FROM to_update
 WHERE to_update.objoid = pg_init_privs.objoid
   AND classoid = 'pg_class'::regclass
   AND objsubid = 0;

-- Can only restore permissions on views after they have been rebuilt,
-- so we restore for all types of objects here.
WITH to_update AS (
     SELECT cl.oid, tmpacl
     FROM pg_class cl JOIN pg_namespace ns ON ns.oid = relnamespace
                      JOIN saved_privs ON tmpnsp = nspname AND tmpname = relname)
UPDATE pg_class cl SET relacl = tmpacl
  FROM to_update WHERE cl.oid = to_update.oid;

DROP TABLE saved_privs;
set timescaledb.update_script_stage = '';
