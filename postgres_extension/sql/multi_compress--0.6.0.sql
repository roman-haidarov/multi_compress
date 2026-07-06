\echo Use "CREATE EXTENSION multi_compress" to load this file. \quit

CREATE FUNCTION multi_compress_db_version()
RETURNS text
AS 'MODULE_PATHNAME', 'multi_compress_db_version'
LANGUAGE C
IMMUTABLE
PARALLEL SAFE;

-- MCDB1: dictionary-free, one blob argument.
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

-- MCDB2 metadata and dictionary registry validation helpers.
CREATE FUNCTION multi_compress_db_original_size(blob bytea)
RETURNS bigint
AS 'MODULE_PATHNAME', 'multi_compress_db_original_size'
LANGUAGE C
IMMUTABLE
STRICT
PARALLEL SAFE;

CREATE FUNCTION multi_compress_db_dictionary_ref(blob bytea)
RETURNS bigint
AS 'MODULE_PATHNAME', 'multi_compress_db_dictionary_ref'
LANGUAGE C
IMMUTABLE
STRICT
PARALLEL SAFE;

CREATE FUNCTION multi_compress_db_dictionary_zstd_id(dictionary bytea)
RETURNS bigint
AS 'MODULE_PATHNAME', 'multi_compress_db_dictionary_zstd_id'
LANGUAGE C
IMMUTABLE
STRICT
PARALLEL SAFE;

CREATE FUNCTION multi_compress_db_dictionary_sha256(dictionary bytea)
RETURNS bytea
AS 'MODULE_PATHNAME', 'multi_compress_db_dictionary_sha256'
LANGUAGE C
IMMUTABLE
STRICT
PARALLEL SAFE;

-- MCDB2: blob, immutable application registry id, SHA-256 bytes, dictionary bytes.
CREATE FUNCTION multi_compress_db_is_valid_dict(
  blob bytea,
  dictionary_ref bigint,
  dictionary_sha256 bytea,
  dictionary bytea
)
RETURNS boolean
AS 'MODULE_PATHNAME', 'multi_compress_db_is_valid_dict'
LANGUAGE C
IMMUTABLE
STRICT
PARALLEL SAFE;

CREATE FUNCTION multi_compress_db_decompress_dict(
  blob bytea,
  dictionary_ref bigint,
  dictionary_sha256 bytea,
  dictionary bytea
)
RETURNS text
AS 'MODULE_PATHNAME', 'multi_compress_db_decompress_dict'
LANGUAGE C
IMMUTABLE
STRICT
PARALLEL SAFE;
