import { initializeApp } from 'firebase-admin/app';
import { getMessaging } from 'firebase-admin/messaging';
import { onRequest } from 'firebase-functions/v2/https';

initializeApp();

const allowedApps = new Set(['ai.nuanu.slatrix.dev', 'ai.nuanu.slatrix']);
const isObject = (value) => value !== null && typeof value === 'object' && !Array.isArray(value);
const boundedText = (value, bytes) => typeof value === 'string' && value.length > 0
  && Buffer.byteLength(value) <= bytes && !/[\s\x00-\x1f\x7f]/u.test(value);

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
  if (!isObject(request.body) || !validNotification(request.body.notification)) {
    response.status(400).json({ errcode: 'M_BAD_JSON', error: 'Invalid notification' });
    return;
  }
  const notification = request.body.notification;
  if (notification.event_id === undefined) {
    response.status(200).json({ rejected: [] });
    return;
  }
  await Promise.all(notification.devices.map((device) => getMessaging().send({
    token: device.pushkey,
    data: { event_id: notification.event_id, room_id: notification.room_id },
    android: { priority: 'high', restrictedPackageName: device.app_id },
  })));
  response.status(200).json({ rejected: [] });
});
