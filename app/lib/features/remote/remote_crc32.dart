// CRC32（IEEE 802.3）增量计算，用于文件分片完整性校验。
class Crc32 {
  Crc32() : _value = 0xFFFFFFFF;

  static final List<int> _table = _buildTable();

  int _value;

  void add(List<int> data) {
    int crc = _value;
    for (final int byte in data) {
      crc = _table[(crc ^ byte) & 0xFF] ^ (crc >> 8);
    }
    _value = crc;
  }

  int get value => (_value ^ 0xFFFFFFFF) & 0xFFFFFFFF;

  static List<int> _buildTable() {
    final List<int> table = List<int>.filled(256, 0);
    for (int i = 0; i < 256; i++) {
      int crc = i;
      for (int bit = 0; bit < 8; bit++) {
        crc = crc & 1 != 0 ? 0xEDB88320 ^ (crc >> 1) : crc >> 1;
      }
      table[i] = crc & 0xFFFFFFFF;
    }
    return table;
  }
}
