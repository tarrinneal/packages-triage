// Copyright 2013 The Flutter Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:convert';

import 'package:collection/collection.dart';

import 'detail_cache.dart';
import 'github_client.dart';
import 'types.dart';
import 'utils.dart';

const Set<String> _botAccounts = <String>{'fluttergithubbot', 'engine-flutter-autoroll'};

const Set<String> _teamAssociations = <String>{'OWNER', 'MEMBER', 'COLLABORATOR'};

/// Whether [login] is an automated account.
///
/// [userType] is the `type` of the GitHub user object, if known.
bool isBot(String login, {String? userType}) =>
    userType == 'Bot' || login.endsWith('[bot]') || _botAccounts.contains(login);

/// Whether [login] is on the team.
///
/// GitHub only reports an `author_association` of MEMBER when the caller can
/// see the user's org membership, which is often not the case, so this also
/// checks the [roster] built by [fetchRoster].
bool isTeamMember(String login, String? association, Set<String> roster) =>
    _teamAssociations.contains(association) || roster.contains(login.toLowerCase());

Uri _apiUrl(String path, [Map<String, String>? query]) => Uri.https('api.github.com', path, query);

List<Map<String, dynamic>> _jsonList(GitHubResponse response) =>
    (response.json! as List<dynamic>).cast<Map<String, dynamic>>();

/// Fetches the open PRs in [repo], newest first.
///
/// If [limit] is given, stops once at least that many have been fetched and
/// returns only the first [limit].
Future<List<Map<String, dynamic>>> fetchOpenPRs(
  GitHubClient client,
  String repo, {
  int? limit,
}) async {
  final prs = <Map<String, dynamic>>[];
  for (var page = 1; ; page++) {
    final GitHubResponse response = await client.get(
      _apiUrl('/repos/$repo/pulls', <String, String>{
        'state': 'open',
        'per_page': '100',
        'page': '$page',
      }),
    );
    final List<Map<String, dynamic>> batch = _jsonList(response);
    prs.addAll(batch);
    if (limit != null && prs.length >= limit) {
      return prs.take(limit).toList();
    }
    if (batch.isEmpty || !response.hasNextPage) {
      return prs;
    }
  }
}

/// Fetches PR [number] in [repo], in the same form as [fetchOpenPRs] entries.
Future<Map<String, dynamic>> fetchSinglePR(GitHubClient client, String repo, int number) async {
  final GitHubResponse response = await client.get(_apiUrl('/repos/$repo/pulls/$number'));
  return response.json! as Map<String, dynamic>;
}

List<String> _requestedReviewers(Map<String, dynamic> pr) => <String>[
  for (final Map<String, dynamic> user
      in (pr['requested_reviewers'] as List<dynamic>? ?? const <dynamic>[])
          .cast<Map<String, dynamic>>())
    user['login']! as String,
];

/// Builds a set of team members' logins, in lowercase, that doesn't depend on
/// what org membership the caller can see.
///
/// GitHub only allows requesting reviews from collaborators, so everyone with
/// a pending review request on one of [prs] is included, as is everyone
/// mentioned in the repository's SUGGESTED_REVIEWERS.md.
Future<Set<String>> fetchRoster(
  GitHubClient client,
  String repo,
  Iterable<Map<String, dynamic>> prs, {
  void Function(String message)? onWarning,
}) async {
  final roster = <String>{
    for (final Map<String, dynamic> pr in prs)
      for (final String login in _requestedReviewers(pr)) login.toLowerCase(),
  };
  try {
    final GitHubResponse response = await client.get(
      _apiUrl('/repos/$repo/contents/SUGGESTED_REVIEWERS.md'),
    );
    final content = (response.json! as Map<String, dynamic>)['content']! as String;
    final String text = utf8.decode(base64.decode(content.replaceAll(RegExp(r'\s'), '')));
    roster.addAll(
      RegExp(r'@([A-Za-z0-9-]+)').allMatches(text).map((Match m) => m.group(1)!.toLowerCase()),
    );
  } on GitHubException catch (e) {
    // Not every repository has the file.
    if (e.statusCode != 404) {
      onWarning?.call('Could not read SUGGESTED_REVIEWERS.md: $e');
    }
  } on FormatException catch (e) {
    onWarning?.call('Could not read SUGGESTED_REVIEWERS.md: $e');
  }
  return roster;
}

