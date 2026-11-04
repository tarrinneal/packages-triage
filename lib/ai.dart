// Copyright 2013 The Flutter Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import 'detail_cache.dart' show cacheDirectory;
import 'github_client.dart';
import 'pr_inspector.dart' show isBot, isTeamMember;
import 'triage.dart';
import 'types.dart';
import 'utils.dart';

/// The environment variable (or `.env` entry) that holds the Gemini API key.
const String geminiApiKeyVariable = 'GEMINI_API_KEY';

/// A fallback for [geminiApiKeyVariable] that Google's Gen AI SDKs also read.
const String googleApiKeyVariable = 'GOOGLE_API_KEY';

/// The environment variable (or `.env` entry) that overrides [defaultAiModel].
const String geminiModelVariable = 'GEMINI_MODEL';

/// The Gemini model used for AI suggestions unless [geminiModelVariable] is
/// set.
const String defaultAiModel = 'gemini-3.5-flash-lite';

/// The version of the AI prompts.
///
/// Bump this whenever [aiSystemInstruction], [buildPRPrompt], or
/// [buildIssuePrompt] change meaningfully, so that cached suggestions are
/// regenerated.
const int aiPromptVersion = 1;

/// The longest AI suggestion that is shown; longer ones are truncated.
const int maxAiSuggestionLength = 400;

/// An error from the Gemini API.
class GeminiException implements Exception {
  /// Creates an exception with [message] and, for HTTP errors, [statusCode].
  GeminiException(this.message, {this.statusCode, this.isFatal = false});

  /// What went wrong.
  final String message;

  /// The HTTP status code, if Gemini returned an error response.
  final int? statusCode;

  /// Whether every later request would fail the same way, as with an invalid
  /// API key, an unknown model, or an exhausted quota.
  final bool isFatal;

  @override
  String toString() => message;
}

/// A minimal client for the Gemini API's `generateContent` endpoint.
class GeminiClient {
  /// Creates a client that authenticates with [apiKey] and generates text
  /// with [model].
  ///
  /// [httpClient] and [sleep] can be replaced in tests.
  GeminiClient({
    required String apiKey,
    String model = defaultAiModel,
    http.Client? httpClient,
    Future<void> Function(Duration delay)? sleep,
  }) : model = model.replaceFirst(RegExp(r'^models/'), ''),
       _apiKey = apiKey,
       _http = httpClient ?? http.Client(),
       _sleep = sleep ?? Future<void>.delayed;

  static const int _maxRetries = 3;
  static const Duration _maxRetryDelay = Duration(seconds: 90);
  static const Duration _timeout = Duration(seconds: 90);

  /// The model that generates text, such as `gemini-3.5-flash-lite`.
  final String model;

  final String _apiKey;
  final http.Client _http;
  final Future<void> Function(Duration delay) _sleep;

  /// The number of HTTP requests sent so far.
  int requestCount = 0;

