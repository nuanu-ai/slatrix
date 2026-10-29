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