/// Builds a [PRInfo] from a PR listing entry, without comment or review data.
PRInfo prInfoFromListing(Map<String, dynamic> pr, Set<String> roster) {
  final user = pr['user']! as Map<String, dynamic>;
  final login = user['login']! as String;
  final association = pr['author_association'] as String?;
  final ContributorType authorType;
  if (isBot(login, userType: user['type'] as String?)) {
    authorType = ContributorType.bot;
  } else if (isTeamMember(login, association, roster)) {
    authorType = ContributorType.member;
  } else {
    authorType = ContributorType.community;
  }
  final bool fromRoster =
      authorType == ContributorType.member && !_teamAssociations.contains(association);
  return PRInfo(
    number: pr['number']! as int,
    author: login,
    title: pr['title']! as String,
    url: pr['html_url']! as String,
    creationDate: DateTime.parse(pr['created_at']! as String),
    updatedDate: DateTime.parse(pr['updated_at']! as String),
    authorType: authorType,
    authorTypeFromRoster: fromRoster,
    isDraft: pr['draft'] as bool? ?? false,
    labels: <String>[
      for (final Map<String, dynamic> label
          in (pr['labels'] as List<dynamic>? ?? const <dynamic>[]).cast<Map<String, dynamic>>())
        label['name']! as String,
    ],
  );
}

/// Builds [PRInfo]s for every entry in [prs], fetching comments and reviews
/// for up to [concurrency] PRs at a time.
///
/// The result is in the same order as [prs]. [onProgress] is called as each
/// PR finishes. If [cache] is given, PRs that haven't changed since they were
/// saved there aren't fetched again; see [fetchPRDetails].
Future<List<PRInfo>> fetchAllPRDetails(
  GitHubClient client,
  String repo,
  List<Map<String, dynamic>> prs,
  Set<String> roster, {
  int concurrency = 8,
  DetailCache? cache,
  void Function(int done, int total, PRInfo pr)? onProgress,
}) async {
  final results = List<PRInfo?>.filled(prs.length, null);
  var next = 0;
  var done = 0;
  Future<void> worker() async {
    while (next < prs.length) {
      final int index = next++;
      final PRInfo pr = await fetchPRDetails(client, repo, prs[index], roster, cache: cache);
      results[index] = pr;
      onProgress?.call(++done, prs.length, pr);
    }
  }

  await Future.wait(<Future<void>>[for (var i = 0; i < concurrency; i++) worker()]);
  return <PRInfo>[for (final PRInfo? pr in results) pr!];
}

