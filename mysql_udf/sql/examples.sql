-- Point lookup an employee runs from DBeaver:
SELECT
  CONVERT(multi_compress_db_decompress(payload_compressed) USING utf8mb4) AS payload
FROM events
WHERE id = 123;

SELECT id
FROM events
WHERE multi_compress_db_is_valid(payload_compressed) = 0;

SELECT multi_compress_db_version();
