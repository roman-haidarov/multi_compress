#include "mcdb_format.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static unsigned char *read_all(const char *path, size_t *len) {
    FILE *f = fopen(path, "rb");
    if (!f) {
        perror("open");
        return NULL;
    }
    fseek(f, 0, SEEK_END);
    long sz = ftell(f);
    fseek(f, 0, SEEK_SET);
    unsigned char *buf = (unsigned char *)malloc(sz > 0 ? (size_t)sz : 1);
    size_t got = fread(buf, 1, (size_t)sz, f);
    fclose(f);
    *len = got;
    return buf;
}

int main(int argc, char **argv) {
    if (argc != 3) {
        fprintf(stderr, "usage: %s decode|valid <file.mcdb>\n", argv[0]);
        return 2;
    }

    size_t in_len = 0;
    unsigned char *in = read_all(argv[2], &in_len);
    if (!in)
        return 2;

    if (strcmp(argv[1], "valid") == 0) {
        uint64_t sz;
        mcdb_status st = mcdb_validate_header(in, in_len, &sz);
        unsigned char *out = NULL;
        size_t out_len = 0;
        char err[MCDB_ERRLEN];
        if (st == MCDB_OK)
            st = mcdb_decode(in, in_len, &out, &out_len, err);
        free(out);
        free(in);
        return st == MCDB_OK ? 0 : 1;
    }

    unsigned char *out = NULL;
    size_t out_len = 0;
    char err[MCDB_ERRLEN];
    mcdb_status st = mcdb_decode(in, in_len, &out, &out_len, err);
    if (st != MCDB_OK) {
        fprintf(stderr, "%s\n", err);
        free(in);
        return 1;
    }
    fwrite(out, 1, out_len, stdout);
    free(out);
    free(in);
    return 0;
}
