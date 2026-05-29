#!/usr/bin/env node
// gen-apple-secret.mjs — generira Apple "Sign in with Apple" client secret (JWT).
//
// Apple ne koristi statični client secret; secret je ES256-potpisani JWT koji
// ISTJEČE (max 6 mjeseci). Ovo je `GOTRUE_EXTERNAL_APPLE_SECRET`.
//
// Ulazi (flag ili env):
//   --p8     <path>      Sign in with Apple Key (.p8)         | APPLE_P8_PATH
//   --team   <TeamID>    Apple Developer Team ID (10 znakova) | APPLE_TEAM_ID
//   --kid    <KeyID>     Key ID iz .p8 keya (10 znakova)      | APPLE_KEY_ID
//   --client <ServicesID> client_id = Services ID identifier  | APPLE_CLIENT_ID
//   --days   <N>         valjanost (default 180; Apple cap ~180)
//
// Primjer:
//   node scripts/gen-apple-secret.mjs \
//     --p8 ~/secrets/AuthKey_ABC123.p8 --team TEAM123456 \
//     --kid ABC123DEFG --client ai.domovina.signin
//
// Output: JWT na stdout (samo token, ništa drugo) → lako u env/clipboard:
//   node scripts/gen-apple-secret.mjs ... | pbcopy

import { readFileSync } from 'node:fs';
import { createPrivateKey, sign } from 'node:crypto';

function arg(name, env) {
  const i = process.argv.indexOf(`--${name}`);
  if (i !== -1 && process.argv[i + 1]) return process.argv[i + 1];
  return process.env[env];
}

const p8Path = arg('p8', 'APPLE_P8_PATH');
const teamId = arg('team', 'APPLE_TEAM_ID');
const keyId = arg('kid', 'APPLE_KEY_ID');
const clientId = arg('client', 'APPLE_CLIENT_ID');
const days = Number(arg('days', 'APPLE_SECRET_DAYS') || '180');

const missing = [
  ['--p8/APPLE_P8_PATH', p8Path],
  ['--team/APPLE_TEAM_ID', teamId],
  ['--kid/APPLE_KEY_ID', keyId],
  ['--client/APPLE_CLIENT_ID', clientId],
].filter(([, v]) => !v).map(([n]) => n);
if (missing.length) {
  console.error(`❌ Nedostaje: ${missing.join(', ')}\n   Vidi: node scripts/gen-apple-secret.mjs --help`);
  process.exit(2);
}
if (process.argv.includes('--help') || process.argv.includes('-h')) {
  console.error(readFileSync(new URL(import.meta.url)).toString().split('\n').slice(1, 24).join('\n'));
  process.exit(0);
}

const b64url = (buf) =>
  Buffer.from(buf).toString('base64').replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');

const now = Math.floor(Date.now() / 1000);
const maxExp = now + 15777000; // Apple hard cap: 6 mjeseci
const exp = Math.min(now + days * 86400, maxExp);

const header = { alg: 'ES256', kid: keyId };
const payload = {
  iss: teamId,
  iat: now,
  exp,
  aud: 'https://appleid.apple.com',
  sub: clientId,
};

const signingInput = `${b64url(JSON.stringify(header))}.${b64url(JSON.stringify(payload))}`;
const privateKey = createPrivateKey(readFileSync(p8Path));
// dsaEncoding ieee-p1363 → raw R||S (JOSE format), ne DER.
const signature = sign('sha256', Buffer.from(signingInput), {
  key: privateKey,
  dsaEncoding: 'ieee-p1363',
});

process.stdout.write(`${signingInput}.${b64url(signature)}\n`);
process.stderr.write(
  `✅ Apple client secret (vrijedi do ${new Date(exp * 1000).toISOString()})\n` +
  `   sub=${clientId} iss=${teamId} kid=${keyId}\n`,
);
