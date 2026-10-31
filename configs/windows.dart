// Copyright 2013 The Flutter Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

// ignore_for_file: avoid_redundant_argument_values

import 'package:pr_inspector/types.dart';

/// Triage configuration for the Flutter Windows team.
///
/// Based on https://github.com/flutter/flutter/blob/master/docs/triage/README.md#windows-triage
/// Edit this file to adjust the repositories, PR filter labels, schedule, or
/// team members.
const TriageConfig config = TriageConfig(
  repos: <String>['flutter/flutter', 'flutter/packages'],
  flutterTeam: 'windows',
  refreshSchedule: '30 19 * * 2',
  prLabels: <String>{'platform-windows', 'team-windows', 'fyi-windows', 'triage-windows'},
  teamMembers: <String>['cbracken', 'loic-sharma', 'stuartmorgan-g'],
);
