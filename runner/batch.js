#!/usr/bin/env node
'use strict';

/**
 * batch.js — run a fill job once per data row (CSV/XLSX).
 *
 * Usage:
 *   node batch.js --job <job.json> --data <rows.csv|rows.xlsx>
 *     [--sheet <name>] [--start-row N] [--max-rows M]
 *     [--results <dir>] [--stop-on-error]
 *     [--row-delay-min <ms>] [--row-delay-max <ms>]
 *
 * Job JSON: same as fill.js, plus job.options:
 *   {
 *     "freshContextPerRow": false,   // new browser context per row
 *     "rowDelayMinMs": 1000, "rowDelayMaxMs": 2500,
 *     "humanize": { … }               // see executor.js
 *   }
 *
 * Template substitution: {{ColumnName}} in step value/selector/url/key,
 * job url and screenshot path is replaced with the current row's values.
 * A missing column keeps its placeholder and emits {type:'warning'}.
 *
 * Output (JSONL on stdout):
 *   {type:'batch_start', totalRows}
 *   {type:'row_start', rowNumber}
 *   {type:'row_result', rowNumber, ok, status, error?, values?}
 *   {type:'warning', message}
 *   {type:'batch_done', totalRows, succeeded, failed, blockedCaptcha,
 *     stoppedEarly?}
 * Per-row step events are forwarded with an added rowNumber field.
 *
 * Send "stop" on stdin to finish the current row and exit gracefully.
 * results.jsonl + summary.json are written to the results dir.
 */

const fs = require('fs');
const path = require('path');
const readline = require('readline');
const { parse } = require('csv-parse/sync');
const ExcelJS = require('exceljs');
const {
  executeSteps,
  launchBrowser,
  buildContextOptions,
  applyTemplate,
  sleep,
  rand,
} = require('./executor');

const emit = (obj) => console.log(JSON.stringify(obj));

function parseArgs(argv) {
  const num = (v) => {
    const n = Number(v);
    return Number.isFinite(n) ? n : undefined;
  };
  const out = {};
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === '--job') out.job = argv[++i];
    else if (a === '--data') out.data = argv[++i];
    else if (a === '--sheet') out.sheet = argv[++i];
    else if (a === '--start-row') out.startRow = num(argv[++i]);
    else if (a === '--max-rows') out.maxRows = num(argv[++i]);
    else if (a === '--results') out.results = argv[++i];
    else if (a === '--stop-on-error') out.stopOnError = true;
    else if (a === '--row-delay-min') out.rowDelayMin = num(argv[++i]);
    else if (a === '--row-delay-max') out.rowDelayMax = num(argv[++i]);
  }
  return out;
}

/** Convert an ExcelJS cell value to plain text (mirrors sheet_to_json raw:false). */
function cellToText(value) {
  if (value === null || value === undefined) return '';
  if (value instanceof Date) {
    // Date-only cells -> YYYY-MM-DD; cells with a time component keep it.
    const hasTime =
      value.getHours() !== 0 || value.getMinutes() !== 0 || value.getSeconds() !== 0;
    const ymd = value.toISOString().slice(0, 10);
    return hasTime ? value.toISOString().replace('T', ' ').slice(0, 19) : ymd;
  }
  if (typeof value === 'object') {
    if (Array.isArray(value.richText)) return value.richText.map((r) => r.text || '').join('');
    if (value.text !== undefined && value.hyperlink !== undefined) return String(value.text);
    if (value.result !== undefined) return cellToText(value.result); // formula cell
    if (value.text !== undefined) return String(value.text);
    return '';
  }
  return String(value).trim();
}

