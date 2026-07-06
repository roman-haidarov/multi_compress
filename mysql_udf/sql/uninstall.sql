-- Run only after verifying no generated readable view depends on these UDFs.
DROP FUNCTION IF EXISTS multi_compress_db_decompress_dict;
DROP FUNCTION IF EXISTS multi_compress_db_is_valid_dict;
DROP FUNCTION IF EXISTS multi_compress_db_dictionary_sha256;
DROP FUNCTION IF EXISTS multi_compress_db_dictionary_zstd_id;
DROP FUNCTION IF EXISTS multi_compress_db_original_size;
DROP FUNCTION IF EXISTS multi_compress_db_dictionary_ref;
DROP FUNCTION IF EXISTS multi_compress_db_decompress;
DROP FUNCTION IF EXISTS multi_compress_db_is_valid;
DROP FUNCTION IF EXISTS multi_compress_db_version;
