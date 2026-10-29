import { initializeApp } from 'firebase-admin/app';
import { getMessaging } from 'firebase-admin/messaging';
import { onRequest } from 'firebase-functions/v2/https';

initializeApp();

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
  const notification = request.body.notification;
  await Promise.all(notification.devices.map((device) => getMessaging().send({
    token: device.pushkey,
    data: { event_id: notification.event_id, room_id: notification.room_id },
    android: { priority: 'high', restrictedPackageName: device.app_id },
  })));
  response.status(200).json({ rejected: [] });
});