async function parseDataFile(dataPath, sheetName) {
  const ext = path.extname(dataPath).toLowerCase();
  if (ext === '.csv') {
    const text = fs.readFileSync(dataPath, 'utf8').replace(/^\uFEFF/, '');
    return parse(text, {
      columns: true,
      skip_empty_lines: true,
      trim: true,
      relax_column_count: true,
    });
  }
  if (ext === '.xls') {
    throw new Error(
      'Legacy .xls files are not supported — please re-save the workbook as .xlsx and try again'
    );
  }
  if (ext === '.xlsx') {
    const workbook = new ExcelJS.Workbook();
    await workbook.xlsx.readFile(dataPath);
    const ws = sheetName ? workbook.getWorksheet(sheetName) : workbook.worksheets[0];
    if (!ws) {
      throw new Error(
        sheetName ? `Sheet "${sheetName}" not found` : 'Workbook has no sheets'
      );
    }
    const rows = [];
    let headers = null;
    ws.eachRow({ includeEmpty: false }, (row, rowNumber) => {
      // row.values is 1-indexed; slice(1) drops the empty slot 0.
      const vals = row.values.slice(1).map(cellToText);
      if (rowNumber === 1) {
        headers = vals;
        return;
      }
      const obj = {};
      headers.forEach((h, i) => {
        obj[h] = vals[i] !== undefined ? vals[i] : '';
      });
      rows.push(obj);
    });
    return rows;
  }
  throw new Error(`Unsupported data file: ${ext} (use .csv or .xlsx)`);
}

/** Substitute {{columns}} in a step; returns {step, missing:[...]}. */
function substituteStep(step, row) {
  const out = { ...step };
  const missing = [];
  for (const field of ['value', 'selector', 'url', 'key']) {
    if (typeof out[field] === 'string' && out[field].includes('{{')) {
      const r = applyTemplate(out[field], row);
      out[field] = r.text;
      for (const m of r.missing) if (!missing.includes(m)) missing.push(m);
    }
  }
  if (Array.isArray(out.selectors)) {
    out.selectors = out.selectors.map((s) => {
      if (typeof s === 'string' && s.includes('{{')) {
        const r = applyTemplate(s, row);
        for (const m of r.missing) if (!missing.includes(m)) missing.push(m);
        return r.text;
      }
      return s;
    });
  }
  return { step: out, missing };
}

