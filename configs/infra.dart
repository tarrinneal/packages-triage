// Copyright 2013 The Flutter Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

// ignore_for_file: avoid_redundant_argument_values

import 'package:pr_inspector/types.dart';

/// Triage configuration for the Flutter Infrastructure team.
///
/// Based on https://github.com/flutter/flutter/blob/master/docs/triage/Infra-Triage.md
/// Edit this file to adjust the repositories, PR filter labels, schedule, or
/// team members.
const TriageConfig config = TriageConfig(
  repos: <String>['flutter/cocoon'],
  flutterTeam: 'infra',
  refreshSchedule: '45 17 * * 2',
  teamMembers: <String>['jtmcdole', 'keyonghan', 'matanlurey'],
);
