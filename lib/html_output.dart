// Copyright 2013 The Flutter Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:io';

import 'report_state.dart';
import 'triage.dart';
import 'types.dart';
import 'utils.dart';

/// The team page that [writeHtmlReport] writes next to [communityFile], e.g.
/// `triage_team.html` for `triage.html`.
File teamPageFileFor(File communityFile) => File('${_stem(communityFile.path)}_team.html');

/// The issues page that [writeHtmlReport] writes next to [communityFile], e.g.
/// `triage_issues.html` for `triage.html`.
File issuesPageFileFor(File communityFile) => File('${_stem(communityFile.path)}_issues.html');

/// The state file used for NEW and MOVED badges, next to [communityFile],
/// e.g. `triage.state.json` for `triage.html`.
File stateFileFor(File communityFile) => File('${_stem(communityFile.path)}.state.json');

int _lastSeparator(String path) {
  final int slash = path.lastIndexOf('/');
  final int backslash = path.lastIndexOf(r'\');
  return slash > backslash ? slash : backslash;
}

String _stem(String path) {
  final int dot = path.lastIndexOf('.');
  return dot > _lastSeparator(path) + 1 ? path.substring(0, dot) : path;
}

String _basename(String path) => path.substring(_lastSeparator(path) + 1);

/// Writes the report as linked HTML pages: community and bot PRs to
/// [communityFile], team PRs to [teamPageFileFor] it, and actionable package
/// issues to [issuesPageFileFor] it.
///
/// [prs] must already be sorted with [comparePRs], and [issues] with
/// [compareIssues]. PRs with any of [hiddenLabels] start out hidden unless
/// [showHiddenByDefault] is true, and a button on each page shows or hides
/// them. [previous] placements, if given, are used for NEW and MOVED badges.
/// [note] is shown under the header, e.g. to say the report is partial.
void writeHtmlReport({
  required String repo,
  required List<PRAnalysis> prs,
  required File communityFile,
  required DateTime generatedAt,
  List<IssueAnalysis> issues = const <IssueAnalysis>[],
  String? issuesRepo,
  Map<int, PreviousPlacement>? previous,
  Set<String> hiddenLabels = defaultHiddenLabels,
  bool showHiddenByDefault = false,
  String? note,
}) {
  final File issuesFile = issuesPageFileFor(communityFile);
  final files = <ReportPage, File>{
    ReportPage.community: communityFile,
    ReportPage.team: teamPageFileFor(communityFile),
  };
  for (final ReportPage page in ReportPage.values) {
    final String html = _PageRenderer(
      page: page,
      repo: repo,
      prs: prs,
      issuesCount: issues.length,
      files: files,
      issuesFile: issuesFile,
      generatedAt: generatedAt,
      previous: previous,
      hiddenLabels: hiddenLabels,
      showHiddenByDefault: showHiddenByDefault,
      note: note,
    ).render();
    files[page]!
      ..createSync(recursive: true)
      ..writeAsStringSync(html);
  }
  final String issuesHtml = _IssuesPageRenderer(
    issuesRepo: issuesRepo ?? repo,
    prs: prs,
    issues: issues,
    files: files,
    issuesFile: issuesFile,
    generatedAt: generatedAt,
    note: note,
  ).render();
  issuesFile
    ..createSync(recursive: true)
    ..writeAsStringSync(issuesHtml);
}

class _PageRenderer {
  _PageRenderer({
    required this.page,
    required this.repo,
    required this.prs,
    required this.issuesCount,
    required this.files,
    required this.issuesFile,
    required this.generatedAt,
    required this.previous,
    required this.hiddenLabels,
    required this.showHiddenByDefault,
    required this.note,
  }) : pagePRs = prs.where((PRAnalysis a) => a.page == page).toList();

  final ReportPage page;
  final String repo;
  final List<PRAnalysis> prs;
  final List<PRAnalysis> pagePRs;
  final int issuesCount;
  final Map<ReportPage, File> files;
  final File issuesFile;
  final DateTime generatedAt;
  final Map<int, PreviousPlacement>? previous;
  final Set<String> hiddenLabels;
  final bool showHiddenByDefault;
  final String? note;

  final StringBuffer _out = StringBuffer();

  bool _startsHidden(PRAnalysis analysis) =>
      hiddenLabels.isNotEmpty && showHiddenByDefault != hasHiddenLabel(analysis.pr, hiddenLabels);

  List<PRAnalysis> _inSection(Section section) =>
      pagePRs.where((PRAnalysis a) => a.section == section).toList();

  int _visibleCount(Section section) =>
      _inSection(section).where((PRAnalysis a) => !_startsHidden(a)).length;

  String render() {
    final sections = <Section>[
      for (final Section section in sectionsFor(page))
        if (section != Section.loadError || _inSection(section).isNotEmpty) section,
    ];
    _writeHead();
    _writeHeader(sections);
    sections.forEach(_writeSection);
    _writeLegend();
    _out
      ..writeln('<script>')
      ..write(_script)
      ..writeln('</script>')
      ..writeln('</body>')
      ..writeln('</html>');
    return _out.toString();
  }

  void _writeHead() {
    _out.write('''
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>${_escape('$repo: ${pageTitle(page)}')}</title>
<style>
$_css</style>
</head>
<body data-hidden-labels="${_escape(hiddenLabels.join('|'))}" data-show-hidden-default="$showHiddenByDefault">
''');
  }

  void _writeHeader(List<Section> sections) {
    final pageLinks = <String>[
      for (final ReportPage other in ReportPage.values)
        _pageLink(other, prs.where((PRAnalysis a) => a.page == other).length),
      '<a href="${_escape(_basename(issuesFile.path))}">Issues ($issuesCount)</a>',
    ];
    final sectionLinks = <String>[for (final section in sections) _sectionLink(section)];
    final int hiddenCount = pagePRs
        .where((PRAnalysis a) => hasHiddenLabel(a.pr, hiddenLabels))
        .length;
    final int followUpCount = pagePRs.where((PRAnalysis a) => a.isFollowUp).length;
    final buttonLabel = '${hiddenLabels.join('/')} PRs ($hiddenCount)';
    final int failed = _inSection(Section.loadError).length;
    _out.write('''
<header>
<h1>${_escape(repo)} · ${pageTitle(page)}</h1>
<nav class="pages">${pageLinks.join(' · ')}</nav>
<p class="meta">Generated ${_escape(formatAsMinute(generatedAt))} · ${pagePRs.length} open PRs on this page</p>
<nav class="sections">${sectionLinks.join(' · ')}</nav>
<div class="controls">
<input id="filter" type="search" placeholder="Filter by number, title, author, label, reviewer, or next step" autocomplete="off">
<button id="toggle-followup" type="button" aria-pressed="false"${followUpCount == 0 ? ' disabled' : ''}>Follow-up PRs ($followUpCount)</button>
''');
    if (hiddenLabels.isNotEmpty) {
      _out.writeln(
        '<button id="toggle-hidden" type="button" data-label="${_escape(buttonLabel)}" '
        'aria-pressed="$showHiddenByDefault"${hiddenCount == 0 ? ' disabled' : ''}>'
        '${showHiddenByDefault ? 'Hide' : 'Show'} ${_escape(buttonLabel)}</button>',
      );
    }
    _out.writeln('</div>');
    if (failed > 0) {
      _out.writeln(
        '<p class="banner">⚠️ $failed ${failed == 1 ? 'PR' : 'PRs'} failed to load, so '
        '${failed == 1 ? 'it is' : 'they are'} listed under "Failed to load" instead of '
        'being sorted. Rerun to retry.</p>',
      );
    }
    final String? note = this.note;
    if (note != null) {
      _out.writeln('<p class="note">${_escape(note)}</p>');
    }
    _out.writeln('</header>');
  }

  String _pageLink(ReportPage other, int count) {
    final label = '${pageTitle(other)} ($count)';
    if (other == page) {
      return '<strong>$label</strong>';
    }
    return '<a href="${_escape(_basename(files[other]!.path))}">$label</a>';
  }

  String _sectionLink(Section section) =>
      '<a href="#${section.name}">${_escape(sectionTitle(section, page))} '
      '(<span data-count="${section.name}">${_visibleCount(section)}</span>)</a>';

  void _writeSection(Section section) {
    final List<PRAnalysis> rows = _inSection(section);
    final bool open = section != Section.bots && section != Section.drafts;
    _out.write('''
<details id="${section.name}" data-section="${section.name}"${open ? ' open' : ''}>
<summary><h2>${_escape(sectionTitle(section, page))} (<span data-count="${section.name}">${_visibleCount(section)}</span>)</h2></summary>
<table>
<thead>
<tr>
<th data-sort="number" data-numeric>PR</th>
<th data-sort="title">Title</th>
<th data-sort="author">Author</th>
<th data-sort="next">Next step</th>
<th data-sort="waiting" data-numeric>Waiting</th>
<th data-sort="reviewers">Reviewers</th>
<th data-sort="activity" data-numeric>Last activity</th>
<th data-sort="opened" data-numeric>Opened</th>
</tr>
</thead>
<tbody>
''');
    if (rows.isEmpty) {
      _out.writeln('<tr><td colspan="8" class="empty">None</td></tr>');
    }
    rows.forEach(_writeRow);
    _out.write('''
</tbody>
</table>
</details>
''');
  }

  void _writeRow(PRAnalysis analysis) {
    final PRInfo pr = analysis.pr;
    final DateTime now = generatedAt;
    final classes = <String>[
      if (analysis.urgency == Urgency.notYet && analysis.section != Section.loadError) 'not-due',
      if (pr.isDraft) 'draft',
    ];
    final Badge? badge = badgeFor(analysis, previous);
    final List<ReviewerEntry> reviewers = reviewerEntries(pr);
    final String search = <Object>[
      '#${pr.number}',
      if (pr.repo.isNotEmpty) pr.repo,
      pr.title,
      pr.author,
      ...pr.labels,
      ...pr.reviewers.keys,
      analysis.nextStep,
      if (analysis.isFollowUp) 'follow-up',
    ].join(' ').toLowerCase();
    final _Activity activity = _activity(pr, now);
    final waitingClass = analysis.section == Section.loadError
        ? 'waiting'
        : 'waiting urgency-${analysis.urgency.name}';

    _out
      ..write('<tr')
      ..write(classes.isEmpty ? '' : ' class="${classes.join(' ')}"')
      ..write(' data-number="${pr.number}"')
      ..write(' data-labels="${_escape(pr.labels.join('|'))}"')
      ..write(analysis.isFollowUp ? ' data-followup="true"' : '')
      ..write(' data-search="${_escape(search)}"')
      ..write(' data-waiting="${analysis.waitingDays}"')
      ..write(' data-activity="${activity.days}"')
      ..write(' data-opened="${daysBetween(pr.creationDate, now)}"')
      ..write(_startsHidden(analysis) ? ' hidden' : '')
      ..writeln('>')
      ..write('<td class="pr"><a href="${_escape(pr.url)}" target="_blank" rel="noopener">')
      ..write('#${pr.number}</a>')
      ..write(
        badge == null
            ? ''
            : ' <span class="badge ${badge.label.toLowerCase()}" '
                  'title="${_escape(badge.description)}">${badge.label}</span>',
      )
      ..write(
        analysis.isFollowUp
            ? ' <span class="badge follow-up" '
                  'title="The author replied after the team\'s last comment">FOLLOW-UP</span>'
            : '',
      )
      ..writeln('</td>')
      ..write('<td class="title">${_escape(pr.title)}')
      ..write(_labelChips(pr))
      ..writeln('</td>')
      ..writeln(
        '<td class="author">${emojiForContributorType(pr.authorType)} ${_escape(pr.author)}</td>',
      )
      ..writeln('<td class="next">${_escape(analysis.nextStep)}</td>')
      ..writeln(
        '<td class="$waitingClass" title="${_escape(analysis.reasons.join('\n'))}">'
        '${_escape(waitingLabel(analysis))}</td>',
      )
      ..write('<td class="reviewers">')
      ..write(
        reviewers
            .map((ReviewerEntry e) => '<span class="reviewer">${_escape(reviewerText(e))}</span>')
            .join(' '),
      )
      ..writeln('</td>')
      ..writeln(
        '<td class="activity" title="${_escape(activity.details)}">'
        '${_escape(activity.summary)}</td>',
      )
      ..writeln('<td class="opened">${formatAsDay(pr.creationDate)}</td>')
      ..writeln('</tr>');
  }

  String _labelChips(PRInfo pr) {
    final chips = <String>[
      if (pr.repo.isNotEmpty && pr.repo != repo)
        '<span class="label repo-label">${_escape(pr.repo.split('/').last)}</span>',
      for (final String label in pr.labels)
        if (isRoutingLabel(label) || hiddenLabels.contains(label)) _labelChip(label),
    ];
    return chips.isEmpty ? '' : '<div class="labels">${chips.join()}</div>';
  }

  String _labelChip(String label) {
    final classes = hiddenLabels.contains(label) ? 'label hidden-label' : 'label';
    return '<span class="$classes">${_escape(label)}</span>';
  }

  void _writeLegend() {
    _out.write('''
<section class="legend">
<h2>Legend</h2>
<ul>
<li>Sections are sorted by how long each PR has been waiting on whoever needs to act next. Hover over a waiting time to see why a PR is where it is.</li>
<li>Waiting: <span class="urgency-notYet">under ${dueDays}d</span> · <span class="urgency-due">due at ${dueDays}d</span> · <span class="urgency-overdue">overdue at ${overdueDays}d</span> · <span class="urgency-critical">critical at ${criticalDays}d</span> (community PRs waiting this long on their author are candidates for closing). Rows that aren't due yet are dimmed.</li>
<li>Reviewers: ${emojiForReviewState(ReviewState.changesRequested)} changes requested · ${emojiForReviewState(ReviewState.commented)} commented · ${emojiForReviewState(ReviewState.pending)} review requested · ${emojiForReviewState(ReviewState.approved)} approved</li>
<li>Authors: ${emojiForContributorType(ContributorType.community)} community · ${emojiForContributorType(ContributorType.member)} team · ${emojiForContributorType(ContributorType.bot)} bot</li>
<li><span class="badge follow-up">FOLLOW-UP</span> author replied after the team's last comment · <span class="badge new">NEW</span> not in the previous report · <span class="badge moved">MOVED</span> in a different section in the previous report</li>
</ul>
</section>
''');
  }
}

class _IssuesPageRenderer {
  _IssuesPageRenderer({
    required this.issuesRepo,
    required this.prs,
    required this.issues,
    required this.files,
    required this.issuesFile,
    required this.generatedAt,
    required this.note,
  });

  final String issuesRepo;
  final List<PRAnalysis> prs;
  final List<IssueAnalysis> issues;
  final Map<ReportPage, File> files;
  final File issuesFile;
  final DateTime generatedAt;
  final String? note;

  final StringBuffer _out = StringBuffer();

  List<IssueAnalysis> _inSection(IssueSection section) =>
      issues.where((IssueAnalysis a) => a.section == section).toList();

  String render() {
    final sections = <IssueSection>[
      for (final IssueSection section in IssueSection.values)
        if (section != IssueSection.loadError || _inSection(section).isNotEmpty) section,
    ];
    _out.write('''
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>${_escape('$issuesRepo: Package Issues')}</title>
<style>
$_css</style>
</head>
<body data-hidden-labels="" data-show-hidden-default="true">
''');
    _writeHeader(sections);
    sections.forEach(_writeSection);
    _writeLegend();
    _out
      ..writeln('<script>')
      ..write(_script)
      ..writeln('</script>')
      ..writeln('</body>')
      ..writeln('</html>');
    return _out.toString();
  }

  void _writeHeader(List<IssueSection> sections) {
    final pageLinks = <String>[
      for (final ReportPage other in ReportPage.values)
        _otherPageLink(other, prs.where((PRAnalysis a) => a.page == other).length),
      '<strong>Issues (${issues.length})</strong>',
    ];
    final sectionLinks = <String>[for (final section in sections) _sectionLink(section)];
    final int followUpCount = issues.where((IssueAnalysis a) => a.isFollowUp).length;
    final int failed = _inSection(IssueSection.loadError).length;
    _out.write('''
<header>
<h1>${_escape(issuesRepo)} · Package Issues</h1>
<nav class="pages">${pageLinks.join(' · ')}</nav>
<p class="meta">Generated ${_escape(formatAsMinute(generatedAt))} · ${issues.length} actionable package issues on this page</p>
<nav class="sections">${sectionLinks.join(' · ')}</nav>
<div class="controls">
<input id="filter" type="search" placeholder="Filter by number, title, author, label, assignee, or next step" autocomplete="off">
<button id="toggle-followup" type="button" aria-pressed="false"${followUpCount == 0 ? ' disabled' : ''}>Follow-up issues ($followUpCount)</button>
</div>
''');
    if (failed > 0) {
      _out.writeln(
        '<p class="banner">⚠️ $failed ${failed == 1 ? 'issue' : 'issues'} failed to load, so '
        '${failed == 1 ? 'it is' : 'they are'} listed under "Failed to load" instead of '
        'being sorted. Rerun to retry.</p>',
      );
    }
    final String? note = this.note;
    if (note != null) {
      _out.writeln('<p class="note">${_escape(note)}</p>');
    }
    _out.writeln('</header>');
  }

  String _otherPageLink(ReportPage other, int count) =>
      '<a href="${_escape(_basename(files[other]!.path))}">${pageTitle(other)} ($count)</a>';

  String _sectionLink(IssueSection section) =>
      '<a href="#${section.name}">${_escape(issueSectionTitle(section))} '
      '(<span data-count="${section.name}">${_inSection(section).length}</span>)</a>';

  void _writeSection(IssueSection section) {
    final List<IssueAnalysis> rows = _inSection(section);
    _out.write('''
<details id="${section.name}" data-section="${section.name}" open>
<summary><h2>${_escape(issueSectionTitle(section))} (<span data-count="${section.name}">${rows.length}</span>)</h2></summary>
<table>
<thead>
<tr>
<th data-sort="number" data-numeric>Issue</th>
<th data-sort="title">Title</th>
<th data-sort="author">Author</th>
<th data-sort="next">Next step</th>
<th data-sort="waiting" data-numeric>Waiting</th>
<th data-sort="assignees">Assignees</th>
<th data-sort="activity" data-numeric>Last activity</th>
<th data-sort="opened" data-numeric>Opened</th>
</tr>
</thead>
<tbody>
''');
    if (rows.isEmpty) {
      _out.writeln('<tr><td colspan="8" class="empty">None</td></tr>');
    }
    rows.forEach(_writeRow);
    _out.write('''
</tbody>
</table>
</details>
''');
  }

  void _writeRow(IssueAnalysis analysis) {
    final IssueInfo issue = analysis.issue;
    final DateTime now = generatedAt;
    final classes = <String>[
      if (analysis.urgency == Urgency.notYet && analysis.section != IssueSection.loadError)
        'not-due',
    ];
    final String search = <Object>[
      '#${issue.number}',
      issue.title,
      issue.author,
      ...issue.labels,
      ...issue.assignees,
      analysis.nextStep,
      if (analysis.isFollowUp) 'follow-up',
    ].join(' ').toLowerCase();
    final _Activity activity = _issueActivity(issue, now);
    final waitingClass = analysis.section == IssueSection.loadError
        ? 'waiting'
        : 'waiting urgency-${analysis.urgency.name}';

    _out
      ..write('<tr')
      ..write(classes.isEmpty ? '' : ' class="${classes.join(' ')}"')
      ..write(' data-number="${issue.number}"')
      ..write(' data-labels="${_escape(issue.labels.join('|'))}"')
      ..write(analysis.isFollowUp ? ' data-followup="true"' : '')
      ..write(' data-search="${_escape(search)}"')
      ..write(' data-waiting="${analysis.waitingDays}"')
      ..write(' data-activity="${activity.days}"')
      ..write(' data-opened="${daysBetween(issue.creationDate, now)}"')
      ..writeln('>')
      ..write('<td class="pr"><a href="${_escape(issue.url)}" target="_blank" rel="noopener">')
      ..write('#${issue.number}</a>')
      ..write(
        analysis.isFollowUp
            ? ' <span class="badge follow-up" '
                  'title="The author replied after the team\'s last comment">FOLLOW-UP</span>'
            : '',
      )
      ..writeln('</td>')
      ..write('<td class="title">${_escape(issue.title)}')
      ..write(_issueLabelChips(issue))
      ..writeln('</td>')
      ..writeln(
        '<td class="author">${emojiForContributorType(issue.authorType)} ${_escape(issue.author)}</td>',
      )
      ..writeln('<td class="next">${_escape(analysis.nextStep)}</td>')
      ..writeln(
        '<td class="$waitingClass" title="${_escape(analysis.reasons.join('\n'))}">'
        '${_escape(issueWaitingLabel(analysis))}</td>',
      )
      ..write('<td class="reviewers">')
      ..write(
        issue.assignees.map((String a) => '<span class="reviewer">@${_escape(a)}</span>').join(' '),
      )
      ..writeln('</td>')
      ..writeln(
        '<td class="activity" title="${_escape(activity.details)}">'
        '${_escape(activity.summary)}</td>',
      )
      ..writeln('<td class="opened">${formatAsDay(issue.creationDate)}</td>')
      ..writeln('</tr>');
  }

  String _issueLabelChips(IssueInfo issue) {
    final chips = <String>[
      for (final String label in issue.labels)
        if (isIssueDisplayLabel(label))
          '<span class="label${label == 'P0'
              ? ' priority-p0'
              : label == 'P1'
              ? ' priority-p1'
              : ''}">${_escape(label)}</span>',
    ];
    return chips.isEmpty ? '' : '<div class="labels">${chips.join()}</div>';
  }

  void _writeLegend() {
    _out.write('''
<section class="legend">
<h2>Legend</h2>
<ul>
<li>Actionable package issues from ${_escape(issuesRepo)} labeled <code>team-ecosystem</code> or <code>fyi-ecosystem</code>. Already-triaged P2/P3 issues that are not waiting on a response are omitted.</li>
<li><span class="badge follow-up">FOLLOW-UP</span> issue author replied after a team member's comment.</li>
</ul>
</section>
''');
  }
}

