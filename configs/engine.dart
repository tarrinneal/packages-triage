// Copyright 2013 The Flutter Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

// ignore_for_file: avoid_redundant_argument_values

import 'package:pr_inspector/types.dart';

/// Triage configuration for the Flutter Engine team.
///
/// Based on https://github.com/flutter/flutter/blob/master/docs/triage/README.md#engine-triage
/// Edit this file to adjust the repositories, PR filter labels, schedule, or
/// team members.
const TriageConfig config = TriageConfig(
  repos: <String>['flutter/flutter', 'flutter/buildroot'],
  flutterTeam: 'engine',
  refreshSchedule: '0 17 * * 2',
  prLabels: <String>{'engine', 'team-engine', 'fyi-engine'},
  teamMembers: <String>[
    'chinmaygarde',
    'domesticmouse',
    'gaaclarke',
    'jason-simmons',
    'jonahwilliams',
    'jtmcdole',
    'loic-sharma',
  ],
);
