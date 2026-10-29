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