typedef _Activity = ({String summary, String details, int days});

_Activity _activity(PRInfo pr, DateTime now) {
  if (!pr.hasDetails) {
    final int days = daysBetween(pr.updatedDate, now);
    return (
      summary: 'updated ${days}d ago',
      details: 'Updated ${formatAsDay(pr.updatedDate)}. Comments were not fetched.',
      days: days,
    );
  }
  return _commentActivity(
    authorComment: pr.authorComment,
    authorFollowUpComment: pr.authorFollowUpComment,
    memberComment: pr.memberComment,
    nonMemberComment: pr.nonMemberComment,
    creationDate: pr.creationDate,
    now: now,
  );
}

_Activity _issueActivity(IssueInfo issue, DateTime now) {
  if (!issue.hasDetails) {
    final int days = daysBetween(issue.updatedDate, now);
    return (
      summary: 'updated ${days}d ago',
      details: 'Updated ${formatAsDay(issue.updatedDate)}. Comments were not fetched.',
      days: days,
    );
  }
  return _commentActivity(
    authorComment: issue.authorComment,
    authorFollowUpComment: issue.authorFollowUpComment,
    memberComment: issue.memberComment,
    nonMemberComment: issue.nonMemberComment,
    creationDate: issue.creationDate,
    now: now,
  );
}

