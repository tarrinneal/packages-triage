// Copyright 2013 The Flutter Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:io';

import 'package:ansicolor/ansicolor.dart';

import 'report_state.dart';
import 'triage.dart';
import 'types.dart';
import 'utils.dart';

/// Prints [prs], which must already be sorted with [comparePRs], grouped by
/// page and section, followed by any actionable [issues].
///
/// PRs with any of [hiddenLabels] are left out unless [showHidden] is true.
void printTextReport(
  String repo,
  List<PRAnalysis> prs, {
  List<IssueAnalysis> issues = const <IssueAnalysis>[],
  String? issuesRepo,
  Set<String> hiddenLabels = defaultHiddenLabels,
  bool showHidden = false,
  Map<int, PreviousPlacement>? previous,
  StringSink? out,
}) {
  final StringSink sink = out ?? stdout;
  final headingPen = AnsiPen()..white(bold: true);
  final List<PRAnalysis> shown = showHidden
      ? prs
      : prs.where((PRAnalysis a) => !hasHiddenLabel(a.pr, hiddenLabels)).toList();
  for (final ReportPage page in ReportPage.values) {
    final List<PRAnalysis> pagePRs = shown.where((PRAnalysis a) => a.page == page).toList();
    sink
      ..writeln(headingPen('$repo · ${pageTitle(page)} (${pagePRs.length})'))
      ..writeln();
    for (final Section section in sectionsFor(page)) {
      final List<PRAnalysis> rows = pagePRs.where((PRAnalysis a) => a.section == section).toList();
      if (rows.isEmpty) {
        continue;
      }
      sink.writeln(headingPen('${sectionTitle(section, page)} (${rows.length})'));
      for (final row in rows) {
        _printRow(sink, row, previous);
      }
      sink.writeln();
    }
  }
  if (issues.isNotEmpty) {
    final String effectiveIssuesRepo = issuesRepo ?? repo;
    sink
      ..writeln(headingPen('$effectiveIssuesRepo · Package Issues (${issues.length})'))
      ..writeln();
    for (final IssueSection section in IssueSection.values) {
      final List<IssueAnalysis> rows = issues
          .where((IssueAnalysis a) => a.section == section)
          .toList();
      if (rows.isEmpty) {
        continue;
      }
      sink.writeln(headingPen('${issueSectionTitle(section)} (${rows.length})'));
      for (final row in rows) {
        _printIssueRow(sink, row);
      }
      sink.writeln();
    }
  }
  final int hiddenCount = prs.length - shown.length;
  if (hiddenCount > 0) {
    sink.writeln(
      '$hiddenCount ${hiddenCount == 1 ? 'PR' : 'PRs'} labeled ${hiddenLabels.join(' or ')} '
      'not shown; use --show-hidden to include them.',
    );
  }
}

void _printRow(StringSink sink, PRAnalysis analysis, Map<int, PreviousPlacement>? previous) {
  final PRInfo pr = analysis.pr;
  final Badge? badge = badgeFor(analysis, previous);
  final String reviewers = reviewersText(pr);
  final details = <String>[
    _penFor(analysis)(waitingLabel(analysis)),
    if (analysis.nextStep.isNotEmpty) analysis.nextStep,
    if (reviewers.isNotEmpty) reviewers,
  ];
  sink
    ..writeln(
      '  #${pr.number}${badge == null ? '' : ' [${badge.label}]'}'
      '${analysis.isFollowUp ? ' [FOLLOW-UP]' : ''} ${pr.title} · '
      '${emojiForContributorType(pr.authorType)} ${pr.author}',
    )
    ..writeln('    ${details.join(' · ')}')
    ..writeln('    ${pr.url}');
}

void _printIssueRow(StringSink sink, IssueAnalysis analysis) {
  final IssueInfo issue = analysis.issue;
  final details = <String>[
    _penForUrgency(analysis.urgency, loadError: analysis.section == IssueSection.loadError)(
      issueWaitingLabel(analysis),
    ),
    if (analysis.nextStep.isNotEmpty) analysis.nextStep,
    if (issue.assignees.isNotEmpty) issue.assignees.map((String a) => '@$a').join(', '),
  ];
  sink
    ..writeln(
      '  #${issue.number}${analysis.isFollowUp ? ' [FOLLOW-UP]' : ''} ${issue.title} · '
      '${emojiForContributorType(issue.authorType)} ${issue.author}',
    )
    ..writeln('    ${details.join(' · ')}')
    ..writeln('    ${issue.url}');
}

AnsiPen _penFor(PRAnalysis analysis) =>
    _penForUrgency(analysis.urgency, loadError: analysis.section == Section.loadError);

AnsiPen _penForUrgency(Urgency urgency, {required bool loadError}) {
  if (loadError) {
    return AnsiPen()..magenta();
  }
  return switch (urgency) {
    Urgency.notYet => AnsiPen()..green(),
    Urgency.due => AnsiPen()..yellow(),
    Urgency.overdue => AnsiPen()..red(),
    Urgency.critical => AnsiPen()..red(bold: true),
  };
}

/// Prints everything the tool knows about [analysis]'s PR, and why it was
/// placed where it was.
void printExplanation(PRAnalysis analysis, {StringSink? out}) {
  final StringSink sink = out ?? stdout;
  final PRInfo pr = analysis.pr;
  final String reviewers = reviewersText(pr);
  sink
    ..writeln('#${pr.number}${analysis.isFollowUp ? ' [FOLLOW-UP]' : ''}: ${pr.title}')
    ..writeln('  ${pr.url}')
    ..writeln(
      '  Author:     ${emojiForContributorType(pr.authorType)} ${pr.author} '
      '(${pr.authorType.name})',
    )
    ..writeln(
      '  Placement:  ${pageTitle(analysis.page)} › ${sectionTitle(analysis.section, analysis.page)}',
    )
    ..writeln(
      '  Waiting:    ${_penFor(analysis)(waitingLabel(analysis))} since '
      '${formatAsDay(analysis.waitingSince)} (${urgencyLabel(analysis.urgency)})',
    )
    ..writeln('  Next step:  ${analysis.nextStep.isEmpty ? 'nothing yet' : analysis.nextStep}')
    ..writeln('  Reviewers:  ${reviewers.isEmpty ? 'none' : reviewers}')
    ..writeln('  Labels:     ${pr.labels.isEmpty ? 'none' : pr.labels.join(', ')}');
  if (pr.hasDetails) {
    sink
      ..writeln('  Last comments:')
      ..writeln('    Author:     ${_formatComment(pr.authorComment)}')
      ..writeln('    Team:       ${_formatComment(pr.memberComment)}')
      ..writeln('    Non-member: ${_formatComment(pr.nonMemberComment)}');
    if (pr.authorFollowUpComment != null &&
        pr.authorComment != null &&
        pr.authorFollowUpComment!.date != pr.authorComment!.date) {
      sink.writeln('    Follow-up:  ${_formatComment(pr.authorFollowUpComment)}');
    }
  }
  sink.writeln('  Why:');
  for (final String reason in analysis.reasons) {
    sink.writeln('    - $reason');
  }
}

String _formatComment(Comment? comment) {
  if (comment == null) {
    return 'N/A';
  }
  return '${comment.username} on ${formatAsDay(comment.date)}';
}
