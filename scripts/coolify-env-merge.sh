#!/usr/bin/env bash
# coolify-env-merge.sh
#
# Non-destruktivni merge: uzme LIVE Coolify env dump i nanese ne-tajne config
# override-e PREKO njega, čuvajući SVE ostalo (uključujući secrete) netaknuto.
# Output je spreman za paste nazad u Coolify Bulk edit.
#
# NE rotira nijedan secret. NE leaka secrete u chat/stdout (samo masked + diff
# za ne-tajne config ključeve).
#
# Workflow:
#   1) Coolify → service → Environment Variables → Developer view → Cmd+A →
#      kopiraj sve KEY=VALUE redove → spremi u:
#         .coolify-current.env        (repo root, gitignored)
#   2) ./scripts/coolify-env-merge.sh
#   3) Pregledaj DIFF (ispod). Ako OK → sadržaj je u clipboardu (+ .coolify-merged.env).
#   4) Coolify → Bulk edit → Cmd+A → Paste → Save → Deploy.
#
# Merge pravila (vidi coolify-config-overrides.env):
#   - scalar key   → override zamjenjuje live vrijednost
#   - CSV_UNION key → union: live stavke ostaju, dodaju se samo one koje fale
#   - key samo u live-u → passthrough netaknut (svi secreti idu ovuda)
#
# Usage:
#   ./scripts/coolify-env-merge.sh
#   ./scripts/coolify-env-merge.sh --current=path.env --overrides=path.env
#   ./scripts/coolify-env-merge.sh --no-copy        # bez clipboarda, samo file+diff

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

CURRENT_FILE="$REPO_ROOT/.coolify-current.env"
OVERRIDES_FILE="$REPO_ROOT/coolify-config-overrides.env"
MERGED_FILE="$REPO_ROOT/.coolify-merged.env"
COPY=true

# Ključevi koji se union-merge-aju (comma-separated liste) umjesto replace.
# NB: GOTRUE_URI_ALLOW_LIST se NE upravlja — Coolify compose ga derivira iz
# ADDITIONAL_REDIRECT_URLS ('${ADDITIONAL_REDIRECT_URLS}'), pa je editable key noop.
CSV_UNION_KEYS="PGRST_DB_SCHEMAS ADDITIONAL_REDIRECT_URLS"

for arg in "$@"; do
  case "$arg" in
    --current=*)   CURRENT_FILE="${arg#*=}" ;;
    --overrides=*) OVERRIDES_FILE="${arg#*=}" ;;
    --no-copy)     COPY=false ;;
    -h|--help)     sed -n '2,30p' "$0"; exit 0 ;;
    *) echo "Unknown arg: $arg" >&2; exit 2 ;;
  esac
done

if [ ! -f "$CURRENT_FILE" ]; then
  cat >&2 <<EOF
❌ '$CURRENT_FILE' ne postoji.

Korak: Coolify → service → Environment Variables → Developer view →
Cmd+A → kopiraj sve KEY=VALUE redove → spremi u:

  $CURRENT_FILE

(Gitignored — secreti neće završiti u repo-u ni u chatu.)
EOF
  exit 1
fi
if [ ! -f "$OVERRIDES_FILE" ]; then
  echo "❌ '$OVERRIDES_FILE' ne postoji (committed config layer)." >&2
  exit 1
fi

