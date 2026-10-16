// Copyright 2013 The Flutter Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:convert';
import 'dart:io';

import 'triage.dart';
import 'types.dart';

/// Where a PR was shown in a previous report.
typedef PreviousPlacement = ({ReportPage page, Section section});

/// A badge marking a PR that is new or has moved since the previous report.
typedef Badge = ({String label, String description});

/// Reads the placements that [writeReportState] saved for [repo], or returns
/// null if there are none.
Map<int, PreviousPlacement>? readReportState(File file, {required String repo}) {
  final Object? json;
  try {
    json = jsonDecode(file.readAsStringSync());
  } on FileSystemException {
    return null;
  } on FormatException {
    return null;
  }
  if (json is! Map<String, dynamic> || json['repo'] != repo) {
    return null;
  }
  final Object? prs = json['prs'];
  if (prs is! Map<String, dynamic>) {
    return null;
  }
  final Map<String, ReportPage> pages = ReportPage.values.asNameMap();
  final Map<String, Section> sections = Section.values.asNameMap();
  final placements = <int, PreviousPlacement>{};
  for (final MapEntry<String, dynamic> entry in prs.entries) {
    final int? number = int.tryParse(entry.key);
    final Object? value = entry.value;
    if (number == null || value is! Map<String, dynamic>) {
      continue;
    }
    final ReportPage? page = pages[value['page']];
    final Section? section = sections[value['section']];
    if (page != null && section != null) {
      placements[number] = (page: page, section: section);
    }
  }
  return placements;
}

/// Saves where each PR in [analyses] was shown, so the next report can mark
/// what changed.
///
/// PRs that failed to load keep their [previous] placement, so that a
/// transient failure doesn't show up as a move in the next report.
void writeReportState(
  File file,
  List<PRAnalysis> analyses, {
  required String repo,
  required DateTime generatedAt,
  Map<int, PreviousPlacement>? previous,
}) {
  final prs = <String, Object?>{};
  for (final analysis in analyses) {
    PreviousPlacement placement = (page: analysis.page, section: analysis.section);
    if (analysis.section == Section.loadError) {
      placement = previous?[analysis.pr.number] ?? placement;
    }
    prs['${analysis.pr.number}'] = <String, String>{
      'page': placement.page.name,
      'section': placement.section.name,
    };
  }
  file
    ..createSync(recursive: true)
    ..writeAsStringSync(
      const JsonEncoder.withIndent('  ').convert(<String, Object?>{
        'repo': repo,
        'generatedAt': generatedAt.toUtc().toIso8601String(),
        'prs': prs,
      }),
    );
}

/// The badge to show for [analysis] given the [previous] report's
/// placements, if any.
Badge? badgeFor(PRAnalysis analysis, Map<int, PreviousPlacement>? previous) {
  if (previous == null || analysis.section == Section.loadError) {
    return null;
  }
  final PreviousPlacement? before = previous[analysis.pr.number];
  if (before == null) {
    return (label: 'NEW', description: 'Not in the previous report');
  }
  if (before.section != Section.loadError &&
      (before.page != analysis.page || before.section != analysis.section)) {
    return (
      label: 'MOVED',
      description:
          'Was in ${pageTitle(before.page)} › ${sectionTitle(before.section, before.page)} '
          'in the previous report',
    );
  }
  return null;
}
