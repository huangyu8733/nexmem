import 'package:flutter/widgets.dart';
import 'package:webview_flutter/webview_flutter.dart';

bool get browserViewSupportedImpl => false;

Widget buildBrowserViewportImpl({
  Key? key,
  WebViewController? controller,
  required String url,
  required ValueChanged<String> onUrlChanged,
}) {
  return const SizedBox.shrink();
}
