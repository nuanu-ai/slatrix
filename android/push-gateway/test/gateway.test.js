import assert from 'node:assert/strict';
import { after, before, test } from 'node:test';
import { http } from '@google-cloud/functions-framework';
import { getTestServer } from '@google-cloud/functions-framework/testing';
import { getMessaging } from 'firebase-admin/messaging';
import { matrixPush } from '../index.js';

http('matrixPush', matrixPush);
const server = getTestServer('matrixPush');
let endpoint;
before(async () => {
  await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
  endpoint = `http://127.0.0.1:${server.address().port}/_matrix/push/v1/notify`;
});
after(async () => {
  await new Promise((resolve, reject) => server.close((error) => error ? reject(error) : resolve()));
});

function notification(overrides = {}) {
  return {
    event_id: '$launch-message',
    room_id: '!launch:example.org',
    devices: [{ app_id: 'ai.nuanu.slatrix.dev', pushkey: 'firebase-registration-token' }],
    ...overrides,
  };
}

async function post(value, options = {}) {
  return fetch(endpoint, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify(value),
    ...options,
  });
}

test('homeserver notification forwards only event IDs to the intended Android package', async (t) => {
  const delivered = [];
  t.mock.method(getMessaging(), 'send', async (message) => {
    delivered.push(message);
    return 'projects/test/messages/delivered';
  });
  const response = await post({ notification: notification({
    content: { body: 'private message' },
    sender: '@private:example.org',
    room_name: 'private room',
    devices: [{
      app_id: 'ai.nuanu.slatrix.dev',
      pushkey: 'firebase-registration-token',
      data: { default_payload: { notification: { title: 'private title' }, arbitrary: 'private data' } },
    }],
  }) });
  assert.equal(response.status, 200);
  assert.deepEqual(await response.json(), { rejected: [] });
  assert.deepEqual(delivered, [{
    token: 'firebase-registration-token',
    data: { event_id: '$launch-message', room_id: '!launch:example.org' },
    android: { priority: 'high', restrictedPackageName: 'ai.nuanu.slatrix.dev' },
  }]);
});

test('untrusted notification fields are rejected before any push is emitted', async (t) => {
  const delivered = [];
  t.mock.method(getMessaging(), 'send', async (message) => {
    delivered.push(message);
    return 'projects/test/messages/unexpected';
  });
  const valid = notification();
  const malformed = [
    null, [], {}, { notification: [] },
    ...[
      { devices: null }, { devices: {} },
      { devices: [null] },
      { devices: [valid.devices[0], { app_id: 'other.application', pushkey: 'foreign-token' }] },
      { devices: [{ app_id: 'ai.nuanu.slatrix.dev' }] },
      { devices: [{ app_id: 'ai.nuanu.slatrix.dev', pushkey: '' }] },
      { devices: [{ app_id: 'ai.nuanu.slatrix.dev', pushkey: 42 }] },
      { devices: [{ app_id: 'ai.nuanu.slatrix.dev', pushkey: 'contains\nnewline' }] },
      { devices: [{ app_id: 'ai.nuanu.slatrix.dev', pushkey: 'x'.repeat(4097) }] },
      { devices: Array.from({ length: 101 }, () => valid.devices[0]) },
      { event_id: null }, { event_id: '' }, { event_id: [] }, { event_id: 'missing-sigil' },
      { event_id: '$' + 'é'.repeat(128) }, { event_id: '$line\nbreak' },
      { room_id: null }, { room_id: '' }, { room_id: 'missing-sigil' },
      { room_id: '!' + 'r'.repeat(255) },
      { prio: 'urgent' },
    ].map((overrides) => ({ notification: notification(overrides) })),
  ];
  for (const [index, value] of malformed.entries()) {
    const response = await post(value);
    assert.equal(response.status, 400, `malformed request ${index}`);
  }
  assert.deepEqual(delivered, []);
});

