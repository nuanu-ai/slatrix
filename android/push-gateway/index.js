import { initializeApp } from 'firebase-admin/app';
import { getMessaging } from 'firebase-admin/messaging';
import { onRequest } from 'firebase-functions/v2/https';

initializeApp();

const invalidTokenCodes = new Set([
  'messaging/registration-token-not-registered', 'messaging/invalid-registration-token',
]);
const allowedApps = new Set(['ai.nuanu.slatrix.dev', 'ai.nuanu.slatrix']);
const isObject = (value) => value !== null && typeof value === 'object' && !Array.isArray(value);
const boundedText = (value, bytes) => typeof value === 'string' && value.length > 0
  && Buffer.byteLength(value) <= bytes && !/[\s\x00-\x1f\x7f]/u.test(value);

function isInvalidToken(error) {
  if (invalidTokenCodes.has(error?.code)) return true;
  const details = error?.httpResponse?.data?.error?.details;
  return error?.code === 'messaging/invalid-argument' && Array.isArray(details)
    && details.some((detail) => detail?.['@type'] === 'type.googleapis.com/google.firebase.fcm.v1.FcmError'
      && detail.errorCode === 'INVALID_ARGUMENT');
}

function validNotification(value) {
  return isObject(value)
    && ((value.event_id === undefined && value.room_id === undefined && isObject(value.counts))
      || (boundedText(value.event_id, 255) && value.event_id.startsWith('$')
        && boundedText(value.room_id, 255) && value.room_id.startsWith('!')))
    && (value.counts === undefined || (isObject(value.counts)
      && ['unread', 'missed_calls'].every((key) => value.counts[key] === undefined
        || (Number.isSafeInteger(value.counts[key]) && value.counts[key] >= 0))))
    && (value.prio === undefined || value.prio === 'high' || value.prio === 'low')
    && Array.isArray(value.devices) && value.devices.length <= 100
    && value.devices.every((device) => isObject(device) && allowedApps.has(device.app_id)
      && boundedText(device.pushkey, 4096));
}

export const matrixPush = onRequest({
  region: 'europe-west1',
  serviceAccount: 'slatrix-push@slatrix-18cdc.iam.gserviceaccount.com',
  invoker: 'public',
  cors: false,
  minInstances: 0,
  maxInstances: 1,
  concurrency: 4,
  memory: '256MiB',
  timeoutSeconds: 30,
}, async (request, response) => {
  if (request.path !== '/_matrix/push/v1/notify') {
    response.status(404).json({ errcode: 'M_UNRECOGNIZED', error: 'Unknown endpoint' });
    return;
  }
  if (request.method !== 'POST') {
    response.set('Allow', 'POST').status(405).json({ errcode: 'M_UNRECOGNIZED', error: 'Unsupported method' });
    return;
  }
  if (!request.is('application/json')) {
    response.status(415).json({ errcode: 'M_NOT_JSON', error: 'Expected application/json' });
    return;
  }
  if (request.rawBody.length > 1024 * 1024) {
    response.status(413).json({ errcode: 'M_TOO_LARGE', error: 'Request too large' });
    return;
  }
  if (!isObject(request.body) || !validNotification(request.body.notification)) {
    response.status(400).json({ errcode: 'M_BAD_JSON', error: 'Invalid notification' });
    return;
  }
  const notification = request.body.notification;
  if (notification.event_id === undefined) {
    response.status(200).json({ rejected: [] });
    return;
  }
  const results = await Promise.allSettled(notification.devices.map((device) => getMessaging().send({
    token: device.pushkey,
    data: { event_id: notification.event_id, room_id: notification.room_id },
    android: { priority: notification.prio === 'low' ? 'normal' : 'high', restrictedPackageName: device.app_id },
  })));
  if (results.some((result) => result.status === 'rejected' && !isInvalidToken(result.reason))) {
    response.set('Retry-After', '60').status(503).json({ errcode: 'M_UNKNOWN', error: 'Push delivery unavailable' });
    return;
  }
  const rejected = notification.devices.filter((_, index) => results[index].status === 'rejected')
    .map((device) => device.pushkey);
  response.status(200).json({ rejected });
});
