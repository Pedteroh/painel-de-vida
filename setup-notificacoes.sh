#!/usr/bin/env bash
# Painel da Vida: instala o servidor de avisos no seu projeto Firebase.
# Rode no Cloud Shell:  bash <(curl -sL https://raw.githubusercontent.com/Pedteroh/painel-de-vida/main/setup-notificacoes.sh)
set -e
PROJECT="painel-de-vida-39987"
echo "==> Painel da Vida: instalando os avisos no projeto $PROJECT"
gcloud config set project "$PROJECT" >/dev/null 2>&1 || true

echo "==> Procurando a região do seu banco de dados..."
LOC=$(gcloud firestore databases describe --project="$PROJECT" --format='value(locationId)' 2>/dev/null || true)
if [ -z "$LOC" ]; then LOC=$(gcloud firestore databases list --project="$PROJECT" --format='value(locationId)' 2>/dev/null | head -n1 || true); fi
case "$LOC" in
  nam5) REGION="us-central1" ;;
  eur3) REGION="europe-west1" ;;
  "") REGION="us-central1"; echo "    Não consegui detectar a região; vou usar us-central1." ;;
  *) REGION="$LOC" ;;
esac
echo "    Banco em: ${LOC:-desconhecido}  |  funções em: $REGION"

WORK="$HOME/painel-avisos"
rm -rf "$WORK"; mkdir -p "$WORK/functions"; cd "$WORK"

cat > firebase.json <<'PAINEL_EOF'
{ "functions": [ { "source": "functions", "codebase": "default", "runtime": "nodejs22" } ] }
PAINEL_EOF

cat > .firebaserc <<PAINEL_EOF
{ "projects": { "default": "$PROJECT" } }
PAINEL_EOF

cat > functions/package.json <<'PAINEL_EOF'
{
  "name": "painel-functions",
  "private": true,
  "main": "index.js",
  "engines": { "node": "22" },
  "dependencies": {
    "firebase-admin": "^13.0.0",
    "firebase-functions": "^6.3.0",
    "web-push": "^3.6.7"
  }
}
PAINEL_EOF

cat > functions/.env <<PAINEL_EOF
DB_REGION=$REGION
FN_REGION=$REGION
PAINEL_EOF

cat > functions/index.js <<'PAINEL_EOF'
/* Painel da Vida: avisos (Web Push). Os textos dos avisos chegam criptografados e só o celular os lê. */
const { onSchedule } = require('firebase-functions/v2/scheduler');
const { onDocumentWritten } = require('firebase-functions/v2/firestore');
const admin = require('firebase-admin');
const webpush = require('web-push');

admin.initializeApp();
const db = admin.firestore();
const DB_REGION = process.env.DB_REGION || 'us-central1';
const FN_REGION = process.env.FN_REGION || DB_REGION;
const SITE = 'https://pedteroh.github.io/painel-de-vida/';

let vapidReady = null;
function ensureVapid() {
  if (vapidReady) return vapidReady;
  vapidReady = (async () => {
    const ref = db.collection('config').doc('vapid');
    let snap = await ref.get();
    let keys;
    if (snap.exists && snap.data().pub && snap.data().priv) keys = snap.data();
    else {
      keys = webpush.generateVAPIDKeys();
      keys = { pub: keys.publicKey, priv: keys.privateKey };
      await ref.set(keys);
    }
    await db.collection('config').doc('vapidPublic').set({ key: keys.pub });
    webpush.setVapidDetails(SITE, keys.pub, keys.priv);
  })().catch((e) => { vapidReady = null; throw e; });
  return vapidReady;
}

async function sendTo(uid, payload, ttl) {
  if (!uid) return 0;
  await ensureVapid();
  const ref = db.collection('push').doc(uid);
  const snap = await ref.get();
  if (!snap.exists) return 0;
  const subs = Array.isArray(snap.data().subs) ? snap.data().subs : [];
  const keep = [];
  let sent = 0;
  await Promise.all(subs.map(async (s) => {
    try {
      await webpush.sendNotification({ endpoint: s.endpoint, keys: s.keys }, JSON.stringify(payload), { TTL: ttl || 3600, urgency: 'high' });
      keep.push(s); sent++;
    } catch (e) {
      if (e && (e.statusCode === 404 || e.statusCode === 410)) return;
      keep.push(s);
    }
  }));
  if (keep.length !== subs.length) await ref.update({ subs: keep });
  return sent;
}

