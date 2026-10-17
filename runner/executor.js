#!/usr/bin/env node
'use strict';

/**
 * executor.js — shared browser + step execution for fill.js and batch.js.
 *
 * Exports:
 *   launchBrowser(job, humanize, emit) -> Promise<Browser>
 *   buildContextOptions(job, humanize) -> object
 *   executeSteps(page, steps, opts)    -> Promise<{ok:true} | {ok:false, ...}>
 *   detectCaptcha(page)               -> Promise<boolean>
 *   applyTemplate(str, row)           -> {text, missing:[...]}
 *   resolveLocator(page, step)        -> Locator
 *   rand(min, max), sleep(ms)
 *
 * Humanization (job.options.humanize):
 *   { enabled, stepDelayMinMs, stepDelayMaxMs, typeDelayMinMs, typeDelayMaxMs,
 *     mouseSteps, stealth, channel, viewportW, viewportH, userAgent, locale,
 *     timezoneId }
 *
 * CAPTCHAs are never solved automatically. When one is detected:
 *   - headed mode: emit 'awaiting_manual_captcha' and wait up to 5 minutes
 *     for the user to solve it manually;
 *   - headless mode: the row/run is marked blocked_captcha and skipped.
 */

function rand(min, max) {
  const lo = Number(min);
  const hi = Number(max);
  if (!isFinite(lo) || !isFinite(hi) || hi < lo) return isFinite(lo) ? lo : 0;
  return lo + Math.random() * (hi - lo);
}

function sleep(ms) {
  return new Promise((r) => setTimeout(r, Math.max(0, ms)));
}

const CAPTCHA_SELECTORS = [
  'iframe[src*="recaptcha"]',
  'div.g-recaptcha',
  '[data-sitekey]',
  '.cf-turnstile',
  'iframe[src*="challenges.cloudflare"]',
  'img[src*="captcha"]',
  '#captcha',
];

/** True when any known CAPTCHA marker is present on the page. */
async function detectCaptcha(page) {
  try {
    return await page.evaluate((sels) => {
      return sels.some((sel) => {
        try {
          return document.querySelector(sel) !== null;
        } catch (e) {
          return false;
        }
      });
    }, CAPTCHA_SELECTORS);
  } catch (e) {
    return false;
  }
}

function resolveLocator(page, step) {
  const sel = step.selector || '';
  const t = (step.selectorType || 'css').toLowerCase();
  if (t === 'xpath') return page.locator(`xpath=${sel}`);
  if (t === 'text') return page.locator(`text=${sel}`);
  return page.locator(sel); // css default
}

/**
 * Replace {{ColumnName}} placeholders with row values.
 * Missing columns keep their placeholder; their names are returned so the
 * caller can warn exactly once per name.
 */
function applyTemplate(str, row) {
  const missing = [];
  const text = String(str ?? '').replace(
    /\{\{\s*([^{}]+?)\s*\}\}/g,
    (m, name) => {
      const key = String(name).trim();
      if (row != null && Object.prototype.hasOwnProperty.call(row, key)) {
        const v = row[key];
        return v == null ? '' : String(v);
      }
      if (!missing.includes(key)) missing.push(key);
      return m;
    }
  );
  return { text, missing };
}

/** Humanized mouse click: eased move + click with a small random offset. */
async function humanizedClick(page, loc, humanize, timeoutMs) {
  const steps = Math.max(1, Number(humanize.mouseSteps) || 12);
  try {
    await loc.scrollIntoViewIfNeeded({ timeout: timeoutMs });
    const box = await loc.boundingBox({ timeout: timeoutMs });
    if (box) {
      const x = box.x + box.width / 2 + rand(-6, 6);
      const y = box.y + box.height / 2 + rand(-6, 6);
      await page.mouse.move(x, y, { steps });
      await sleep(rand(40, 160));
      await page.mouse.down();
      await sleep(rand(30, 120));
      await page.mouse.up();
      return;
    }
  } catch (e) {
    // Fall through to a plain click.
  }
  await loc.click({ timeout: timeoutMs });
}

/** Humanized fill: focus the field, select-all, then type with random delays. */
async function humanizedFill(page, loc, value, humanize, timeoutMs) {
  const delay = rand(humanize.typeDelayMinMs, humanize.typeDelayMaxMs);
  try {
    await loc.click({ timeout: timeoutMs });
    await sleep(rand(60, 220));
    await page.keyboard.press('ControlOrMeta+a');
    await sleep(rand(40, 140));
    await page.keyboard.type(String(value ?? ''), { delay });
    return;
  } catch (e) {
    // Fall back to an instant fill if the humanized path fails.
    await loc.fill(String(value ?? ''), { timeout: timeoutMs });
  }
}

