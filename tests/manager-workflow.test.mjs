import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { createRequire } from 'node:module';
import { createElement } from 'react';
import { renderToStaticMarkup } from 'react-dom/server';
import ts from 'typescript';

const require = createRequire(import.meta.url);
function load(path, dependencies = {}) {
  const { outputText } = ts.transpileModule(readFileSync(path, 'utf8'), {
    compilerOptions: {
      module: ts.ModuleKind.CommonJS,
      target: ts.ScriptTarget.ES2022,
      jsx: ts.JsxEmit.ReactJSX,
    },
  });
  const exports = {};
  new Function('require', 'exports', outputText)(name => dependencies[name] ?? require(name), exports);
  return exports;
}

const billing = { '@/lib/billing/types': load('src/lib/billing/types.ts') };
const { DocumentSheet } = load('src/components/billing/DocumentSheet.tsx', billing);
const doc = JSON.parse(readFileSync('tests/print-fixture.json', 'utf8'));
const print = overrides => renderToStaticMarkup(createElement(DocumentSheet, { doc: { ...doc, ...overrides } }));
const cancelled = print({ cancelled_at: '2026-11-10T23:30:00Z' });
assert.match(cancelled, /CANCELLED INVOICE/);
assert.match(cancelled, /Cancelled on 11\/11\/2026/);
assert.ok(cancelled.includes(doc.number));
assert.doesNotMatch(cancelled, /Balance due|PAYMENT DETAILS/);
assert.match(print({ cancelled_at: null }), /Balance due/);

const { PaymentAmount } = load('src/components/billing/PaymentAmount.tsx', billing);
const renderPayment = amount => renderToStaticMarkup(createElement(PaymentAmount, {
  due: 100000, amount, onChange() {},
}));
assert.match(renderPayment(''), /Abhi baki ₹1,00,000.00/);
assert.match(renderPayment('25000'), /₹25,000.00 jama honge · ₹75,000.00 baki/);
assert.match(renderPayment('100000'), /₹0.00 baki/);
assert.match(renderPayment('100001'), /baki se zyada/);

const { routeModule } = load('src/lib/auth/permissions.ts');
assert.equal(routeModule('/receivables'), 'invoices');
assert.equal(routeModule('/admin'), 'admin');
console.log('PASS: cancelled and active invoice printouts, partial-payment previews, manager receivables permission.');