_Activity _commentActivity({
  required Comment? authorComment,
  required Comment? authorFollowUpComment,
  required Comment? memberComment,
  required Comment? nonMemberComment,
  required DateTime creationDate,
  required DateTime now,
}) {
  final comments = <(String, Comment?)>[
    ('author', authorComment),
    ('team', memberComment),
    ('other', nonMemberComment),
  ];
  final summary = <String>[];
  final details = <String>[];
  for (final (String who, Comment? comment) in comments) {
    if (comment == null) {
      details.add('Last $who comment: none');
      continue;
    }
    final int days = daysBetween(comment.date, now);
    if (who != 'other') {
      summary.add('$who ${days}d');
    }
    details.add(
      'Last $who comment: ${comment.username}, ${formatAsDay(comment.date)} (${days}d ago)',
    );
  }
  if (authorFollowUpComment != null &&
      authorComment != null &&
      authorFollowUpComment.date != authorComment.date) {
    final int days = daysBetween(authorFollowUpComment.date, now);
    details.add(
      'First follow-up after team: ${authorFollowUpComment.username}, '
      '${formatAsDay(authorFollowUpComment.date)} (${days}d ago)',
    );
  }
  final DateTime newest =
      newestComment(<Comment?>[authorComment, memberComment, nonMemberComment])?.date ??
      creationDate;
  return (
    summary: summary.isEmpty ? 'no comments' : summary.join(' · '),
    details: details.join('\n'),
    days: daysBetween(newest, now),
  );
}