  /// Generates a reply to [prompt] that follows [systemInstruction].
  ///
  /// Retries rate-limited and transient failures. Throws a [GeminiException]
  /// if no text could be generated.
  Future<String> generateText({
    required String systemInstruction,
    required String prompt,
    int maxOutputTokens = 1024,
  }) async {
    final url = Uri.https(
      'generativelanguage.googleapis.com',
      '/v1beta/models/$model:generateContent',
    );
    final String body = jsonEncode(<String, Object?>{
      'systemInstruction': <String, Object?>{
        'parts': <Object?>[
          <String, Object?>{'text': systemInstruction},
        ],
      },
      'contents': <Object?>[
        <String, Object?>{
          'role': 'user',
          'parts': <Object?>[
            <String, Object?>{'text': prompt},
          ],
        },
      ],
      'generationConfig': <String, Object?>{
        'maxOutputTokens': maxOutputTokens,
        // A little reasoning helps weigh the conversation; more only adds
        // latency and cost for a one- or two-sentence answer.
        if (_supportsThinkingLevel(model))
          'thinkingConfig': <String, Object?>{'thinkingLevel': 'LOW'},
      },
    });
    for (var attempt = 0; ; attempt++) {
      final http.Response response;
      try {
        requestCount++;
        response = await _http
            .post(
              url,
              headers: <String, String>{
                'Content-Type': 'application/json',
                'x-goog-api-key': _apiKey,
              },
              body: body,
            )
            .timeout(_timeout);
      } on Exception catch (e) {
        if (attempt < _maxRetries) {
          await _sleep(_backoff(attempt));
          continue;
        }
        throw GeminiException('Gemini request failed: $e');
      }
      if (response.statusCode == 200) {
        return _textFrom(response.body);
      }
      final error = _GeminiError.parse(response);
      final int status = response.statusCode;
      if ((status == 429 || status >= 500) && !error.isDailyQuota && attempt < _maxRetries) {
        final Duration delay = error.retryDelay ?? _backoff(attempt);
        if (delay <= _maxRetryDelay) {
          await _sleep(delay);
          continue;
        }
      }
      throw GeminiException(
        'Gemini ($model) returned $status: ${error.message}',
        statusCode: status,
        isFatal: const <int>{400, 401, 403, 404, 429}.contains(status),
      );
    }
  }

  /// Closes the underlying connection.
  void close() => _http.close();

  static Duration _backoff(int attempt) => Duration(seconds: 2 << attempt);
}

/// Whether [model] accepts a `thinkingLevel`, which only Gemini 3 and later
/// models do.
bool _supportsThinkingLevel(String model) {
  final RegExpMatch? match = RegExp(r'^gemini-(\d+)').firstMatch(model);
  return match != null && int.parse(match.group(1)!) >= 3;
}

bool _isThought(Object? part) => switch (part) {
  {'thought': true} => true,
  _ => false,
};

/// The text of the first candidate in a `generateContent` response.
String _textFrom(String responseBody) {
  final Object? json;
  try {
    json = jsonDecode(responseBody);
  } on FormatException {
    throw GeminiException('Gemini returned a response that is not JSON');
  }
  if (json case {'candidates': [final Object? candidate, ...]}) {
    final texts = <String>[
      if (candidate case {'content': {'parts': final List<Object?> parts}})
        for (final Object? part in parts)
          if (part case {'text': final String text} when !_isThought(part)) text,
    ];
    final String text = texts.join().trim();
    if (text.isNotEmpty) {
      return text;
    }
    final Object? finishReason = switch (candidate) {
      {'finishReason': final Object? reason} => reason,
      _ => null,
    };
    throw GeminiException('Gemini returned no text (finish reason: ${finishReason ?? 'unknown'})');
  }
  final Object? blockReason = switch (json) {
    {'promptFeedback': {'blockReason': final Object? reason}} => reason,
    _ => null,
  };
  throw GeminiException(
    blockReason == null
        ? 'Gemini returned no candidates'
        : 'Gemini blocked the prompt ($blockReason)',
  );
}

/// The useful parts of a Gemini error response.
class _GeminiError {
  _GeminiError(this.message, {this.retryDelay, this.isDailyQuota = false});

  factory _GeminiError.parse(http.Response response) {
    final int? retryAfter = int.tryParse(response.headers['retry-after'] ?? '');
    Duration? retryDelay = retryAfter == null ? null : Duration(seconds: retryAfter);
    String message = response.reasonPhrase ?? 'no details';
    var isDailyQuota = false;
    try {
      final Object? json = jsonDecode(response.body);
      if (json case {'error': final Map<String, Object?> error}) {
        if (error['message'] case final String text when text.isNotEmpty) {
          message = text;
        }
        if (error['details'] case final List<Object?> details) {
          for (final detail in details) {
            if (detail case {'retryDelay': final String delay}) {
              retryDelay ??= _parseSeconds(delay);
            }
            if (detail case {'violations': final List<Object?> violations}) {
              for (final violation in violations) {
                if (violation case {
                  'quotaId': final String quotaId,
                } when quotaId.contains('PerDay')) {
                  isDailyQuota = true;
                }
              }
            }
          }
        }
      }
    } on FormatException {
      // Not JSON; the status code will have to do.
    }
    return _GeminiError(message, retryDelay: retryDelay, isDailyQuota: isDailyQuota);
  }

