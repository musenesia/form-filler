#!/usr/bin/env node
'use strict';

/**
 * scan.js — inspect a page and list its fillable fields.
 *
 * Usage:
 *   node scan.js --url <url> [--storage <state.json>]
 *
 * Output (JSONL on stdout, one object per line):
 *   {type:'log', message}
 *   {type:'result', fields:[{tag,type,name,id,placeholder,label,css,xpath}]}
 *   {type:'error', message}
 */

const { chromium } = require('playwright');

function parseArgs(argv) {
  const out = {};
  for (let i = 0; i < argv.length; i++) {
    if (argv[i] === '--url') out.url = argv[++i];
    else if (argv[i] === '--storage') out.storage = argv[++i];
  }
  return out;
}

const emit = (obj) => console.log(JSON.stringify(obj));

async function main() {
  const args = parseArgs(process.argv.slice(2));
  if (!args.url) {
    emit({ type: 'error', message: 'Missing required --url argument' });
    process.exit(1);
  }

  emit({ type: 'log', message: `Launching browser for ${args.url}` });
  const browser = await chromium.launch({ headless: true });
  try {
    const contextOpts = {};
    if (args.storage) contextOpts.storageState = args.storage;
    const context = await browser.newContext(contextOpts);
    const page = await context.newPage();
    emit({ type: 'log', message: 'Loading page…' });
    await page.goto(args.url, { waitUntil: 'domcontentloaded', timeout: 45000 });
    await page.waitForLoadState('networkidle', { timeout: 15000 }).catch(() => {});

    emit({ type: 'log', message: 'Collecting fields…' });
    const fields = await page.evaluate(() => {
      function uniqueCss(el) {
        if (el.id && /^[A-Za-z][\w:-]*$/.test(el.id)) {
          if (document.querySelectorAll('#' + CSS.escape(el.id)).length === 1) {
            return '#' + CSS.escape(el.id);
          }
        }
        const name = el.getAttribute('name');
        if (name) {
          const sel = el.tagName.toLowerCase() + '[name="' + name.replace(/"/g, '\\"') + '"]';
          if (document.querySelectorAll(sel).length === 1) return sel;
        }
        const parts = [];
        let node = el;
        while (node && node.nodeType === 1 && node.tagName.toLowerCase() !== 'html') {
          let namePart = node.tagName.toLowerCase();
          const parent = node.parentElement;
          if (parent) {
            const siblings = Array.from(parent.children).filter(
              (c) => c.tagName === node.tagName
            );
            if (siblings.length > 1) {
              namePart += ':nth-of-type(' + (siblings.indexOf(node) + 1) + ')';
            }
          }
          parts.unshift(namePart);
          node = parent;
        }
        return parts.join(' > ');
      }

      function xpath(el) {
        const parts = [];
        let node = el;
        while (node && node.nodeType === 1) {
          let idx = 1;
          let sib = node.previousElementSibling;
          while (sib) {
            if (sib.tagName === node.tagName) idx++;
            sib = sib.previousElementSibling;
          }
          parts.unshift(node.tagName.toLowerCase() + '[' + idx + ']');
          node = node.parentElement;
        }
        return '/' + parts.join('/');
      }

      function labelFor(el) {
        if (el.id) {
          const lab = document.querySelector('label[for="' + CSS.escape(el.id) + '"]');
          if (lab) return lab.innerText.trim().slice(0, 120);
        }
        const wrap = el.closest('label');
        if (wrap) {
          const clone = wrap.cloneNode(true);
          clone.querySelectorAll('input,textarea,select,button').forEach((n) => n.remove());
          return clone.innerText.trim().slice(0, 120);
        }
        const aria = el.getAttribute('aria-label');
        if (aria) return aria.trim().slice(0, 120);
        return '';
      }

      const els = Array.from(
        document.querySelectorAll('input, textarea, select, button')
      ).filter((el) => {
        const style = window.getComputedStyle(el);
        return style.display !== 'none' && style.visibility !== 'hidden';
      });

      return els.slice(0, 300).map((el) => ({
        tag: el.tagName.toLowerCase(),
        type: el.getAttribute('type') || '',
        name: el.getAttribute('name') || '',
        id: el.id || '',
        placeholder: el.getAttribute('placeholder') || '',
        label: labelFor(el),
        css: uniqueCss(el),
        xpath: xpath(el),
      }));
    });

    emit({ type: 'result', fields });
  } catch (err) {
    emit({ type: 'error', message: String((err && err.message) || err) });
    process.exitCode = 1;
  } finally {
    await browser.close();
  }
}

main();