String _escape(String text) {
  return text
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;')
      .replaceAll('"', '&quot;')
      .replaceAll("'", '&#39;')
      .replaceAll('\n', '&#10;');
}

const String _css = r'''
  :root {
    color-scheme: light dark;
    --bg: #f8fafc;
    --card-bg: #ffffff;
    --header-bg: #ffffff;
    --table-head-bg: #f1f5f9;
    --row-even: #f8fafc;
    --row-hover: #eff6ff;
    --followup-row: #fff1f2;
    --followup-accent: #e11d48;
    --text: #0f172a;
    --muted: #64748b;
    --border: #e2e8f0;
    --row-border: #f1f5f9;
    --link: #2563eb;
    --link-hover: #1d4ed8;
    --chip-bg: #f1f5f9;
    --chip-text: #334155;
    --chip-border: #cbd5e1;
    --hidden-chip-bg: #fef3c7;
    --hidden-chip-text: #92400e;
    --btn-bg: #ffffff;
    --btn-hover: #f8fafc;
    --btn-active-bg: #2563eb;
    --btn-active-border: #1d4ed8;
    --shadow: 0 1px 3px rgba(15, 23, 42, 0.06), 0 1px 2px rgba(15, 23, 42, 0.04);
    --urg-not-yet: #15803d;
    --urg-due: #b45309;
    --urg-due-bg: #fef3c7;
    --urg-overdue: #dc2626;
    --urg-overdue-bg: #fee2e2;
    --urg-critical: #991b1b;
    --urg-critical-bg: #fecaca;
  }
  @media (prefers-color-scheme: dark) {
    :root {
      --bg: #0b1120;
      --card-bg: #111827;
      --header-bg: #111827;
      --table-head-bg: #1e293b;
      --row-even: #131c2e;
      --row-hover: #1e293b;
      --followup-row: rgba(225, 29, 72, 0.08);
      --followup-accent: #fb7185;
      --text: #f1f5f9;
      --muted: #94a3b8;
      --border: #1e293b;
      --row-border: #1e293b;
      --link: #60a5fa;
      --link-hover: #93c5fd;
      --chip-bg: #1e293b;
      --chip-text: #cbd5e1;
      --chip-border: #334155;
      --hidden-chip-bg: rgba(245, 158, 11, 0.2);
      --hidden-chip-text: #fcd34d;
      --btn-bg: #1e293b;
      --btn-hover: #334155;
      --btn-active-bg: #3b82f6;
      --btn-active-border: #60a5fa;
      --shadow: 0 1px 3px rgba(0, 0, 0, 0.35);
      --urg-not-yet: #4ade80;
      --urg-due: #fbbf24;
      --urg-due-bg: rgba(245, 158, 11, 0.16);
      --urg-overdue: #f87171;
      --urg-overdue-bg: rgba(239, 68, 68, 0.16);
      --urg-critical: #fca5a5;
      --urg-critical-bg: rgba(220, 38, 38, 0.28);
    }
  }
  * { box-sizing: border-box; }
  body {
    font-family: -apple-system, BlinkMacSystemFont, "Inter", "Segoe UI", Roboto, sans-serif;
    margin: 0;
    padding: 24px 28px 48px;
    max-width: 1600px;
    margin-inline: auto;
    background: var(--bg);
    color: var(--text);
    line-height: 1.45;
    -webkit-font-smoothing: antialiased;
  }
  a { color: var(--link); text-decoration: none; font-weight: 500; }
  a:hover { color: var(--link-hover); text-decoration: underline; }
  header {
    background: var(--header-bg);
    border: 1px solid var(--border);
    border-radius: 12px;
    padding: 20px 24px;
    margin-bottom: 20px;
    box-shadow: var(--shadow);
  }
  h1 {
    font-size: 1.45rem;
    font-weight: 700;
    letter-spacing: -0.02em;
    margin: 0 0 12px;
  }
  h2 {
    display: inline;
    font-size: 1.02rem;
    font-weight: 600;
    letter-spacing: -0.01em;
  }
  nav.pages {
    display: inline-flex;
    flex-wrap: wrap;
    align-items: center;
    gap: 6px;
    background: var(--table-head-bg);
    padding: 4px;
    border-radius: 9px;
    border: 1px solid var(--border);
    margin: 4px 0 10px;
    color: transparent;
    font-size: 0;
  }
  nav.pages a, nav.pages strong {
    font-size: 0.88rem;
    padding: 6px 14px;
    border-radius: 6px;
    text-decoration: none;
    transition: background 0.15s, color 0.15s;
  }
  nav.pages a { color: var(--muted); font-weight: 500; }
  nav.pages a:hover { color: var(--text); background: rgba(148, 163, 184, 0.12); }
  nav.pages strong {
    background: var(--card-bg);
    color: var(--text);
    font-weight: 600;
    box-shadow: 0 1px 2px rgba(15, 23, 42, 0.08);
  }
  .meta, .note {
    color: var(--muted);
    font-size: 0.85rem;
    margin: 6px 0;
  }
  nav.sections {
    display: flex;
    flex-wrap: wrap;
    gap: 6px;
    margin: 12px 0;
    color: transparent;
    font-size: 0;
  }
  nav.sections a {
    font-size: 0.82rem;
    color: var(--chip-text);
    background: var(--chip-bg);
    border: 1px solid var(--border);
    padding: 4px 10px;
    border-radius: 999px;
    text-decoration: none;
    transition: border-color 0.15s, background 0.15s;
  }
  nav.sections a:hover {
    border-color: var(--link);
    color: var(--link);
  }
  .controls {
    display: flex;
    flex-wrap: wrap;
    gap: 10px;
    margin: 14px 0 4px;
    align-items: center;
  }
  #filter {
    flex: 1;
    min-width: 260px;
    max-width: 42em;
    padding: 8px 12px;
    font-size: 0.9rem;
    border: 1px solid var(--chip-border);
    border-radius: 8px;
    background: var(--bg);
    color: var(--text);
    outline: none;
    transition: border-color 0.15s, box-shadow 0.15s;
  }
  #filter:focus {
    border-color: var(--link);
    box-shadow: 0 0 0 3px rgba(37, 99, 235, 0.18);
  }
  button {
    font-family: inherit;
    font-size: 0.85rem;
    font-weight: 500;
    padding: 8px 14px;
    border-radius: 8px;
    border: 1px solid var(--chip-border);
    background: var(--btn-bg);
    color: var(--text);
    cursor: pointer;
    transition: background 0.15s, border-color 0.15s, color 0.15s;
  }
  button:hover:not(:disabled) {
    background: var(--btn-hover);
    border-color: var(--muted);
  }
  button:disabled {
    opacity: 0.45;
    cursor: not-allowed;
  }
  button[aria-pressed="true"] {
    background: var(--btn-active-bg);
    color: #ffffff;
    border-color: var(--btn-active-border);
  }
  #toggle-followup:not(:disabled)[aria-pressed="false"] {
    border-color: var(--followup-accent);
    color: var(--followup-accent);
  }
  #toggle-followup[aria-pressed="true"] {
    background: var(--followup-accent);
    border-color: var(--followup-accent);
    color: #ffffff;
  }
  .banner {
    background: var(--urg-overdue-bg);
    border: 1px solid var(--urg-overdue);
    color: var(--urg-overdue);
    border-radius: 8px;
    padding: 10px 14px;
    font-size: 0.9rem;
    margin-top: 12px;
  }
  details {
    margin: 16px 0;
    background: var(--card-bg);
    border: 1px solid var(--border);
    border-radius: 12px;
    box-shadow: var(--shadow);
    overflow: hidden;
  }
  summary {
    cursor: pointer;
    padding: 14px 18px;
    background: var(--card-bg);
    user-select: none;
    border-bottom: 1px solid transparent;
    transition: background 0.15s;
  }
  details[open] > summary {
    border-bottom-color: var(--border);
  }
  summary:hover {
    background: var(--row-even);
  }
  table {
    border-collapse: collapse;
    width: 100%;
    margin: 0;
  }
  tr { font-size: 0.9rem; }
  tbody tr {
    border-bottom: 1px solid var(--row-border);
    transition: background-color 0.1s;
  }
  tbody tr:last-child { border-bottom: none; }
  tbody tr:nth-child(even) { background-color: var(--row-even); }
  tbody tr[data-followup="true"] {
    background-color: var(--followup-row);
    box-shadow: inset 4px 0 0 var(--followup-accent);
  }
  tbody tr:hover { background-color: var(--row-hover); }
  th, td {
    border: none;
    padding: 10px 14px;
    text-align: left;
    vertical-align: top;
  }
  th {
    background-color: var(--table-head-bg);
    color: var(--muted);
    font-size: 0.74rem;
    font-weight: 600;
    text-transform: uppercase;
    letter-spacing: 0.05em;
    cursor: pointer;
    user-select: none;
    white-space: nowrap;
    border-bottom: 1px solid var(--border);
  }
  th:hover { color: var(--text); }
  th[aria-sort="ascending"]::after { content: " \25B2"; color: var(--link); }
  th[aria-sort="descending"]::after { content: " \25BC"; color: var(--link); }
  td.pr, td.waiting, td.activity, td.opened { white-space: nowrap; }
  td.pr a { font-family: ui-monospace, SFMono-Regular, Menlo, monospace; font-weight: 600; }
  td.title { font-weight: 500; }
  td.next { font-weight: 500; }
  td.activity, td.opened { color: var(--muted); font-size: 0.85rem; }
  td.waiting[title], td.activity[title] {
    text-decoration: underline dotted var(--muted);
    text-underline-offset: 3px;
    cursor: help;
  }
  tr.not-due { opacity: 0.58; }
  tr.draft td.title { color: var(--muted); }
  .labels { margin-top: 5px; display: flex; flex-wrap: wrap; gap: 4px; }
  .label {
    display: inline-block;
    font-size: 0.75rem;
    font-weight: 500;
    background: var(--chip-bg);
    color: var(--chip-text);
    border: 1px solid var(--border);
    border-radius: 999px;
    padding: 1px 8px;
    white-space: nowrap;
  }
  .label.hidden-label {
    background: var(--hidden-chip-bg);
    color: var(--hidden-chip-text);
    border-color: transparent;
  }
  .label.repo-label {
    font-weight: 600;
    color: var(--link);
    border-color: var(--link);
  }
  .label.priority-p0 {
    background: var(--urg-critical-bg);
    color: var(--urg-critical);
    border-color: transparent;
    font-weight: 700;
  }
  .label.priority-p1 {
    background: var(--urg-due-bg);
    color: var(--urg-due);
    border-color: transparent;
    font-weight: 600;
  }
  .badge {
    display: inline-block;
    font-size: 0.66rem;
    font-weight: 700;
    letter-spacing: 0.03em;
    color: #ffffff;
    border-radius: 999px;
    padding: 2px 7px;
    margin-left: 4px;
    vertical-align: middle;
  }
  .badge.new { background: #16a34a; }
  .badge.moved { background: #7c3aed; }
  .badge.follow-up { background: #e11d48; }
  .urgency-notYet { color: var(--urg-not-yet); }
  .urgency-due {
    color: var(--urg-due);
    font-weight: 600;
  }
  .urgency-overdue {
    color: var(--urg-overdue);
    font-weight: 600;
  }
  .urgency-critical {
    color: var(--urg-critical);
    font-weight: 700;
  }
  .reviewer {
    display: inline-block;
    white-space: nowrap;
    font-size: 0.82rem;
    background: var(--chip-bg);
    border: 1px solid var(--border);
    border-radius: 6px;
    padding: 1px 7px;
    margin: 1px 2px 1px 0;
  }
  .empty {
    color: var(--muted);
    font-style: italic;
    text-align: center;
    padding: 18px;
  }
  .legend {
    color: var(--muted);
    font-size: 0.85rem;
    margin-top: 28px;
    background: var(--card-bg);
    border: 1px solid var(--border);
    border-radius: 12px;
    padding: 16px 22px;
    box-shadow: var(--shadow);
  }
  .legend h2 {
    display: block;
    font-size: 0.9rem;
    text-transform: uppercase;
    letter-spacing: 0.05em;
    color: var(--text);
    margin: 0 0 8px;
  }
  .legend ul { margin: 0; padding-left: 18px; }
  .legend li { margin: 4px 0; }
''';

