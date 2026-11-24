// Web 端没有本机文件路径：预览入口不会走到这里，仅提供编译期实现。
import 'package:flutter/widgets.dart';
import 'package:video_player/video_player.dart';

ImageProvider mediaImageProvider(String path) =>
    throw UnsupportedError('Web 不支持本机文件预览');

VideoPlayerController mediaVideoController(String path) =>
    throw UnsupportedError('Web 不支持本机视频预览');

String mediaTempDir() => throw UnsupportedError('Web 不支持 ffmpeg 转码');
