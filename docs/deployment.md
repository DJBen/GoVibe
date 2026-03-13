# Deployment Guide

## Prerequisites

- Firebase CLI (`npm i -g firebase-tools`)
- GCP project with billing enabled
- Enabled APIs: Cloud Functions, Firestore, Cloud Run, Secret Manager, Cloud KMS

## Firebase

1. Login and set project:

```bash
firebase login
firebase use govibe-demo
```

2. Configure secrets for functions:

```bash
firebase functions:secrets:set SESSION_TOKEN_SECRET
firebase functions:secrets:set TURN_SECRET
```

3. Deploy:

```bash
cd backend/functions
npm install
npm run build
cd ../..
firebase deploy --only functions,firestore
```

4. Verify scheduled stale-session cleanup is deployed:

```bash
gcloud scheduler jobs list --location us-west1 | grep closeStaleSessions
```

5. Verify Firestore TTL for auto-deletion is active on `sessions.expiresAt`:

```bash
gcloud firestore fields ttls list \
  --database='(default)' \
  --filter='collectionGroup:sessions AND field:expiresAt'
```

If TTL is not active yet, deploy Firestore config again (`firebase deploy --only firestore`) and wait for TTL field policy propagation.

## Cloud Run Relay

```bash
cd infra/cloud-run-relay
npm install

gcloud run deploy govibe-relay \
  --source . \
  --region us-west1 \
  --allow-unauthenticated \
  --min-instances 0
```

Set relay URL in iOS/mac clients via environment/config.

## TURN

For demo, deploy a single-zone Coturn VM and set `TURN_URLS` in Functions environment.
