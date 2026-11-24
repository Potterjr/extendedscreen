#ifndef RUNNER_VIDEO_DECODER_PLUGIN_H_
#define RUNNER_VIDEO_DECODER_PLUGIN_H_

#include <flutter/plugin_registrar_windows.h>

// The Windows client's video decoder: Media Foundation H.264/H.265 into a
// Flutter texture. It speaks the channel contract of Android's
// VideoDecoderPlugin.kt (and ios/Runner/VideoDecoderPlugin.swift):
// `extended_screen/video_decoder` (initialize, setRefreshRate, requestIdr,
// getDropCount, getMaxRefreshRate, dispose; onRequestIdr and onCodecError to
// Dart) and the BinaryCodec `extended_screen/nal_feed`, one Annex-B access
// unit per message.
void VideoDecoderPluginRegister(flutter::PluginRegistrarWindows* registrar);

#endif  // RUNNER_VIDEO_DECODER_PLUGIN_H_