async function main() {
  const args = parseArgs(process.argv.slice(2));
  if (!args.job || !args.data) {
    emit({ type: 'error', message: 'Missing required --job and/or --data arguments' });
    process.exit(1);
  }

  let job;
  try {
    job = JSON.parse(fs.readFileSync(args.job, 'utf8'));
  } catch (err) {
    emit({ type: 'error', message: `Cannot read job file: ${err.message}` });
    process.exit(1);
  }

  let allRows;
  try {
    allRows = await parseDataFile(args.data, args.sheet);
  } catch (err) {
    emit({ type: 'error', message: `Cannot read data file: ${err.message}` });
    process.exit(1);
  }

  const startRow = Math.max(1, args.startRow || 1);
  const maxRows = args.maxRows || 0;
  let rows = allRows.slice(startRow - 1);
  if (maxRows > 0) rows = rows.slice(0, maxRows);
  if (rows.length === 0) {
    emit({ type: 'error', message: 'No data rows to process' });
    process.exit(1);
  }

  const resultsDir =
    args.results ||
    path.join(process.cwd(), `batch-results-${Date.now()}`);
  fs.mkdirSync(resultsDir, { recursive: true });

  const options = job.options || {};
  const humanize = options.humanize || {};
  const defaultTimeout = 30000;
  const headless = job.headless !== false;
  const freshContextPerRow = !!options.freshContextPerRow;
  const rowDelayMin =
    args.rowDelayMin ?? options.rowDelayMinMs ?? 1000;
  const rowDelayMax =
    args.rowDelayMax ?? options.rowDelayMaxMs ?? 2500;

  emit({ type: 'batch_start', totalRows: rows.length, resultsDir });

  // Graceful stop via stdin ("stop" finishes the current row, then exits).
  let stopRequested = false;
  const rl = readline.createInterface({ input: process.stdin });
  rl.on('line', (line) => {
    if (line.trim().toLowerCase() === 'stop') {
      stopRequested = true;
      emit({ type: 'log', message: 'Stop requested — finishing current row…' });
    }
  });

  const rowResults = [];
  let succeeded = 0;
  let failed = 0;
  let blockedCaptcha = 0;
  let stoppedEarly = false;
  const startedAt = new Date().toISOString();

  const browser = await launchBrowser(job, humanize, emit);
  let sharedContext = null;
  const getContext = async () => {
    if (freshContextPerRow) {
      return browser.newContext(buildContextOptions(job, humanize));
    }
    if (!sharedContext) {
      sharedContext = await browser.newContext(buildContextOptions(job, humanize));
    }
    return sharedContext;
  };

  try {
    for (let i = 0; i < rows.length; i++) {
      if (stopRequested) {
        stoppedEarly = true;
        break;
      }
      const row = rows[i];
      const rowNumber = startRow + i; // 1-based, matches the source file
      emit({ type: 'row_start', rowNumber });

      // Substitute templates.
      const urlR = applyTemplate(job.url, row);
      const missingCols = [...urlR.missing];
      const subSteps = (job.steps || []).map((s) => {
        const { step, missing } = substituteStep(s, row);
        for (const m of missing) if (!missingCols.includes(m)) missingCols.push(m);
        return step;
      });
      for (const m of missingCols) {
        emit({
          type: 'warning',
          rowNumber,
          message: `Row ${rowNumber}: column "${m}" not found — placeholder kept as-is.`,
        });
      }

      let shotPath = null;
      if (job.screenshotPath) {
        shotPath = applyTemplate(job.screenshotPath, row).text;
      }

      const context = await getContext();
      const page = await context.newPage();
      const rowValues = {};
      const rowEmit = (ev) => {
        if (ev.type === 'result' && ev.values) {
          Object.assign(rowValues, ev.values);
          return; // folded into row_result below
        }
        emit({ ...ev, rowNumber });
      };

      let status = 'ok';
      let error = '';
      try {
        const steps = [
          { action: 'goto', url: urlR.text },
          ...subSteps,
        ];
        const outcome = await executeSteps(page, steps, {
          emit: rowEmit,
          humanize,
          defaultTimeout,
          headless,
          job,
        });
        if (!outcome.ok) {
          if (outcome.blocked === 'captcha') {
            status = 'blocked_captcha';
            blockedCaptcha++;
          } else {
            status = 'failed';
            failed++;
          }
          error = outcome.message || '';
          if (shotPath) {
            await page.screenshot({ path: shotPath }).catch(() => {});
            rowEmit({ type: 'log', message: `Row screenshot saved: ${shotPath}` });
          }
        } else {
          succeeded++;
          if (shotPath) {
            await page.screenshot({ path: shotPath }).catch(() => {});
          }
        }
      } catch (err) {
        status = 'failed';
        failed++;
        error = String((err && err.message) || err).split('\n')[0];
      } finally {
        await page.close().catch(() => {});
        if (freshContextPerRow) await context.close().catch(() => {});
      }

      const result = {
        type: 'row_result',
        rowNumber,
        ok: status === 'ok',
        status,
        error,
        values: rowValues,
      };
      rowResults.push(result);
      emit(result);

      if (status === 'failed' && args.stopOnError) {
        stoppedEarly = true;
        emit({ type: 'log', message: 'Stopping after first failed row (--stop-on-error).' });
        break;
      }

      // Human-like pause between rows (not after the last one).
      if (i < rows.length - 1 && !stopRequested) {
        await sleep(rand(rowDelayMin, rowDelayMax));
      }
    }
  } finally {
    if (sharedContext) await sharedContext.close().catch(() => {});
    await browser.close().catch(() => {});
    rl.close();
  }

  const summary = {
    totalRows: rows.length,
    succeeded,
    failed,
    blockedCaptcha,
    stoppedEarly,
    startedAt,
    finishedAt: new Date().toISOString(),
  };
  try {
    fs.writeFileSync(
      path.join(resultsDir, 'results.jsonl'),
      rowResults.map((r) => JSON.stringify(r)).join('\n') + '\n'
    );
    fs.writeFileSync(
      path.join(resultsDir, 'summary.json'),
      JSON.stringify(summary, null, 2)
    );
  } catch (e) {
    emit({ type: 'warning', message: `Could not write results files: ${e.message}` });
  }

  emit({ type: 'batch_done', ...summary });
  process.exitCode = failed > 0 ? 1 : 0;
}

main();
