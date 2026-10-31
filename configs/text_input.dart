// Copyright 2013 The Flutter Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

// ignore_for_file: avoid_redundant_argument_values

import 'package:pr_inspector/types.dart';

/// Triage configuration for the Flutter Text Input team.
///
/// Based on https://github.com/flutter/flutter/blob/master/docs/triage/README.md#text-input-triage
/// Edit this file to adjust the repositories, PR filter labels, schedule, or
/// team members.
const TriageConfig config = TriageConfig(
  repos: <String>['flutter/flutter'],
  flutterTeam: 'text-input',
  refreshSchedule: '45 18 * * 2',
  prLabels: <String>{'a: text input', 'f: selection', 'team-text-input', 'fyi-text-input'},
  teamMembers: <String>['justinmc', 'LongCatIsLooong', 'Renzo-Olivares'],
);