const String _script = r'''
(() => {
  'use strict';
  const body = document.body;
  const hiddenLabels = (body.dataset.hiddenLabels || '').split('|').filter((label) => label !== '');
  const storageKey = 'prTriage.showHidden';
  const filter = document.getElementById('filter');
  const toggle = document.getElementById('toggle-hidden');
  const followUpToggle = document.getElementById('toggle-followup');
  const rows = Array.from(document.querySelectorAll('tbody tr[data-number]'));
  let showHidden = body.dataset.showHiddenDefault === 'true';
  let onlyFollowUp = false;
  try {
    const saved = localStorage.getItem(storageKey);
    if (saved !== null) {
      showHidden = saved === 'true';
    }
  } catch (e) {
    // Storage may be unavailable for file: URLs; use the default.
  }

  if (toggle && toggle.disabled) {
    showHidden = false;
  }

  function hiddenByLabel(row) {
    if (hiddenLabels.length === 0) {
      return false;
    }
    const hasLabel = row.dataset.labels.split('|').some((label) => hiddenLabels.includes(label));
    return showHidden ? !hasLabel : hasLabel;
  }

  function update() {
    const query = filter.value.trim().toLowerCase();
    for (const row of rows) {
      row.hidden = hiddenByLabel(row) ||
          (onlyFollowUp && row.dataset.followup !== 'true') ||
          (query !== '' && !row.dataset.search.includes(query));
    }
    for (const count of document.querySelectorAll('[data-count]')) {
      const section = document.getElementById(count.dataset.count);
      count.textContent = section
          ? section.querySelectorAll('tbody tr[data-number]:not([hidden])').length
          : '0';
    }
    if (toggle) {
      toggle.textContent = (showHidden ? 'Hide ' : 'Show ') + toggle.dataset.label;
      toggle.setAttribute('aria-pressed', String(showHidden));
    }
    if (followUpToggle) {
      followUpToggle.setAttribute('aria-pressed', String(onlyFollowUp));
    }
  }

  filter.addEventListener('input', update);
  document.addEventListener('keydown', (e) => {
    if (e.key === '/' && document.activeElement !== filter && !e.ctrlKey && !e.metaKey) {
      e.preventDefault();
      filter.focus();
    } else if (e.key === 'Escape' && document.activeElement === filter) {
      filter.value = '';
      filter.blur();
      update();
    }
  });
  if (toggle) {
    toggle.addEventListener('click', () => {
      showHidden = !showHidden;
      try {
        localStorage.setItem(storageKey, String(showHidden));
      } catch (e) {
        // Not saved, but the toggle still works on this page.
      }
      update();
    });
  }
  if (followUpToggle) {
    followUpToggle.addEventListener('click', () => {
      onlyFollowUp = !onlyFollowUp;
      update();
    });
  }

  for (const header of document.querySelectorAll('th[data-sort]')) {
    header.addEventListener('click', () => {
      const table = header.closest('table');
      const tbody = table.tBodies[0];
      const column = header.cellIndex;
      const key = header.dataset.sort;
      const numeric = header.hasAttribute('data-numeric');
      const ascending = header.getAttribute('aria-sort') !== 'ascending';
      for (const other of table.querySelectorAll('th[data-sort]')) {
        other.removeAttribute('aria-sort');
      }
      header.setAttribute('aria-sort', ascending ? 'ascending' : 'descending');
      const value = (row) => numeric
          ? Number(row.dataset[key])
          : row.cells[column].textContent.trim().toLowerCase();
      const sorted = Array.from(tbody.querySelectorAll('tr[data-number]')).sort((a, b) => {
        const x = value(a);
        const y = value(b);
        const result = x < y ? -1 : (x > y ? 1 : 0);
        return ascending ? result : -result;
      });
      for (const row of sorted) {
        tbody.appendChild(row);
      }
    });
  }

  update();
})();
''';
