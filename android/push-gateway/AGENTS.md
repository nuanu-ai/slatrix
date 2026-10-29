# Push gateway

Root and Android rules apply here. The owner's Firebase Cloud Function decision supersedes the earlier Sygnal requirement for this gateway.

- Test the exported HTTP function through the Functions Framework, with Firebase Admin Messaging as the external seam. This catches protocol validation, payload privacy and provider error handling; it misses deployed IAM, FCM delivery and Android notification behavior.
- Use ambient credentials from the dedicated runtime service account. Never add a service-account key or log request bodies and push keys.
