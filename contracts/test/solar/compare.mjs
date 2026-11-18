#!/usr/bin/env node
// Reads a `forge test --json` run of the suites compiled by solar (bin/solar-diff) and compares it with solc.
//
// Usage: node contracts/test/solar/compare.mjs <tests.json> [.gas-snapshot] [selected-files.txt]
//
// Correctness: verify.yml holds every suite to passing under solc, so solc is the oracle. A test that fails under
// solar, a suite that fails to set up, or a run with no results (solar failed to compile) is a divergence, and the
// script exits 1. So is a test the source declares that solar's run doesn't report: for every concrete contract in the
// files selected-files.txt lists (one path per line), each test, testFuzz and invariant function it declares or
// inherits (bases resolved across contracts/test), so a dropped suite, fuzz test or invariant can't pass silently.
// Gas: each test the committed solc snapshot records (a unit test's gas, or a fuzz test's median) is
// compared with the same test under solar. The test contracts are compiled by solar too, so a test's gas also counts
// its harness, not only the contract under test. Writes a Markdown report to stdout.
import { readFileSync, readdirSync } from 'node:fs';
import { join } from 'node:path';

const [resultsPath, snapshotPath = '.gas-snapshot', selectedPath] = process.argv.slice(2);
if (!resultsPath) {
  console.error('usage: compare.mjs <tests.json> [.gas-snapshot] [selected-files.txt]');
  process.exit(2);
}

// `Contract:test() (gas: 123)` or `Contract:testFuzz(uint256) (runs: 1024, μ: 120, ~: 118)`.
const snapshot = new Map();
for (const line of readFileSync(snapshotPath, 'utf8').split('\n')) {
  const match = line.match(/^(\S+?):(\S+\)) \((.*)\)$/);
  const gas = match?.[3].match(/^gas: (\d+)$/) ?? match?.[3].match(/~: (\d+)$/);
  if (gas) snapshot.set(`${match[1]}:${match[2]}`, Number(gas[1]));
}

const code = (text) => `\`${text}\``;
const cell = (text) => String(text).replaceAll('\n', ' ').replaceAll('|', '\\|');
const percent = (solar, solc) => `${solar > solc ? '+' : ''}${((solar / solc - 1) * 100).toFixed(1)}%`;

let suites;
try {
  suites = JSON.parse(readFileSync(resultsPath, 'utf8'));
} catch {
  suites = {};
}
const failures = [];
const rows = [];
let passed = 0;
for (const [suite, result] of Object.entries(suites)) {
  const contract = suite.slice(suite.lastIndexOf(':') + 1);
  for (const warning of result.warnings ?? []) failures.push({ name: suite, reason: warning });
  for (const [test, outcome] of Object.entries(result.test_results ?? {})) {
    const name = `${contract}:${test}`;
    if (outcome.status === 'Skipped') continue;
    if (outcome.status !== 'Success') {
      failures.push({ name, reason: outcome.reason ?? outcome.status });
      continue;
    }
    passed++;
    const gas = outcome.kind?.Unit?.gas ?? outcome.kind?.Fuzz?.median_gas;
    const solc = snapshot.get(name);
    if (gas !== undefined && solc) rows.push({ name, solc, solar: gas });
  }
}
const ran = new Set();
for (const [suite, result] of Object.entries(suites)) {
  const contract = suite.slice(suite.lastIndexOf(':') + 1);
  for (const test of Object.keys(result.test_results ?? {})) {
    ran.add(`${contract}:${test}`);
    ran.add(`${contract}:${test.slice(0, test.indexOf('('))}`);
    // Forge 1.8 checks every invariant of a contract in one campaign and reports them under its first.
    for (const predicate of result.test_results[test].invariant_predicate_results ?? []) {
      ran.add(`${contract}:${predicate.name}`);
      if (predicate.status !== 'Success') {
        failures.push({ name: `${contract}:${predicate.name}`, reason: predicate.reason ?? predicate.status });
      }
    }
  }
}
if (selectedPath) {
  for (const name of expectedTests(readFileSync(selectedPath, 'utf8').split('\n').filter(Boolean))) {
    if (!ran.has(name)) failures.push({ name, reason: 'declared in the source but not run under solar' });
  }
}
if (!passed && !failures.length) {
  failures.push({ name: resultsPath, reason: 'no test results: solar or forge failed before the tests ran (see the log)' });
}

