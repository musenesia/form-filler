#!/usr/bin/env node
'use strict';

/**
 * login.js — open a HEADED browser so the user can sign in manually,
 * then save the session (storage state) for later headless runs.
 *
 * Usage:
 *   node login.js --url <url> --state <out.json>
 *
 * Output (JSONL on stdout):
 *   {type:'log', message}
 *   {type:'info', message:'LOGIN_WINDOW_OPEN'}
 *   {type:'result', statePath}
 *   {type:'error', message}
 *
 * Control: the parent process writes a line "done" to stdin once the user
 * has finished signing in. If stdin closes first, the login is cancelled.
 */

const readline = require('readline');
const { chromium } = require('playwright');

const emit = (obj) => console.log(JSON.stringify(obj));

function parseArgs(argv) {
  const out = {};
  for (let i = 0; i < argv.length; i++) {
    if (argv[i] === '--url') out.url = argv[++i];
    else if (argv[i] === '--state') out.state = argv[++i];
  }
  return out;
}

async function main() {
  const args = parseArgs(process.argv.slice(2));
  if (!args.url || !args.state) {
    emit({ type: 'error', message: 'Usage: node login.js --url <url> --state <out.json>' });
    process.exit(1);
  }

  emit({ type: 'log', message: 'Opening login window…' });
  const browser = await chromium.launch({ headless: false });
  const context = await browser.newContext();
  const page = await context.newPage();
  await page.goto(args.url, { waitUntil: 'domcontentloaded', timeout: 45000 }).catch((err) => {
    emit({ type: 'log', message: `Navigation note: ${String(err.message).split('\n')[0]}` });
  });

  emit({ type: 'info', message: 'LOGIN_WINDOW_OPEN' });

  const rl = readline.createInterface({ input: process.stdin, terminal: false });
  let settled = false;

  const finish = async (ok, message) => {
    if (settled) return;
    settled = true;
    try {
      if (ok) {
        await context.storageState({ path: args.state });
        emit({ type: 'result', statePath: args.state });
      } else {
        emit({ type: 'error', message });
      }
    } catch (err) {
      emit({ type: 'error', message: String((err && err.message) || err) });
      process.exitCode = 1;
    } finally {
      rl.close();
      await browser.close();
      if (!ok) process.exitCode = 1;
    }
  };

  rl.on('line', (line) => {
    if (line.trim().toLowerCase() === 'done') finish(true);
  });
  rl.on('close', () => finish(false, 'Login cancelled before completion'));
  process.on('SIGTERM', () => finish(false, 'Login window closed by app'));
}

main();