test('badge-count updates are acknowledged without FCM while partial event IDs are invalid', async (t) => {
  const delivered = [];
  t.mock.method(getMessaging(), 'send', async (message) => {
    delivered.push(message);
    return 'projects/test/messages/unexpected';
  });
  for (const counts of [{ unread: 14, missed_calls: 2 }, {}]) {
    const response = await post({ notification: { devices: notification().devices, counts } });
    assert.equal(response.status, 200);
    assert.deepEqual(await response.json(), { rejected: [] });
  }
  for (const fields of [
    { counts: { unread: 1 }, event_id: '$partial' },
    { counts: { unread: 1 }, room_id: '!partial:example.org' },
    {}, { counts: [] }, { counts: { unread: -1 } }, { counts: { missed_calls: 0.5 } },
  ]) {
    const response = await post({ notification: { devices: notification().devices, ...fields } });
    assert.equal(response.status, 400);
  }
  assert.deepEqual(delivered, []);
});

test('only expired or invalid registration tokens remove Matrix pushers; other failures retry', async (t) => {
  let providerCode;
  t.mock.method(getMessaging(), 'send', async (message) => {
    if (message.token === 'failed-token') {
      throw Object.assign(new Error('Provider detail must not be returned'), { code: providerCode });
    }
    return 'projects/test/messages/delivered';
  });
  const devices = [
    { app_id: 'ai.nuanu.slatrix.dev', pushkey: 'failed-token' },
    { app_id: 'ai.nuanu.slatrix', pushkey: 'healthy-token' },
  ];
  for (const code of [
    'messaging/registration-token-not-registered', 'messaging/invalid-registration-token',
    'messaging/invalid-argument', 'messaging/invalid-credential', 'messaging/mismatched-credential',
    'messaging/server-unavailable', 'messaging/quota-exceeded', 'messaging/internal-error', undefined,
  ]) {
    providerCode = code;
    const response = await post({ notification: notification({ devices }) });
    if (code === 'messaging/registration-token-not-registered' || code === 'messaging/invalid-registration-token') {
      assert.equal(response.status, 200, code);
      assert.deepEqual(await response.json(), { rejected: ['failed-token'] });
    } else {
      assert.equal(response.status, 503, code);
      assert.equal((await response.text()).includes('Provider detail'), false);
    }
  }
});

test('low-priority Matrix pushes use normal FCM priority for the release app', async (t) => {
  const delivered = [];
  t.mock.method(getMessaging(), 'send', async (message) => {
    delivered.push(message);
    return 'projects/test/messages/delivered';
  });
  const response = await post({ notification: notification({
    prio: 'low',
    devices: [{ app_id: 'ai.nuanu.slatrix', pushkey: 'release-registration-token' }],
  }) });
  assert.equal(response.status, 200);
  assert.deepEqual(delivered, [{
    token: 'release-registration-token',
    data: { event_id: '$launch-message', room_id: '!launch:example.org' },
    android: { priority: 'normal', restrictedPackageName: 'ai.nuanu.slatrix' },
  }]);
});

test('the Matrix endpoint enforces its path, HTTP method, JSON media type and body limit', async (t) => {
  const delivered = [];
  t.mock.method(getMessaging(), 'send', async (message) => {
    delivered.push(message);
    return 'projects/test/messages/unexpected';
  });
  const unknown = await fetch(new URL('/other', endpoint), { method: 'POST' });
  assert.equal(unknown.status, 404);
  assert.equal((await unknown.json()).errcode, 'M_UNRECOGNIZED');
  const method = await fetch(endpoint);
  assert.equal(method.status, 405);
  assert.equal(method.headers.get('allow'), 'POST');
  assert.equal((await method.json()).errcode, 'M_UNRECOGNIZED');
  const plain = await post({ notification: notification() }, { headers: { 'content-type': 'text/plain' } });
  assert.equal(plain.status, 415);
  const oversized = await post({ notification: notification({ content: { body: 'x'.repeat(1024 * 1024) } }) });
  assert.equal(oversized.status, 413);
  assert.deepEqual(delivered, []);
});
