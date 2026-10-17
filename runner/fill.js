#!/usr/bin/env node
'use strict';

/**
 * fill.js — execute a single fill job against a website.
 *
 * Usage:
 *   node fill.js --job <job.json>
 *
 * Job JSON:
 *   {
 *     "url": "https://…",
 *     "storageState": "/path/state.json",   // optional
 *     "headless": true,                      // optional, default true
 *     "slowMoMs": 0,                         // optional
 *     "screenshotPath": "/path/shot.png",    // optional; also used on failure
 *     "options": {
 *       "humanize": {                        // optional, see executor.js
 *         "enabled": true, "stepDelayMinMs": 400, "stepDelayMaxMs": 1200,
 *         "typeDelayMinMs": 40, "typeDelayMaxMs": 140, "mouseSteps": 12,
 *         "stealth": true, "channel": "chromium",
 *         "viewportW": 1280, "viewportH": 800,
 *         "userAgent": "", "locale": "", "timezoneId": ""
 *       }
 *     },
 *     "steps": [ … ]                          // see executor.js runStep
 *   }
 *
 * Output (JSONL on stdout):
 *   {type:'log'|'progress'|'warning'|'captcha_detected'|'awaiting_manual_captcha', …}
 *   {type:'result', ok:true, steps:N}            on success
 *   {type:'result', values:{…}}                  for dump steps
 *   {type:'error', step, action, message}        on failure (fail fast)
 */

const fs = require('fs');
const {
  executeSteps,
  launchBrowser,
  buildContextOptions,
  handleCaptcha,
} = require('./executor');

const emit = (obj) => console.log(JSON.stringify(obj));

function parseArgs(argv) {
  const out = {};
  for (let i = 0; i < argv.length; i++) {
    if (argv[i] === '--job') out.job = argv[++i];
  }
  return out;
}

async function main() {
  const args = parseArgs(process.argv.slice(2));
  if (!args.job) {
    emit({ type: 'error', message: 'Missing required --job argument' });
    process.exit(1);
  }

  let job;
  try {
    job = JSON.parse(fs.readFileSync(args.job, 'utf8'));
  } catch (err) {
    emit({ type: 'error', message: `Cannot read job file: ${err.message}` });
    process.exit(1);
  }
  if (!job.url) {
    emit({ type: 'error', message: 'Job needs "url"' });
    process.exit(1);
  }
  const steps = job.steps || [];
  const humanize = (job.options && job.options.humanize) || {};
  const defaultTimeout = 30000;

  emit({ type: 'log', message: `Launching browser (${job.headless === false ? 'headed' : 'headless'})` });
  const browser = await launchBrowser(job, humanize, emit);

  let failureShot = null;
  try {
    const context = await browser.newContext(buildContextOptions(job, humanize));
    const page = await context.newPage();

    emit({ type: 'log', message: `Opening ${job.url}` });
    await page.goto(job.url, { waitUntil: 'domcontentloaded', timeout: 45000 });
    await page.waitForLoadState('networkidle', { timeout: 15000 }).catch(() => {});

    // CAPTCHA check after the initial navigation (before running steps).
    const headless = job.headless !== false;
    const initialCaptcha = await handleCaptcha(page, headless, emit);
    if (initialCaptcha.status === 'blocked' || initialCaptcha.status === 'timeout') {
      if (job.screenshotPath) {
        failureShot = job.screenshotPath;
        await page.screenshot({ path: failureShot }).catch(() => {});
      }
      emit({
        type: 'result',
        ok: false,
        blocked: 'captcha',
        message: 'Blocked by CAPTCHA (manual solve required)',
      });
      process.exitCode = 1;
      return;
    }

    const outcome = await executeSteps(page, steps, {
      emit,
      humanize,
      defaultTimeout,
      headless: job.headless !== false,
      job,
    });

    if (!outcome.ok) {
      if (job.screenshotPath) {
        failureShot = job.screenshotPath;
        await page.screenshot({ path: failureShot }).catch(() => {});
        emit({ type: 'log', message: `Failure screenshot saved: ${failureShot}` });
      }
      process.exitCode = 1;
      return;
    }

    if (job.screenshotPath && !failureShot) {
      await page.screenshot({ path: job.screenshotPath }).catch(() => {});
    }
    emit({ type: 'result', ok: true, steps: steps.length });
  } catch (err) {
    emit({ type: 'error', message: String((err && err.message) || err).split('\n')[0] });
    process.exitCode = 1;
  } finally {
    await browser.close();
  }
}

main();