  /// The error message.
  final String message;

  /// How long Gemini asked the caller to wait before retrying, if it said.
  final Duration? retryDelay;

  /// Whether a daily quota ran out, so retrying today is pointless.
  final bool isDailyQuota;

  /// Parses a protobuf duration such as `"37s"` or `"1.5s"`.
  static Duration? _parseSeconds(String value) {
    final double? seconds = double.tryParse(value.replaceFirst(RegExp(r's$'), ''));
    return seconds == null ? null : Duration(milliseconds: (seconds * 1000).round());
  }
}

/// Bump this when the saved format changes, so old caches are ignored.
const int _aiCacheFormatVersion = 1;

/// The file in [directory] (by default, [cacheDirectory]) that holds the
/// [AiSuggestionCache] for config [configName].
File aiSuggestionCacheFileFor(String configName, {Directory? directory}) => File(
  '${(directory ?? cacheDirectory()).path}${Platform.pathSeparator}'
  'ai_${configName.replaceAll(RegExp(r'[^\w.-]'), '_')}.json',
);

/// AI suggestions saved between runs, keyed by the URL of their PR or issue.
///
/// A suggestion is only reused while its item's `updated_at`, the model, and
/// [aiPromptVersion] all match the ones it was generated with, so each item
/// is only sent to the model again after it changes. Suggestions for items
/// that haven't been seen open for [maxUnseen] are removed.
class AiSuggestionCache {
  AiSuggestionCache._(this.file, this.now, this._entries) {
    _removeUnseen();
  }

  /// Loads the cache from [file], as of [now].
  ///
  /// If [file] can't be read, calls [onWarning] and starts empty.
  factory AiSuggestionCache.load(
    File file, {
    required DateTime now,
    void Function(String message)? onWarning,
  }) {
    final entries = <String, _AiEntry>{};
    try {
      final Object? json = jsonDecode(file.readAsStringSync());
      if (json case {
        'version': _aiCacheFormatVersion,
        'suggestions': final Map<String, Object?> suggestions,
      }) {
        for (final MapEntry<String, Object?> suggestion in suggestions.entries) {
          final _AiEntry? entry = _AiEntry.fromJson(suggestion.value);
          if (entry != null) {
            entries[suggestion.key] = entry;
          }
        }
      }
    } on PathNotFoundException {
      // Nothing has been saved yet.
    } on FileSystemException catch (e) {
      onWarning?.call('Could not read the AI suggestions ${file.path}: ${e.message}');
    } on FormatException catch (e) {
      onWarning?.call('Ignoring the unreadable AI suggestions ${file.path}: ${e.message}');
    }
    return AiSuggestionCache._(file, now, entries);
  }

  /// How long a suggestion is kept after its item was last seen open.
  static const Duration maxUnseen = Duration(days: 30);

  /// Where the cache is saved.
  final File file;

  /// The time of this run, which is when items are seen and suggestions saved.
  final DateTime now;

  final Map<String, _AiEntry> _entries;

  /// The number of saved suggestions.
  int get length => _entries.length;

  /// Returns the suggestion saved for [key], if it was generated by [model]
  /// with the current [aiPromptVersion] when the item's `updated_at` was
  /// [updatedAt].
  String? lookup(String key, {required String updatedAt, required String model}) {
    final _AiEntry? entry = _entries[key];
    if (entry == null ||
        entry.updatedAt != updatedAt ||
        entry.model != model ||
        entry.promptVersion != aiPromptVersion) {
      return null;
    }
    return entry.text;
  }

  /// Saves [text] as the suggestion for [key] as of the item's `updated_at`
  /// of [updatedAt].
  void store(String key, {required String updatedAt, required String model, required String text}) {
    _entries[key] = _AiEntry(
      updatedAt: updatedAt,
      model: model,
      promptVersion: aiPromptVersion,
      text: text,
      generatedAt: now,
      lastSeen: now,
    );
  }

