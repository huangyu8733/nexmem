// Web：没有可直接读取的本地文件路径。
import 'remote_file.dart';

class UnsupportedRemoteFileReader implements RemoteFileReader {
  const UnsupportedRemoteFileReader();

  @override
  int get chunkSize => 16 * 1024;

  @override
  Future<RemoteFileHandle> open(String path) async =>
      throw UnsupportedError('当前平台不支持读取本地文件路径');
}

RemoteFileReader createRemoteFileReader() => const UnsupportedRemoteFileReader();
