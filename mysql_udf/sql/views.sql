-- Example read-side view for DBeaver / DataGrip / mysql console.

CREATE OR REPLACE VIEW events_readable AS
SELECT
  id,
  CONVERT(multi_compress_db_decompress(payload_compressed) USING utf8mb4) AS payload,
  created_at
FROM events;
