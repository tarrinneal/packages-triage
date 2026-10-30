// Copyright 2013 The Flutter Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:convert';
import 'dart:io';

import 'package:collection/collection.dart';

import 'detail_cache.dart';
import 'github_client.dart';
import 'triage.dart';
import 'types.dart';
import 'utils.dart';

const Set<String> _teamAssociations = <String>{'OWNER', 'MEMBER', 'COLLABORATOR'};

/// Whether [login] is an automated account.
///
/// [userType] is the `type` of the GitHub user object, if known.
bool isBot(String login, {String? userType, TriageConfig config = const TriageConfig()}) =>
    userType == 'Bot' || login.endsWith('[bot]') || config.botAccounts.contains(login);

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

/// Parses `SUGGESTED_REVIEWERS.md` content into a map from package name to a
/// formatted summary of suggested reviewers for that package and its
/// subpackages/platforms.
Map<String, String> parseSuggestedReviewers(String markdown) {
  final headerPattern = RegExp(r'^`([^`]+)`:\s*$');
  final bulletPattern = RegExp(r'^\s*-\s+(.+?)\s*$');
  final sections = <({String header, List<String> packages, List<String> bullets})>[];

  String? currentHeader;
  List<String>? currentPackages;
  var currentBullets = <String>[];

  void flush() {
    if (currentHeader != null && currentPackages != null && currentBullets.isNotEmpty) {
      sections.add((
        header: currentHeader!,
        packages: currentPackages!,
        bullets: List<String>.unmodifiable(currentBullets),
      ));
    }
    currentHeader = null;
    currentPackages = null;
    currentBullets = <String>[];
  }

  for (final String line in const LineSplitter().convert(markdown)) {
    final Match? headerMatch = headerPattern.firstMatch(line);
    if (headerMatch != null) {
      flush();
      final String rawHeader = headerMatch.group(1)!.trim();
      final List<String> packages = rawHeader
          .split(RegExp(r'[,/]'))
          .map((String s) => s.trim())
          .where((String s) => s.isNotEmpty)
          .toList();
      currentHeader = rawHeader;
      currentPackages = packages;
      continue;
    }
    if (currentHeader != null) {
      final Match? bulletMatch = bulletPattern.firstMatch(line);
      if (bulletMatch != null) {
        currentBullets.add(bulletMatch.group(1)!.replaceAll('**', '').trim());
      } else if (line.trim().isNotEmpty && !line.startsWith(' ')) {
        flush();
      }
    }
  }
  flush();

  final allPackages = <String>{for (final section in sections) ...section.packages};

  final result = <String, String>{};
  for (final pkg in allPackages) {
    final List<({String header, List<String> packages, List<String> bullets})> matching = sections
        .where((section) => section.packages.any((String p) => p == pkg || p.startsWith('${pkg}_')))
        .toList();
    if (matching.isEmpty) {
      continue;
    }
    final buffer = StringBuffer();
    for (var i = 0; i < matching.length; i++) {
      final ({String header, List<String> packages, List<String> bullets}) section = matching[i];
      if (i == 0) {
        buffer.writeln('Suggested reviewers (${section.header}):');
      } else {
        buffer.writeln('${section.header}:');
      }
      for (final String bullet in section.bullets) {
        buffer.writeln('• $bullet');
      }
    }
    result[pkg] = buffer.toString().trimRight();
  }
  return result;
}

/// Extracts individual GitHub usernames (`@login`) from a `CODEOWNERS` file,
/// ignoring `#` comments and `@org/team` team slugs.
Set<String> parseCodeowners(String content) {
  final owners = <String>{};
  final userPattern = RegExp(r'(?:^|\s)@([A-Za-z0-9-]+)(?=\s|$)');
  for (final String rawLine in const LineSplitter().convert(content)) {
    final String line = rawLine.trim();
    if (line.isEmpty || line.startsWith('#')) {
      continue;
    }
    final String withoutInlineComment = line.split(RegExp(r'\s+#')).first;
    for (final Match match in userPattern.allMatches(withoutInlineComment)) {
      owners.add(match.group(1)!.toLowerCase());
    }
  }
  return owners;
}

