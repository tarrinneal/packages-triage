// Copyright 2013 The Flutter Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:convert';
import 'dart:io';

import 'package:pr_inspector/detail_cache.dart';
import 'package:pr_inspector/github_client.dart';
import 'package:pr_inspector/pr_inspector.dart';
import 'package:pr_inspector/triage.dart';
import 'package:pr_inspector/types.dart';
import 'package:test/test.dart';

const String _repo = 'o/r';

String _url(String path, [Map<String, String>? query]) =>
    Uri.https('api.github.com', path, query).toString();

Map<String, Object?> _ok(Object body, {String? link}) => <String, Object?>{
  'status': 200,
  'link': link,
  'body': jsonEncode(body),
};

Map<String, Object?> _user(String login, {String type = 'User'}) => <String, Object?>{
  'login': login,
  'type': type,
};

Map<String, Object?> _listing(
  int number, {
  String author = 'contributor',
  String association = 'CONTRIBUTOR',
  String userType = 'User',
  bool draft = false,
  List<String> requested = const <String>[],
  List<String> labels = const <String>[],
}) => <String, Object?>{
  'number': number,
  'title': 'PR $number',
  'html_url': 'https://github.com/$_repo/pull/$number',
  'user': _user(author, type: userType),
  'author_association': association,
  'draft': draft,
  'created_at': '2026-09-01T00:00:00Z',
  'updated_at': '2026-09-20T00:00:00Z',
  'labels': <Object?>[
    for (final label in labels) <String, Object?>{'name': label},
  ],
  'requested_reviewers': <Object?>[for (final login in requested) _user(login)],
};

Map<String, Object?> _comment(
  String login, {
  String association = 'CONTRIBUTOR',
  String created = '2026-09-10T00:00:00Z',
  String? updated,
  String type = 'User',
}) => <String, Object?>{
  'user': _user(login, type: type),
  'author_association': association,
  'created_at': created,
  'updated_at': updated ?? created,
};

Map<String, Object?> _review(
  String login,
  String state, {
  String association = 'MEMBER',
  String? submitted = '2026-09-10T00:00:00Z',
}) => <String, Object?>{
  'user': _user(login),
  'author_association': association,
  'state': state,
  'submitted_at': submitted,
};

/// Responses for all three comment sources of PR [number].
Map<String, Map<String, Object?>> _commentResponses(
  int number, {
  List<Object?> issueComments = const <Object?>[],
  List<Object?> inlineComments = const <Object?>[],
  List<Object?> reviews = const <Object?>[],
}) => <String, Map<String, Object?>>{
  _url('/repos/$_repo/issues/$number/comments', <String, String>{'per_page': '100', 'page': '1'}):
      _ok(issueComments),
  _url('/repos/$_repo/pulls/$number/comments', <String, String>{'per_page': '100', 'page': '1'}):
      _ok(inlineComments),
  _url('/repos/$_repo/pulls/$number/reviews', <String, String>{'per_page': '100', 'page': '1'}):
      _ok(reviews),
};

