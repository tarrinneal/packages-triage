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

/// Writes the report as two linked HTML pages: community and bot PRs to
/// [communityFile], and team PRs to [teamPageFileFor] it.
///
/// [prs] must already be sorted with [comparePRs]. PRs with any of
/// [hiddenLabels] start out hidden unless [showHiddenByDefault] is true, and
/// a button on each page shows or hides them. [previous] placements, if
/// given, are used for NEW and MOVED badges. [note] is shown under the
/// header, e.g. to say the report is partial.
void writeHtmlReport({
  required String repo,
  required List<PRAnalysis> prs,
  required File communityFile,
  required DateTime generatedAt,
  Map<int, PreviousPlacement>? previous,
  Set<String> hiddenLabels = defaultHiddenLabels,
  bool showHiddenByDefault = false,
  String? note,
}) {
  final files = <ReportPage, File>{
    ReportPage.community: communityFile,
    ReportPage.team: teamPageFileFor(communityFile),
  };
  for (final ReportPage page in ReportPage.values) {
    final String html = _PageRenderer(
      page: page,
      repo: repo,
      prs: prs,
      files: files,
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
}

class _PageRenderer {
  _PageRenderer({
    required this.page,
    required this.repo,
    required this.prs,
    required this.files,
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
  final Map<ReportPage, File> files;
  final DateTime generatedAt;
  final Map<int, PreviousPlacement>? previous;
  final Set<String> hiddenLabels;
  final bool showHiddenByDefault;
  final String? note;

  final StringBuffer _out = StringBuffer();

  bool _startsHidden(PRAnalysis analysis) =>
      !showHiddenByDefault && hasHiddenLabel(analysis.pr, hiddenLabels);

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
    ];
    final sectionLinks = <String>[for (final section in sections) _sectionLink(section)];
    final int hiddenCount = pagePRs
        .where((PRAnalysis a) => hasHiddenLabel(a.pr, hiddenLabels))
        .length;
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
      pr.title,
      pr.author,
      ...pr.labels,
      ...pr.reviewers.keys,
      analysis.nextStep,
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
<li><span class="badge new">NEW</span> not in the previous report · <span class="badge moved">MOVED</span> in a different section in the previous report</li>
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
  final comments = <(String, Comment?)>[
    ('author', pr.authorComment),
    ('team', pr.memberComment),
    ('other', pr.nonMemberComment),
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
  final DateTime newest =
      newestComment(<Comment?>[pr.authorComment, pr.memberComment, pr.nonMemberComment])?.date ??
      pr.creationDate;
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
  body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif; margin: 20px; color: #202124; }
  h1 { font-size: 1.5em; margin: 0 0 4px; }
  h2 { display: inline; font-size: 1.15em; }
  nav, .meta, .note { margin: 4px 0; }
  .meta, .note { color: #5f6368; }
  .controls { display: flex; gap: 8px; margin: 10px 0; }
  #filter { flex: 1; max-width: 36em; padding: 4px 8px; }
  .banner { background: #fce8e6; border: 1px solid #d93025; border-radius: 4px; padding: 8px; }
  details { margin: 14px 0; }
  summary { cursor: pointer; padding: 4px 0; }
  table { border-collapse: collapse; width: 100%; margin: 4px 0 12px; }
  tr { font-size: 11pt; }
  tbody tr:nth-child(even) { background-color: #ebf7fd; }
  th, td { border: none; padding: 6px 8px; text-align: left; vertical-align: top; }
  th { background-color: #7dc7f4; cursor: pointer; user-select: none; white-space: nowrap; }
  th[aria-sort="ascending"]::after { content: " \25B2"; }
  th[aria-sort="descending"]::after { content: " \25BC"; }
  td.pr, td.waiting, td.activity, td.opened { white-space: nowrap; }
  tr.not-due { opacity: 0.55; }
  tr.draft td.title { color: #888; }
  .labels { margin-top: 2px; }
  .label { display: inline-block; font-size: 0.8em; background: #e8eaed; border-radius: 8px; padding: 0 6px; margin: 2px 4px 0 0; white-space: nowrap; }
  .label.hidden-label { background: #fde293; }
  .badge { display: inline-block; font-size: 0.7em; font-weight: bold; color: white; border-radius: 4px; padding: 1px 4px; vertical-align: middle; }
  .badge.new { background: #1e8e3e; }
  .badge.moved { background: #9334e6; }
  .urgency-notYet { color: green; }
  .urgency-due { color: #e37400; }
  .urgency-overdue { color: red; }
  .urgency-critical { color: #a50e0e; font-weight: bold; }
  .reviewer { white-space: nowrap; }
  .empty { color: #5f6368; font-style: italic; }
  .legend { color: #5f6368; font-size: 0.9em; margin-top: 24px; }
''';

const String _script = r'''
(() => {
  'use strict';
  const body = document.body;
  const hiddenLabels = (body.dataset.hiddenLabels || '').split('|').filter((label) => label !== '');
  const storageKey = 'prTriage.showHidden';
  const filter = document.getElementById('filter');
  const toggle = document.getElementById('toggle-hidden');
  const rows = Array.from(document.querySelectorAll('tbody tr[data-number]'));
  let showHidden = body.dataset.showHiddenDefault === 'true';
  try {
    const saved = localStorage.getItem(storageKey);
    if (saved !== null) {
      showHidden = saved === 'true';
    }
  } catch (e) {
    // Storage may be unavailable for file: URLs; use the default.
  }

  function hiddenByLabel(row) {
    return !showHidden &&
        row.dataset.labels.split('|').some((label) => hiddenLabels.includes(label));
  }

  function update() {
    const query = filter.value.trim().toLowerCase();
    for (const row of rows) {
      row.hidden = hiddenByLabel(row) || (query !== '' && !row.dataset.search.includes(query));
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
  }

  filter.addEventListener('input', update);
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
