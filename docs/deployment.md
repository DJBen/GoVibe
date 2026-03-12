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
