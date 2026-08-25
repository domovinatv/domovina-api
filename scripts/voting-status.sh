#!/usr/bin/env bash
# Stanje „Izbornog dana" + eID verifikacija na live bazi (read-only).
#
# Usage:
#   ./scripts/voting-status.sh          # sažetak
#   ./scripts/voting-status.sh --full   # + ljestvica i glasovi po danu
#
# Sve su to SELECT-ovi; skripta NIŠTA ne piše u bazu.
#
# Napomena: `voters.user_id` je `on delete set null`, a `identity_verifications`
# kaskadno nestaje s računom — zato se veza verificiran↔glasač radi preko
# `oib_hash`, ne preko `user_id`.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/db-env.sh
. "$SCRIPT_DIR/lib/db-env.sh"

FULL=false
[ "${1:-}" = "--full" ] && FULL=true

# Bitno: detect_db_container ide PRIJE heredoca — ssh unutar njega bi inače
# pojeo SQL sa stdina (tiho prazan izlaz).
CONTAINER=$(detect_db_container)
echo "→ container: $CONTAINER (user=$COOLIFY_DB_USER db=$COOLIFY_DB_NAME)" >&2

SQL_CORE=$(cat <<'SQL'
\pset border 2
\echo ''
\echo '── eID verifikacije (Certilia) ─────────────────────────────'
select provider,
       count(*)                       as ukupno,
       min(verified_at)::date         as prva,
       max(verified_at)::date         as zadnja
  from public.identity_verifications
 group by provider
 order by provider;

\echo '── Funnel ──────────────────────────────────────────────────'
select (select count(*) from auth.users)                                as racuna_ukupno,
       (select count(*) from auth.users where not is_anonymous)         as s_racunom,
       (select count(*) from public.identity_verifications)             as verificiranih,
       (select count(*) from domovina_ai.voters)                        as glasaca,
       (select count(*) from domovina_ai.voters where consented_at is not null)
                                                                        as prihvatili_privolu;

\echo '── Glasovi ─────────────────────────────────────────────────'
select count(*)                                      as glasova,
       count(*) filter (where direction = 1)         as up,
       count(*) filter (where direction = -1)        as down,
       count(distinct voter_id)                      as razlicitih_glasaca,
       min(vote_day)                                 as prvi_dan,
       max(vote_day)                                 as zadnji_dan
  from domovina_ai.votes;

\echo '── Kola ────────────────────────────────────────────────────'
-- votes_rows može biti < tally: kolo bez pobjednika prenosi tally naprijed
-- (carry-over, close_expired_rounds §7.2) pa novo kolo ima zbroj bez glasova.
select r.id, r.starts_on, r.ends_on, r.status,
       coalesce(r.winner_slug, r.no_winner_reason, '') as ishod,
       r.quorum_net, r.quorum_total,
       (select count(*) from domovina_ai.votes v where v.round_id = r.id) as votes_rows,
       (select coalesce(sum(up), 0)   from domovina_ai.vote_tallies t where t.round_id = r.id) as tally_up,
       (select coalesce(sum(down), 0) from domovina_ai.vote_tallies t where t.round_id = r.id) as tally_down
  from domovina_ai.vote_rounds r
 order by r.id;

\echo '── Kandidati ───────────────────────────────────────────────'
select status, count(*) from domovina_ai.vote_candidates group by 1 order by 2 desc;
SQL
)

SQL_FULL=$(cat <<'SQL'
\echo '── Ljestvica otvorenog kola ────────────────────────────────'
select t.slug, c.display_name, t.up, t.down, t.net
  from domovina_ai.vote_tallies t
  join domovina_ai.vote_candidates c using (slug)
 where t.round_id = (select id from domovina_ai.vote_rounds where status = 'open')
 order by t.net desc, t.up desc, t.slug
 limit 25;

\echo '── Glasovi po danu ─────────────────────────────────────────'
select vote_day,
       count(*)                               as glasova,
       count(*) filter (where direction = 1)  as up,
       count(*) filter (where direction = -1) as down
  from domovina_ai.votes
 group by 1
 order by 1;

\echo '── Verifikacije po danu ────────────────────────────────────'
select verified_at::date as dan, count(*)
  from public.identity_verifications
 group by 1
 order by 1;

\echo '── Praćeni kandidati (⚑) ───────────────────────────────────'
select count(*) as follows, count(distinct user_id) as korisnika
  from domovina_ai.candidate_follows;
SQL
)

if $FULL; then
  printf '%s\n%s\n' "$SQL_CORE" "$SQL_FULL" | remote_psql_exec "$CONTAINER"
else
  printf '%s\n' "$SQL_CORE" | remote_psql_exec "$CONTAINER"
fi
