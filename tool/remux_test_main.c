#include "VBMediaRemux.h"
#include <stdio.h>
int main(int argc, char **argv) {
    if (argc != 3) return 2;
    char error[512];
    int result = vb_remux_ts_to_mp4_with_error(argv[1], argv[2], error, sizeof(error));
    if (result) fprintf(stderr, "%s\n", error);
    return result ? 1 : 0;
}
