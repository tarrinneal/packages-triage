// Copyright 2013 The Flutter Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pr_inspector/ai.dart';
import 'package:pr_inspector/github_client.dart';
import 'package:pr_inspector/types.dart';
import 'package:test/test.dart';

final DateTime _now = DateTime.utc(2026, 10, 1, 12);
const String _model = 'gemini-test';

http.Response _json(Object body, int status) => http.Response(
  jsonEncode(body),
  status,
  headers: <String, String>{'content-type': 'application/json; charset=utf-8'},
);

http.Response _reply(String text) => _json(<String, Object?>{
  'candidates': <Object?>[
    <String, Object?>{
      'content': <String, Object?>{
        'role': 'model',
        'parts': <Object?>[
          <String, Object?>{'text': text},
        ],
      },
      'finishReason': 'STOP',
    },
  ],
}, 200);

http.Response _error(int status, String message, {List<Object?> details = const <Object?>[]}) =>
    _json(<String, Object?>{
      'error': <String, Object?>{'code': status, 'message': message, 'details': details},
    }, status);

Map<String, dynamic> _bodyOf(http.Request request) =>
    jsonDecode(request.body) as Map<String, dynamic>;

String _textOf(Object? content) {
  final parts = (content! as Map<String, dynamic>)['parts'] as List<dynamic>;
  return (parts.single as Map<String, dynamic>)['text'] as String;
}

String _promptOf(http.Request request) =>
    _textOf((_bodyOf(request)['contents'] as List<dynamic>).single);

String _systemInstructionOf(http.Request request) => _textOf(_bodyOf(request)['systemInstruction']);

PRAnalysis _pr(int number, {Section section = Section.waitingOnTeam, String body = ''}) {
  final pr = PRInfo(
    number: number,
    repo: 'o/r',
    author: 'author$number',
    title: 'PR $number',
    url: 'https://github.com/o/r/pull/$number',
    creationDate: DateTime.utc(2026, 9),
    updatedDate: DateTime.utc(2026, 9, 20),
    authorType: ContributorType.community,
    isDraft: false,
    labels: const <String>['p: camera'],
    body: body,
  );
  pr.reviewers['alice'] = ReviewerStatus()..requested = true;
  return PRAnalysis(
    pr: pr,
    page: ReportPage.community,
    section: section,
    waitingSince: DateTime.utc(2026, 9, 20),
    waitingDays: 11,
    urgency: Urgency.due,
    nextStep: 'Ping @alice',
    reasons: const <String>['Waiting since the PR was opened'],
  );
}

IssueAnalysis _issue(int number, {IssueSection section = IssueSection.untriaged}) {
  final issue = IssueInfo(
    number: number,
    author: 'reporter',
    title: 'Issue $number',
    url: 'https://github.com/flutter/flutter/issues/$number',
    creationDate: DateTime.utc(2026, 9),
    updatedDate: DateTime.utc(2026, 9, 20),
    authorType: ContributorType.community,
    labels: const <String>['team-ecosystem', 'p: camera'],
    body: 'The camera crashes on iOS.',
  );
  return IssueAnalysis(
    issue: issue,
    section: section,
    waitingSince: DateTime.utc(2026, 9),
    waitingDays: 30,
    urgency: Urgency.critical,
    nextStep: 'Assign priority and add triaged-ecosystem',
    reasons: const <String>['Missing triaged-ecosystem and priority label'],
  );
}

String _github(String path) =>
    Uri.https('api.github.com', path, <String, String>{'per_page': '100', 'page': '1'}).toString();

Map<String, Object?> _ok(Object body) => <String, Object?>{
  'status': 200,
  'link': null,
  'body': jsonEncode(body),
};