  /// Records that the items with [keys] are still open, which keeps their
  /// suggestions for another [maxUnseen].
  void markSeen(Iterable<String> keys) {
    for (final key in keys) {
      _entries[key]?.lastSeen = now;
    }
  }

  /// Writes the cache to [file], leaving out suggestions that haven't been
  /// seen for [maxUnseen].
  void save() {
    _removeUnseen();
    file.parent.createSync(recursive: true);
    // Write to a temporary file first so an interrupted run can't leave a
    // truncated cache behind.
    final temp = File('${file.path}.tmp')
      ..writeAsStringSync(
        const JsonEncoder.withIndent('  ').convert(<String, Object?>{
          'version': _aiCacheFormatVersion,
          'suggestions': <String, Object?>{
            for (final MapEntry<String, _AiEntry> entry in _entries.entries)
              entry.key: entry.value.toJson(),
          },
        }),
      );
    temp.renameSync(file.path);
  }

  void _removeUnseen() {
    _entries.removeWhere((String _, _AiEntry entry) => now.difference(entry.lastSeen) >= maxUnseen);
  }
}

class _AiEntry {
  _AiEntry({
    required this.updatedAt,
    required this.model,
    required this.promptVersion,
    required this.text,
    required this.generatedAt,
    required this.lastSeen,
  });

  static _AiEntry? fromJson(Object? json) {
    if (json case {
      'updatedAt': final String updatedAt,
      'model': final String model,
      'promptVersion': final int promptVersion,
      'text': final String text,
      'generatedAt': final String generatedAt,
      'lastSeen': final String lastSeen,
    }) {
      final DateTime? generated = DateTime.tryParse(generatedAt);
      final DateTime? seen = DateTime.tryParse(lastSeen);
      if (generated != null && seen != null) {
        return _AiEntry(
          updatedAt: updatedAt,
          model: model,
          promptVersion: promptVersion,
          text: text,
          generatedAt: generated,
          lastSeen: seen,
        );
      }
    }
    return null;
  }

  final String updatedAt;
  final String model;
  final int promptVersion;
  final String text;
  final DateTime generatedAt;
  DateTime lastSeen;

  Map<String, Object?> toJson() => <String, Object?>{
    'updatedAt': updatedAt,
    'model': model,
    'promptVersion': promptVersion,
    'text': text,
    'generatedAt': generatedAt.toUtc().toIso8601String(),
    'lastSeen': lastSeen.toUtc().toIso8601String(),
  };
}

/// A comment or review on a PR or issue, used as context for an AI
/// suggestion.
///
/// [role] is `author`, `team`, or `community`, and [kind] says what was left:
/// `comment`, `review`, `approved`, or `requested changes`.
typedef ConversationEntry = ({String login, String role, String kind, DateTime date, String text});

