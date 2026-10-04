#ifndef VB_MEDIA_REMUX_H
#define VB_MEDIA_REMUX_H
int vb_remux_ts_to_mp4(const char *input_path, const char *output_path);
int vb_remux_ts_to_mp4_with_error(const char *input_path, const char *output_path, char *error, int error_size);
#endif
