#ifndef MCDB_MYSQL_UDF_ABI_57_H
#define MCDB_MYSQL_UDF_ABI_57_H

typedef char my_bool;

enum Item_result {
    STRING_RESULT = 0,
    REAL_RESULT,
    INT_RESULT,
    ROW_RESULT,
    DECIMAL_RESULT
};

typedef struct st_udf_args {
    unsigned int arg_count;
    enum Item_result *arg_type;
    char **args;
    unsigned long *lengths;
    char *maybe_null;
    char **attributes;
    unsigned long *attribute_lengths;
    char *extension;
} UDF_ARGS;

typedef struct st_udf_init {
    my_bool maybe_null;
    unsigned int decimals;
    unsigned long max_length;
    char *ptr;
    my_bool const_item;
    void *extension;
} UDF_INIT;

#endif
