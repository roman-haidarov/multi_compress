-- Install into a dedicated schema.
CREATE SCHEMA IF NOT EXISTS multi_compress;
CREATE EXTENSION multi_compress WITH SCHEMA multi_compress;

SELECT multi_compress.multi_compress_db_version();
SELECT multi_compress.multi_compress_db_is_valid(payload_compressed)
FROM events
WHERE id = 123;

SELECT multi_compress.multi_compress_db_decompress(payload_compressed)
FROM events
WHERE id = 123;