/// Parses a GitHub `owner/repo` slug from a git remote URL (HTTPS or SSH), or
/// returns `null` if [remoteUrl] is not a recognizable GitHub URL.
String? parseGitHubRepoFromRemoteUrl(String remoteUrl) {
  final String trimmed = remoteUrl.trim();
  final patterns = <RegExp>[
    RegExp(r'^https?://github\.com/([\w.-]+/[\w.-]+?)(?:\.git)?/*$'),
    RegExp(r'^git@github\.com:([\w.-]+/[\w.-]+?)(?:\.git)?/*$'),
    RegExp(r'^ssh://git@github\.com/([\w.-]+/[\w.-]+?)(?:\.git)?/*$'),
  ];
  for (final pattern in patterns) {
    final Match? match = pattern.firstMatch(trimmed);
    if (match != null) {
      return match.group(1);
    }
  }
  return null;
}

/// Attempts to detect the GitHub `owner/repo` for [workingDirectory] (by
/// default, [Directory.current]) from `git remote get-url origin`.
String? detectGitHubRepo({Directory? workingDirectory}) {
  try {
    final ProcessResult result = Process.runSync('git', const <String>[
      'remote',
      'get-url',
      'origin',
    ], workingDirectory: (workingDirectory ?? Directory.current).path);
    if (result.exitCode == 0 && result.stdout is String) {
      return parseGitHubRepoFromRemoteUrl(result.stdout as String);
    }
  } on ProcessException {
    // `git` is not installed or not available.
  }
  return null;
}

/// Builds a set of team members' logins, in lowercase, that doesn't depend on
/// what org membership the caller can see.
///
/// GitHub only allows requesting reviews from collaborators, so everyone with
/// a pending review request on one of [prs] is included, as is everyone
/// mentioned in the repository's [TriageConfig.rosterFile] (or, if that file is
/// absent, `.github/CODEOWNERS` or `CODEOWNERS`). If [suggestedReviewers] is
/// provided, it is populated with package reviewer descriptions parsed from
/// [TriageConfig.rosterFile].
Future<Set<String>> fetchRoster(
  GitHubClient client,
  String repo,
  Iterable<Map<String, dynamic>> prs, {
  Map<String, String>? suggestedReviewers,
  void Function(String message)? onWarning,
  TriageConfig config = const TriageConfig(),
}) async {
  final roster = <String>{
    for (final String member in config.teamMembers)
      member.replaceFirst(RegExp(r'^@'), '').toLowerCase(),
    for (final Map<String, dynamic> pr in prs)
      for (final String login in _requestedReviewers(pr)) login.toLowerCase(),
  };
  var foundSuggestedReviewers = false;
  final String? rosterFile = config.rosterFile;
  if (rosterFile != null && rosterFile.isNotEmpty) {
    final int colonIndex = rosterFile.indexOf(':');
    final String targetRepo = colonIndex > 0 ? rosterFile.substring(0, colonIndex) : repo;
    final String targetPath = colonIndex > 0 ? rosterFile.substring(colonIndex + 1) : rosterFile;
    try {
      final GitHubResponse response = await client.get(
        _apiUrl('/repos/$targetRepo/contents/$targetPath'),
      );
      final content = (response.json! as Map<String, dynamic>)['content']! as String;
      final String text = utf8.decode(base64.decode(content.replaceAll(RegExp(r'\s'), '')));
      roster.addAll(
        RegExp(r'@([A-Za-z0-9-]+)').allMatches(text).map((Match m) => m.group(1)!.toLowerCase()),
      );
      if (suggestedReviewers != null) {
        suggestedReviewers.addAll(parseSuggestedReviewers(text));
      }
      foundSuggestedReviewers = true;
    } on GitHubException catch (e) {
      // Not every repository has the file.
      if (e.statusCode != 404) {
        onWarning?.call('Could not read $rosterFile: $e');
      }
    } on FormatException catch (e) {
      onWarning?.call('Could not read $rosterFile: $e');
    }
  }

  if (!foundSuggestedReviewers) {
    for (final codeownersPath in const <String>['.github/CODEOWNERS', 'CODEOWNERS']) {
      try {
        final GitHubResponse response = await client.get(
          _apiUrl('/repos/$repo/contents/$codeownersPath'),
        );
        final content = (response.json! as Map<String, dynamic>)['content'] as String?;
        if (content != null) {
          final String text = utf8.decode(base64.decode(content.replaceAll(RegExp(r'\s'), '')));
          roster.addAll(parseCodeowners(text));
          break;
        }
      } on GitHubException catch (e) {
        if (e.statusCode != 404 && !e.message.startsWith('No recorded response')) {
          onWarning?.call('Could not read $codeownersPath: $e');
        }
      } on FormatException catch (e) {
        onWarning?.call('Could not read $codeownersPath: $e');
      }
    }
  }
  return roster;
}

