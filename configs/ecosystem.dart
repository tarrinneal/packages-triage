// Copyright 2013 The Flutter Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

// ignore_for_file: avoid_redundant_argument_values

import 'package:pr_inspector/types.dart';

/// Configuration for the Flutter Ecosystem triage report (`ecosystem`).
///
/// To add another team page to the hosted site, copy this file to
/// `configs/<team>.dart` and update `repos` and `flutterTeam` (which
/// automatically configures `team-<name>`, `fyi-<name>`, and `triaged-<name>`
/// labels on `flutter/flutter`).
const TriageConfig config = TriageConfig(
  repos: <String>['flutter/packages', 'flutter/core-packages'],
  flutterTeam: 'ecosystem',
  refreshSchedule: '37 19 * * 2',
  teamMembers: <String>[
    'adsonpleal',
    'bkonyi',
    'bparrishMines',
    'camsim99',
    'chunhtai',
    'ditman',
    'dkwingsmt',
    'domesticmouse',
    'gmackall',
    'hannah-hyj',
    'hellohuanlin',
    'Hixie',
    'jesswrd',
    'jtmcdole',
    'LongCatIsLooong',
    'louisehsu',
    'mboetger',
    'mdebbar',
    'okorohelijah',
    'parlough',
    'Piinks',
    'qunccccccc',
    'reidbaker',
    'robert-ancell',
    'sokoloff06',
    'stuartmorgan-g',
    'tarrinneal',
    'vashworth',
    'victorsanni',
    'yjbanov',
  ],

  // flutter/packages-specific settings (set rosterFile to 'owner/repo:path' to
  // load from another repo, or null to disable):
  rosterFile: 'flutter/packages:SUGGESTED_REVIEWERS.md',
  hiddenLabels: <String>{'triage-design'},
  nonHiddenFilterLabel: 'triage-packages',

  // Optional overrides:
  // issuesRepo: 'flutter/flutter',
  // workflowRepo: 'tarrinneal/packages-triage',
  // requiredApprovals: 2,
  // showAllLabels: false,
);