async function runStep(page, step, timeoutMs, humanize, emit) {
  const action = step.action;
  const hz = humanize && humanize.enabled ? humanize : null;
  switch (action) {
    case 'goto': {
      const url = step.url || step.value;
      if (!url) throw new Error('goto step needs "url"');
      await page.goto(url, { waitUntil: 'domcontentloaded', timeout: timeoutMs });
      await page.waitForLoadState('networkidle', { timeout: 15000 }).catch(() => {});
      return;
    }
    case 'fill': {
      const loc = resolveLocator(page, step);
      if (hz) {
        await humanizedFill(page, loc, step.value, hz, timeoutMs);
      } else {
        await loc.fill(String(step.value ?? ''), { timeout: timeoutMs });
      }
      return;
    }
    case 'type': {
      const loc = resolveLocator(page, step);
      const delay = hz ? rand(hz.typeDelayMinMs, hz.typeDelayMaxMs) : 0;
      await loc.pressSequentially(String(step.value ?? ''), {
        timeout: timeoutMs,
        delay,
      });
      return;
    }
    case 'click': {
      const loc = resolveLocator(page, step);
      if (hz) {
        await humanizedClick(page, loc, hz, timeoutMs);
      } else {
        await loc.click({ timeout: timeoutMs });
      }
      return;
    }
    case 'select': {
      const loc = resolveLocator(page, step);
      await loc.selectOption(String(step.value ?? ''), { timeout: timeoutMs });
      return;
    }
    case 'check': {
      const loc = resolveLocator(page, step);
      await loc.check({ timeout: timeoutMs });
      return;
    }
    case 'uncheck': {
      const loc = resolveLocator(page, step);
      await loc.uncheck({ timeout: timeoutMs });
      return;
    }
    case 'press': {
      const key = step.key || step.value;
      if (!key) throw new Error('press step needs "key"');
      if (step.selector) {
        await resolveLocator(page, step).press(String(key), { timeout: timeoutMs });
      } else {
        await page.keyboard.press(String(key));
      }
      return;
    }
    case 'waitForTimeout': {
      const ms = Number(step.value ?? step.timeoutMs ?? 1000);
      await sleep(ms);
      return;
    }
    case 'waitForSelector': {
      const sel = step.selector || '';
      const t = (step.selectorType || 'css').toLowerCase();
      const resolved = t === 'xpath' ? `xpath=${sel}` : t === 'text' ? `text=${sel}` : sel;
      await page.waitForSelector(resolved, { timeout: step.timeoutMs || timeoutMs });
      return;
    }
    case 'screenshot': {
      const p = step.value || step.screenshotPath;
      if (!p) throw new Error('screenshot step needs "value" (path)');
      await page.screenshot({ path: p });
      emit({ type: 'log', message: `Screenshot saved: ${p}` });
      return;
    }
    case 'dump': {
      const sels = step.selectors || (step.value ? JSON.parse(step.value) : []);
      const values = {};
      for (const s of sels) {
        const loc = page.locator(s);
        const tag = await loc.evaluate((el) => el.tagName.toLowerCase()).catch(() => '');
        if (tag === 'input' || tag === 'textarea' || tag === 'select') {
          values[s] = await loc.inputValue({ timeout: timeoutMs }).catch(() => null);
        } else {
          values[s] = await loc.textContent({ timeout: timeoutMs }).catch(() => null);
        }
      }
      emit({ type: 'result', values });
      return;
    }
    default:
      throw new Error(`Unknown action: ${action}`);
  }
}

/** Heuristic: a click that submits a form (selector mentions "submit"). */
function isSubmitClick(step) {
  return (
    step.action === 'click' && /submit/i.test(String(step.selector || ''))
  );
}

/**
 * Check for a CAPTCHA and handle it.
 * Returns {status:'clear'} | {status:'solved'} | {status:'blocked'} | {status:'timeout'}.
 * Never attempts to solve a CAPTCHA automatically.
 */
async function handleCaptcha(page, headless, emit) {
  if (!(await detectCaptcha(page))) return { status: 'clear' };
  emit({ type: 'captcha_detected', message: 'CAPTCHA markers found on the page.' });
  if (headless) {
    emit({
      type: 'log',
      message: 'Headless mode: cannot solve CAPTCHA manually — skipping.',
    });
    return { status: 'blocked' };
  }
  emit({
    type: 'awaiting_manual_captcha',
    message:
      'CAPTCHA detected. Please solve it in the browser window — the run will continue automatically.',
  });
  const deadline = Date.now() + 5 * 60 * 1000;
  while (Date.now() < deadline) {
    await sleep(2000);
    if (!(await detectCaptcha(page))) {
      emit({ type: 'log', message: 'CAPTCHA cleared, continuing.' });
      return { status: 'solved' };
    }
  }
  emit({ type: 'log', message: 'Timed out waiting for manual CAPTCHA solve.' });
  return { status: 'timeout' };
}

