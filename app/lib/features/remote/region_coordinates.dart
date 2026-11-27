// 归属地 → 近似 GCJ-02 坐标。
//
// IP 库只能给出国家/省/市，不能给出设备精确位置；这里用省市中心点做地图标注，
// 且只在中国大陆与港澳台范围内提供坐标，避免把境外 IP 误标到国内。
// 坐标表随 App 一起分发，不把查询结果上传给任何服务。

({double? lat, double? lng}) lookupRegionCenter({
  required String country,
  required String province,
  required String city,
}) {
  if (country != '中国') {
    return (lat: null, lng: null);
  }
  final String p = _normalize(province);
  final String c = _normalize(city);
  final Map<String, ({double lat, double lng})> cities = _cityCenters;
  final ({double lat, double lng})? cityCenter = cities[c] ?? cities[p];
  if (cityCenter != null) {
    return (lat: cityCenter.lat, lng: cityCenter.lng);
  }
  final ({double lat, double lng})? provinceCenter = _provinceCenters[p];
  if (provinceCenter != null) {
    return (lat: provinceCenter.lat, lng: provinceCenter.lng);
  }
  return (lat: null, lng: null);
}

String _normalize(String value) {
  String s = value.trim();
  for (final String suffix in <String>[
    '维吾尔自治区',
    '壮族自治区',
    '回族自治区',
    '特别行政区',
    '自治区',
    '省',
    '市',
    '地区',
    '盟',
  ]) {
    if (s.endsWith(suffix) && s.length > suffix.length) {
      s = s.substring(0, s.length - suffix.length);
      break;
    }
  }
  return s;
}

const Map<String, ({double lat, double lng})> _provinceCenters =
    <String, ({double lat, double lng})>{
  '北京': (lat: 39.9042, lng: 116.4074),
  '上海': (lat: 31.2304, lng: 121.4737),
  '天津': (lat: 39.3434, lng: 117.3616),
  '重庆': (lat: 29.5630, lng: 106.5516),
  '河北': (lat: 38.0428, lng: 114.5149),
  '山西': (lat: 37.8706, lng: 112.5489),
  '辽宁': (lat: 41.8057, lng: 123.4315),
  '吉林': (lat: 43.8171, lng: 125.3235),
  '黑龙江': (lat: 45.8038, lng: 126.5349),
  '江苏': (lat: 32.0603, lng: 118.7969),
  '浙江': (lat: 30.2741, lng: 120.1551),
  '安徽': (lat: 31.8206, lng: 117.2272),
  '福建': (lat: 26.0745, lng: 119.2965),
  '江西': (lat: 28.6829, lng: 115.8582),
  '山东': (lat: 36.6512, lng: 117.1201),
  '河南': (lat: 34.7466, lng: 113.6254),
  '湖北': (lat: 30.5928, lng: 114.3055),
  '湖南': (lat: 28.2282, lng: 112.9388),
  '广东': (lat: 23.1291, lng: 113.2644),
  '广西': (lat: 22.8170, lng: 108.3665),
  '海南': (lat: 20.0442, lng: 110.1999),
  '四川': (lat: 30.5728, lng: 104.0668),
  '贵州': (lat: 26.6470, lng: 106.6302),
  '云南': (lat: 25.0389, lng: 102.7183),
  '西藏': (lat: 29.6520, lng: 91.1721),
  '陕西': (lat: 34.3416, lng: 108.9398),
  '甘肃': (lat: 36.0611, lng: 103.8343),
  '青海': (lat: 36.6171, lng: 101.7782),
  '宁夏': (lat: 38.4872, lng: 106.2309),
  '新疆': (lat: 43.8256, lng: 87.6168),
  '内蒙古': (lat: 40.8426, lng: 111.7492),
  '香港': (lat: 22.3193, lng: 114.1694),
  '澳门': (lat: 22.1987, lng: 113.5439),
  '台湾': (lat: 25.0330, lng: 121.5654),
};

const Map<String, ({double lat, double lng})> _cityCenters =
    <String, ({double lat, double lng})>{
  '深圳': (lat: 22.5431, lng: 114.0579),
  '广州': (lat: 23.1291, lng: 113.2644),
  '东莞': (lat: 23.0207, lng: 113.7518),
  '佛山': (lat: 23.0218, lng: 113.1214),
  '珠海': (lat: 22.2710, lng: 113.5767),
  '汕头': (lat: 23.3541, lng: 116.6817),
  '上海': (lat: 31.2304, lng: 121.4737),
  '杭州': (lat: 30.2741, lng: 120.1551),
  '宁波': (lat: 29.8683, lng: 121.5440),
  '温州': (lat: 27.9948, lng: 120.6994),
  '南京': (lat: 32.0603, lng: 118.7969),
  '苏州': (lat: 31.2989, lng: 120.5853),
  '无锡': (lat: 31.4912, lng: 120.3119),
  '北京': (lat: 39.9042, lng: 116.4074),
  '天津': (lat: 39.3434, lng: 117.3616),
  '石家庄': (lat: 38.0428, lng: 114.5149),
  '太原': (lat: 37.8706, lng: 112.5489),
  '呼和浩特': (lat: 40.8426, lng: 111.7492),
  '沈阳': (lat: 41.8057, lng: 123.4315),
  '大连': (lat: 38.9140, lng: 121.6147),
  '长春': (lat: 43.8171, lng: 125.3235),
  '哈尔滨': (lat: 45.8038, lng: 126.5349),
  '济南': (lat: 36.6512, lng: 117.1201),
  '青岛': (lat: 36.0671, lng: 120.3826),
  '郑州': (lat: 34.7466, lng: 113.6254),
  '武汉': (lat: 30.5928, lng: 114.3055),
  '长沙': (lat: 28.2282, lng: 112.9388),
  '合肥': (lat: 31.8206, lng: 117.2272),
  '福州': (lat: 26.0745, lng: 119.2965),
  '厦门': (lat: 24.4798, lng: 118.0894),
  '泉州': (lat: 24.8741, lng: 118.6757),
  '南昌': (lat: 28.6829, lng: 115.8582),
  '重庆': (lat: 29.5630, lng: 106.5516),
  '成都': (lat: 30.5728, lng: 104.0668),
  '贵阳': (lat: 26.6470, lng: 106.6302),
  '昆明': (lat: 25.0389, lng: 102.7183),
  '拉萨': (lat: 29.6520, lng: 91.1721),
  '西安': (lat: 34.3416, lng: 108.9398),
  '兰州': (lat: 36.0611, lng: 103.8343),
  '西宁': (lat: 36.6171, lng: 101.7782),
  '银川': (lat: 38.4872, lng: 106.2309),
  '乌鲁木齐': (lat: 43.8256, lng: 87.6168),
  '南宁': (lat: 22.8170, lng: 108.3665),
  '海口': (lat: 20.0442, lng: 110.1999),
  '香港': (lat: 22.3193, lng: 114.1694),
  '澳门': (lat: 22.1987, lng: 113.5439),
  '台北': (lat: 25.0330, lng: 121.5654),
};