void main() {
  late Directory tempDir;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('ai_test');
  });

  tearDown(() {
    tempDir.deleteSync(recursive: true);
  });

  GitHubClient replayClient(Map<String, Map<String, Object?>> responses) {
    final file = File('${tempDir.path}/recording.json')
      ..writeAsStringSync(
        jsonEncode(<String, Object?>{
          'recordedAt': '2026-10-01T12:00:00.000Z',
          'responses': responses,
        }),
      );
    return GitHubClient(token: '', replayFile: file);
  }

  group('GeminiClient', () {
    test('sends a generateContent request and returns the reply', () async {
      final requests = <http.Request>[];
      final gemini = GeminiClient(
        apiKey: 'test-key',
        model: 'models/gemini-3.5-flash-lite',
        httpClient: MockClient((http.Request request) async {
          requests.add(request);
          return _reply('Ping @alice for a review.');
        }),
      );

      expect(
        await gemini.generateText(systemInstruction: 'Be brief.', prompt: 'What next?'),
        'Ping @alice for a review.',
      );
      final http.Request request = requests.single;
      expect(
        request.url.toString(),
        'https://generativelanguage.googleapis.com/v1beta/models/gemini-3.5-flash-lite:generateContent',
      );
      expect(request.headers['x-goog-api-key'], 'test-key');
      expect(_systemInstructionOf(request), 'Be brief.');
      expect(_promptOf(request), 'What next?');
      expect(_bodyOf(request)['generationConfig'], <String, Object?>{
        'maxOutputTokens': 1024,
        'thinkingConfig': <String, Object?>{'thinkingLevel': 'LOW'},
      });
      expect(gemini.requestCount, 1);
    });

    test('only sets a thinking level for Gemini 3 and later', () async {
      late http.Request sent;
      final gemini = GeminiClient(
        apiKey: 'k',
        model: 'gemini-2.5-flash',
        httpClient: MockClient((http.Request request) async {
          sent = request;
          return _reply('OK');
        }),
      );
      await gemini.generateText(systemInstruction: 's', prompt: 'p');
      expect(_bodyOf(sent)['generationConfig'], <String, Object?>{'maxOutputTokens': 1024});
    });

    test('retries rate limits after the delay Gemini asks for', () async {
      var calls = 0;
      final delays = <Duration>[];
      final gemini = GeminiClient(
        apiKey: 'k',
        httpClient: MockClient((http.Request request) async {
          calls++;
          return calls == 1
              ? _error(
                  429,
                  'Slow down',
                  details: <Object?>[
                    <String, Object?>{
                      '@type': 'type.googleapis.com/google.rpc.RetryInfo',
                      'retryDelay': '7s',
                    },
                  ],
                )
              : _reply('Done');
        }),
        sleep: (Duration delay) async => delays.add(delay),
      );

      expect(await gemini.generateText(systemInstruction: 's', prompt: 'p'), 'Done');
      expect(calls, 2);
      expect(delays, <Duration>[const Duration(seconds: 7)]);
    });

    test('gives up right away on an exhausted daily quota or a bad key', () async {
      Future<void> noRetries(Duration delay) async => fail('Should not retry');
      final quota = GeminiClient(
        apiKey: 'k',
        httpClient: MockClient(
          (http.Request request) async => _error(
            429,
            'Quota exceeded',
            details: <Object?>[
              <String, Object?>{
                'violations': <Object?>[
                  <String, Object?>{'quotaId': 'GenerateRequestsPerDayPerProjectPerModel-FreeTier'},
                ],
              },
            ],
          ),
        ),
        sleep: noRetries,
      );
      await expectLater(
        quota.generateText(systemInstruction: 's', prompt: 'p'),
        throwsA(
          isA<GeminiException>()
              .having((GeminiException e) => e.isFatal, 'isFatal', isTrue)
              .having((GeminiException e) => e.message, 'message', contains('Quota exceeded')),
        ),
      );

      final badKey = GeminiClient(
        apiKey: 'k',
        httpClient: MockClient((http.Request request) async => _error(400, 'API key not valid.')),
        sleep: noRetries,
      );
      await expectLater(
        badKey.generateText(systemInstruction: 's', prompt: 'p'),
        throwsA(
          isA<GeminiException>()
              .having((GeminiException e) => e.isFatal, 'isFatal', isTrue)
              .having((GeminiException e) => e.statusCode, 'statusCode', 400),
        ),
      );
    });

    test('reports blocked prompts as errors that only affect that item', () async {
      final gemini = GeminiClient(
        apiKey: 'k',
        httpClient: MockClient(
          (http.Request request) async => _json(<String, Object?>{
            'promptFeedback': <String, Object?>{'blockReason': 'SAFETY'},
          }, 200),
        ),
      );
      await expectLater(
        gemini.generateText(systemInstruction: 's', prompt: 'p'),
        throwsA(
          isA<GeminiException>()
              .having((GeminiException e) => e.isFatal, 'isFatal', isFalse)
              .having((GeminiException e) => e.message, 'message', contains('SAFETY')),
        ),
      );
    });
  });

  group('AiSuggestionCache', () {
    const url = 'https://github.com/o/r/pull/1';

    test('reuses a suggestion only while the item, model, and prompt are unchanged', () {
      final file = File('${tempDir.path}/ai_ecosystem.json');
      final cache = AiSuggestionCache.load(file, now: _now)
        ..store(url, updatedAt: 'u1', model: _model, text: 'Ping @alice.');
      expect(cache.lookup(url, updatedAt: 'u1', model: _model), 'Ping @alice.');
      expect(cache.lookup(url, updatedAt: 'u2', model: _model), isNull);
      expect(cache.lookup(url, updatedAt: 'u1', model: 'other-model'), isNull);
      cache.save();

      final reloaded = AiSuggestionCache.load(file, now: _now.add(const Duration(days: 1)));
      expect(reloaded.lookup(url, updatedAt: 'u1', model: _model), 'Ping @alice.');

      final json = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
      ((json['suggestions'] as Map<String, dynamic>)[url]
              as Map<String, dynamic>)['promptVersion'] =
          aiPromptVersion + 1;
      file.writeAsStringSync(jsonEncode(json));
      expect(
        AiSuggestionCache.load(file, now: _now).lookup(url, updatedAt: 'u1', model: _model),
        isNull,
      );
    });

    test('drops suggestions for items that have not been seen for a while', () {
      final file = File('${tempDir.path}/ai_ecosystem.json');
      AiSuggestionCache.load(file, now: _now)
        ..store(url, updatedAt: 'u1', model: _model, text: 'Ping @alice.')
        ..save();
      expect(AiSuggestionCache.load(file, now: _now.add(const Duration(days: 29))).length, 1);
      expect(AiSuggestionCache.load(file, now: _now.add(AiSuggestionCache.maxUnseen)).length, 0);
    });

    test('starts empty when the file is unreadable', () {
      final file = File('${tempDir.path}/ai_ecosystem.json')..writeAsStringSync('not json');
      final warnings = <String>[];
      expect(AiSuggestionCache.load(file, now: _now, onWarning: warnings.add).length, 0);
      expect(warnings.single, contains('Ignoring the unreadable AI suggestions'));
    });
  });

  group('generateAiSuggestions', () {
    test('reuses cached suggestions, generates the rest with recent conversation, and skips '
        'failed loads and the Other issues section', () async {
      final cache = AiSuggestionCache.load(File('${tempDir.path}/ai.json'), now: _now)
        ..store(
          'https://github.com/o/r/pull/1',
          updatedAt: '2026-09-20T00:00:00.000Z',
          model: _model,
          text: 'Cached suggestion.',
        );
      final requests = <http.Request>[];
      final gemini = GeminiClient(
        apiKey: 'k',
        model: _model,
        httpClient: MockClient((http.Request request) async {
          requests.add(request);
          return _promptOf(request).contains('/pull/2')
              ? _reply('**Next step:** Ask @alice to\nre-review.')
              : _reply('Set P2 and add triaged-ecosystem.');
        }),
      );
      final GitHubClient github = replayClient(<String, Map<String, Object?>>{
        _github('/repos/o/r/issues/2/comments'): _ok(<Object?>[
          <String, Object?>{
            'user': <String, Object?>{'login': 'author2', 'type': 'User'},
            'author_association': 'CONTRIBUTOR',
            'created_at': '2026-09-15T12:00:00Z',
            'body': 'I addressed the feedback.',
          },
          <String, Object?>{
            'user': <String, Object?>{'login': 'ci-bot', 'type': 'Bot'},
            'created_at': '2026-09-15T13:00:00Z',
            'body': 'CI passed',
          },
          <String, Object?>{
            'user': <String, Object?>{'login': 'alice', 'type': 'User'},
            'author_association': 'MEMBER',
            'created_at': '2026-09-16T12:00:00Z',
            'body': '> I addressed the feedback.\nThanks, will look.',
          },
        ]),
        _github('/repos/o/r/pulls/2/reviews'): _ok(<Object?>[
          <String, Object?>{
            'user': <String, Object?>{'login': 'alice', 'type': 'User'},
            'author_association': 'MEMBER',
            'state': 'CHANGES_REQUESTED',
            'submitted_at': '2026-09-12T12:00:00Z',
            'body': 'Please add tests.',
          },
        ]),
        _github('/repos/flutter/flutter/issues/42/comments'): _ok(<Object?>[]),
      });

      final AiSuggestionResult result = await generateAiSuggestions(
        prs: <PRAnalysis>[
          _pr(1),
          _pr(2, body: 'Fixes a crash.\n<!-- hint -->\n## Pre-Review Checklist\n- [x] Done'),
          _pr(3, section: Section.loadError),
        ],
        issues: <IssueAnalysis>[
          _issue(42),
          _issue(77, section: IssueSection.otherTeamIssues),
        ],
        cache: cache,
        model: _model,
        now: _now,
        gemini: gemini,
        github: github,
      );

      expect(result.suggestions, <String, String>{
        'https://github.com/o/r/pull/1': 'Cached suggestion.',
        'https://github.com/o/r/pull/2': 'Ask @alice to re-review.',
        'https://github.com/flutter/flutter/issues/42': 'Set P2 and add triaged-ecosystem.',
      });
      expect(result.reused, 1);
      expect(result.generated, 2);
      expect(result.failed, 0);
      expect(result.skipped, 0);
      expect(requests, hasLength(2));
      expect(_systemInstructionOf(requests.first), contains('the Flutter ecosystem team'));

      final String prPrompt = requests
          .map(_promptOf)
          .firstWhere((String prompt) => prompt.contains('/pull/2'));
      expect(prPrompt, contains('Title: PR 2'));
      expect(prPrompt, contains('Labels: p: camera'));
      expect(prPrompt, contains('Reviewers: @alice (review requested)'));
      expect(prPrompt, contains('Heuristic next step: Ping @alice'));
      expect(prPrompt, contains('Description:\nFixes a crash.'));
      expect(prPrompt, isNot(contains('Pre-Review Checklist')));
      expect(prPrompt, contains('@alice (team) requested changes: Please add tests.'));
      expect(prPrompt, contains('@author2 (author) comment: I addressed the feedback.'));
      expect(prPrompt, contains('@alice (team) comment: Thanks, will look.'));
      expect(prPrompt, isNot(contains('CI passed')));
      expect(
        prPrompt.indexOf('Please add tests.'),
        lessThan(prPrompt.indexOf('I addressed the feedback.')),
      );

      final String issuePrompt = requests
          .map(_promptOf)
          .firstWhere((String prompt) => prompt.contains('/issues/42'));
      expect(issuePrompt, contains('Triage section: Untriaged (team-ecosystem)'));
      expect(
        issuePrompt,
        contains(
          'an issue is triaged once it has a priority label (P0, P1, P2, P3) and the '
          'triaged-ecosystem label',
        ),
      );
      expect(issuePrompt, contains('Recent conversation, oldest first:\n(none)'));

      expect(
        cache.lookup(
          'https://github.com/o/r/pull/2',
          updatedAt: '2026-09-20T00:00:00.000Z',
          model: _model,
        ),
        'Ask @alice to re-review.',
      );
    });

    test('only returns cached suggestions without a Gemini client', () async {
      final cache = AiSuggestionCache.load(File('${tempDir.path}/ai.json'), now: _now)
        ..store(
          'https://github.com/o/r/pull/1',
          updatedAt: '2026-09-20T00:00:00.000Z',
          model: _model,
          text: 'Cached suggestion.',
        );
      final AiSuggestionResult result = await generateAiSuggestions(
        prs: <PRAnalysis>[_pr(1), _pr(2)],
        issues: const <IssueAnalysis>[],
        cache: cache,
        model: _model,
        now: _now,
      );
      expect(result.suggestions, <String, String>{
        'https://github.com/o/r/pull/1': 'Cached suggestion.',
      });
      expect(result.skipped, 1);
    });

    test('stops after an error that would affect every request', () async {
      var calls = 0;
      final warnings = <String>[];
      final AiSuggestionResult result = await generateAiSuggestions(
        prs: <PRAnalysis>[_pr(1), _pr(2), _pr(3)],
        issues: const <IssueAnalysis>[],
        cache: AiSuggestionCache.load(File('${tempDir.path}/ai.json'), now: _now),
        model: _model,
        now: _now,
        gemini: GeminiClient(
          apiKey: 'bad',
          model: _model,
          httpClient: MockClient((http.Request request) async {
            calls++;
            return _error(400, 'API key not valid.');
          }),
        ),
        concurrency: 1,
        onWarning: warnings.add,
      );
      expect(calls, 1);
      expect(result.suggestions, isEmpty);
      expect(result.failed, 1);
      expect(result.skipped, 2);
      expect(warnings.single, contains('Stopped generating AI suggestions'));
      expect(warnings.single, contains('API key not valid.'));
    });
  });

  group('text helpers', () {
    test('cleanAiText makes a single line of plain text', () {
      expect(cleanAiText('**Next step:** Ask `@alice`\nto review.'), 'Ask @alice to review.');
      expect(cleanAiText('"Close it as stale."'), 'Close it as stale.');
      final String long = cleanAiText('word ' * 200);
      expect(long.length, lessThanOrEqualTo(maxAiSuggestionLength));
      expect(long, endsWith('…'));
    });

    test('descriptionExcerpt drops template comments and the checklist', () {
      expect(
        descriptionExcerpt(
          'Fixes a crash.\r\n<!-- Describe the change -->\r\n\r\n\r\n'
          '## Pre-launch Checklist\r\n- [x] I read the guide',
        ),
        'Fixes a crash.',
      );
      expect(descriptionExcerpt('a' * 2000).length, 1500);
    });
  });
}
