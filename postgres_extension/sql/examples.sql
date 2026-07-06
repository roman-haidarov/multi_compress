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

-- MCDB2: dictionary-backed payloads. The generated view should be preferred:
-- SELECT id, payload FROM admin.events_readable WHERE id >= 100 ORDER BY id LIMIT 100;
--
-- Direct diagnostic shape:
-- SELECT multi_compress_db_decompress_dict(
--   e.payload_compressed, e.payload_dictionary_id, d.sha256, d.bytes
-- )
-- FROM app.events e
-- JOIN app.mcdb_dictionary_versions d ON d.id = e.payload_dictionary_id
-- WHERE e.id = 123;
