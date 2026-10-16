// Copyright 2013 The Flutter Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

/// An error talking to GitHub that the tool couldn't recover from.
class GitHubException implements Exception {
  /// Creates an exception with [message] and, for HTTP errors, [statusCode].
  GitHubException(this.message, {this.statusCode});

  /// What went wrong.
  final String message;

  /// The HTTP status code, if GitHub returned an error response.
  final int? statusCode;

  @override
  String toString() => message;
}

/// A response from GitHub, either live or replayed from a recording.
class GitHubResponse {
  /// Creates a response.
  GitHubResponse({required this.statusCode, required this.body, this.link});

  factory GitHubResponse._fromJson(Map<String, dynamic> json) => GitHubResponse(
    statusCode: json['status']! as int,
    body: json['body']! as String,
    link: json['link'] as String?,
  );

  /// The HTTP status code.
  final int statusCode;

  /// The raw response body.
  final String body;

  /// The `Link` header, which GitHub uses for pagination.
  final String? link;

  /// Whether GitHub says there is another page of results.
  bool get hasNextPage => link?.contains('rel="next"') ?? false;

  /// The body, decoded as JSON.
  Object? get json => jsonDecode(body);

  Map<String, Object?> _toJson() => <String, Object?>{
    'status': statusCode,
    'link': link,
    'body': body,
  };
}

typedef _Recording = ({DateTime recordedAt, Map<String, GitHubResponse> responses});

/// A small GitHub REST client.
///
/// It reuses one connection for every request, retries transient failures,
/// and can save responses to a file and replay them later, so sorting and
/// rendering changes can be tried without calling GitHub again.
class GitHubClient {
  /// Creates a client that authenticates with [token], if it isn't empty.
  ///
  /// If [replayFile] is given, responses come from that recording (written by
  /// [writeRecording]) instead of the network, and [now] is the time the
  /// recording was made.
  GitHubClient({required String token, File? replayFile})
    : this._(token, replayFile == null ? null : _loadRecording(replayFile));

  GitHubClient._(this._token, _Recording? replay)
    : _replay = replay?.responses,
      _recordedAt = replay?.recordedAt;

  static const int _maxRetries = 2;

  final String _token;
  final Map<String, GitHubResponse>? _replay;
  final DateTime? _recordedAt;
  final http.Client _http = http.Client();
  final DateTime _startedAt = DateTime.now();
  final Map<String, GitHubResponse> _recorded = <String, GitHubResponse>{};

  /// The number of HTTP requests sent so far.
  int requestCount = 0;

  /// The remaining request budget GitHub last reported, if known.
  int? rateLimitRemaining;

  /// The time to treat as "now": when this client was created, or when the
  /// replayed recording was made.
  DateTime get now => _recordedAt ?? _startedAt;

  /// The number of responses [writeRecording] would save.
  int get recordedCount => _recorded.length;

  Map<String, String> get _headers => <String, String>{
    'Accept': 'application/vnd.github+json',
    'X-GitHub-Api-Version': '2022-11-28',
    if (_token.isNotEmpty) 'Authorization': 'Bearer $_token',
  };

  /// Fetches [url], retrying transient failures.
  ///
  /// Throws a [GitHubException] if the request fails or GitHub returns
  /// anything other than 200.
  Future<GitHubResponse> get(Uri url) async {
    final key = url.toString();
    final Map<String, GitHubResponse>? replay = _replay;
    if (replay != null) {
      final GitHubResponse? response = replay[key];
      if (response == null) {
        throw GitHubException('No recorded response for $url');
      }
      return _checked(url, response);
    }

    for (var attempt = 0; ; attempt++) {
      final http.Response response;
      try {
        requestCount++;
        response = await _http.get(url, headers: _headers).timeout(const Duration(seconds: 30));
      } on Exception catch (e) {
        if (attempt < _maxRetries) {
          await Future<void>.delayed(_backoff(attempt));
          continue;
        }
        throw GitHubException('GET $url failed: $e');
      }
      rateLimitRemaining =
          int.tryParse(response.headers['x-ratelimit-remaining'] ?? '') ?? rateLimitRemaining;
      final Duration? delay = attempt < _maxRetries ? _retryDelay(response, attempt) : null;
      if (delay != null) {
        await Future<void>.delayed(delay);
        continue;
      }
      final result = GitHubResponse(
        statusCode: response.statusCode,
        body: response.body,
        link: response.headers['link'],
      );
      _recorded[key] = result;
      return _checked(url, result);
    }
  }

  /// Writes every response received so far to [file], for use as a
  /// `replayFile`.
  void writeRecording(File file) {
    file
      ..createSync(recursive: true)
      ..writeAsStringSync(
        jsonEncode(<String, Object?>{
          'recordedAt': now.toUtc().toIso8601String(),
          'responses': <String, Object?>{
            for (final MapEntry<String, GitHubResponse> entry in _recorded.entries)
              entry.key: entry.value._toJson(),
          },
        }),
      );
  }

  /// Closes the underlying connection.
  void close() => _http.close();

  GitHubResponse _checked(Uri url, GitHubResponse response) {
    if (response.statusCode == 200) {
      return response;
    }
    var message = 'GET $url returned ${response.statusCode}';
    try {
      final Object? body = response.json;
      if (body is Map<String, dynamic> && body['message'] is String) {
        message += ': ${body['message']}';
      }
    } on FormatException {
      // Not JSON; the status code will have to do.
    }
    throw GitHubException(message, statusCode: response.statusCode);
  }

  Duration? _retryDelay(http.Response response, int attempt) {
    final int status = response.statusCode;
    if (status >= 500) {
      return _backoff(attempt);
    }
    if (status == 403 || status == 429) {
      final int? retryAfter = int.tryParse(response.headers['retry-after'] ?? '');
      if (retryAfter != null) {
        return retryAfter <= 60 ? Duration(seconds: retryAfter) : null;
      }
      // For secondary rate limits without a retry-after header, GitHub asks
      // clients to wait at least a minute. Primary limit exhaustion
      // (remaining == 0) can last up to an hour, so don't wait for that.
      if (response.headers['x-ratelimit-remaining'] != '0' &&
          response.body.contains('secondary rate limit')) {
        return const Duration(minutes: 1);
      }
    }
    return null;
  }

  static Duration _backoff(int attempt) => Duration(seconds: 1 << attempt);
}

_Recording _loadRecording(File file) {
  final recording = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
  final responses = recording['responses']! as Map<String, dynamic>;
  return (
    recordedAt: DateTime.parse(recording['recordedAt']! as String),
    responses: <String, GitHubResponse>{
      for (final MapEntry<String, dynamic> entry in responses.entries)
        entry.key: GitHubResponse._fromJson(entry.value as Map<String, dynamic>),
    },
  );
}
