-- Replace multi_compress with the schema used in CREATE EXTENSION ... WITH SCHEMA.
CREATE OR REPLACE VIEW events_readable AS
SELECT
  id,
  multi_compress.multi_compress_db_decompress(payload_compressed) AS payload,
  created_at
FROM events;
