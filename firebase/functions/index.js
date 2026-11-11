'use strict';

const { onSchedule } = require('firebase-functions/v2/scheduler');
const { defineSecret } = require('firebase-functions/params');
const { triggerWorkflowRefresh } = require('./refresh');

const githubActionsToken = defineSecret('GITHUB_ACTIONS_TOKEN');
const defaultWorkflowRepo = process.env.WORKFLOW_REPO || 'tarrinneal/packages-triage';

const recentDispatches = new Map();

/**
 * Reliable hourly Cloud Scheduler trigger that calls workflow_dispatch on
 * deploy_pages.yml, avoiding GitHub Actions on.schedule delays and drops.
 * Uses ALLOW_INTERNAL_ONLY ingress to satisfy GCP org ingress constraints.
 */
exports.scheduledTriageRefresh = onSchedule(
  {
    schedule: '0 * * * *',
    timeZone: 'Etc/UTC',
    ingressSettings: 'ALLOW_INTERNAL_ONLY',
    secrets: [githubActionsToken],
  },
  async () => {
    const result = await triggerWorkflowRefresh({
      repo: defaultWorkflowRepo,
      token: githubActionsToken.value(),
      recentDispatches,
    });
    console.log('Scheduled triage refresh result:', result.httpStatus, JSON.stringify(result.body));
  },
);