/// Builds a [PRInfo] from a PR listing entry and fetches its comments and
/// reviews.
///
/// The placement of drafts and bot PRs doesn't depend on comments, so they
/// aren't fetched for those unless [alwaysFetchDetails] is true.
///
/// If [cache] has comments and reviews saved for the PR since it last
/// changed, those are used instead of fetching them again. Otherwise the
/// fetched ones are saved there. Either way, who is on the team is decided
/// afterwards, since the [roster] can change between runs.
///
/// Failures are recorded in [PRInfo.fetchErrors] instead of being thrown, so
/// one bad PR doesn't stop the whole report.
Future<PRInfo> fetchPRDetails(
  GitHubClient client,
  String repo,
  Map<String, dynamic> listing,
  Set<String> roster, {
  bool alwaysFetchDetails = false,
  DetailCache? cache,
}) async {
  final PRInfo pr = prInfoFromListing(listing, roster);
  if (alwaysFetchDetails || !(pr.isDraft || pr.authorType == ContributorType.bot)) {
    final updatedAt = listing['updated_at']! as String;
    Map<_CommentType, List<_Activity>>? activity = _activityFromJson(
      cache?.lookup(pr.number, updatedAt),
    );
    if (activity == null) {
      activity = await _fetchActivity(client, repo, pr);
      // Incomplete data isn't saved, so that failed fetches are retried.
      if (pr.fetchErrors.isEmpty) {
        cache?.store(pr.number, updatedAt, _activityToJson(activity));
      }
    }
    for (final MapEntry<_CommentType, List<_Activity>> source in activity.entries) {
      _applyActivity(pr, source.key, source.value, roster);
    }
    pr.hasDetails = true;
  }

  // Add pending reviewers to the review states. If someone is in the pending
  // reviewers list, any review comment found above is older than the last
  // time review was re-requested, so replace those states.
  for (final String reviewer in _requestedReviewers(listing)) {
    pr.reviewers.putIfAbsent(reviewer, ReviewerStatus.new).requested = true;
  }
  return pr;
}

enum _CommentType {
  issue('conversation comments'),
  reviewInline('inline review comments'),
  reviewOverall('reviews');

  const _CommentType(this.description);

  final String description;
}

/// A comment or review: who left it, when, and for reviews, the state.
///
/// This is all triage needs, so it's all that [DetailCache] saves.
typedef _Activity = ({String login, String? association, DateTime date, String? state});

/// Fetches each type of comment on [pr], recording failures in
/// [PRInfo.fetchErrors].
Future<Map<_CommentType, List<_Activity>>> _fetchActivity(
  GitHubClient client,
  String repo,
  PRInfo pr,
) async {
  final activity = <_CommentType, List<_Activity>>{};
  // Fetch all three types of comments.
  for (final _CommentType commentType in _CommentType.values) {
    try {
      activity[commentType] = await _fetchComments(client, repo, pr.number, commentType);
    } on Exception catch (e) {
      pr.fetchErrors.add('Failed to fetch ${commentType.description}: $e');
    }
  }
  return activity;
}

/// Fetches every comment of [commentType] on PR [number], other than ones
/// from bots.
Future<List<_Activity>> _fetchComments(
  GitHubClient client,
  String repo,
  int number,
  _CommentType commentType,
) async {
  final (String path, String dateKey) = switch (commentType) {
    _CommentType.issue => ('/repos/$repo/issues/$number/comments', 'created_at'),
    _CommentType.reviewInline => ('/repos/$repo/pulls/$number/comments', 'created_at'),
    _CommentType.reviewOverall => ('/repos/$repo/pulls/$number/reviews', 'submitted_at'),
  };
  final activity = <_Activity>[];
  // Use the maximum page size, since every comment is needed: who is on the
  // team is decided later, and can change between runs.
  for (var page = 1; ; page++) {
    final GitHubResponse response = await client.get(
      _apiUrl(path, <String, String>{'per_page': '100', 'page': '$page'}),
    );
    final List<Map<String, dynamic>> comments = _jsonList(response);

    for (final comment in comments) {
      final user = comment['user'] as Map<String, dynamic>?;
      final dateString = comment[dateKey] as String?;
      final state = comment['state'] as String?;
      // Skip deleted users, and the caller's own unsubmitted (PENDING) review,
      // which has no date.
      if (user == null || dateString == null || state == 'PENDING') {
        continue;
      }
      final author = user['login']! as String;
      // Ignore bots.
      if (isBot(author, userType: user['type'] as String?)) {
        continue;
      }
      activity.add((
        login: author,
        association: comment['author_association'] as String?,
        date: DateTime.parse(dateString),
        state: state,
      ));
    }

    if (comments.isEmpty || !response.hasNextPage) {
      return activity;
    }
  }
}

