import 'dart:convert';

import 'package:dio/dio.dart';

/// Public update metadata; never ships an account token in the application.
class ReleaseMetadataClient {
  ReleaseMetadataClient(this._dio);
  final Dio _dio;
  DateTime? _apiRetryAt;
  static const apiUrl =
      'https://api.github.com/repos/vialoyed-ctrl/video_browser2/releases/latest';
  static const fallbackUrl =
      'https://raw.githubusercontent.com/vialoyed-ctrl/video_browser2/main/docs/releases/latest.json';

  Future<Map<String, dynamic>> fetchLatest() async {
    if (_apiRetryAt == null || !DateTime.now().isBefore(_apiRetryAt!)) {
      try {
        return await _read(apiUrl);
      } on DioException catch (error) {
        final code = error.response?.statusCode;
        if (code == 403 || code == 429) {
          final reset = int.tryParse(
            error.response?.headers.value('x-ratelimit-reset') ?? '',
          );
          final retry = int.tryParse(
            error.response?.headers.value('retry-after') ?? '',
          );
          final now = DateTime.now();
          final minimum = now.add(
            Duration(seconds: retry != null && retry > 60 ? retry : 60),
          );
          final resetAt = reset == null
              ? minimum
              : DateTime.fromMillisecondsSinceEpoch(reset * 1000);
          _apiRetryAt = resetAt.isAfter(minimum) ? resetAt : minimum;
        }
        // A bounded public-file request remains available when REST metadata
        // cannot be reached. Never repeatedly retry the exhausted API.
      }
    }
    return _read(fallbackUrl);
  }

  Future<Map<String, dynamic>> _read(String url) async {
    final response = await _dio.get<Object?>(
      url,
      options: Options(
        responseType: ResponseType.json,
        headers: const {'Accept': 'application/json'},
      ),
    );
    final data = response.data is String
        ? jsonDecode(response.data! as String)
        : response.data;
    if (data is! Map) throw const FormatException('Invalid release metadata');
    final release = Map<String, dynamic>.from(data);
    if (release['tag_name'] is! String || release['assets'] is! List) {
      throw const FormatException(
        'Release metadata is missing its version or assets',
      );
    }
    return release;
  }
}
