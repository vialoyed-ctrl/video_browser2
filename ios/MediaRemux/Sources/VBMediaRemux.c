#include "VBMediaRemux.h"
#include <libavformat/avformat.h>
#include <libavutil/mathematics.h>
#include <libavutil/mem.h>
#include <stdio.h>
#include <stdlib.h>

int vb_remux_ts_to_mp4(const char *input_path, const char *output_path) {
    AVFormatContext *input = NULL, *output = NULL;
    AVPacket *packet = NULL;
    int *mapping = NULL;
    int status = -1, header_written = 0;
    if (avformat_open_input(&input, input_path, NULL, NULL) < 0) goto cleanup;
    if (avformat_find_stream_info(input, NULL) < 0) goto cleanup;
    if (avformat_alloc_output_context2(&output, NULL, "mp4", output_path) < 0) goto cleanup;
    mapping = av_malloc_array(input->nb_streams, sizeof(*mapping));
    if (!mapping) goto cleanup;
    for (unsigned i = 0; i < input->nb_streams; ++i) {
        AVStream *source = input->streams[i];
        mapping[i] = -1;
        if (source->codecpar->codec_type != AVMEDIA_TYPE_VIDEO &&
            source->codecpar->codec_type != AVMEDIA_TYPE_AUDIO) continue;
        AVStream *target = avformat_new_stream(output, NULL);
        if (!target || avcodec_parameters_copy(target->codecpar, source->codecpar) < 0) goto cleanup;
        mapping[i] = target->index;
        target->codecpar->codec_tag = 0;
        target->time_base = source->time_base;
    }
    if (output->nb_streams == 0) goto cleanup;
    if (avio_open(&output->pb, output_path, AVIO_FLAG_WRITE) < 0) goto cleanup;
    AVDictionary *options = NULL;
    av_dict_set(&options, "movflags", "+faststart", 0);
    int result = avformat_write_header(output, &options);
    av_dict_free(&options);
    if (result < 0) goto cleanup;
    header_written = 1;
    packet = av_packet_alloc();
    if (!packet) goto cleanup;
    while ((result = av_read_frame(input, packet)) >= 0) {
        int original = packet->stream_index;
        if (mapping[original] < 0) { av_packet_unref(packet); continue; }
        packet->stream_index = mapping[original];
        av_packet_rescale_ts(packet, input->streams[original]->time_base,
                            output->streams[packet->stream_index]->time_base);
        packet->pos = -1;
        if (av_interleaved_write_frame(output, packet) < 0) goto cleanup;
        av_packet_unref(packet);
    }
    if (result != AVERROR_EOF) goto cleanup;
    if (av_write_trailer(output) < 0) goto cleanup;
    header_written = 0;
    status = 0;
cleanup:
    if (header_written) av_write_trailer(output);
    av_packet_free(&packet);
    av_free(mapping);
    avformat_close_input(&input);
    if (output) {
        if (output->pb) avio_closep(&output->pb);
        avformat_free_context(output);
    }
    if (status != 0) remove(output_path);
    return status;
}
