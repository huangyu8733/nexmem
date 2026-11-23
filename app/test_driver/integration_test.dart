// `flutter drive` 的标准 driver：把 integration_test 的结果回传给宿主。
import 'package:integration_test/integration_test_driver.dart';

Future<void> main() => integrationDriver();
