# Matrix push gateway

A Firebase HTTP function forwards Matrix event and room IDs to FCM. It sends data messages only. Message text, sender, room name, counts and client-supplied payloads never enter FCM. Android resolves each event and suppresses duplicate alerts.

The [Matrix push gateway API](https://spec.matrix.org/latest/push-gateway-api/) permits badge-only updates. This gateway acknowledges those without sending FCM. Only expired or invalid registration tokens appear in `rejected`; other [FCM failures](https://firebase.google.com/docs/cloud-messaging/error-codes) return 503 for Matrix to retry. A retry can redeliver to a device that already succeeded.

Requests allow up to 100 device registrations, a 4 KiB push key per device, 255 UTF-8 bytes per Matrix ID and a 1 MiB JSON body. The device limit accommodates accounts with many installations while bounding provider fan-out. Only `ai.nuanu.slatrix.dev` and `ai.nuanu.slatrix` are accepted, with FCM restricted to the same Android package. This allowlist is not authentication: the endpoint is public, as Matrix requires. Do not log requests, push keys or provider error details.

## Test

With Node 24, run from this directory:

```sh
npm ci
npm test
```

Tests invoke the exported function through Google's Functions Framework and fake only Firebase Admin Messaging. They do not contact Firebase.

## Deploy

The owner must approve and enable Blaze billing for `slatrix-18cdc` before deployment. Register both Android packages in that Firebase project and install the matching `google-services.json` in the Android app separately.

Create `slatrix-push@slatrix-18cdc.iam.gserviceaccount.com` with only `roles/firebasecloudmessaging.admin` for runtime messaging. The deployer needs permission to deploy functions and act as that account. Use the account configured in `index.js`; do not grant Editor to a default runtime account.

The Admin SDK uses [ambient Application Default Credentials](https://firebase.google.com/docs/admin/setup) from the [configured runtime service account](https://firebase.google.com/docs/functions/manage-functions#set_a_service_account). No service-account JSON key is needed.

After those prerequisites, sign in with the Firebase CLI and run from this directory:

```sh
npm ci
npm test
firebase deploy --project slatrix-18cdc --only functions:slatrix-push
```

Deploying creates the public `matrixPush` function in `europe-west1`. It scales to zero, with at most one instance, four concurrent requests, 256 MiB memory and a 30-second request timeout. These limits bound concurrency, not total spend; billing alerts and usage monitoring remain the owner's responsibility.

Use the function URL printed by deployment, followed by `/_matrix/push/v1/notify`, as the Android push gateway URL. For the Firebase function URL form, the full endpoint is:

```text
https://europe-west1-slatrix-18cdc.cloudfunctions.net/matrixPush/_matrix/push/v1/notify
```

The function-name prefix belongs to the deployment URL. The handler receives the `/_matrix/push/v1/notify` suffix. Confirm the deployed endpoint, IAM and delivery from a designated test account before treating Android notifications as working.