mask() {
  local v=$1 n=${#1}
  if [ -z "$v" ]; then printf '<empty>'
  elif [ "$n" -le 8 ]; then printf '%*s' "$n" '' | tr ' ' '*'
  else printf '%s…%s (len=%d)' "${v:0:4}" "${v: -4}" "$n"
  fi
}

WORK=$(mktemp -d -t domovina-merge.XXXXXX)
trap 'rm -rf "$WORK"' EXIT

# Merge u awk-u. Output: merged env (order = live dump, pa novi override-only keys).
# Diff redovi (samo za config-override ključeve) idu na fd 3 → odvojeni file.
awk -v csv_union="$CSV_UNION_KEYS" '
  function trim(s){ sub(/^[ \t]+/,"",s); sub(/[ \t\r]+$/,"",s); return s }
  function in_csv(k,   i){ for(i in CSVU) if(CSVU[i]==k) return 1; return 0 }
  # union dvije CSV liste: zadrži live order, appendaj missing iz ovr
  function csv_union_merge(live,ovr,   a,b,i,j,out,seen,n,m,found){
    n=split(live,a,","); m=split(ovr,b,",")
    out=""; delete seen
    for(i=1;i<=n;i++){ x=trim(a[i]); if(x=="")continue; if(!(x in seen)){seen[x]=1; out=(out==""?x:out","x)} }
    for(j=1;j<=m;j++){ y=trim(b[j]); if(y=="")continue; if(!(y in seen)){seen[y]=1; out=(out==""?y:out","y)} }
    return out
  }
  BEGIN{
    nc=split(csv_union,CSVU," ")
    phase="ovr"   # prvi file = overrides
  }
  FNR==1 { files++; if(files==1) phase="ovr"; else phase="live" }
  # skip komentare/prazno
  /^[[:space:]]*#/ { next }
  /^[[:space:]]*$/ { next }
  {
    line=$0; sub(/\r$/,"",line)
    eq=index(line,"=")
    if(eq==0) next
    key=substr(line,1,eq-1)
    val=substr(line,eq+1)
    key=trim(key)
  }
  phase=="ovr" {
    OVR[key]=val
    if(!(key in OVRSEEN)){ OVRSEEN[key]=1; OVRORDER[++no]=key }
    next
  }
  phase=="live" {
    if(!(key in LIVESEEN)){ LIVESEEN[key]=1; LIVEORDER[++nl]=key }
    LIVE[key]=val
    next
  }
  END{
    # 1) emitiraj live order
    for(i=1;i<=nl;i++){
      k=LIVEORDER[i]; lv=LIVE[k]
      if(k in OVR){
        if(in_csv(k)){
          nv=csv_union_merge(lv,OVR[k])
        } else {
          nv=OVR[k]
        }
        if(nv!=lv) printf("CHG\t%s\t%s\t%s\n",k,lv,nv) > "/dev/stderr"
        print k "=" nv
        EMIT[k]=1
      } else {
        print k "=" lv
        EMIT[k]=1
      }
    }
    # 2) override-only keys (fale u live-u) — dodaj na kraj
    for(i=1;i<=no;i++){
      k=OVRORDER[i]
      if(!(k in EMIT)){
        nv=OVR[k]
        printf("NEW\t%s\t\t%s\n",k,nv) > "/dev/stderr"
        print k "=" nv
      }
    }
  }
' "$OVERRIDES_FILE" "$CURRENT_FILE" > "$WORK/merged.env" 2> "$WORK/diff.txt"

# Header
{
  echo "# DOMOVINA-API — merged Coolify env (built $(date -u +'%Y-%m-%dT%H:%M:%SZ'))"
  echo "# Source: live dump ($(basename "$CURRENT_FILE")) + coolify-config-overrides.env"
  echo "# Generated by scripts/coolify-env-merge.sh — secreti su passthrough, ne-rotirani."
  cat "$WORK/merged.env"
} > "$MERGED_FILE"

LIVE_COUNT=$(grep -c '=' "$CURRENT_FILE" 2>/dev/null || echo 0)
MERGED_COUNT=$(grep -c '=' "$WORK/merged.env" 2>/dev/null || echo 0)

echo "→ live keys:   $LIVE_COUNT"
echo "→ merged keys: $MERGED_COUNT"
echo ""
echo "Promjene (samo ne-tajni config ključevi; secreti netaknuti):"
if [ -s "$WORK/diff.txt" ]; then
  while IFS=$'\t' read -r kind key oldv newv; do
    case "$kind" in
      CHG) echo "  ~ $key"; echo "      old: $oldv"; echo "      new: $newv" ;;
      NEW) echo "  + $key=$newv  (novi key)" ;;
    esac
  done < "$WORK/diff.txt"
else
  echo "  (nema promjena — live je već u skladu s config override-ima)"
fi

echo ""
echo "→ merged file: $MERGED_FILE  (gitignored)"

if $COPY; then
  if   command -v pbcopy  >/dev/null; then pbcopy   < "$MERGED_FILE"; echo "✅ Copied to clipboard (pbcopy)"
  elif command -v xclip   >/dev/null; then xclip -selection clipboard < "$MERGED_FILE"; echo "✅ Copied to clipboard (xclip)"
  elif command -v wl-copy >/dev/null; then wl-copy  < "$MERGED_FILE"; echo "✅ Copied to clipboard (wl-copy)"
  else echo "⚠️  Nema clipboard utila — koristi $MERGED_FILE ručno."
  fi
fi

echo ""
echo "Next: Coolify → Bulk edit → Cmd+A → Paste → Save → Deploy."
echo "Cleanup kad gotov:  rm -f $CURRENT_FILE $MERGED_FILE"
