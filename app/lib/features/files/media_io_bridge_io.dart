import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:video_player/video_player.dart';

ImageProvider mediaImageProvider(String path) => FileImage(File(path));

bool mediaFileExists(String path) => File(path).existsSync();

VideoPlayerController mediaVideoController(String path) =>
    VideoPlayerController.file(File(path));

String mediaTempDir() => Directory.systemTemp.path;
