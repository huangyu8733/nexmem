// Web 等无原生平台：不提供屏幕几何。
import 'display_geometry.dart';

DisplayGeometryProvider createDisplayGeometryProvider() =>
    const EmptyDisplayGeometryProvider();