const out = ['## Solar differential', '', `${passed} tests passed under solar, ${failures.length} failed.`, ''];
if (failures.length) {
  out.push('### Divergences from solc', '', '| Test | Reason |', '| --- | --- |');
  for (const { name, reason } of failures) out.push(`| ${code(name)} | ${cell(reason)} |`);
  out.push('');
}
if (rows.length) {
  const solcTotal = rows.reduce((sum, row) => sum + row.solc, 0);
  const solarTotal = rows.reduce((sum, row) => sum + row.solar, 0);
  const ratio = (row) => row.solar / row.solc;
  const byRatio = rows.toSorted((a, b) => ratio(b) - ratio(a));
  const median = byRatio[Math.floor(byRatio.length / 2)];
  const dearer = byRatio.filter((row) => row.solar > row.solc);
  const cheaper = byRatio.filter((row) => row.solar < row.solc).reverse();
  out.push('### Gas against the solc snapshot', '');
  out.push(
    `${rows.length} tests compared: ${solcTotal} gas under solc, ${solarTotal} under solar (${percent(solarTotal, solcTotal)}); ` +
      `median test ${percent(median.solar, median.solc)}; ${cheaper.length} cheaper and ${dearer.length} dearer under solar. ` +
      'Each figure includes the test harness, which solar compiles too.',
    '',
  );
  const table = (title, list) => {
    if (!list.length) return;
    out.push(`<details><summary>${title}</summary>`, '', '| Test | solc | solar | Change |', '| --- | ---: | ---: | ---: |');
    for (const row of list) out.push(`| ${code(row.name)} | ${row.solc} | ${row.solar} | ${percent(row.solar, row.solc)} |`);
    out.push('', '</details>', '');
  };
  table(`Dearer under solar (${dearer.length})`, dearer);
  table('Cheapest under solar (top 20)', cheaper.slice(0, 20));
  table(`Every compared test (${rows.length})`, rows.toSorted((a, b) => a.name.localeCompare(b.name)));
}
console.log(out.join('\n'));
process.exit(failures.length ? 1 : 0);

/// Each `Contract:function` the selected files' concrete test contracts (forge-std Test descendants) declare or
/// inherit, by name (forge reports `name(args)`; ran holds both forms). Reads every contract under contracts/test
/// to resolve bases, with comments stripped; a base outside contracts/test (forge-std) declares no tests.
function expectedTests(selected) {
  const contracts = new Map();
  const parse = (path) => {
    const source = readFileSync(path, 'utf8').replace(/\/\*[\s\S]*?\*\//g, '').replace(/\/\/.*$/gm, '');
    const heads = [...source.matchAll(/^(abstract\s+)?contract\s+(\w+)(?:\s+is\s+([^{]+))?\s*\{/gm)];
    heads.forEach((head, i) => {
      const body = source.slice(head.index, heads[i + 1]?.index ?? source.length);
      contracts.set(head[2], {
        path,
        abstract: Boolean(head[1]),
        bases: (head[3] ?? '').split(',').map((base) => base.trim().split(/[\s(]/)[0]).filter(Boolean),
        tests: [...body.matchAll(/\bfunction\s+((?:test|invariant)\w*)\s*\(/g)].map((match) => match[1]),
      });
    });
  };
  const walk = (dir) => {
    for (const entry of readdirSync(dir, { withFileTypes: true })) {
      const path = join(dir, entry.name);
      if (entry.isDirectory()) walk(path);
      else if (path.endsWith('.sol')) parse(path);
    }
  };
  walk('contracts/test');
  const testsOf = (name, seen = new Set()) => {
    const contract = contracts.get(name);
    if (!contract || seen.has(name)) return [];
    seen.add(name);
    return [...contract.tests, ...contract.bases.flatMap((base) => testsOf(base, seen))];
  };
  // forge-std's Test, directly or through a base: mocks with a testOnly helper aren't suites.
  const isTest = (name, seen = new Set()) => {
    if (name === 'Test') return true;
    const contract = contracts.get(name);
    if (!contract || seen.has(name)) return false;
    seen.add(name);
    return contract.bases.some((base) => isTest(base, seen));
  };
  const wanted = new Set(selected);
  const expected = new Set();
  for (const [name, contract] of contracts) {
    if (contract.abstract || !wanted.has(contract.path) || !isTest(name)) continue;
    for (const test of testsOf(name)) expected.add(`${name}:${test}`);
  }
  return expected;
}