/// Fetches the newest [maxEntries] conversation comments (and, if
/// [isPullRequest], reviews) on item [number] in [repo], oldest first,
/// leaving out bots.
///
/// [author] is the item's author, and [roster] identifies team members (see
/// [isTeamMember]).
Future<List<ConversationEntry>> fetchConversation(
  GitHubClient client,
  String repo,
  int number, {
  required String author,
  required bool isPullRequest,
  Set<String> roster = const <String>{},
  TriageConfig config = const TriageConfig(),
  int maxEntries = 8,
}) async {
  final entries = <ConversationEntry>[];

  Future<void> collect(String path, String dateKey) async {
    for (var page = 1; ; page++) {
      final GitHubResponse response = await client.get(
        Uri.https('api.github.com', path, <String, String>{'per_page': '100', 'page': '$page'}),
      );
      final List<Map<String, dynamic>> items = (response.json! as List<dynamic>)
          .cast<Map<String, dynamic>>();
      for (final item in items) {
        final user = item['user'] as Map<String, dynamic>?;
        final dateString = item[dateKey] as String?;
        final state = item['state'] as String?;
        // Skip deleted users, unsubmitted (PENDING) reviews, and dismissed
        // reviews, which no longer say anything about the PR.
        if (user == null || dateString == null || state == 'PENDING' || state == 'DISMISSED') {
          continue;
        }
        final login = user['login']! as String;
        if (isBot(login, userType: user['type'] as String?, config: config)) {
          continue;
        }
        final String kind = switch (state) {
          'APPROVED' => 'approved',
          'CHANGES_REQUESTED' => 'requested changes',
          'COMMENTED' => 'review',
          _ => 'comment',
        };
        final String text = _oneLine(item['body'] as String? ?? '', maxLength: 500);
        // Approvals and change requests say something even without text.
        if (text.isEmpty && (kind == 'comment' || kind == 'review')) {
          continue;
        }
        final role = login == author
            ? 'author'
            : isTeamMember(login, item['author_association'] as String?, roster)
            ? 'team'
            : 'community';
        entries.add((
          login: login,
          role: role,
          kind: kind,
          date: DateTime.parse(dateString),
          text: text,
        ));
      }
      if (items.isEmpty || !response.hasNextPage) {
        return;
      }
    }
  }

  await collect('/repos/$repo/issues/$number/comments', 'created_at');
  if (isPullRequest) {
    await collect('/repos/$repo/pulls/$number/reviews', 'submitted_at');
  }
  entries.sort((ConversationEntry a, ConversationEntry b) => a.date.compareTo(b.date));
  return entries.length > maxEntries ? entries.sublist(entries.length - maxEntries) : entries;
}

/// Truncates [text] to at most [maxLength] characters, ending with `…` if
/// anything was cut.
String _truncate(String text, int maxLength) {
  if (text.length <= maxLength) {
    return text;
  }
  int end = maxLength - 1;
  // Don't split a surrogate pair, such as an emoji.
  final int last = text.codeUnitAt(end - 1);
  if (last >= 0xD800 && last <= 0xDBFF) {
    end--;
  }
  return '${text.substring(0, end).trimRight()}…';
}

