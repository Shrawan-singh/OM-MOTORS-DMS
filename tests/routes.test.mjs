import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { existsSync } from 'node:fs';
import { once } from 'node:events';

// Use a running test server when supplied. Otherwise use the production build, or Next's
// dev server in a clean checkout. Port 0 leaves port allocation to the operating system.
let server;
async function start() {
  const mode = existsSync('.next/BUILD_ID') ? 'start' : 'dev';
  server = spawn(
    process.execPath,
    ['node_modules/next/dist/bin/next', mode, '-H', '127.0.0.1', '-p', '0'],
    {
      env: { ...process.env, FORCE_COLOR: '0', NEXT_TELEMETRY_DISABLED: '1' },
      stdio: ['ignore', 'pipe', 'pipe'],
    }
  );
  return new Promise((resolve, reject) => {
    let output = '';
    const timeout = setTimeout(() => reject(new Error('Next did not start: ' + output)), 60_000);
    const fail = (e) => {
      clearTimeout(timeout);
      reject(e);
    };
    server.once('error', fail);
    server.once('exit', (code) => fail(new Error('Next exited with ' + code + ': ' + output)));
    const receive = (chunk) => {
      output = (output + chunk.toString()).slice(-16000);
      const base = output.match(/Local:\s+(http:\/\/127\.0\.0\.1:\d+)/)?.[1];
      if (base && output.includes('Ready in')) {
        clearTimeout(timeout);
        resolve(base);
      }
    };
    server.stdout.on('data', receive);
    server.stderr.on('data', receive);
  });
}

try {
  const base = process.env.ROUTE_TEST_BASE_URL || (await start());
  const read = (path, options = {}) =>
    fetch(base + path, { redirect: 'manual', signal: AbortSignal.timeout(60_000), ...options });
  for (const path of [
    '/',
    '/admin',
    '/customers',
    '/inventory',
    '/quotations/new',
    '/invoices',
    '/service',
    '/vehicles',
    '/vehicles/receive',
    '/vehicles/00000000-0000-4000-8000-000000000001',
    '/vehicles/00000000-0000-4000-8000-000000000001/print',
  ]) {
    const response = await read(path);
    assert.equal(response.status, 307, path);
    assert.equal(new URL(response.headers.get('location')).pathname, '/login', path);
  }
  const attack = await read('/admin', {
    headers: {
      'x-middleware-subrequest': 'middleware:middleware:middleware:middleware:middleware',
    },
  });
  assert.notEqual(attack.status, 200, 'Middleware bypass header must not expose admin');
  const callback = await read('/auth/callback');
  assert.equal(new URL(callback.headers.get('location')).pathname, '/login');
  assert.equal((await read('/login')).status, 200);
  console.log(
    'PASS: protected routes including vehicle intake and detail deny anonymous requests, middleware header rejected, callback and login work.'
  );
} finally {
  if (server && server.exitCode === null && server.signalCode === null) {
    const closed = once(server, 'close');
    server.kill('SIGTERM');
    await closed;
  }
}
