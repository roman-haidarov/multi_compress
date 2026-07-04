-- Install the MultiCompress MCDB1 reader UDFs (MySQL 5.7).

CREATE FUNCTION multi_compress_db_version
  RETURNS STRING
  SONAME 'multi_compress_mysql.so';

CREATE FUNCTION multi_compress_db_is_valid
  RETURNS INTEGER
  SONAME 'multi_compress_mysql.so';

CREATE FUNCTION multi_compress_db_decompress
  RETURNS STRING
  SONAME 'multi_compress_mysql.so';

SELECT multi_compress_db_version();