/* a cada minuto: manda os lembretes que venceram e apaga */
exports.sendDue = onSchedule({ schedule: 'every 1 minutes', region: FN_REGION, timeoutSeconds: 120, memory: '256MiB' }, async () => {
  const now = Date.now();
  const qs = await db.collection('reminders').where('fireAt', '<=', now).limit(300).get();
  if (qs.empty) return;
  const jobs = [];
  qs.forEach((doc) => {
    const r = doc.data();
    if (now - r.fireAt > 30 * 60 * 1000) return;
    jobs.push(sendTo(r.uid, { u: r.u, p: r.p }, 3600).catch(() => 0));
  });
  await Promise.all(jobs);
  const batch = db.batch();
  qs.forEach((doc) => batch.delete(doc.ref));
  await batch.commit();
});

async function wantsCouple(uid) {
  const p = await db.collection('push').doc(uid).get();
  return p.exists && p.data().couple !== false;
}

/* o par registrou o humor do dia */
exports.onShared = onDocumentWritten({ document: 'shared/{uid}', region: DB_REGION }, async (event) => {
  const after = event.data && event.data.after && event.data.after.exists ? event.data.after.data() : null;
  const before = event.data && event.data.before && event.data.before.exists ? event.data.before.data() : null;
  if (!after || after.ev !== 'mood' || !after.partner) return;
  if (before && before.evAt === after.evAt) return;
  if (!(await wantsCouple(after.partner))) return;
  await sendTo(after.partner, { t: 'Nós', b: 'Seu par registrou o humor de hoje 💗', g: 'couple-mood', x: './' }, 3600);
});

/* o par marcou um hábito em conjunto */
exports.onCouple = onDocumentWritten({ document: 'couples/{cid}', region: DB_REGION }, async (event) => {
  const after = event.data && event.data.after && event.data.after.exists ? event.data.after.data() : null;
  const before = event.data && event.data.before && event.data.before.exists ? event.data.before.data() : null;
  if (!after || after.ev !== 'habit' || !Array.isArray(after.members)) return;
  if (before && before.evAt === after.evAt) return;
  const other = after.members.filter((m) => m !== after.by);
  for (const uid of other) {
    if (await wantsCouple(uid)) await sendTo(uid, { t: 'Nós', b: 'Seu par marcou um hábito em conjunto ✔️', g: 'couple-habit', x: './' }, 3600);
  }
});
PAINEL_EOF

echo "==> Instalando as bibliotecas (pode levar 1 minuto)..."
( cd functions && npm install --no-audit --no-fund --loglevel=error )

if ! firebase projects:list --non-interactive >/dev/null 2>&1; then
  echo "==> Faça login no Firebase: abra o link que vai aparecer, entre com a MESMA conta do projeto e cole o código aqui."
  firebase login --no-localhost
fi

echo "==> Publicando as funções (a primeira vez demora alguns minutos)..."
OK=0
for TRY in 1 2 3; do
  if firebase deploy --only functions --project "$PROJECT" --force; then OK=1; break; fi
  echo "    Tentativa $TRY não deu certo. Se apareceu algo sobre faturamento (Blaze), ative o plano e rode de novo."
  [ "$TRY" -lt 3 ] && { echo "    Esperando 60 segundos e tentando de novo..."; sleep 60; }
done
if [ "$OK" -ne 1 ]; then echo "==> Não foi possível publicar. Me mande a mensagem de erro acima."; exit 1; fi

echo "==> Limpando arquivos de instalação antigos (evita custo de armazenamento)..."
firebase functions:artifacts:setpolicy --project "$PROJECT" --force >/dev/null 2>&1 || true

echo ""
echo "==> PRONTO! Espere 2 minutos, abra o Painel da Vida e vá em Ajustes > Notificações."
