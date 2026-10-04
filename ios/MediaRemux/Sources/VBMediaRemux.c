#include "VBMediaRemux.h"
#include <libavformat/avformat.h>
#include <libavutil/mathematics.h>
#include <libavutil/mem.h>
#include <libavutil/error.h>
#include <stdio.h>
#include <stdlib.h>

int vb_remux_ts_to_mp4_with_error(const char *input_path, const char *output_path, char *error, int error_size) {
    AVFormatContext *input = NULL, *output = NULL;
    AVPacket *packet = NULL;
    int *mapping = NULL;
    int64_t *last_dts = NULL, *offset = NULL, *step = NULL;
    int status = -1, header_written = 0, result = 0;
    const char *stage = "open input";
    if (error && error_size > 0) error[0] = 0;
    if ((result = avformat_open_input(&input, input_path, NULL, NULL)) < 0) goto cleanup;
    stage = "read stream parameters";
    if ((result = avformat_find_stream_info(input, NULL)) < 0) goto cleanup;
    stage = "create MP4";
    if ((result = avformat_alloc_output_context2(&output, NULL, "mp4", output_path)) < 0) goto cleanup;
    mapping = av_malloc_array(input->nb_streams, sizeof(*mapping));
    last_dts = av_malloc_array(input->nb_streams, sizeof(*last_dts));
    offset = av_calloc(input->nb_streams, sizeof(*offset));
    step = av_calloc(input->nb_streams, sizeof(*step));
    if (!mapping || !last_dts || !offset || !step) { result = AVERROR(ENOMEM); goto cleanup; }
    for (unsigned i = 0; i < input->nb_streams; ++i) last_dts[i] = AV_NOPTS_VALUE;
    for (unsigned i = 0; i < input->nb_streams; ++i) {
        AVStream *source = input->streams[i];
        mapping[i] = -1;
        if (source->codecpar->codec_type != AVMEDIA_TYPE_VIDEO &&
            source->codecpar->codec_type != AVMEDIA_TYPE_AUDIO) continue;
        AVStream *target = avformat_new_stream(output, NULL);
        if (!target || avcodec_parameters_copy(target->codecpar, source->codecpar) < 0) goto cleanup;
        mapping[i] = target->index;
        target->codecpar->codec_tag = 0;
        if (source->codecpar->codec_id == AV_CODEC_ID_HEVC)
            target->codecpar->codec_tag = (unsigned)'h' | ((unsigned)'v' << 8) | ((unsigned)'c' << 16) | ((unsigned)'1' << 24);
        target->time_base = source->time_base;
    }
    if (output->nb_streams == 0) { result = AVERROR_INVALIDDATA; goto cleanup; }
    stage = "open output";
    if ((result = avio_open(&output->pb, output_path, AVIO_FLAG_WRITE)) < 0) goto cleanup;
    AVDictionary *options = NULL;
    av_dict_set(&options, "movflags", "+faststart", 0);
    stage = "write MP4 header";
    result = avformat_write_header(output, &options);
    av_dict_free(&options);
    if (result < 0) goto cleanup;
    header_written = 1;
    packet = av_packet_alloc();
    if (!packet) goto cleanup;
    stage = "write media packets";
    while ((result = av_read_frame(input, packet)) >= 0) {
        int original = packet->stream_index;
        if (mapping[original] < 0) { av_packet_unref(packet); continue; }
        packet->stream_index = mapping[original];
        av_packet_rescale_ts(packet, input->streams[original]->time_base,
                            output->streams[packet->stream_index]->time_base);
        // Concatenated HLS segments may restart their clocks. MP4 requires
        // strictly increasing DTS; retain each packet's PTS-DTS relationship.
        if (packet->dts == AV_NOPTS_VALUE && packet->pts != AV_NOPTS_VALUE)
            packet->dts = packet->pts;
        int64_t duration = packet->duration;
        if (duration <= 0 && step[original] > 0) duration = step[original];
        if (duration <= 0 && input->streams[original]->codecpar->codec_type == AVMEDIA_TYPE_VIDEO) {
            AVRational rate = av_guess_frame_rate(input, input->streams[original], NULL);
            if (rate.num > 0 && rate.den > 0)
                duration = av_rescale_q(1, av_inv_q(rate), output->streams[packet->stream_index]->time_base);
        }
        if (duration <= 0) duration = 1;
        if (packet->dts == AV_NOPTS_VALUE) {
            packet->dts = last_dts[original] == AV_NOPTS_VALUE ? 0 : last_dts[original] + duration;
            if (packet->pts == AV_NOPTS_VALUE) packet->pts = packet->dts;
        } else {
            packet->dts += offset[original];
            if (packet->pts != AV_NOPTS_VALUE) packet->pts += offset[original];
            if (last_dts[original] != AV_NOPTS_VALUE && packet->dts <= last_dts[original]) {
                int64_t adjustment = last_dts[original] + duration - packet->dts;
                offset[original] += adjustment;
                packet->dts += adjustment;
                if (packet->pts != AV_NOPTS_VALUE) packet->pts += adjustment;
            }
        }
        if (packet->pts == AV_NOPTS_VALUE) packet->pts = packet->dts;
        last_dts[original] = packet->dts;
        step[original] = duration;
        packet->pos = -1;
        if ((result = av_interleaved_write_frame(output, packet)) < 0) goto cleanup;
        av_packet_unref(packet);
    }
    if (result != AVERROR_EOF) goto cleanup;
    stage = "finalize MP4";
    if ((result = av_write_trailer(output)) < 0) goto cleanup;
    header_written = 0;
    status = 0;
cleanup:
    if (status != 0 && error && error_size > 0) {
        char detail[AV_ERROR_MAX_STRING_SIZE];
        av_strerror(result < 0 ? result : AVERROR_UNKNOWN, detail, sizeof(detail));
        snprintf(error, error_size, "%s: %s", stage, detail);
    }
    if (header_written) av_write_trailer(output);
    av_packet_free(&packet);
    av_free(mapping);
    av_free(last_dts);
    av_free(offset);
    av_free(step);
    avformat_close_input(&input);
    if (output) {
        if (output->pb) avio_closep(&output->pb);
        avformat_free_context(output);
    }
    if (status != 0) remove(output_path);
    return status;
}

int vb_remux_ts_to_mp4(const char *input_path, const char *output_path) {
    return vb_remux_ts_to_mp4_with_error(input_path, output_path, NULL, 0);
}