void main() {
  late Directory tempDir;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('pr_inspector_test');
  });

  tearDown(() {
    tempDir.deleteSync(recursive: true);
  });

  GitHubClient replayClient(Map<String, Map<String, Object?>> responses) {
    final file = File('${tempDir.path}/recording.json')
      ..writeAsStringSync(
        jsonEncode(<String, Object?>{
          'recordedAt': '2026-10-01T00:00:00.000Z',
          'responses': responses,
        }),
      );
    return GitHubClient(token: '', replayFile: file);
  }

  Future<PRInfo> fetch(
    Map<String, Object?> listing,
    Map<String, Map<String, Object?>> responses, {
    Set<String> roster = const <String>{},
  }) async {
    final GitHubClient client = replayClient(responses);
    try {
      return await fetchPRDetails(client, _repo, listing, roster);
    } finally {
      client.close();
    }
  }

  test('a comment review after an approval keeps the approval', () async {
    final PRInfo pr = await fetch(
      _listing(1),
      _commentResponses(
        1,
        reviews: <Object?>[
          _review('alice', 'APPROVED'),
          _review('alice', 'COMMENTED', submitted: '2026-09-11T00:00:00Z'),
        ],
      ),
    );
    expect(pr.fetchErrors, isEmpty);
    expect(pr.reviewers['alice']!.displayStates, <ReviewState>[
      ReviewState.approved,
      ReviewState.commented,
    ]);
    expect(pr.approvalCount, 1);
  });

  test('a new approval replaces earlier changes requested', () async {
    final PRInfo pr = await fetch(
      _listing(1),
      _commentResponses(
        1,
        reviews: <Object?>[
          _review('alice', 'CHANGES_REQUESTED'),
          _review('alice', 'COMMENTED', submitted: '2026-09-11T00:00:00Z'),
          _review('alice', 'APPROVED', submitted: '2026-09-12T00:00:00Z'),
        ],
      ),
    );
    expect(pr.reviewers['alice']!.displayStates, <ReviewState>[ReviewState.approved]);
  });

  test('dismissed reviews are cleared', () async {
    final PRInfo pr = await fetch(
      _listing(1),
      _commentResponses(1, reviews: <Object?>[_review('bob', 'DISMISSED')]),
    );
    expect(pr.reviewers['bob']!.displayStates, isEmpty);
    expect(pr.reviewStateCount, isEmpty);
  });

  test("the caller's unsubmitted review is skipped without losing other reviews", () async {
    final PRInfo pr = await fetch(
      _listing(1),
      _commentResponses(
        1,
        reviews: <Object?>[
          _review('carol', 'PENDING', submitted: null),
          _review('alice', 'APPROVED'),
        ],
      ),
    );
    expect(pr.fetchErrors, isEmpty);
    expect(pr.reviewers.keys, <String>['alice']);
    expect(pr.approvalCount, 1);
  });

  test('requested reviewers show as pending even after an earlier review', () async {
    final PRInfo pr = await fetch(
      _listing(1, requested: <String>['dave']),
      _commentResponses(1, reviews: <Object?>[_review('dave', 'APPROVED')]),
    );
    expect(pr.reviewers['dave']!.displayStates, <ReviewState>[ReviewState.pending]);
  });

  test('bot comments are ignored', () async {
    final PRInfo pr = await fetch(
      _listing(1),
      _commentResponses(
        1,
        issueComments: <Object?>[
          _comment('engine-flutter-autoroll', association: 'MEMBER'),
          _comment('dependabot[bot]', type: 'Bot'),
          _comment('some-app', type: 'Bot'),
        ],
      ),
    );
    expect(pr.memberComment, isNull);
    expect(pr.nonMemberComment, isNull);
  });

  test('comment times use created_at, so edits do not count as activity', () async {
    final PRInfo pr = await fetch(
      _listing(1),
      _commentResponses(
        1,
        issueComments: <Object?>[
          _comment('contributor', created: '2026-09-02T00:00:00Z', updated: '2026-09-25T00:00:00Z'),
        ],
      ),
    );
    expect(pr.authorComment!.date, DateTime.utc(2026, 9, 2));
  });

  test('keeps the newest comment of each kind across sources', () async {
    final PRInfo pr = await fetch(
      _listing(1),
      _commentResponses(
        1,
        issueComments: <Object?>[
          _comment('contributor', created: '2026-09-05T00:00:00Z'),
          _comment('teammate', association: 'MEMBER', created: '2026-09-03T00:00:00Z'),
          _comment('passerby', created: '2026-09-04T00:00:00Z'),
        ],
        inlineComments: <Object?>[
          _comment('teammate', association: 'MEMBER', created: '2026-09-08T00:00:00Z'),
          _comment('contributor', created: '2026-09-07T00:00:00Z'),
        ],
      ),
    );
    expect(pr.authorComment!.date, DateTime.utc(2026, 9, 7));
    expect(pr.memberComment!.date, DateTime.utc(2026, 9, 8));
    expect(pr.nonMemberComment!.username, 'passerby');
  });

  test('the roster identifies team members GitHub reports as contributors', () async {
    final GitHubClient client = replayClient(<String, Map<String, Object?>>{
      _url('/repos/$_repo/contents/SUGGESTED_REVIEWERS.md'): _ok(<String, Object?>{
        'content': base64.encode(utf8.encode('`camera`:\n  - @TeamMember, @other-member\n')),
      }),
      ..._commentResponses(
        1,
        issueComments: <Object?>[_comment('other-member', created: '2026-09-12T00:00:00Z')],
      ),
    });
    try {
      final listings = <Map<String, dynamic>>[
        _listing(1, author: 'teammember'),
        _listing(2, requested: <String>['Requested-Reviewer']),
      ];
      final Set<String> roster = await fetchRoster(client, _repo, listings);
      expect(roster, <String>{'requested-reviewer', 'teammember', 'other-member'});

      final PRInfo pr = await fetchPRDetails(client, _repo, listings.first, roster);
      expect(pr.authorType, ContributorType.member);
      expect(pr.authorTypeFromRoster, isTrue);
      expect(pr.memberComment!.username, 'other-member');
      expect(analyzePR(pr, now: client.now).page, ReportPage.team);
    } finally {
      client.close();
    }
  });

  test('a missing SUGGESTED_REVIEWERS.md is not an error', () async {
    final GitHubClient client = replayClient(<String, Map<String, Object?>>{
      _url('/repos/$_repo/contents/SUGGESTED_REVIEWERS.md'): <String, Object?>{
        'status': 404,
        'link': null,
        'body': '{"message": "Not Found"}',
      },
    });
    final warnings = <String>[];
    try {
      final Set<String> roster = await fetchRoster(
        client,
        _repo,
        <Map<String, dynamic>>[],
        onWarning: warnings.add,
      );
      expect(roster, isEmpty);
      expect(warnings, isEmpty);
    } finally {
      client.close();
    }
  });

  test('failed fetches are recorded instead of looking like an untouched PR', () async {
    final PRInfo pr = await fetch(_listing(1), <String, Map<String, Object?>>{});
    expect(pr.fetchErrors, hasLength(3));
    expect(analyzePR(pr, now: DateTime.utc(2026, 10)).section, Section.loadError);
  });

  test('drafts and bot PRs skip comment fetches', () async {
    final PRInfo draft = await fetch(
      _listing(1, draft: true, requested: <String>['alice']),
      <String, Map<String, Object?>>{},
    );
    expect(draft.fetchErrors, isEmpty);
    expect(draft.hasDetails, isFalse);
    expect(draft.reviewers['alice']!.requested, isTrue);

    final PRInfo bot = await fetch(
      _listing(2, author: 'dependabot[bot]', userType: 'Bot'),
      <String, Map<String, Object?>>{},
    );
    expect(bot.authorType, ContributorType.bot);
    expect(bot.fetchErrors, isEmpty);
  });

  test('parses listing fields', () async {
    final PRInfo pr = prInfoFromListing(
      _listing(7, association: 'MEMBER', labels: <String>['p: camera', 'triage-design']),
      const <String>{},
    );
    expect(pr.number, 7);
    expect(pr.authorType, ContributorType.member);
    expect(pr.authorTypeFromRoster, isFalse);
    expect(pr.labels, <String>['p: camera', 'triage-design']);
    expect(pr.creationDate, DateTime.utc(2026, 9));
    expect(pr.updatedDate, DateTime.utc(2026, 9, 20));
  });

  test('fetchOpenPRs follows pagination and respects the limit', () async {
    String pageUrl(int page) => _url('/repos/$_repo/pulls', <String, String>{
      'state': 'open',
      'per_page': '100',
      'page': '$page',
    });
    final GitHubClient client = replayClient(<String, Map<String, Object?>>{
      pageUrl(1): _ok(<Object?>[_listing(3), _listing(2)], link: '<${pageUrl(2)}>; rel="next"'),
      pageUrl(2): _ok(<Object?>[_listing(1)]),
    });
    try {
      final List<Map<String, dynamic>> all = await fetchOpenPRs(client, _repo);
      expect(all.map((Map<String, dynamic> pr) => pr['number']), <int>[3, 2, 1]);
      final List<Map<String, dynamic>> limited = await fetchOpenPRs(client, _repo, limit: 1);
      expect(limited.map((Map<String, dynamic> pr) => pr['number']), <int>[3]);
    } finally {
      client.close();
    }
  });

  test('fetchAllPRDetails keeps the listing order', () async {
    final GitHubClient client = replayClient(<String, Map<String, Object?>>{
      for (final number in <int>[1, 2, 3]) ..._commentResponses(number),
    });
    try {
      final progress = <int>[];
      final List<PRInfo> prs = await fetchAllPRDetails(
        client,
        _repo,
        <Map<String, dynamic>>[_listing(3), _listing(1), _listing(2)],
        const <String>{},
        concurrency: 2,
        onProgress: (int done, int total, PRInfo pr) => progress.add(done),
      );
      expect(prs.map((PRInfo pr) => pr.number), <int>[3, 1, 2]);
      expect(progress, <int>[1, 2, 3]);
    } finally {
      client.close();
    }
  });

  group('with a cache', () {
    late DetailCache cache;

    setUp(() {
      cache = DetailCache.load(
        File('${tempDir.path}/cache.json'),
        repo: _repo,
        now: DateTime.utc(2026, 10),
      );
    });

    Future<PRInfo> fetchWithCache(
      Map<String, Object?> listing,
      Map<String, Map<String, Object?>> responses, {
      Set<String> roster = const <String>{},
    }) async {
      final GitHubClient client = replayClient(responses);
      try {
        return await fetchPRDetails(client, _repo, listing, roster, cache: cache);
      } finally {
        client.close();
      }
    }

    test('unchanged PRs reuse saved comments and reviews', () async {
      final PRInfo fetched = await fetchWithCache(
        _listing(1),
        _commentResponses(
          1,
          issueComments: <Object?>[_comment('contributor', created: '2026-09-12T00:00:00Z')],
          inlineComments: <Object?>[_comment('teammate', association: 'MEMBER')],
          reviews: <Object?>[_review('alice', 'APPROVED')],
        ),
      );
      // There are no responses, so anything not in the cache would fail.
      final PRInfo reused = await fetchWithCache(_listing(1), <String, Map<String, Object?>>{});
      expect(reused.fetchErrors, isEmpty);
      expect(cache.reusedCount, 1);
      expect(reused.authorComment, fetched.authorComment);
      expect(reused.memberComment, fetched.memberComment);
      expect(reused.reviewers['alice']!.displayStates, <ReviewState>[ReviewState.approved]);
    });

    test('changed PRs are fetched again', () async {
      await fetchWithCache(_listing(1), _commentResponses(1));
      final PRInfo changed = await fetchWithCache(
        _listing(1)..['updated_at'] = '2026-09-21T00:00:00Z',
        <String, Map<String, Object?>>{},
      );
      expect(changed.fetchErrors, hasLength(3));
      expect(cache.reusedCount, 0);
    });

    test('failed fetches are not saved', () async {
      await fetchWithCache(_listing(1), <String, Map<String, Object?>>{});
      final PRInfo retried = await fetchWithCache(_listing(1), _commentResponses(1));
      expect(retried.fetchErrors, isEmpty);
      expect(cache.reusedCount, 0);
    });

    test('team membership is decided again for saved comments', () async {
      final PRInfo before = await fetchWithCache(
        _listing(1),
        _commentResponses(1, issueComments: <Object?>[_comment('newcomer')]),
      );
      expect(before.nonMemberComment!.username, 'newcomer');
      final PRInfo after = await fetchWithCache(
        _listing(1),
        <String, Map<String, Object?>>{},
        roster: <String>{'newcomer'},
      );
      expect(after.memberComment!.username, 'newcomer');
      expect(after.nonMemberComment, isNull);
    });

    test('saved details can be reloaded', () async {
      await fetchWithCache(
        _listing(1),
        _commentResponses(1, reviews: <Object?>[_review('alice', 'APPROVED')]),
      );
      cache.save();
      cache = DetailCache.load(cache.file, repo: _repo, now: DateTime.utc(2026, 10, 2));
      final PRInfo reloaded = await fetchWithCache(_listing(1), <String, Map<String, Object?>>{});
      expect(reloaded.fetchErrors, isEmpty);
      expect(reloaded.approvalCount, 1);
    });
  });
}
