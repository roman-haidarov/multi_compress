-- Point lookup an employee runs from DBeaver:
SELECT
  CONVERT(multi_compress_db_decompress(payload_compressed) USING utf8mb4) AS payload
FROM events
WHERE id = 123;

SELECT id
FROM events
WHERE multi_compress_db_is_valid(payload_compressed) = 0;

SELECT multi_compress_db_version();

-- MCDB2: use the generated ALGORITHM=MERGE readable view. Avoid filtering on
-- decoded payload text; filter/order by indexed source columns before LIMIT.
--
-- SELECT id, payload FROM admin.events_readable WHERE id >= 100 ORDER BY id LIMIT 100;