/// Adds the [activity] of one [commentType] to [pr]: the newest comment from
/// each kind of commenter and, for reviews, team members' review states.
void _applyActivity(
  PRInfo pr,
  _CommentType commentType,
  List<_Activity> activity,
  Set<String> roster,
) {
  Comment? latestAuthorComment;
  Comment? latestMemberComment;
  Comment? latestNonMemberComment;
  final reviews = <_Activity>[];

  for (final item in activity) {
    final Comment currentComment = (username: item.login, date: item.date);
    if (item.login == pr.author) {
      if (latestAuthorComment == null || item.date.isAfter(latestAuthorComment.date)) {
        latestAuthorComment = currentComment;
      }
    } else if (isTeamMember(item.login, item.association, roster)) {
      if (commentType == _CommentType.reviewOverall) {
        reviews.add(item);
      }
      if (latestMemberComment == null || item.date.isAfter(latestMemberComment.date)) {
        latestMemberComment = currentComment;
      }
    } else {
      if (latestNonMemberComment == null || item.date.isAfter(latestNonMemberComment.date)) {
        latestNonMemberComment = currentComment;
      }
    }
  }

  // GitHub lists reviews oldest first; sort (stably) to be sure the latest
  // review wins.
  mergeSort(reviews, compare: (_Activity a, _Activity b) => a.date.compareTo(b.date));
  for (final review in reviews) {
    _applyReview(pr.reviewers.putIfAbsent(review.login, ReviewerStatus.new), review);
  }
  pr.authorComment = newestComment(<Comment?>[pr.authorComment, latestAuthorComment]);
  pr.memberComment = newestComment(<Comment?>[pr.memberComment, latestMemberComment]);
  pr.nonMemberComment = newestComment(<Comment?>[pr.nonMemberComment, latestNonMemberComment]);
}

/// The form that [DetailCache] saves [activity] in.
Map<String, dynamic> _activityToJson(Map<_CommentType, List<_Activity>> activity) =>
    <String, dynamic>{
      for (final MapEntry<_CommentType, List<_Activity>> source in activity.entries)
        source.key.name: <Map<String, Object?>>[
          for (final _Activity item in source.value)
            <String, Object?>{
              'login': item.login,
              'association': item.association,
              'date': item.date.toUtc().toIso8601String(),
              'state': item.state,
            },
        ],
    };

/// The inverse of [_activityToJson], or null if [json] is null or isn't in
/// that form.
Map<_CommentType, List<_Activity>>? _activityFromJson(Map<String, dynamic>? json) {
  if (json == null) {
    return null;
  }
  final activity = <_CommentType, List<_Activity>>{};
  for (final _CommentType commentType in _CommentType.values) {
    final Object? items = json[commentType.name];
    if (items is! List<dynamic>) {
      return null;
    }
    final list = <_Activity>[];
    for (final Object? item in items) {
      if (item case {
        'login': final String login,
        'association': final String? association,
        'date': final String date,
        'state': final String? state,
      }) {
        if (DateTime.tryParse(date) case final DateTime parsed) {
          list.add((login: login, association: association, date: parsed, state: state));
          continue;
        }
      }
      return null;
    }
    activity[commentType] = list;
  }
  return activity;
}

void _applyReview(ReviewerStatus status, _Activity review) {
  switch (review.state) {
    case 'APPROVED':
      status
        ..decision = ReviewState.approved
        ..decisionDate = review.date
        ..commented = false;
    case 'CHANGES_REQUESTED':
      status
        ..decision = ReviewState.changesRequested
        ..decisionDate = review.date
        ..commented = false;
    case 'COMMENTED':
      // A comment review doesn't withdraw an earlier approval or change
      // request, so keep the decision.
      status.commented = true;
    default:
      // DISMISSED.
      status
        ..decision = null
        ..decisionDate = null
        ..commented = false;
  }
}
