// Copyright 2013 The Flutter Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

// ignore_for_file: avoid_redundant_argument_values

import 'package:pr_inspector/types.dart';

/// Triage configuration for the Flutter Design Languages (Material & Cupertino)
/// team.
///
/// Based on https://github.com/flutter/flutter/blob/master/docs/triage/README.md#design-languages-triage
/// Edit this file to adjust the repositories, PR filter labels, schedule, or
/// team members.
const TriageConfig config = TriageConfig(
  repos: <String>['flutter/flutter', 'flutter/packages'],
  flutterTeam: 'design',
  refreshSchedule: '30 16 * * 2',
  prLabels: <String>{
    'f: cupertino',
    'f: material design',
    'p: animations',
    'p: cupertino_icons',
    'p: cupertino_ui',
    'p: google_fonts',
    'p: material_ui',
    'team-design',
    'fyi-design',
    'triage-design',
  },
  teamMembers: <String>[
    'dkwingsmt',
    'hannah-hyj',
    'justinmc',
    'Piinks',
    'qunccccccc',
    'Renzo-Olivares',
    'victorsanni',
  ],
);
