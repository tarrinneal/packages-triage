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
/// page and section.
///
/// PRs with any of [hiddenLabels] are left out unless [showHidden] is true.
void printTextReport(
  String repo,
  List<PRAnalysis> prs, {
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
      '  #${pr.number}${badge == null ? '' : ' [${badge.label}]'} ${pr.title} · '
      '${emojiForContributorType(pr.authorType)} ${pr.author}',
    )
    ..writeln('    ${details.join(' · ')}')
    ..writeln('    ${pr.url}');
}

AnsiPen _penFor(PRAnalysis analysis) {
  if (analysis.section == Section.loadError) {
    return AnsiPen()..magenta();
  }
  return switch (analysis.urgency) {
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
    ..writeln('#${pr.number}: ${pr.title}')
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
