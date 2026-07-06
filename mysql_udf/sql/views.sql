-- MCDB1 view example. Generate production SQL with:
--   multi_compress db view mysql ...
CREATE OR REPLACE VIEW events_readable AS
SELECT
  id,
  CONVERT(multi_compress_db_decompress(payload_compressed) USING utf8mb4) AS payload
FROM events;

-- MCDB2 dictionary-backed shape. The generated view uses ALGORITHM=MERGE and
-- a source-first STRAIGHT_JOIN to the append-only registry, so an indexed outer
-- WHERE predicate is pushed into the source scan in MySQL 5.7. An outer ORDER BY
-- may still use filesort; that is not view materialization.
--
-- CREATE ALGORITHM=MERGE SQL SECURITY DEFINER VIEW events_readable AS
-- SELECT e.id,
--   CONVERT(multi_compress_db_decompress_dict(
--     e.payload_compressed, e.payload_dictionary_id, d.sha256, d.bytes
--   ) USING utf8mb4) AS payload
-- FROM events e
-- STRAIGHT_JOIN mcdb_dictionary_versions d ON d.id = e.payload_dictionary_id;
