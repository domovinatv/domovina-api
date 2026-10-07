#!/usr/bin/env bash
# Utrka: N stvarnih procesa (različiti korisnici) kupuje ISTI trenutak u istom
# trenu. Jednodretveni test ne dokazuje ništa o zaključavanju
# (docs/migration-testing-playbook.md §8).
#
#   supabase/tests/20261007_sponzorski_trenuci_utrka.sh
#
# Očekivano: točno 1 uspjeh, N-1 × slot_taken (→ HTTP 409 u pinka-contribute),
# nula deadlockova. Pretpostavlja da je 20261007_sponzorski_trenuci.sql već
# jednom prošao (seed + fixture postoje).
set -euo pipefail

DB="${DB:-postgresql://postgres:postgres@127.0.0.1:55322/postgres}"
N="${N:-12}"
KEY="${KEY:-b-nls1ck8EE@200}"
CAMPAIGN=7e5a0f3e-2f1d-4c9b-9a51-0d0b1a5e7101
OUT="$(mktemp -d)"

psql "$DB" -q -v ON_ERROR_STOP=1 <<SQL
update pinka_finance.slots set state = 'free', contribution_id = null, holder_account_id = null,
       hold_session_key = null, hold_expires_at = null
 where slot_key = '$KEY';
SQL

for i in $(seq 1 "$N"); do
  uid=$(printf '00000000-0000-4000-8000-0000000052%02d' "$i")
  (psql "$DB" -tA -v ON_ERROR_STOP=1 >"$OUT/$i.out" 2>"$OUT/$i.err" <<SQL
begin;
select set_config('role', 'authenticated', true);
select set_config('request.jwt.claims', '{"sub":"$uid","role":"authenticated"}', true);
select contribution_id from pinka_finance.create_sponsor_contribution(
  '$CAMPAIGN', array['$KEY'], 'Utrka $i', null, null, null,
  '{"company":"Utrka $i d.o.o.","email":"utrka$i@example.com"}'::jsonb, true);
commit;
SQL
  ) &
done
wait

ok=$(grep -lE '^[0-9a-f-]{36}$' "$OUT"/*.out | wc -l | tr -d ' ')
taken=$(grep -l 'slot_taken' "$OUT"/*.err | wc -l | tr -d ' ')
dead=$(grep -l 'deadlock' "$OUT"/*.err | wc -l | tr -d ' ' || true)
echo "uspjeh=$ok slot_taken=$taken deadlock=$dead (N=$N)"
grep -ohE 'ERROR:.*' "$OUT"/*.err | sort | uniq -c || true

if [ "$ok" = 1 ] && [ "$taken" = $((N - 1)) ] && [ "$dead" = 0 ]; then
  echo "OK — utrka: 1 pobjednik, $((N - 1)) × slot_taken, bez deadlocka"
else
  echo "PAO TEST: utrka" >&2
  exit 1
fi