/// [text] as a single line, without HTML comments or quoted replies, and
/// truncated to [maxLength] characters.
String _oneLine(String text, {required int maxLength}) {
  final String cleaned = text
      .replaceAll(RegExp(r'<!--[\s\S]*?-->'), ' ')
      .split('\n')
      .where((String line) => !line.trimLeft().startsWith('>'))
      .join(' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  return _truncate(cleaned, maxLength);
}

/// The part of a PR or issue description worth sending to the model:
/// without HTML comments or the Flutter PR template's checklist, and
/// truncated to [maxLength] characters.
String descriptionExcerpt(String body, {int maxLength = 1500}) {
  String text = body.replaceAll('\r\n', '\n').replaceAll(RegExp(r'<!--[\s\S]*?-->'), '');
  final RegExpMatch? checklist = RegExp(
    r'^#+\s*Pre-(?:launch|Review) Checklist',
    multiLine: true,
    caseSensitive: false,
  ).firstMatch(text);
  if (checklist != null) {
    text = text.substring(0, checklist.start);
  }
  text = text.replaceAll(RegExp(r'[ \t]+'), ' ').replaceAll(RegExp(r'\n\s*\n+'), '\n\n').trim();
  return _truncate(text, maxLength);
}

/// Tidies a suggestion from the model into a single line of plain text.
String cleanAiText(String text) {
  String result = text
      .replaceAll('**', '')
      .replaceAll('`', '')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim()
      .replaceFirst(RegExp(r'^[-*•]\s+'), '')
      .replaceFirst(RegExp(r'^(?:suggested\s+)?next\s+steps?\s*:\s*', caseSensitive: false), '');
  if (result.length >= 2 && result.startsWith('"') && result.endsWith('"')) {
    result = result.substring(1, result.length - 1).trim();
  }
  return _truncate(result, maxAiSuggestionLength);
}

/// The system instruction for AI next-step suggestions for [config].
String aiSystemInstruction(TriageConfig config) {
  final team = config.flutterTeam == null
      ? 'the maintainers'
      : 'the Flutter ${config.flutterTeam} team';
  final String? issuesRepo = config.issuesRepo;
  final issues = issuesRepo == null || config.repos.contains(issuesRepo)
      ? ''
      : ', whose issues are tracked in $issuesRepo';
  return '''
You help $team triage open GitHub pull requests and issues in ${config.repos.join(', ')}$issues.
Given details about one pull request or issue, reply with the single most useful next step for the team, in one or two short sentences (at most 40 words).
- Say who should act and what they should do, using @handles from the details when that helps.
- Base it on the description, labels, reviews, and recent conversation. The triage tool's heuristic next step is only a hint, and may be generic or wrong.
- Typical next steps: find or ping a reviewer, ask the author for changes or information, re-request review, land an approved PR, set a priority or triage label, or close a stale, duplicate, or abandoned item.
- If the team doesn't need to do anything yet, say so and say who it is waiting on.
- Don't mention how long anything has been waiting; the suggestion is reused until the item changes.
- Reply in plain text only, without markdown, lists, quotes, or a preamble.''';
}

String _contributorDescription(ContributorType type) => switch (type) {
  ContributorType.member => 'team member',
  ContributorType.bot => 'bot',
  ContributorType.community => 'community contributor',
};

String _reviewerDescription(ReviewerEntry entry) {
  final String states = entry.states
      .map(
        (ReviewState state) => switch (state) {
          ReviewState.approved => 'approved',
          ReviewState.changesRequested => 'requested changes',
          ReviewState.pending => 'review requested',
          ReviewState.commented => 'commented',
        },
      )
      .join(', ');
  return '@${entry.name} ($states)';
}

String _conversationLine(ConversationEntry entry) {
  final text = entry.text.isEmpty ? '' : ': ${entry.text}';
  return '- ${formatAsDay(entry.date)} @${entry.login} (${entry.role}) ${entry.kind}$text';
}

String _followUpNote(bool isFollowUp) =>
    isFollowUp ? " (the author replied after the team's last comment)" : '';

List<String> _contextLines(String body, List<ConversationEntry> conversation) {
  final String description = descriptionExcerpt(body);
  return <String>[
    'Description:',
    if (description.isEmpty) '(none)' else description,
    '',
    'Recent conversation, oldest first:',
    if (conversation.isEmpty) '(none)',
    ...conversation.map(_conversationLine),
  ];
}

/// The prompt asking for a next step for [analysis]'s PR, given its recent
/// [conversation].
String buildPRPrompt(
  PRAnalysis analysis, {
  required List<ConversationEntry> conversation,
  required DateTime now,
  TriageConfig config = const TriageConfig(),
}) {
  final PRInfo pr = analysis.pr;
  final List<ReviewerEntry> reviewers = reviewerEntries(pr);
  final String section = sectionTitle(analysis.section, analysis.page);
  return <String>[
    'Today: ${formatAsDay(now)}',
    'Pull request: ${pr.url}',
    'Title: ${pr.title}',
    'Author: @${pr.author} (${_contributorDescription(pr.authorType)})',
    'State: ${pr.isDraft ? 'draft' : 'open'}',
    'Labels: ${pr.labels.isEmpty ? 'none' : pr.labels.join(', ')}',
    'Opened: ${formatAsDay(pr.creationDate)}; last updated: ${formatAsDay(pr.updatedDate)}',
    'Reviewers: ${reviewers.isEmpty ? 'none' : reviewers.map(_reviewerDescription).join(', ')}',
    if (pr.authorType == ContributorType.community)
      'Approvals: ${pr.approvalCount} (community PRs need ${config.requiredApprovals})',
    'Triage section: ${pageTitle(analysis.page)} > $section${_followUpNote(analysis.isFollowUp)}',
    'Heuristic next step: ${analysis.nextStep.isEmpty ? 'none' : analysis.nextStep}',
    if (analysis.reasons.isNotEmpty) 'Heuristic reasons: ${analysis.reasons.join('; ')}',
    '',
    ..._contextLines(pr.body, conversation),
  ].join('\n');
}

/// The prompt asking for a next step for [analysis]'s issue, given its
/// recent [conversation].
String buildIssuePrompt(
  IssueAnalysis analysis, {
  required List<ConversationEntry> conversation,
  required DateTime now,
  TriageConfig config = const TriageConfig(),
}) {
  final IssueInfo issue = analysis.issue;
  final String triagedLabel = config.issueTriagedLabel;
  final String section = issueSectionTitle(analysis.section, config: config);
  final String assignees = issue.assignees.isEmpty
      ? 'none'
      : issue.assignees.map((String a) => '@$a').join(', ');
  final convention =
      'Triage convention: an issue is triaged once it has a priority label '
      '(${config.priorityLabels.join(', ')}) and the $triagedLabel label.';
  return <String>[
    'Today: ${formatAsDay(now)}',
    'Issue: ${issue.url}',
    'Title: ${issue.title}',
    'Author: @${issue.author} (${_contributorDescription(issue.authorType)})',
    'Labels: ${issue.labels.isEmpty ? 'none' : issue.labels.join(', ')}',
    'Assignees: $assignees',
    'Opened: ${formatAsDay(issue.creationDate)}; last updated: ${formatAsDay(issue.updatedDate)}',
    'Triage section: $section${_followUpNote(analysis.isFollowUp)}',
    'Heuristic next step: ${analysis.nextStep.isEmpty ? 'none' : analysis.nextStep}',
    if (analysis.reasons.isNotEmpty) 'Heuristic reasons: ${analysis.reasons.join('; ')}',
    if (triagedLabel.isNotEmpty && config.priorityLabels.isNotEmpty) convention,
    '',
    ..._contextLines(issue.body, conversation),
  ].join('\n');
}

/// Whether [analysis]'s PR gets an AI suggestion: every PR does unless it
/// failed to load.
bool wantsAiSuggestion(PRAnalysis analysis) => analysis.section != Section.loadError;

/// Whether [analysis]'s issue gets an AI suggestion: every issue does unless
/// it failed to load or is in the catch-all [IssueSection.otherTeamIssues]
/// section.
bool wantsAiIssueSuggestion(IssueAnalysis analysis) =>
    analysis.section != IssueSection.loadError && analysis.section != IssueSection.otherTeamIssues;

/// The outcome of [generateAiSuggestions].
///
/// [suggestions] are keyed by PR or issue URL. [skipped] counts items that
/// have no suggestion because Gemini wasn't available or generation stopped
/// early.
typedef AiSuggestionResult = ({
  Map<String, String> suggestions,
  int reused,
  int generated,
  int failed,
  int skipped,
});

class _AiItem {
  _AiItem({
    required this.url,
    required this.updatedAt,
    required this.number,
    required this.author,
    required this.isPullRequest,
    required this.prompt,
  });

  final String url;
  final String updatedAt;
  final int number;
  final String author;
  final bool isPullRequest;
  final String Function(List<ConversationEntry> conversation) prompt;

  /// The `owner/repo` in [url], such as `flutter/packages` for
  /// `https://github.com/flutter/packages/pull/1`.
  String get repo {
    final List<String> segments = Uri.parse(url).pathSegments;
    return segments.length >= 2 ? '${segments[0]}/${segments[1]}' : '';
  }

  String get label => '$repo#$number';
}

/// Returns AI next-step suggestions for [prs] and [issues], keyed by URL.
///
/// Suggestions saved in [cache] are reused while their item hasn't changed.
/// The rest are generated by [gemini], up to [concurrency] at a time, from
/// each item's details and its recent conversation (fetched with [github]),
/// and saved in [cache]. If [gemini] is null, only cached suggestions are
/// returned.
///
/// PRs and issues that failed to load, and issues in
/// [IssueSection.otherTeamIssues], never get suggestions.
///
/// Failures are reported to [onWarning] rather than thrown. An error that
/// would affect every request, such as an invalid API key or an exhausted
/// quota, stops generation; the remaining items are retried on the next run.
Future<AiSuggestionResult> generateAiSuggestions({
  required List<PRAnalysis> prs,
  required List<IssueAnalysis> issues,
  required AiSuggestionCache cache,
  required String model,
  required DateTime now,
  GeminiClient? gemini,
  GitHubClient? github,
  Set<String> roster = const <String>{},
  TriageConfig config = const TriageConfig(),
  int concurrency = 4,
  void Function(int pending, int reused)? onStart,
  void Function(int done, int total)? onProgress,
  void Function(String message)? onWarning,
}) async {
  final items = <_AiItem>[
    for (final PRAnalysis analysis in prs)
      if (wantsAiSuggestion(analysis))
        _AiItem(
          url: analysis.pr.url,
          updatedAt: analysis.pr.updatedDate.toUtc().toIso8601String(),
          number: analysis.pr.number,
          author: analysis.pr.author,
          isPullRequest: true,
          prompt: (List<ConversationEntry> conversation) =>
              buildPRPrompt(analysis, conversation: conversation, now: now, config: config),
        ),
    for (final IssueAnalysis analysis in issues)
      if (wantsAiIssueSuggestion(analysis))
        _AiItem(
          url: analysis.issue.url,
          updatedAt: analysis.issue.updatedDate.toUtc().toIso8601String(),
          number: analysis.issue.number,
          author: analysis.issue.author,
          isPullRequest: false,
          prompt: (List<ConversationEntry> conversation) =>
              buildIssuePrompt(analysis, conversation: conversation, now: now, config: config),
        ),
  ];
  cache.markSeen(<String>[for (final item in items) item.url]);

  final suggestions = <String, String>{};
  final pending = <_AiItem>[];
  for (final item in items) {
    final String? cached = cache.lookup(item.url, updatedAt: item.updatedAt, model: model);
    if (cached == null) {
      pending.add(item);
    } else {
      suggestions[item.url] = cached;
    }
  }
  final int reused = suggestions.length;
  if (gemini == null || pending.isEmpty) {
    return (
      suggestions: suggestions,
      reused: reused,
      generated: 0,
      failed: 0,
      skipped: pending.length,
    );
  }

  onStart?.call(pending.length, reused);
  final String systemInstruction = aiSystemInstruction(config);
  var next = 0;
  var done = 0;
  var generated = 0;
  var failed = 0;
  GeminiException? fatal;
  Future<void> worker() async {
    while (fatal == null && next < pending.length) {
      final _AiItem item = pending[next++];
      try {
        final List<ConversationEntry> conversation = github == null
            ? const <ConversationEntry>[]
            : await fetchConversation(
                github,
                item.repo,
                item.number,
                author: item.author,
                isPullRequest: item.isPullRequest,
                roster: roster,
                config: config,
              );
        final String text = cleanAiText(
          await gemini.generateText(
            systemInstruction: systemInstruction,
            prompt: item.prompt(conversation),
          ),
        );
        if (text.isEmpty) {
          failed++;
          onWarning?.call('Gemini returned an empty suggestion for ${item.label}.');
        } else {
          cache.store(item.url, updatedAt: item.updatedAt, model: model, text: text);
          suggestions[item.url] = text;
          generated++;
        }
      } on GeminiException catch (e) {
        failed++;
        if (e.isFatal) {
          fatal ??= e;
        } else {
          onWarning?.call('Could not generate an AI suggestion for ${item.label}: $e');
        }
      } on GitHubException catch (e) {
        failed++;
        onWarning?.call('Could not fetch the conversation on ${item.label}: $e');
      }
      done++;
      onProgress?.call(done, pending.length);
    }
  }

  await Future.wait(<Future<void>>[for (var i = 0; i < concurrency; i++) worker()]);
  final int skipped = pending.length - done;
  if (fatal != null) {
    onWarning?.call(
      'Stopped generating AI suggestions: $fatal'
      '${skipped > 0 ? ' ($skipped skipped; they will be retried on the next run)' : ''}',
    );
  }
  return (
    suggestions: suggestions,
    reused: reused,
    generated: generated,
    failed: failed,
    skipped: skipped,
  );
}
