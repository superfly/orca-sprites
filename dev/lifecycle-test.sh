#!/usr/bin/env bash
# End-to-end check of the Sprites recipe against a real Orca client.
#   dev/lifecycle-test.sh <git repo with an origin remote>
# Runs the built recipe (recipes/sprites.json) through dev/run-phase.sh, as Orca would.
# create, pair with `orca-ide status`; let the Sprite sleep on its own and pair again (wake);
# suspend, let it sleep, resume, pair again with the OLD code; destroy. Prints JSON.
set -euo pipefail
repo="$(cd "${1:?repo path}" && pwd)"
here="$(cd "$(dirname "$0")" && pwd)"
run() { "$here/run-phase.sh" "$1" "$repo"; }
. "$here/../src/sprites/lib.sh"
ensure_org
now() { node -e 'process.stdout.write(String(Date.now()/1000))'; }
since() { node -e 'process.stdout.write((Date.now()/1000 - Number(process.argv[1])).toFixed(1))' "$1"; }
pair_once() { { orca-ide status --pairing-code "$1" --json 2>/dev/null || true; } | node -e '
  let d=""; process.stdin.on("data",c=>d+=c).on("end",()=>{ try { const j=JSON.parse(d);
  process.stdout.write(j.ok && j.result?.runtime?.connectionState==="connected" ? "ok" : "fail"); } catch { process.stdout.write("fail"); } });'; }
# pair <code>: retry for up to 60 s, as a reconnecting client would. Prints "ok/<attempts>" or "fail/<attempts>".
pair() { local n=0 r; for _ in $(seq 1 12); do n=$((n+1)); r="$(pair_once "$1")"; [ "$r" = ok ] && { printf 'ok/%s' "$n"; return; }; sleep 2; done; printf 'fail/%s' "$n"; }
service_logs() { rexec "$1" -- bash -c 'sprite-env services logs orca --lines 30' 2>&1 | node -e 'let d="";process.stdin.on("data",c=>d+=c).on("end",()=>{for(const l of d.split("\n")){try{for(const e of JSON.parse(l).events||[]) if(e.type==="log"&&!/telemetry/.test(e.data)) process.stderr.write(new Date(e.at_ms).toISOString().slice(11,19)+" "+e.data.slice(0,200).trim()+"\n")}catch{}}})' || true; }
field() { node -e 'const r=JSON.parse(process.argv[1]); const v=process.argv[2].split(".").reduce((o,k)=>o?.[k], r); process.stdout.write(String(v ?? ""))' "$1" "$2"; }
code_field() { # decode a field from the base64url pairing payload
  node -e 'const u=new URL(process.argv[1]); const j=JSON.parse(Buffer.from(u.searchParams.get("code"),"base64url")); process.stdout.write(String(j[process.argv[2]] ?? ""))' "$1" "$2"; }

status_of() { sp --json list --prefix "$1" | node -e 'let d="";process.stdin.on("data",c=>d+=c).on("end",()=>{const s=(JSON.parse(d).sprites||[]).find(x=>x.name===process.argv[1]);process.stdout.write(s?.status??"")})' "$1"; }
wait_sleep() { local t; t=$(now); for _ in $(seq 1 60); do st="$(status_of "$1")"; [ "$st" != running ] && { printf '%s %s\n' "$st" "$(since "$t")"; return; }; sleep 5; done; printf 'running %s\n' "$(since "$t")"; }
cd "$repo"
t=$(now); result="$(run create)"; t_create=$(since "$t")
name="$(field "$result" userData.resourceId)"; code="$(field "$result" pairingCode)"
trap 'printf "%s" "{\"recipeResult\":$result}" | run destroy >/dev/null || true' EXIT
t2=$(now); p1="$(pair "$code")"; t_pair=$(since "$t2"); t_total=$(since "$t")
log "create ${t_create}s, first pair ${t_pair}s ($p1), create→paired ${t_total}s"

read -r idle_status idle_wait <<<"$(wait_sleep "$name")"
t=$(now); pw="$(pair "$code")"; t_wake=$(since "$t")
log "idle: '$idle_status' after ${idle_wait}s; pair on wake: $pw (${t_wake}s)"
case "$pw" in ok/*) ;; *) log "service logs after a failed wake:"; service_logs "$name" ;; esac

payload="{\"recipeResult\":$result}"
t=$(now); printf '%s' "$payload" | run suspend >/dev/null; t_suspend=$(since "$t")
read -r slept t_sleep <<<"$(wait_sleep "$name")"
log "suspend ${t_suspend}s; Sprite '$slept' after ${t_sleep}s"

t=$(now); resumed="$(printf '%s' "$payload" | run resume)"; t_resume=$(since "$t")
code2="$(field "$resumed" pairingCode)"
t=$(now); p2="$(pair "$code")"; t_pair2=$(since "$t")
same_endpoint=false; [ "$(code_field "$code" endpoint)" = "$(code_field "$code2" endpoint)" ] && same_endpoint=true
log "resume ${t_resume}s; old code pairs: $p2 (${t_pair2}s); same endpoint: $same_endpoint"
case "$p2" in ok/*) ;; *) service_logs "$name" ;; esac

node -e 'console.log(JSON.stringify(Object.fromEntries(process.argv.slice(1).map(a=>a.split("=")))))' \
  sprite="$name" create_s="$t_create" first_pair="$p1" first_pair_s="$t_pair" create_to_paired_s="$t_total" \
  idle_status="$idle_status" idle_wait_s="$idle_wait" pair_on_wake="$pw" pair_on_wake_s="$t_wake" suspend_s="$t_suspend" status_after_suspend="$slept" sleep_wait_s="$t_sleep" resume_s="$t_resume" \
  old_code_after_resume="$p2" pair_after_resume_s="$t_pair2" same_endpoint="$same_endpoint" \
  device_token="$(code_field "$code" deviceToken | cut -c1-12)" paired_device="$(code_field "$code" pairedDeviceId)"
