#!/data/data/com.termux/files/usr/bin/env bash
# === start.sh — avvia climbo-logbook su Termux (o Linux) senza Docker ===
# Metti questo file DENTRO la cartella dell'app (accanto a server.js) e lancia:
#   bash start.sh
# Idempotente: rilancialo quante volte vuoi.
#
# Cosa fa:
#  1. installa nodejs-lts + postgresql se mancano (pkg su Termux, apt su Linux)
#  2. initdb + avvia postgres locale in ./pgdata (porta $PGPORT, default 5432)
#  3. npm install (express, multer, pg — JS puro, niente nativi)
#  4. crea il db 'climbo_logbook' se manca (usando node+pg, senza psql)
#  5. node server.js -> http://localhost:3000
# Non dipende da psql/createdb/pg_isready: serve solo initdb/pg_ctl/postgres + node.
set -e

# --- config (modifica se vuoi) ---
PGPORT="${PGPORT:-5432}"
PGUSER_APP="climbo"            # superuser creato da initdb (auth trust locale)
PGDB="climbo_logbook"
UPLOAD_DIR="$PWD/uploads"
PGDATA="$PWD/pgdata"

# --- 1. dipendenze di sistema ---
need() { command -v "$1" >/dev/null 2>&1; }
if ! need node || ! need npm || ! need initdb || ! need pg_ctl || ! need postgres; then
  echo ">> installo nodejs-lts + postgresql..."
  if command -v pkg >/dev/null 2>&1; then
    pkg update -y >/dev/null && pkg install -y nodejs-lts postgresql
  elif command -v apt-get >/dev/null 2>&1; then
    sudo apt-get update -y && sudo apt-get install -y nodejs npm postgresql
  else
    echo "!! Nessun pkg/apt. Installa manualmente nodejs-lts e postgresql."; exit 1
  fi
fi
echo ">> node $(node -v)"

# --- 2. initdb + start postgres ---
if [ ! -d "$PGDATA" ]; then
  echo ">> initdb in $PGDATA (superuser: $PGUSER_APP, auth trust)"
  initdb -D "$PGDATA" -U "$PGUSER_APP" --auth=trust >/dev/null
  printf "\nlisten_addresses = '127.0.0.1'\nport = %s\n" "$PGPORT" >> "$PGDATA/postgresql.conf"
fi
if ! pg_ctl -D "$PGDATA" status >/dev/null 2>&1; then
  echo ">> avvio postgres su porta $PGPORT..."
  pg_ctl -D "$PGDATA" -l "$PGDATA/pg.log" -w start >/dev/null
fi

# --- 3. dipendenze app (serve pg per il passo 4) ---
if [ ! -d node_modules ]; then
  echo ">> npm install (express, multer, pg — JS puro, niente compilazione nativa)"
  npm install --omit=dev
fi
mkdir -p "$UPLOAD_DIR"

# --- 4. env per l'app + creazione db via node+pg ---
export PGHOST=127.0.0.1
export PGPORT
export PGUSER="$PGUSER_APP"
export PGPASSWORD="CLIMB"          # ignorato con auth trust, ma coerente con .env
export PGDATABASE="$PGDB"
export PGDB                         # usato dallo script node sotto
export UPLOAD_DIR                   # sovrascrive il default /data/uploads (non scrivibile)
export MAX_UPLOAD_MB=10
export ALLOW_REGISTRATION=true
export COOKIE_SECURE=false
export ADMIN_EMAIL="${ADMIN_EMAIL:-davide@gmail.com}"

echo ">> attendo postgres e creo il db '$PGDB' se manca..."
node - <<'NODE'
const { Client } = require('pg');
const cfg = {
  host: '127.0.0.1', port: Number(process.env.PGPORT),
  user: process.env.PGUSER, password: process.env.PGPASSWORD, database: 'postgres'
};
(async () => {
  // aspetta che il server accetti connessioni
  for (let i = 0; i < 30; i++) {
    try { const c = new Client(cfg); await c.connect(); await c.end(); break; }
    catch (e) { await new Promise(r => setTimeout(r, 1000)); }
    if (i === 29) { console.error('!! postgres non raggiungibile dopo 30s'); process.exit(1); }
  }
  // crea il db se non esiste
  const c = new Client(cfg);
  await c.connect();
  const r = await c.query("SELECT 1 FROM pg_database WHERE datname=$1", [process.env.PGDB]);
  if (!r.rowCount) {
    console.log(`>> creo database ${process.env.PGDB}`);
    await c.query(`CREATE DATABASE "${process.env.PGDB}"`);
  }
  await c.end();
})();
NODE

# --- 5. avvio app ---
echo
echo "============================================================"
echo "  Climbo Logbook in ascolto su  http://localhost:3000"
echo "  (Ctrl+C per fermare. Rilancia 'bash start.sh' per ripartire.)"
echo "============================================================"
exec node server.js
