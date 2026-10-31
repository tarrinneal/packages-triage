// Copyright 2013 The Flutter Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

// ignore_for_file: avoid_redundant_argument_values

import 'package:pr_inspector/types.dart';

/// Triage configuration for the Flutter Android team.
///
/// Based on https://github.com/flutter/flutter/blob/master/docs/triage/README.md#android-triage
/// Edit this file to adjust the repositories, PR filter labels, schedule, or
/// team members.
const TriageConfig config = TriageConfig(
  repos: <String>['flutter/flutter', 'flutter/packages'],
  flutterTeam: 'android',
  refreshSchedule: '15 16 * * 2',
  prLabels: <String>{'platform-android', 'team-android', 'fyi-android', 'triage-android'},
  teamMembers: <String>[
    'camsim99',
    'gmackall',
    'jesswrd',
    'johnmccutchan',
    'mboetger',
    'reidbaker',
  ],
);
