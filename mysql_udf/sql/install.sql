-- Install the MultiCompress MCDB1/MCDB2 reader UDFs (MySQL 5.7).

CREATE FUNCTION multi_compress_db_version
  RETURNS STRING
  SONAME 'multi_compress_mysql.so';

CREATE FUNCTION multi_compress_db_is_valid
  RETURNS INTEGER
  SONAME 'multi_compress_mysql.so';

CREATE FUNCTION multi_compress_db_decompress
  RETURNS STRING
  SONAME 'multi_compress_mysql.so';

CREATE FUNCTION multi_compress_db_original_size
  RETURNS INTEGER
  SONAME 'multi_compress_mysql.so';

CREATE FUNCTION multi_compress_db_dictionary_ref
  RETURNS INTEGER
  SONAME 'multi_compress_mysql.so';

CREATE FUNCTION multi_compress_db_dictionary_zstd_id
  RETURNS INTEGER
  SONAME 'multi_compress_mysql.so';

CREATE FUNCTION multi_compress_db_dictionary_sha256
  RETURNS STRING
  SONAME 'multi_compress_mysql.so';

CREATE FUNCTION multi_compress_db_is_valid_dict
  RETURNS INTEGER
  SONAME 'multi_compress_mysql.so';

CREATE FUNCTION multi_compress_db_decompress_dict
  RETURNS STRING
  SONAME 'multi_compress_mysql.so';

SELECT multi_compress_db_version();
