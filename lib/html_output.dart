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

const String _unsetReportLabel = '\u0000';

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
  Map<String, String> suggestedReviewers = const <String, String>{},
  Set<String>? hiddenLabels,
  bool showHiddenByDefault = false,
  bool? showAllLabels,
  String? workflowRepo,
  String? teamLabel = _unsetReportLabel,
  String? fyiLabel = _unsetReportLabel,
  TriageConfig config = const TriageConfig(),
  String? note,
}) {
  final Set<String> effectiveHiddenLabels = hiddenLabels ?? config.hiddenLabels;
  final bool effectiveShowAllLabels = showAllLabels ?? config.showAllLabels;
  final String effectiveWorkflowRepo = workflowRepo ?? config.workflowRepo;
  final String? effectiveTeamLabel = identical(teamLabel, _unsetReportLabel)
      ? config.issueTeamLabel
      : teamLabel;
  final String? effectiveFyiLabel = identical(fyiLabel, _unsetReportLabel)
      ? config.issueFyiLabel
      : fyiLabel;
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
      suggestedReviewers: suggestedReviewers,
      hiddenLabels: effectiveHiddenLabels,
      showHiddenByDefault: showHiddenByDefault,
      showAllLabels: effectiveShowAllLabels,
      workflowRepo: effectiveWorkflowRepo,
      config: config,
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
    suggestedReviewers: suggestedReviewers,
    showAllLabels: effectiveShowAllLabels,
    workflowRepo: effectiveWorkflowRepo,
    teamLabel: effectiveTeamLabel,
    fyiLabel: effectiveFyiLabel,
    config: config,
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
    required this.suggestedReviewers,
    required this.hiddenLabels,
    required this.showHiddenByDefault,
    required this.showAllLabels,
    required this.workflowRepo,
    required this.config,
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
  final Map<String, String> suggestedReviewers;
  final Set<String> hiddenLabels;
  final bool showHiddenByDefault;
  final bool showAllLabels;
  final String workflowRepo;
  final TriageConfig config;
  final String? note;

  final StringBuffer _out = StringBuffer();

  bool _startsHidden(PRAnalysis analysis) =>
      (hiddenLabels.isNotEmpty &&
          showHiddenByDefault != hasHiddenLabel(analysis.pr, hiddenLabels)) ||
      hasWaitingForResponseLabel(analysis.pr.labels, config: config);

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
      ..writeln(
        '<aside id="triage-companion-dock" class="companion-dock" hidden aria-label="Triage companion"></aside>',
      )
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
<body data-hidden-labels="${_escape(hiddenLabels.join('|'))}" data-show-hidden-default="$showHiddenByDefault" data-generated-at="${_escape(generatedAt.toUtc().toIso8601String())}" data-workflow-repo="${_escape(workflowRepo)}">
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
    final int nonHiddenCount = pagePRs.length - hiddenCount;
    final int waitingResponseCount = pagePRs
        .where((PRAnalysis a) => hasWaitingForResponseLabel(a.pr.labels, config: config))
        .length;
    final int followUpCount = pagePRs.where((PRAnalysis a) => a.isFollowUp).length;
    final String hiddenLabel = hiddenLabels.join('/');
    final int failed = _inSection(Section.loadError).length;
    _out.write('''
<header>
<h1>${_escape(repo)} · ${pageTitle(page)}</h1>
<nav class="pages">${pageLinks.join(' · ')}</nav>
<p class="meta">Generated ${_escape(formatAsMinute(generatedAt))} · ${pagePRs.length} open PRs on this page</p>
<nav class="sections">${sectionLinks.join(' · ')}</nav>
<div class="controls">
<button id="toggle-followup" type="button" aria-pressed="false"${followUpCount == 0 ? ' disabled' : ''}>Follow-up PRs ($followUpCount)</button>
''');
    if (hiddenLabels.isNotEmpty) {
      _out.writeln(
        <String>[
          '<div class="filter-group" role="group" aria-label="Design filter">',
          '<label class="filter-chip"><input id="show-non-design" type="checkbox"${showHiddenByDefault ? '' : ' checked'}>',
          '<span>${_escape(config.nonHiddenFilterLabel)} ($nonHiddenCount)</span></label>',
          '<label class="filter-chip"><input id="show-design" type="checkbox"${showHiddenByDefault ? ' checked' : ''}>',
          '<span>${_escape(hiddenLabel)} ($hiddenCount)</span></label>',
          '</div>',
        ].join(),
      );
    }
    _out
      ..writeln(
        '<label class="filter-chip"><input id="hide-waiting-response" type="checkbox" checked><span>Hide waiting-for-response ($waitingResponseCount)</span></label>',
      )
      ..writeln(
        '<button id="open-companion" type="button" title="Open an always-on-top floating window with the active row&#39;s triage details">🪟 Triage companion</button>',
      )
      ..writeln('<button id="refresh-report" type="button">↻ Refresh report</button>')
      ..writeln('<span id="refresh-status" class="refresh-status" aria-live="polite"></span>')
      ..writeln('</div>')
      ..writeln(
        '<input id="filter" type="search" placeholder="Filter by number, title, author, label, reviewer, or next step" autocomplete="off">',
      );
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
    final int visible = _visibleCount(section);
    final bool open = section != Section.bots && section != Section.drafts;
    final disabledAttr = visible == 0 ? ' disabled' : '';
    _out.write('''
<details id="${section.name}" data-section="${section.name}"${open ? ' open' : ''}>
<summary><h2>${_escape(sectionTitle(section, page))} (<span data-count="${section.name}">$visible</span>)</h2><span class="section-actions"><button type="button" class="section-btn open-batch"$disabledAttr>Open first 10</button><button type="button" class="section-btn open-all"$disabledAttr>Open all</button></span></summary>
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
      ..write(
        hasWaitingForResponseLabel(pr.labels, config: config)
            ? ' data-waiting-response="true"'
            : '',
      )
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
        if ((showAllLabels && !label.startsWith('cla:')) ||
            isRoutingLabel(label, config: config) ||
            hiddenLabels.contains(label) ||
            config.waitingForResponseLabels.contains(label))
          _labelChip(label),
    ];
    return chips.isEmpty ? '' : '<div class="labels">${chips.join()}</div>';
  }

  String _labelChip(String label) {
    final classes = hiddenLabels.contains(label) ? 'label hidden-label' : 'label';
    final String? tooltip = _packageReviewerTooltip(
      label,
      suggestedReviewers,
      packageLabelPrefix: config.packageLabelPrefix,
    );
    final titleAttr = tooltip == null ? '' : ' title="${_escape(tooltip)}"';
    return '<span class="$classes"$titleAttr>${_escape(label)}</span>';
  }

  void _writeLegend() {
    _out.write('''
<section class="legend">
<h2>Legend</h2>
<ul>
<li>Sections are sorted by how long each PR has been waiting on whoever needs to act next. Hover over a waiting time to see why a PR is where it is.</li>
<li>Click any row or <strong>🪟 Triage companion</strong> to open an always-on-top floating window with that item's expanded waiting reasons, suggested reviewers, and queue navigation while viewing GitHub.</li>
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
    required this.suggestedReviewers,
    required this.showAllLabels,
    required this.workflowRepo,
    required this.teamLabel,
    required this.fyiLabel,
    required this.config,
    required this.note,
  });

  final String issuesRepo;
  final List<PRAnalysis> prs;
  final List<IssueAnalysis> issues;
  final Map<ReportPage, File> files;
  final File issuesFile;
  final DateTime generatedAt;
  final Map<String, String> suggestedReviewers;
  final bool showAllLabels;
  final String workflowRepo;
  final String? teamLabel;
  final String? fyiLabel;
  final TriageConfig config;
  final String? note;

  final StringBuffer _out = StringBuffer();

  bool _startsHidden(IssueAnalysis analysis) =>
      hasWaitingForResponseLabel(analysis.issue.labels, config: config);

  List<IssueAnalysis> _inSection(IssueSection section) =>
      issues.where((IssueAnalysis a) => a.section == section).toList();

  int _visibleCount(IssueSection section) =>
      _inSection(section).where((IssueAnalysis a) => !_startsHidden(a)).length;

  String _sectionTitle(IssueSection section) =>
      issueSectionTitle(section, teamLabel: teamLabel, fyiLabel: fyiLabel, config: config);

  String render() {
    final sections = <IssueSection>[
      for (final IssueSection section in IssueSection.values)
        if ((section != IssueSection.loadError || _inSection(section).isNotEmpty) &&
            (section != IssueSection.fyiEcosystem ||
                (fyiLabel != null && fyiLabel!.isNotEmpty) ||
                _inSection(section).isNotEmpty))
          section,
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
<body data-hidden-labels="" data-show-hidden-default="true" data-generated-at="${_escape(generatedAt.toUtc().toIso8601String())}" data-workflow-repo="${_escape(workflowRepo)}">
''');
    _writeHeader(sections);
    sections.forEach(_writeSection);
    _writeLegend();
    _out
      ..writeln(
        '<aside id="triage-companion-dock" class="companion-dock" hidden aria-label="Triage companion"></aside>',
      )
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
    final int waitingResponseCount = issues
        .where((IssueAnalysis a) => hasWaitingForResponseLabel(a.issue.labels, config: config))
        .length;
    final int failed = _inSection(IssueSection.loadError).length;
    _out.write('''
<header>
<h1>${_escape(issuesRepo)} · Package Issues</h1>
<nav class="pages">${pageLinks.join(' · ')}</nav>
<p class="meta">Generated ${_escape(formatAsMinute(generatedAt))} · ${issues.length} actionable package issues on this page</p>
<nav class="sections">${sectionLinks.join(' · ')}</nav>
<div class="controls">
<button id="toggle-followup" type="button" aria-pressed="false"${followUpCount == 0 ? ' disabled' : ''}>Follow-up issues ($followUpCount)</button>
<label class="filter-chip"><input id="hide-waiting-response" type="checkbox" checked><span>Hide waiting-for-response ($waitingResponseCount)</span></label>
<button id="open-companion" type="button" title="Open an always-on-top floating window with the active row&#39;s triage details">🪟 Triage companion</button>
<button id="refresh-report" type="button">↻ Refresh report</button>
<span id="refresh-status" class="refresh-status" aria-live="polite"></span>
</div>
<input id="filter" type="search" placeholder="Filter by number, title, author, label, assignee, or next step" autocomplete="off">
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
      '<a href="#${section.name}">${_escape(_sectionTitle(section))} '
      '(<span data-count="${section.name}">${_visibleCount(section)}</span>)</a>';

  void _writeSection(IssueSection section) {
    final List<IssueAnalysis> rows = _inSection(section);
    final int visible = _visibleCount(section);
    final disabledAttr = visible == 0 ? ' disabled' : '';
    _out.write('''
<details id="${section.name}" data-section="${section.name}" open>
<summary><h2>${_escape(_sectionTitle(section))} (<span data-count="${section.name}">$visible</span>)</h2><span class="section-actions"><button type="button" class="section-btn open-batch"$disabledAttr>Open first 10</button><button type="button" class="section-btn open-all"$disabledAttr>Open all</button></span></summary>
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
      ..write(
        hasWaitingForResponseLabel(issue.labels, config: config)
            ? ' data-waiting-response="true"'
            : '',
      )
      ..write(analysis.isFollowUp ? ' data-followup="true"' : '')
      ..write(' data-search="${_escape(search)}"')
      ..write(' data-waiting="${analysis.waitingDays}"')
      ..write(' data-activity="${activity.days}"')
      ..write(' data-opened="${daysBetween(issue.creationDate, now)}"')
      ..write(_startsHidden(analysis) ? ' hidden' : '')
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
        if ((showAllLabels && !label.startsWith('cla:')) ||
            isIssueDisplayLabel(label, config: config) ||
            label == teamLabel ||
            label == fyiLabel)
          _issueLabelChip(label),
    ];
    return chips.isEmpty ? '' : '<div class="labels">${chips.join()}</div>';
  }

  String _issueLabelChip(String label) {
    final bool isTopPriority =
        config.priorityLabels.isNotEmpty && label == config.priorityLabels.first;
    final priorityClass = isTopPriority
        ? ' priority-p0'
        : config.highPriorityLabels.contains(label)
        ? ' priority-p1'
        : '';
    final String? tooltip = _packageReviewerTooltip(
      label,
      suggestedReviewers,
      packageLabelPrefix: config.packageLabelPrefix,
    );
    final titleAttr = tooltip == null ? '' : ' title="${_escape(tooltip)}"';
    return '<span class="label$priorityClass"$titleAttr>${_escape(label)}</span>';
  }

  void _writeLegend() {
    final labelDesc = (teamLabel != null && teamLabel!.isNotEmpty)
        ? ' labeled <code>${_escape(teamLabel!)}</code>'
              '${fyiLabel != null && fyiLabel!.isNotEmpty ? ' or <code>${_escape(fyiLabel!)}</code>' : ''}'
        : '';
    final lowPriorities = config.lowPriorityLabels.isNotEmpty
        ? '${_escape(config.lowPriorityLabels.join('/'))} '
        : '';
    _out.write('''
<section class="legend">
<h2>Legend</h2>
<ul>
<li>Actionable package issues from ${_escape(issuesRepo)}$labelDesc. Already-triaged ${lowPriorities}issues that are not waiting on a response are omitted.</li>
<li>Click any row or <strong>🪟 Triage companion</strong> to open an always-on-top floating window with that issue's expanded waiting reasons, suggested reviewers, and queue navigation while viewing GitHub.</li>
<li><span class="badge follow-up">FOLLOW-UP</span> issue author replied after a team member's comment.</li>
</ul>
</section>
''');
  }
}

String? _packageReviewerTooltip(
  String label,
  Map<String, String> suggestedReviewers, {
  String packageLabelPrefix = defaultPackageLabelPrefix,
}) {
  if (packageLabelPrefix.isEmpty ||
      !label.startsWith(packageLabelPrefix) ||
      suggestedReviewers.isEmpty) {
    return null;
  }
  final String pkg = label.substring(packageLabelPrefix.length).trim();
  final String? exact = suggestedReviewers[pkg];
  if (exact != null) {
    return exact;
  }
  String? bestKey;
  for (final String key in suggestedReviewers.keys) {
    if (pkg.startsWith('${key}_') && (bestKey == null || key.length > bestKey.length)) {
      bestKey = key;
    }
  }
  return bestKey == null ? null : suggestedReviewers[bestKey];
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
    margin: 12px 0;
    align-items: center;
  }
  #filter {
    display: block;
    width: 100%;
    max-width: 42em;
    margin-top: 12px;
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
  tbody tr[data-number] {
    border-bottom: 1px solid var(--row-border);
    transition: background-color 0.1s, box-shadow 0.1s;
    cursor: pointer;
  }
  tbody tr:last-child { border-bottom: none; }
  tbody tr:nth-child(even) { background-color: var(--row-even); }
  tbody tr[data-followup="true"] {
    background-color: var(--followup-row);
    box-shadow: inset 4px 0 0 var(--followup-accent);
  }
  tbody tr.active-triage-row {
    background-color: var(--row-hover);
    box-shadow: inset 4px 0 0 var(--link);
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
  .label[title] {
    text-decoration: underline dotted var(--muted);
    text-underline-offset: 2px;
    cursor: help;
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
  .refresh-status {
    font-size: 0.82rem;
    color: var(--muted);
  }
  .filter-group {
    display: inline-flex;
    align-items: center;
    gap: 3px;
    background: var(--table-head-bg);
    padding: 3px;
    border-radius: 10px;
    border: 1px solid var(--border);
  }
  .filter-chip {
    display: inline-flex;
    align-items: center;
    gap: 7px;
    font-size: 0.84rem;
    font-weight: 500;
    padding: 7px 12px;
    border-radius: 8px;
    border: 1px solid var(--chip-border);
    background: var(--btn-bg);
    color: var(--muted);
    cursor: pointer;
    user-select: none;
    transition: background 0.15s, border-color 0.15s, color 0.15s, box-shadow 0.15s;
  }
  .filter-group .filter-chip {
    padding: 5px 11px;
    border-radius: 7px;
    border-color: transparent;
    background: transparent;
  }
  .filter-chip:hover {
    color: var(--text);
    background: var(--btn-hover);
    border-color: var(--muted);
  }
  .filter-group .filter-chip:hover {
    border-color: transparent;
    background: rgba(148, 163, 184, 0.12);
  }
  .filter-chip:has(input:checked) {
    color: var(--text);
    background: var(--card-bg);
    border-color: var(--link);
    box-shadow: 0 0 0 1px rgba(37, 99, 235, 0.12);
  }
  .filter-group .filter-chip:has(input:checked) {
    background: var(--card-bg);
    border-color: var(--border);
    box-shadow: 0 1px 2px rgba(15, 23, 42, 0.08);
  }
  .filter-chip input[type="checkbox"] {
    appearance: none;
    -webkit-appearance: none;
    width: 15px;
    height: 15px;
    margin: 0;
    border-radius: 4px;
    border: 1.5px solid var(--chip-border);
    background: var(--bg);
    display: inline-grid;
    place-content: center;
    cursor: pointer;
    transition: background 0.15s, border-color 0.15s;
  }
  .filter-chip input[type="checkbox"]::before {
    content: "";
    width: 8px;
    height: 5px;
    border-left: 2px solid #ffffff;
    border-bottom: 2px solid #ffffff;
    transform: rotate(-45deg) translate(0.5px, -0.5px) scale(0);
    transition: transform 0.12s ease-in-out;
  }
  .filter-chip input[type="checkbox"]:checked {
    background: var(--btn-active-bg);
    border-color: var(--btn-active-border);
  }
  .filter-chip input[type="checkbox"]:checked::before {
    transform: rotate(-45deg) translate(0.5px, -0.5px) scale(1);
  }
  .section-actions {
    float: right;
    display: inline-flex;
    align-items: center;
    gap: 6px;
    margin-top: -3px;
  }
  .section-btn {
    font-size: 0.78rem;
    padding: 4px 10px;
    border-radius: 6px;
  }
  .companion-dock {
    position: fixed;
    right: 20px;
    bottom: 20px;
    width: min(560px, calc(100vw - 40px));
    max-height: calc(100vh - 40px);
    overflow-y: auto;
    background: var(--card-bg);
    border: 1px solid var(--link);
    border-radius: 14px;
    box-shadow: 0 12px 32px rgba(15, 23, 42, 0.22);
    z-index: 1000;
  }
  body.pip-companion-body {
    padding: 0;
    margin: 0;
    max-width: none;
    background: var(--card-bg);
  }
  .companion-card {
    padding: 12px 14px;
    font-size: 0.84rem;
    display: flex;
    flex-direction: column;
    gap: 10px;
  }
  .companion-topbar {
    display: flex;
    flex-wrap: wrap;
    align-items: center;
    justify-content: space-between;
    gap: 8px;
    padding-bottom: 8px;
    border-bottom: 1px solid var(--border);
  }
  .companion-section-meta {
    font-size: 0.76rem;
    font-weight: 600;
    text-transform: uppercase;
    letter-spacing: 0.04em;
    color: var(--muted);
  }
  .companion-nav {
    display: inline-flex;
    align-items: center;
    gap: 6px;
    flex-wrap: wrap;
  }
  .companion-btn {
    font-size: 0.76rem;
    padding: 4px 9px;
    border-radius: 6px;
  }
  .companion-btn.primary {
    background: var(--btn-active-bg);
    border-color: var(--btn-active-border);
    color: #ffffff;
  }
  .companion-btn.primary:hover:not(:disabled) {
    opacity: 0.92;
  }
  .companion-queue {
    display: flex;
    gap: 5px;
    overflow-x: auto;
    padding-bottom: 4px;
    scrollbar-width: thin;
  }
  .queue-pill {
    font-family: ui-monospace, SFMono-Regular, Menlo, monospace;
    font-size: 0.74rem;
    font-weight: 600;
    padding: 3px 8px;
    border-radius: 999px;
    border: 1px solid var(--border);
    background: var(--chip-bg);
    color: var(--chip-text);
    white-space: nowrap;
    cursor: pointer;
  }
  .queue-pill[data-followup="true"] {
    border-color: var(--followup-accent);
  }
  .queue-pill.active {
    background: var(--btn-active-bg);
    border-color: var(--btn-active-border);
    color: #ffffff;
  }
  .companion-title-row {
    display: flex;
    align-items: flex-start;
    justify-content: space-between;
    gap: 10px;
  }
  .companion-heading {
    font-size: 0.96rem;
    font-weight: 600;
    line-height: 1.35;
    margin: 0;
  }
  .companion-heading .pr-num {
    font-family: ui-monospace, SFMono-Regular, Menlo, monospace;
    color: var(--link);
    margin-right: 4px;
  }
  .companion-grid {
    display: grid;
    grid-template-columns: repeat(auto-fit, minmax(210px, 1fr));
    gap: 8px;
  }
  .companion-box {
    background: var(--bg);
    border: 1px solid var(--border);
    border-radius: 8px;
    padding: 8px 10px;
  }
  .companion-box.full {
    grid-column: 1 / -1;
  }
  .companion-box h3 {
    margin: 0 0 4px;
    font-size: 0.7rem;
    font-weight: 700;
    text-transform: uppercase;
    letter-spacing: 0.05em;
    color: var(--muted);
  }
  .companion-next {
    font-size: 0.88rem;
    font-weight: 600;
    margin-bottom: 4px;
  }
  .companion-list {
    margin: 4px 0 0;
    padding-left: 16px;
    color: var(--text);
    font-size: 0.8rem;
  }
  .companion-list li {
    margin: 2px 0;
  }
  .copy-handles {
    display: flex;
    flex-wrap: wrap;
    gap: 4px;
    margin-top: 5px;
  }
  .copy-handle {
    font-family: ui-monospace, SFMono-Regular, Menlo, monospace;
    font-size: 0.73rem;
    padding: 2px 7px;
    border-radius: 6px;
    background: var(--card-bg);
    border: 1px solid var(--chip-border);
    color: var(--link);
    cursor: pointer;
  }
  .copy-handle:hover {
    border-color: var(--link);
    background: var(--row-hover);
  }
  .companion-auto-label {
    display: inline-flex;
    align-items: center;
    gap: 5px;
    font-size: 0.75rem;
    color: var(--muted);
    cursor: pointer;
    user-select: none;
  }
''';

const String _script = r'''
(() => {
  'use strict';
  const body = document.body;
  const hiddenLabels = (body.dataset.hiddenLabels || '').split('|').filter((label) => label !== '');
  const nonDesignStorageKey = 'prTriage.showNonDesign';
  const designStorageKey = 'prTriage.showDesign';
  const waitingResponseStorageKey = 'prTriage.hideWaitingForResponse';
  const companionAutoOpenStorageKey = 'prTriage.companionAutoOpen';
  const tokenStorageKey = 'prTriage.githubToken';
  const lastRunStorageKey = 'prTriage.lastWorkflowRunAt';
  const cooldownMs = 5 * 60 * 1000;
  const filter = document.getElementById('filter');
  const showNonDesignCheckbox = document.getElementById('show-non-design');
  const showDesignCheckbox = document.getElementById('show-design');
  const followUpToggle = document.getElementById('toggle-followup');
  const hideWaitingCheckbox = document.getElementById('hide-waiting-response');
  const openCompanionButton = document.getElementById('open-companion');
  const companionDock = document.getElementById('triage-companion-dock');
  const refreshButton = document.getElementById('refresh-report');
  const refreshStatus = document.getElementById('refresh-status');
  const rows = Array.from(document.querySelectorAll('tbody tr[data-number]'));
  const sections = Array.from(document.querySelectorAll('details[data-section]'));
  const showHiddenDefault = body.dataset.showHiddenDefault === 'true';
  let showNonDesign = showNonDesignCheckbox ? showNonDesignCheckbox.checked : !showHiddenDefault;
  let showDesign = showDesignCheckbox ? showDesignCheckbox.checked : showHiddenDefault;
  let hideWaitingResponse = hideWaitingCheckbox ? hideWaitingCheckbox.checked : true;
  let companionAutoOpen = true;
  let onlyFollowUp = false;
  try {
    const savedNonDesign = localStorage.getItem(nonDesignStorageKey);
    const savedDesign = localStorage.getItem(designStorageKey);
    if (savedNonDesign !== null) {
      showNonDesign = savedNonDesign === 'true';
    }
    if (savedDesign !== null) {
      showDesign = savedDesign === 'true';
    }
    if (!showNonDesign && !showDesign) {
      showNonDesign = true;
    }
    const savedWaiting = localStorage.getItem(waitingResponseStorageKey);
    if (savedWaiting !== null) {
      hideWaitingResponse = savedWaiting === 'true';
    }
    const savedAutoOpen = localStorage.getItem(companionAutoOpenStorageKey);
    if (savedAutoOpen !== null) {
      companionAutoOpen = savedAutoOpen === 'true';
    }
  } catch (e) {
    // Storage may be unavailable for file: URLs; use the default.
  }

  let companionQueue = [];
  let companionIndex = 0;
  let companionQueueLabel = '';
  let pipWindow = null;
  const openedTabsByUrl = new Map();

  function escapeHtml(str) {
    return String(str || '')
        .replace(/&/g, '&amp;')
        .replace(/</g, '&lt;')
        .replace(/>/g, '&gt;')
        .replace(/"/g, '&quot;')
        .replace(/'/g, '&#39;');
  }

  function extractHandles(text) {
    const matches = String(text || '').match(/@[A-Za-z0-9_-]+/g) || [];
    return Array.from(new Set(matches));
  }

  function extractRowData(row) {
    const link = row.querySelector('td.pr a[href]');
    const url = link ? link.href : '';
    const number = row.dataset.number || '';
    const badges = Array.from(row.querySelectorAll('td.pr .badge')).map((b) => ({
      text: b.textContent.trim(),
      className: b.className,
      title: b.getAttribute('title') || '',
    }));
    const titleCell = row.querySelector('td.title');
    let title = '';
    if (titleCell) {
      const clone = titleCell.cloneNode(true);
      const labelsEl = clone.querySelector('.labels');
      if (labelsEl) {
        labelsEl.remove();
      }
      title = clone.textContent.trim();
    }
    const labels = Array.from(row.querySelectorAll('td.title .label')).map((l) => ({
      text: l.textContent.trim(),
      className: l.className,
      tooltip: l.getAttribute('title') || '',
    }));
    const suggested = labels.filter((l) => l.tooltip !== '').map((l) => ({
      label: l.text,
      lines: l.tooltip.split('\n').map((s) => s.trim()).filter(Boolean),
      handles: extractHandles(l.tooltip),
    }));
    const author = (row.querySelector('td.author')?.textContent || '').trim();
    const nextStep = (row.querySelector('td.next')?.textContent || '').trim();
    const waitingCell = row.querySelector('td.waiting');
    const waitingText = (waitingCell?.textContent || '').trim();
    const waitingClass = waitingCell?.className || 'waiting';
    const waitingReasons = (waitingCell?.getAttribute('title') || '')
        .split('\n')
        .map((s) => s.trim())
        .filter(Boolean);
    const table = row.closest('table');
    const reviewersHeading = (table?.querySelector('thead th:nth-child(6)')?.textContent || 'Reviewers').trim();
    const reviewers = Array.from(row.querySelectorAll('td.reviewers .reviewer')).map((r) => r.textContent.trim());
    const activityCell = row.querySelector('td.activity');
    const activitySummary = (activityCell?.textContent || '').trim();
    const activityDetails = (activityCell?.getAttribute('title') || '')
        .split('\n')
        .map((s) => s.trim())
        .filter(Boolean);
    const openedDate = (row.querySelector('td.opened')?.textContent || '').trim();
    const openedDays = row.dataset.opened || '';
    const sectionEl = row.closest('details[data-section]');
    const sectionH2 = sectionEl?.querySelector('summary h2');
    let sectionTitle = sectionEl?.dataset.section || '';
    if (sectionH2) {
      sectionTitle = sectionH2.textContent.replace(/\s*\(\d+\)\s*$/, '').trim();
    }
    const allHandles = Array.from(new Set([
      ...extractHandles(nextStep),
      ...suggested.flatMap((s) => s.handles),
      ...reviewers.flatMap((r) => extractHandles(r.includes('@') ? r : '@' + r.replace(/^[^\w@]+/, '').trim())),
    ]));
    return {
      row,
      number,
      url,
      badges,
      isDraft: row.classList.contains('draft'),
      isFollowUp: row.dataset.followup === 'true',
      title,
      labels,
      suggested,
      author,
      nextStep,
      waitingText,
      waitingClass,
      waitingReasons,
      reviewersHeading,
      reviewers,
      activitySummary,
      activityDetails,
      openedDate,
      openedDays,
      sectionTitle,
      allHandles,
    };
  }

  function highlightActiveRow() {
    const activeRow = companionQueue[companionIndex] || null;
    for (const r of rows) {
      r.classList.toggle('active-triage-row', r === activeRow);
    }
  }

  function openOrFocusGitHub(url) {
    if (!url) {
      return;
    }
    const existing = openedTabsByUrl.get(url);
    if (existing && !existing.closed) {
      existing.focus();
      return;
    }
    const win = window.open(url, 'prTriageGitHub');
    if (win) {
      openedTabsByUrl.set(url, win);
      win.focus();
    }
  }

  function buildCompanionHtml(inPip) {
    if (companionQueue.length === 0) {
      return `<div class="companion-card"><div class="empty">No visible items to triage.</div></div>`;
    }
    if (companionIndex >= companionQueue.length) {
      companionIndex = 0;
    }
    const item = extractRowData(companionQueue[companionIndex]);
    const queueHeading = companionQueueLabel || item.sectionTitle || 'Queue';
    const posText = `${escapeHtml(queueHeading)} · ${companionIndex + 1} of ${companionQueue.length}`;
    const badgesHtml = [
      ...item.badges.map(
        (b) => `<span class="${escapeHtml(b.className)}" title="${escapeHtml(b.title)}">${escapeHtml(b.text)}</span>`
      ),
      item.isDraft ? '<span class="label">DRAFT</span>' : '',
    ].join(' ');
    const pillsHtml = companionQueue.map((r, idx) => {
      const num = r.dataset.number || '';
      const activeClass = idx === companionIndex ? ' active' : '';
      const followUpAttr = r.dataset.followup === 'true' ? ' data-followup="true"' : '';
      return `<button type="button" class="queue-pill${activeClass}"${followUpAttr} data-queue-index="${idx}">#${escapeHtml(num)}</button>`;
    }).join('');
    const reasonsHtml = item.waitingReasons.length > 0
        ? `<ul class="companion-list">${item.waitingReasons.map((line) => `<li>${escapeHtml(line)}</li>`).join('')}</ul>`
        : '';
    const suggestedHtml = item.suggested.length > 0
        ? `<div class="companion-box full">
            <h3>Suggested Reviewers (from SUGGESTED_REVIEWERS.md)</h3>
            ${item.suggested.map((s) => `<ul class="companion-list">${s.lines.map((line) => `<li>${escapeHtml(line)}</li>`).join('')}</ul>`).join('')}
            ${item.suggested.some((s) => s.handles.length > 0)
                ? `<div class="copy-handles">${Array.from(new Set(item.suggested.flatMap((s) => s.handles))).map((h) => `<button type="button" class="copy-handle" data-copy="${escapeHtml(h)}" title="Copy ${escapeHtml(h)}">📋 ${escapeHtml(h)}</button>`).join('')}</div>`
                : ''}
          </div>`
        : '';
    const reviewersContent = item.reviewers.length > 0
        ? item.reviewers.map((r) => `<span class="reviewer">${escapeHtml(r)}</span>`).join(' ')
        : '<span class="meta">None</span>';
    const labelsContent = item.labels.length > 0
        ? `<div class="labels">${item.labels.map((l) => `<span class="${escapeHtml(l.className)}">${escapeHtml(l.text)}</span>`).join('')}</div>`
        : '';
    const activityLinesHtml = item.activityDetails.length > 0
        ? `<ul class="companion-list">${item.activityDetails.map((line) => `<li>${escapeHtml(line)}</li>`).join('')}</ul>`
        : `<div class="meta">${escapeHtml(item.activitySummary)}</div>`;
    const popOutBtnHtml = !inPip
        ? `<button type="button" class="companion-btn primary" data-action="popout" title="Float this bar on top of Chrome while browsing GitHub">🪟 Float on top</button>
           <button type="button" class="companion-btn" data-action="close-dock" title="Hide panel">✕</button>`
        : '';

    return `<div class="companion-card">
      <div class="companion-topbar">
        <span class="companion-section-meta">${posText}</span>
        <div class="companion-nav">
          <label class="companion-auto-label" title="Automatically open or focus the GitHub tab when stepping with Prev/Next or clicking a #number pill">
            <input type="checkbox" data-action="toggle-auto-open"${companionAutoOpen ? ' checked' : ''}>
            <span>Auto-open GitHub</span>
          </label>
          <button type="button" class="companion-btn" data-action="prev"${companionQueue.length <= 1 ? ' disabled' : ''}>◀ Prev</button>
          <button type="button" class="companion-btn" data-action="next"${companionQueue.length <= 1 ? ' disabled' : ''}>Next ▶</button>
          ${popOutBtnHtml}
        </div>
      </div>
      <div class="companion-queue" role="tablist" aria-label="Triage queue">${pillsHtml}</div>
      <div class="companion-title-row">
        <div>
          <p class="companion-heading"><span class="pr-num">#${escapeHtml(item.number)}</span>${escapeHtml(item.title)} ${badgesHtml}</p>
          ${labelsContent}
        </div>
        <button type="button" class="companion-btn primary" data-action="open-github">Open #${escapeHtml(item.number)} on GitHub ↗</button>
      </div>
      <div class="companion-grid">
        <div class="companion-box">
          <h3>Next Step &amp; Waiting</h3>
          <div class="companion-next">${escapeHtml(item.nextStep)}</div>
          <div><span class="${escapeHtml(item.waitingClass)}">${escapeHtml(item.waitingText)}</span></div>
          ${reasonsHtml}
        </div>
        <div class="companion-box">
          <h3>Author &amp; ${escapeHtml(item.reviewersHeading)}</h3>
          <div><strong>Author:</strong> ${escapeHtml(item.author)}</div>
          <div style="margin-top:4px;"><strong>${escapeHtml(item.reviewersHeading)}:</strong> ${reviewersContent}</div>
          ${item.allHandles.length > 0
              ? `<div class="copy-handles">${item.allHandles.map((h) => `<button type="button" class="copy-handle" data-copy="${escapeHtml(h)}" title="Copy ${escapeHtml(h)}">📋 ${escapeHtml(h)}</button>`).join('')}</div>`
              : ''}
        </div>
        ${suggestedHtml}
        <div class="companion-box full">
          <h3>Activity &amp; Timeline (Opened ${escapeHtml(item.openedDate)}${item.openedDays ? `, ${escapeHtml(item.openedDays)}d ago` : ''})</h3>
          ${activityLinesHtml}
        </div>
      </div>
    </div>`;
  }

  function bindCompanionEvents(rootEl, targetWindow) {
    rootEl.addEventListener('click', async (e) => {
      const copyBtn = e.target.closest('[data-copy]');
      if (copyBtn) {
        const handle = copyBtn.getAttribute('data-copy') || '';
        try {
          await targetWindow.navigator.clipboard.writeText(handle);
          const original = copyBtn.textContent;
          copyBtn.textContent = `✓ Copied ${handle}`;
          setTimeout(() => {
            copyBtn.textContent = original;
          }, 1400);
        } catch (err) {
          // Clipboard fallback
        }
        return;
      }
      const pillBtn = e.target.closest('[data-queue-index]');
      if (pillBtn) {
        const idx = Number(pillBtn.getAttribute('data-queue-index') || '0');
        if (idx >= 0 && idx < companionQueue.length) {
          companionIndex = idx;
          renderCompanion();
          if (companionAutoOpen) {
            const item = extractRowData(companionQueue[companionIndex]);
            openOrFocusGitHub(item.url);
          }
        }
        return;
      }
      const actionEl = e.target.closest('[data-action]');
      if (!actionEl) {
        return;
      }
      const action = actionEl.getAttribute('data-action');
      if (action === 'prev' && companionQueue.length > 0) {
        companionIndex = (companionIndex - 1 + companionQueue.length) % companionQueue.length;
        renderCompanion();
        if (companionAutoOpen) {
          const item = extractRowData(companionQueue[companionIndex]);
          openOrFocusGitHub(item.url);
        }
      } else if (action === 'next' && companionQueue.length > 0) {
        companionIndex = (companionIndex + 1) % companionQueue.length;
        renderCompanion();
        if (companionAutoOpen) {
          const item = extractRowData(companionQueue[companionIndex]);
          openOrFocusGitHub(item.url);
        }
      } else if (action === 'open-github' && companionQueue.length > 0) {
        const item = extractRowData(companionQueue[companionIndex]);
        openOrFocusGitHub(item.url);
      } else if (action === 'popout') {
        await openPipCompanion();
      } else if (action === 'close-dock') {
        if (companionDock) {
          companionDock.hidden = true;
        }
      }
    });
    rootEl.addEventListener('change', (e) => {
      const toggle = e.target.closest('[data-action="toggle-auto-open"]');
      if (toggle) {
        companionAutoOpen = toggle.checked;
        try {
          localStorage.setItem(companionAutoOpenStorageKey, String(companionAutoOpen));
        } catch (err) {
          // Ignore storage errors.
        }
        renderCompanion();
      }
    });
  }

  function renderCompanion() {
    highlightActiveRow();
    const activePillSelector = `.queue-pill[data-queue-index="${companionIndex}"]`;
    if (pipWindow && !pipWindow.closed) {
      const root = pipWindow.document.getElementById('pip-companion-root');
      if (root) {
        root.innerHTML = buildCompanionHtml(true);
        root.querySelector(activePillSelector)?.scrollIntoView({ block: 'nearest', inline: 'nearest' });
      }
      if (companionDock) {
        companionDock.hidden = true;
      }
      return;
    }
    if (companionDock && companionQueue.length > 0) {
      companionDock.innerHTML = buildCompanionHtml(false);
      companionDock.querySelector(activePillSelector)?.scrollIntoView({ block: 'nearest', inline: 'nearest' });
    }
  }

  async function openPipCompanion() {
    if (companionQueue.length === 0) {
      const visible = rows.filter((r) => !r.hidden);
      companionQueue = visible;
      companionIndex = 0;
      companionQueueLabel = '';
    }
    if (pipWindow && !pipWindow.closed) {
      renderCompanion();
      pipWindow.focus();
      return;
    }
    if ('documentPictureInPicture' in window) {
      try {
        pipWindow = await window.documentPictureInPicture.requestWindow({
          width: 560,
          height: 410,
        });
        pipWindow.document.title = 'Triage Companion';
        const styleEl = pipWindow.document.createElement('style');
        styleEl.textContent = Array.from(document.querySelectorAll('style'))
            .map((s) => s.textContent)
            .join('\n');
        pipWindow.document.head.appendChild(styleEl);
        pipWindow.document.body.className = 'pip-companion-body';
        const root = pipWindow.document.createElement('div');
        root.id = 'pip-companion-root';
        pipWindow.document.body.appendChild(root);
        bindCompanionEvents(root, pipWindow);
        pipWindow.addEventListener('keydown', (e) => {
          if (e.key === 'ArrowLeft' || e.key === '[') {
            e.preventDefault();
            if (companionQueue.length > 0) {
              companionIndex = (companionIndex - 1 + companionQueue.length) % companionQueue.length;
              renderCompanion();
              if (companionAutoOpen) {
                openOrFocusGitHub(extractRowData(companionQueue[companionIndex]).url);
              }
            }
          } else if (e.key === 'ArrowRight' || e.key === ']') {
            e.preventDefault();
            if (companionQueue.length > 0) {
              companionIndex = (companionIndex + 1) % companionQueue.length;
              renderCompanion();
              if (companionAutoOpen) {
                openOrFocusGitHub(extractRowData(companionQueue[companionIndex]).url);
              }
            }
          }
        });
        pipWindow.addEventListener('pagehide', () => {
          pipWindow = null;
          if (companionDock && companionQueue.length > 0) {
            companionDock.hidden = false;
            renderCompanion();
          }
        });
        renderCompanion();
        return;
      } catch (err) {
        pipWindow = null;
      }
    }
    if (companionDock) {
      companionDock.hidden = false;
      renderCompanion();
    }
  }

  function selectRowInCompanion(row, shouldOpenPip) {
    const sectionEl = row.closest('details[data-section]');
    const sectionRows = sectionEl
        ? Array.from(sectionEl.querySelectorAll('tbody tr[data-number]:not([hidden])'))
        : rows.filter((r) => !r.hidden);
    if (!companionQueue.includes(row)) {
      companionQueue = sectionRows.length > 0 ? sectionRows : [row];
      companionQueueLabel = '';
    }
    companionIndex = Math.max(0, companionQueue.indexOf(row));
    if (shouldOpenPip) {
      openPipCompanion();
    } else {
      if (companionDock && !(pipWindow && !pipWindow.closed)) {
        companionDock.hidden = false;
      }
      renderCompanion();
    }
  }

  if (companionDock) {
    bindCompanionEvents(companionDock, window);
  }
  if (openCompanionButton) {
    openCompanionButton.addEventListener('click', () => {
      if (companionQueue.length === 0) {
        companionQueue = rows.filter((r) => !r.hidden);
        companionIndex = 0;
        companionQueueLabel = '';
      }
      openPipCompanion();
    });
  }
  for (const row of rows) {
    row.addEventListener('click', (e) => {
      const link = e.target.closest('a[href]');
      if (link) {
        selectRowInCompanion(row, false);
        return;
      }
      selectRowInCompanion(row, true);
    });
  }

  function hiddenByLabel(row) {
    if (hiddenLabels.length === 0) {
      return false;
    }
    const hasLabel = row.dataset.labels.split('|').some((label) => hiddenLabels.includes(label));
    return hasLabel ? !showDesign : !showNonDesign;
  }

  function saveDesignPrefs() {
    try {
      localStorage.setItem(nonDesignStorageKey, String(showNonDesign));
      localStorage.setItem(designStorageKey, String(showDesign));
    } catch (e) {
      // Not saved, but the checkboxes still work on this page.
    }
  }

  function visibleRows(sectionEl) {
    return Array.from(sectionEl.querySelectorAll('tbody tr[data-number]:not([hidden])'));
  }

  function visibleLinks(sectionEl) {
    return Array.from(
      sectionEl.querySelectorAll('tbody tr[data-number]:not([hidden]) td.pr a[href]')
    ).map((a) => a.href).filter(Boolean);
  }

  function syncSectionButtons(sectionEl) {
    const links = visibleLinks(sectionEl);
    let offset = Number(sectionEl.dataset.batchOffset || '0');
    if (offset >= links.length) {
      offset = 0;
      sectionEl.dataset.batchOffset = '0';
    }
    const batchBtn = sectionEl.querySelector('.open-batch');
    const allBtn = sectionEl.querySelector('.open-all');
    if (batchBtn) {
      batchBtn.disabled = links.length === 0;
      batchBtn.textContent = offset > 0 ? 'Open next 10' : 'Open first 10';
    }
    if (allBtn) {
      allBtn.disabled = links.length === 0;
    }
  }

  function update() {
    const query = filter.value.trim().toLowerCase();
    for (const row of rows) {
      row.hidden = hiddenByLabel(row) ||
          (hideWaitingResponse && row.dataset.waitingResponse === 'true') ||
          (onlyFollowUp && row.dataset.followup !== 'true') ||
          (query !== '' && !row.dataset.search.includes(query));
    }
    for (const count of document.querySelectorAll('[data-count]')) {
      const section = document.getElementById(count.dataset.count);
      count.textContent = section
          ? section.querySelectorAll('tbody tr[data-number]:not([hidden])').length
          : '0';
    }
    for (const sectionEl of sections) {
      sectionEl.dataset.batchOffset = '0';
      syncSectionButtons(sectionEl);
    }
    if (showNonDesignCheckbox) {
      showNonDesignCheckbox.checked = showNonDesign;
    }
    if (showDesignCheckbox) {
      showDesignCheckbox.checked = showDesign;
    }
    if (followUpToggle) {
      followUpToggle.setAttribute('aria-pressed', String(onlyFollowUp));
    }
    if (hideWaitingCheckbox) {
      hideWaitingCheckbox.checked = hideWaitingResponse;
    }
    if (openCompanionButton) {
      openCompanionButton.disabled = rows.every((r) => r.hidden);
    }
  }

  for (const sectionEl of sections) {
    const batchBtn = sectionEl.querySelector('.open-batch');
    const allBtn = sectionEl.querySelector('.open-all');
    if (batchBtn) {
      batchBtn.addEventListener('click', (e) => {
        e.preventDefault();
        e.stopPropagation();
        const sectionRows = visibleRows(sectionEl);
        const links = visibleLinks(sectionEl);
        if (links.length === 0) {
          return;
        }
        let offset = Number(sectionEl.dataset.batchOffset || '0');
        if (offset >= links.length) {
          offset = 0;
        }
        const batchRows = sectionRows.slice(offset, offset + 10);
        for (const url of links.slice(offset, offset + 10)) {
          const win = window.open(url, '_blank');
          if (win) {
            openedTabsByUrl.set(url, win);
          }
        }
        if (batchRows.length > 0) {
          companionQueue = batchRows;
          companionIndex = 0;
          const h2 = sectionEl.querySelector('summary h2');
          const secTitle = h2 ? h2.textContent.replace(/\s*\(\d+\)\s*$/, '').trim() : '';
          companionQueueLabel = `${secTitle} (${offset + 1}–${offset + batchRows.length})`;
          if (companionDock && !(pipWindow && !pipWindow.closed)) {
            companionDock.hidden = false;
          }
          renderCompanion();
        }
        const nextOffset = offset + 10;
        sectionEl.dataset.batchOffset = nextOffset < links.length ? String(nextOffset) : '0';
        syncSectionButtons(sectionEl);
      });
    }
    if (allBtn) {
      allBtn.addEventListener('click', (e) => {
        e.preventDefault();
        e.stopPropagation();
        const sectionRows = visibleRows(sectionEl);
        for (const url of visibleLinks(sectionEl)) {
          const win = window.open(url, '_blank');
          if (win) {
            openedTabsByUrl.set(url, win);
          }
        }
        if (sectionRows.length > 0) {
          companionQueue = sectionRows;
          companionIndex = 0;
          companionQueueLabel = '';
          if (companionDock && !(pipWindow && !pipWindow.closed)) {
            companionDock.hidden = false;
          }
          renderCompanion();
        }
      });
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
  if (showNonDesignCheckbox) {
    showNonDesignCheckbox.addEventListener('change', () => {
      showNonDesign = showNonDesignCheckbox.checked;
      if (!showNonDesign && !showDesign) {
        showDesign = true;
      }
      saveDesignPrefs();
      update();
    });
  }
  if (showDesignCheckbox) {
    showDesignCheckbox.addEventListener('change', () => {
      showDesign = showDesignCheckbox.checked;
      if (!showDesign && !showNonDesign) {
        showNonDesign = true;
      }
      saveDesignPrefs();
      update();
    });
  }
  if (followUpToggle) {
    followUpToggle.addEventListener('click', () => {
      onlyFollowUp = !onlyFollowUp;
      update();
    });
  }
  if (hideWaitingCheckbox) {
    hideWaitingCheckbox.addEventListener('change', () => {
      hideWaitingResponse = hideWaitingCheckbox.checked;
      try {
        localStorage.setItem(waitingResponseStorageKey, String(hideWaitingResponse));
      } catch (e) {
        // Not saved, but the checkbox still works on this page.
      }
      update();
    });
  }

  if (refreshButton) {
    const hostMatch = window.location.hostname.match(/^([^.]+)\.github\.io$/);
    const pathSeg = window.location.pathname.split('/').filter(Boolean)[0];
    const workflowRepo = (hostMatch && pathSeg)
        ? `${hostMatch[1]}/${pathSeg}`
        : (body.dataset.workflowRepo || 'tarrinneal/packages-triage');
    const runsApiUrl = `https://api.github.com/repos/${workflowRepo}/actions/workflows/deploy_pages.yml/runs?per_page=10`;
    const dispatchApiUrl = `https://api.github.com/repos/${workflowRepo}/actions/workflows/deploy_pages.yml/dispatches`;
    const actionsHtmlUrl = `https://github.com/${workflowRepo}/actions/workflows/deploy_pages.yml`;

    let lastRunTimeMs = Date.parse(body.dataset.generatedAt || '') || 0;
    try {
      const savedLastRun = Number(localStorage.getItem(lastRunStorageKey));
      if (savedLastRun > lastRunTimeMs) {
        lastRunTimeMs = savedLastRun;
      }
    } catch (e) {
      // Ignore storage errors.
    }
    let runInProgress = false;
    let pollTimer = null;

    function formatRemaining(ms) {
      const totalSec = Math.max(1, Math.ceil(ms / 1000));
      const min = Math.floor(totalSec / 60);
      const sec = totalSec % 60;
      return min > 0 ? `${min}m ${String(sec).padStart(2, '0')}s` : `${sec}s`;
    }

    function syncRefreshButton() {
      if (runInProgress) {
        refreshButton.disabled = true;
        refreshButton.textContent = '↻ Running action…';
        refreshButton.title = 'GitHub Action is currently running.';
        return;
      }
      const elapsed = Date.now() - lastRunTimeMs;
      if (lastRunTimeMs > 0 && elapsed < cooldownMs) {
        refreshButton.disabled = true;
        refreshButton.textContent = `↻ Refresh in ${formatRemaining(cooldownMs - elapsed)}`;
        refreshButton.title = 'Action can only be run at least 5 minutes after the last run.';
      } else {
        refreshButton.disabled = false;
        refreshButton.textContent = '↻ Refresh report';
        refreshButton.title = 'Trigger the GitHub Action to rebuild and deploy this report.';
      }
    }

    async function checkWorkflowRuns() {
      try {
        const res = await fetch(runsApiUrl, {
          headers: { 'Accept': 'application/vnd.github+json' },
          cache: 'no-store',
        });
        if (!res.ok) {
          return;
        }
        const data = await res.json();
        const runs = Array.isArray(data.workflow_runs) ? data.workflow_runs : [];
        const activeRun = runs.find((r) => r.status !== 'completed');
        if (activeRun) {
          runInProgress = true;
          const startedMs = Date.parse(activeRun.run_started_at || activeRun.created_at || '') || Date.now();
          if (startedMs > lastRunTimeMs) {
            lastRunTimeMs = startedMs;
          }
          if (!pollTimer) {
            pollTimer = setInterval(async () => {
              await checkWorkflowRuns();
              if (!runInProgress) {
                clearInterval(pollTimer);
                pollTimer = null;
                window.location.reload();
              }
            }, 10000);
          }
        } else {
          runInProgress = false;
        }
        for (const run of runs) {
          if (run.conclusion !== 'success') {
            continue;
          }
          const started = Date.parse(run.run_started_at || run.created_at || '') || 0;
          const updated = Date.parse(run.updated_at || '') || 0;
          if (updated - started < 20000) {
            continue;
          }
          if (updated > lastRunTimeMs) {
            lastRunTimeMs = updated;
            try {
              localStorage.setItem(lastRunStorageKey, String(lastRunTimeMs));
            } catch (e) {
              // Ignore storage errors.
            }
          }
          break;
        }
      } catch (e) {
        // Ignore network errors during background status check.
      }
      syncRefreshButton();
    }

    refreshButton.addEventListener('click', async () => {
      await checkWorkflowRuns();
      if (runInProgress || (lastRunTimeMs > 0 && Date.now() - lastRunTimeMs < cooldownMs)) {
        syncRefreshButton();
        return;
      }
      let token = null;
      try {
        token = localStorage.getItem(tokenStorageKey);
      } catch (e) {
        // Ignore storage errors.
      }
      if (!token) {
        const input = window.prompt(
          `Enter a GitHub token with Actions write permission for ${workflowRepo} (saved in localStorage):`
        );
        if (!input || !input.trim()) {
          return;
        }
        token = input.trim();
        try {
          localStorage.setItem(tokenStorageKey, token);
        } catch (e) {
          // Ignore storage errors.
        }
      }
      refreshButton.disabled = true;
      refreshButton.textContent = '↻ Starting…';
      if (refreshStatus) {
        refreshStatus.textContent = '';
      }
      try {
        const res = await fetch(dispatchApiUrl, {
          method: 'POST',
          headers: {
            'Accept': 'application/vnd.github+json',
            'Authorization': `Bearer ${token}`,
            'Content-Type': 'application/json',
          },
          body: JSON.stringify({ ref: 'main' }),
        });
        if (res.status === 401 || res.status === 403) {
          try {
            localStorage.removeItem(tokenStorageKey);
          } catch (e) {
            // Ignore storage errors.
          }
          if (refreshStatus) {
            refreshStatus.textContent = `Token rejected (needs Actions write access on ${workflowRepo}). Click again to enter a new token.`;
          }
          syncRefreshButton();
          return;
        }
        if (!res.ok) {
          if (refreshStatus) {
            refreshStatus.textContent = `Failed to start workflow (HTTP ${res.status}).`;
          }
          syncRefreshButton();
          return;
        }
        lastRunTimeMs = Date.now();
        try {
          localStorage.setItem(lastRunStorageKey, String(lastRunTimeMs));
        } catch (e) {
          // Ignore storage errors.
        }
        runInProgress = true;
        if (refreshStatus) {
          refreshStatus.innerHTML = `Workflow triggered — <a href="${actionsHtmlUrl}" target="_blank" rel="noopener">view on GitHub Actions</a>`;
        }
        syncRefreshButton();
        setTimeout(checkWorkflowRuns, 4000);
      } catch (e) {
        if (refreshStatus) {
          refreshStatus.textContent = 'Network error triggering workflow.';
        }
        syncRefreshButton();
      }
    });

    syncRefreshButton();
    setInterval(syncRefreshButton, 1000);
    checkWorkflowRuns();
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
      const sectionEl = table.closest('details[data-section]');
      if (sectionEl) {
        sectionEl.dataset.batchOffset = '0';
        syncSectionButtons(sectionEl);
      }
    });
  }

  update();
})();
''';
