\echo Use "CREATE EXTENSION multi_compress" to load this file. \quit

CREATE FUNCTION multi_compress_db_version()
RETURNS text
AS 'MODULE_PATHNAME', 'multi_compress_db_version'
LANGUAGE C
IMMUTABLE
PARALLEL SAFE;

CREATE FUNCTION multi_compress_db_is_valid(blob bytea)
RETURNS boolean
AS 'MODULE_PATHNAME', 'multi_compress_db_is_valid'
LANGUAGE C
IMMUTABLE
STRICT
PARALLEL SAFE;

CREATE FUNCTION multi_compress_db_decompress(blob bytea)
RETURNS text
AS 'MODULE_PATHNAME', 'multi_compress_db_decompress'
LANGUAGE C
IMMUTABLE
STRICT
PARALLEL SAFE;