/**
 * Execute steps sequentially.
 * opts: { emit, humanize, defaultTimeout=30000, headless=true, job,
 *         onStepStart(i, step) }
 * Returns {ok:true} or {ok:false, step, action, message, blocked?}.
 */
async function executeSteps(page, steps, opts) {
  const emit = opts.emit || (() => {});
  const humanize = opts.humanize && opts.humanize.enabled ? opts.humanize : null;
  const defaultTimeout = opts.defaultTimeout || 30000;
  const headless = opts.headless !== false;

  for (let i = 0; i < steps.length; i++) {
    const step = steps[i];
    const timeoutMs = step.timeoutMs || defaultTimeout;
    if (opts.onStepStart) opts.onStepStart(i, step);
    emit({ type: 'progress', step: i + 1, of: steps.length, action: step.action });

    // Random human-like pause between steps (not before the first).
    if (humanize && i > 0) {
      await sleep(rand(humanize.stepDelayMinMs, humanize.stepDelayMaxMs));
    }

    // CAPTCHA check before a submit click (a CAPTCHA may have appeared on the
    // page since the last navigation).
    if (isSubmitClick(step)) {
      const captcha = await handleCaptcha(page, headless, emit);
      if (captcha.status === 'blocked' || captcha.status === 'timeout') {
        return {
          ok: false,
          step: i + 1,
          action: step.action,
          message: 'Blocked by CAPTCHA (manual solve required)',
          blocked: 'captcha',
        };
      }
    }

    try {
      await runStep(page, step, timeoutMs, humanize, emit);
    } catch (err) {
      const msg = String((err && err.message) || err).split('\n')[0];
      emit({ type: 'error', step: i + 1, action: step.action, message: msg });
      return { ok: false, step: i + 1, action: step.action, message: msg };
    }

    // CAPTCHA check after navigation completes (covers every goto step).
    if (step.action === 'goto') {
      const captcha = await handleCaptcha(page, headless, emit);
      if (captcha.status === 'blocked' || captcha.status === 'timeout') {
        return {
          ok: false,
          step: i + 1,
          action: step.action,
          message: 'Blocked by CAPTCHA (manual solve required)',
          blocked: 'captcha',
        };
      }
    }
  }
  return { ok: true };
}

/**
 * Launch Chromium, optionally with the stealth plugin and/or real Chrome.
 * Never throws for a missing real Chrome: warns and falls back to Chromium.
 */
async function launchBrowser(job, humanize, emit) {
  const useStealth = !!(humanize && humanize.enabled && humanize.stealth);
  let chromium;
  if (useStealth) {
    const extra = require('playwright-extra');
    const stealth = require('puppeteer-extra-plugin-stealth')();
    extra.chromium.use(stealth);
    chromium = extra.chromium;
    emit({ type: 'log', message: 'Stealth evasions enabled.' });
  } else {
    chromium = require('playwright').chromium;
  }

  const launchOpts = {
    headless: job.headless !== false,
    slowMo: job.slowMoMs || 0,
  };
  if (humanize && humanize.enabled && humanize.channel === 'chrome') {
    try {
      const browser = await chromium.launch({ ...launchOpts, channel: 'chrome' });
      emit({ type: 'log', message: 'Using real installed Chrome.' });
      return browser;
    } catch (e) {
      emit({
        type: 'warning',
        message: 'Real Chrome not found — falling back to bundled Chromium.',
      });
    }
  }
  return chromium.launch(launchOpts);
}

/** Context options: saved session plus humanize fingerprint overrides. */
function buildContextOptions(job, humanize) {
  const o = {};
  if (job.storageState) o.storageState = job.storageState;
  if (humanize && humanize.enabled) {
    const w = Number(humanize.viewportW);
    const h = Number(humanize.viewportH);
    if (w > 0 && h > 0) o.viewport = { width: w, height: h };
    if (humanize.userAgent) o.userAgent = String(humanize.userAgent);
    if (humanize.locale) o.locale = String(humanize.locale);
    if (humanize.timezoneId) o.timezoneId = String(humanize.timezoneId);
  }
  return o;
}

module.exports = {
  rand,
  sleep,
  CAPTCHA_SELECTORS,
  detectCaptcha,
  handleCaptcha,
  resolveLocator,
  applyTemplate,
  executeSteps,
  launchBrowser,
  buildContextOptions,
};