/// Builds a [PRInfo] from a PR listing entry, without comment or review data.
PRInfo prInfoFromListing(
  Map<String, dynamic> pr,
  Set<String> roster, {
  String repo = '',
  TriageConfig config = const TriageConfig(),
}) {
  final user = pr['user']! as Map<String, dynamic>;
  final login = user['login']! as String;
  final association = pr['author_association'] as String?;
  final ContributorType authorType;
  if (isBot(login, userType: user['type'] as String?, config: config)) {
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
    repo: repo,
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
  TriageConfig config = const TriageConfig(),
}) async {
  final results = List<PRInfo?>.filled(prs.length, null);
  var next = 0;
  var done = 0;
  Future<void> worker() async {
    while (next < prs.length) {
      final int index = next++;
      final PRInfo pr = await fetchPRDetails(
        client,
        repo,
        prs[index],
        roster,
        cache: cache,
        config: config,
      );
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
  TriageConfig config = const TriageConfig(),
}) async {
  final PRInfo pr = prInfoFromListing(listing, roster, repo: repo, config: config);
  if (alwaysFetchDetails || !(pr.isDraft || pr.authorType == ContributorType.bot)) {
    final updatedAt = listing['updated_at']! as String;
    Map<_CommentType, List<_Activity>>? activity = _activityFromJson(
      cache?.lookup(pr.number, updatedAt),
    );
    if (activity == null) {
      activity = await _fetchActivity(client, repo, pr, config: config);
      // Incomplete data isn't saved, so that failed fetches are retried.
      if (pr.fetchErrors.isEmpty) {
        cache?.store(pr.number, updatedAt, _activityToJson(activity));
      }
    }
    for (final MapEntry<_CommentType, List<_Activity>> source in activity.entries) {
      _applyActivity(pr, source.key, source.value, roster);
    }
    pr.authorFollowUpComment = _earliestAuthorFollowUp(
      activity.values.expand((List<_Activity> items) => items),
      author: pr.author,
      memberComment: pr.memberComment,
    );
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

/// The repository where issues for [repo] are tracked.
///
/// Configured `repos` in [config] (by default `flutter/packages` and
/// `flutter/core-packages`) track their issues in [TriageConfig.issuesRepo]
/// (`flutter/flutter` by default).
String defaultIssuesRepoFor(String repo, {TriageConfig config = const TriageConfig()}) =>
    (config.issuesRepo != null && config.repos.contains(repo)) ? config.issuesRepo! : repo;

/// Fetches open issues in [issuesRepo] that belong on the issues page.
///
/// When [teamLabel] is set (or defaults to [TriageConfig.issueTeamLabel] for
/// [TriageConfig.issuesRepo]), fetches all open [teamLabel] issues (paginated)
/// plus any untriaged [fyiLabel] issues (`-label:<triagedLabel>`).
///
/// For other repositories when [teamLabel] is not set, queries open issues in
/// [issuesRepo] directly.
Future<List<Map<String, dynamic>>> fetchTriageIssues(
  GitHubClient client,
  String issuesRepo, {
  required DateTime now,
  int? limit,
  String? teamLabel,
  String? fyiLabel,
  String? triagedLabel,
  TriageConfig config = const TriageConfig(),
}) async {
  final bool isConfiguredIssuesRepo = config.issuesRepo != null && issuesRepo == config.issuesRepo;
  final String? effectiveTeamLabel =
      teamLabel ?? (isConfiguredIssuesRepo ? config.issueTeamLabel : null);
  final String? effectiveFyiLabel =
      fyiLabel ?? (isConfiguredIssuesRepo ? config.issueFyiLabel : null);
  final String effectiveTriagedLabel = triagedLabel ?? config.issueTriagedLabel;
  final byNumber = <int, Map<String, dynamic>>{};

  if (effectiveTeamLabel != null && effectiveTeamLabel.isNotEmpty) {
    for (var page = 1; ; page++) {
      final GitHubResponse response = await client.get(
        _apiUrl('/repos/$issuesRepo/issues', <String, String>{
          'state': 'open',
          'labels': effectiveTeamLabel,
          'sort': 'updated',
          'direction': 'desc',
          'per_page': '100',
          'page': '$page',
        }),
      );
      final List<Map<String, dynamic>> batch = _jsonList(response);
      for (final item in batch) {
        if (item.containsKey('pull_request')) {
          continue;
        }
        final number = item['number']! as int;
        byNumber[number] = item;
        if (limit != null && byNumber.length >= limit) {
          return byNumber.values.take(limit).toList();
        }
      }
      if (batch.isEmpty || !response.hasNextPage) {
        break;
      }
    }
  }

  final searchQueries = <String>[
    if (effectiveTeamLabel != null && effectiveTeamLabel.isNotEmpty) ...<String>[
      if (effectiveFyiLabel != null && effectiveFyiLabel.isNotEmpty)
        'repo:$issuesRepo is:issue is:open label:$effectiveFyiLabel -label:$effectiveTriagedLabel',
    ] else
      'repo:$issuesRepo is:issue is:open',
  ];
  for (final query in searchQueries) {
    final GitHubResponse response = await client.get(
      _apiUrl('/search/issues', <String, String>{
        'q': query,
        'sort': 'updated',
        'order': 'desc',
        'per_page': '100',
      }),
    );
    final List<Map<String, dynamic>> items =
        ((response.json! as Map<String, dynamic>)['items'] as List<dynamic>? ?? const <dynamic>[])
            .cast<Map<String, dynamic>>();
    for (final item in items) {
      if (item.containsKey('pull_request')) {
        continue;
      }
      final number = item['number']! as int;
      byNumber[number] = item;
      if (limit != null && byNumber.length >= limit) {
        return byNumber.values.take(limit).toList();
      }
    }
  }
  return byNumber.values.toList();
}

/// Builds an [IssueInfo] from a GitHub issue object, without comment data.
IssueInfo issueInfoFromListing(
  Map<String, dynamic> issue,
  Set<String> roster, {
  TriageConfig config = const TriageConfig(),
}) {
  final user = issue['user']! as Map<String, dynamic>;
  final login = user['login']! as String;
  final association = issue['author_association'] as String?;
  final ContributorType authorType;
  if (isBot(login, userType: user['type'] as String?, config: config)) {
    authorType = ContributorType.bot;
  } else if (isTeamMember(login, association, roster)) {
    authorType = ContributorType.member;
  } else {
    authorType = ContributorType.community;
  }
  return IssueInfo(
    number: issue['number']! as int,
    author: login,
    title: issue['title']! as String,
    url: issue['html_url']! as String,
    creationDate: DateTime.parse(issue['created_at']! as String),
    updatedDate: DateTime.parse(issue['updated_at']! as String),
    authorType: authorType,
    labels: <String>[
      for (final Map<String, dynamic> label
          in (issue['labels'] as List<dynamic>? ?? const <dynamic>[]).cast<Map<String, dynamic>>())
        label['name']! as String,
    ],
    assignees: <String>[
      for (final Map<String, dynamic> assignee
          in (issue['assignees'] as List<dynamic>? ?? const <dynamic>[])
              .cast<Map<String, dynamic>>())
        assignee['login']! as String,
    ],
    commentCount: issue['comments'] as int? ?? -1,
  );
}

/// Builds [IssueInfo]s for every entry in [issues], fetching comments for up
/// to [concurrency] issues at a time.
Future<List<IssueInfo>> fetchAllIssueDetails(
  GitHubClient client,
  String issuesRepo,
  List<Map<String, dynamic>> issues,
  Set<String> roster, {
  int concurrency = 8,
  DetailCache? cache,
  DateTime? now,
  String? teamLabel,
  String? triagedLabel,
  void Function(int done, int total, IssueInfo issue)? onProgress,
  TriageConfig config = const TriageConfig(),
}) async {
  final results = List<IssueInfo?>.filled(issues.length, null);
  var next = 0;
  var done = 0;
  Future<void> worker() async {
    while (next < issues.length) {
      final int index = next++;
      final IssueInfo issue = await fetchIssueDetails(
        client,
        issuesRepo,
        issues[index],
        roster,
        cache: cache,
        now: now,
        teamLabel: teamLabel,
        triagedLabel: triagedLabel,
        config: config,
      );
      results[index] = issue;
      done++;
      onProgress?.call(done, issues.length, issue);
    }
  }

  await Future.wait(<Future<void>>[for (var i = 0; i < concurrency; i++) worker()]);
  return <IssueInfo>[for (final IssueInfo? issue in results) issue!];
}

/// Builds an [IssueInfo] from a GitHub issue entry and fetches its comments
/// when needed.
Future<IssueInfo> fetchIssueDetails(
  GitHubClient client,
  String issuesRepo,
  Map<String, dynamic> listing,
  Set<String> roster, {
  DetailCache? cache,
  DateTime? now,
  String? teamLabel,
  String? triagedLabel,
  TriageConfig config = const TriageConfig(),
}) async {
  final IssueInfo issue = issueInfoFromListing(listing, roster, config: config);
  if (issue.commentCount == 0) {
    issue.hasDetails = true;
    return issue;
  }
  final updatedAt = listing['updated_at']! as String;
  List<_Activity>? comments = _issueCommentsFromJson(cache?.lookup(issue.number, updatedAt));
  if (comments == null) {
    final String effectiveTeamLabel = teamLabel ?? (config.issueTeamLabel ?? '');
    final String effectiveTriagedLabel = triagedLabel ?? config.issueTriagedLabel;
    final bool isAlreadyTriagedTeamIssue =
        effectiveTeamLabel.isNotEmpty &&
        issue.labels.contains(effectiveTeamLabel) &&
        effectiveTriagedLabel.isNotEmpty &&
        issue.labels.contains(effectiveTriagedLabel) &&
        issuePriority(issue, config: config) != null &&
        !hasWaitingForResponseLabel(issue.labels, config: config);
    if (now != null &&
        isAlreadyTriagedTeamIssue &&
        issue.updatedDate.isBefore(now.subtract(const Duration(days: 60)))) {
      return issue;
    }
    try {
      comments = await _fetchComments(
        client,
        issuesRepo,
        issue.number,
        _CommentType.issue,
        config: config,
      );
      cache?.store(issue.number, updatedAt, _issueCommentsToJson(comments));
    } on Exception catch (e) {
      issue.fetchErrors.add('Failed to fetch issue comments: $e');
      return issue;
    }
  }
  for (final _Activity item in comments) {
    final Comment currentComment = (username: item.login, date: item.date);
    if (item.login == issue.author) {
      if (issue.authorComment == null || item.date.isAfter(issue.authorComment!.date)) {
        issue.authorComment = currentComment;
      }
    } else if (isTeamMember(item.login, item.association, roster)) {
      if (issue.memberComment == null || item.date.isAfter(issue.memberComment!.date)) {
        issue.memberComment = currentComment;
      }
    } else {
      if (issue.nonMemberComment == null || item.date.isAfter(issue.nonMemberComment!.date)) {
        issue.nonMemberComment = currentComment;
      }
    }
  }
  issue.authorFollowUpComment = _earliestAuthorFollowUp(
    comments,
    author: issue.author,
    memberComment: issue.memberComment,
  );
  issue.hasDetails = true;
  return issue;
}

Comment? _earliestAuthorFollowUp(
  Iterable<_Activity> activity, {
  required String author,
  required Comment? memberComment,
}) {
  if (memberComment == null) {
    return null;
  }
  Comment? earliest;
  for (final item in activity) {
    if (item.login == author && item.date.isAfter(memberComment.date)) {
      if (earliest == null || item.date.isBefore(earliest.date)) {
        earliest = (username: item.login, date: item.date);
      }
    }
  }
  return earliest;
}

Map<String, dynamic> _issueCommentsToJson(List<_Activity> comments) => <String, dynamic>{
  'issue': <Map<String, Object?>>[
    for (final _Activity item in comments)
      <String, Object?>{
        'login': item.login,
        'association': item.association,
        'date': item.date.toUtc().toIso8601String(),
        'state': item.state,
      },
  ],
};

List<_Activity>? _issueCommentsFromJson(Map<String, dynamic>? json) {
  final Object? items = json?['issue'];
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
  return list;
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
  PRInfo pr, {
  TriageConfig config = const TriageConfig(),
}) async {
  final activity = <_CommentType, List<_Activity>>{};
  // Fetch all three types of comments.
  for (final _CommentType commentType in _CommentType.values) {
    try {
      activity[commentType] = await _fetchComments(
        client,
        repo,
        pr.number,
        commentType,
        config: config,
      );
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
  _CommentType commentType, {
  TriageConfig config = const TriageConfig(),
}) async {
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
      if (isBot(author, userType: user['type'] as String?, config: config)) {
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
