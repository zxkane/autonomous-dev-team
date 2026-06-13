#!/usr/bin/env bash
# measure-event-channels.sh — throwaway validation harness for the run-event
# channel ADR (issue #237, docs/designs/run-event-channel-adr.md).
#
# Measures two real numbers against a GitHub repository, to ground the ADR's
# rate-limit math in observation rather than estimate:
#
#   1. comment-creation propagation lag — the wall-clock delay between a
#      successful `POST .../comments` (HTTP 201) and the moment the new comment
#      becomes visible in a *list* read (`GET .../comments`). This is the
#      eventual-consistency lag that the create-only-comments channel must
#      tolerate if a reconciler reads the comment list to reconstruct state.
#
#   2. check-run creation latency — the wall-clock of a single
#      `POST .../check-runs` (HTTP 201) plus a probe of whether the current
#      token is even *allowed* to create check-runs (the Checks API rejects
#      non-App tokens with 403/422; this is the hard PAT-mode constraint the
#      ADR's auth matrix records).
#
# This script is an APPENDIX artifact, not pipeline code. It creates no durable
# state beyond the comments/check-runs it posts to the target PR/SHA, and it
# is never sourced or invoked by any wrapper. ShellCheck-clean; --dry-run makes
# zero network calls so the unit test can exercise the control flow offline.
#
# Usage:
#   measure-event-channels.sh --repo <owner/name> --pr <N> [--samples K] [--dry-run]
#   measure-event-channels.sh --repo <owner/name> --sha <commit> --check-only [--dry-run]
#
# Auth: uses the `gh` on PATH (honors GH_TOKEN). In this repo's app mode that is
# a GitHub App installation token; in token mode a PAT. The check-run probe's
# result depends on which — that is exactly what the ADR documents.
set -euo pipefail

REPO=""
PR=""
SHA=""
SAMPLES=5
DRY_RUN=false
CHECK_ONLY=false
COMMENT_ONLY=false

usage() {
  sed -n '2,30p' "$0"
  exit "${1:-0}"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo)        REPO="${2:?--repo needs a value}"; shift 2 ;;
    --pr)          PR="${2:?--pr needs a value}"; shift 2 ;;
    --sha)         SHA="${2:?--sha needs a value}"; shift 2 ;;
    --samples)     SAMPLES="${2:?--samples needs a value}"; shift 2 ;;
    --dry-run)     DRY_RUN=true; shift ;;
    --check-only)  CHECK_ONLY=true; shift ;;
    --comment-only) COMMENT_ONLY=true; shift ;;
    -h|--help)     usage 0 ;;
    *) echo "ERROR: unknown argument '$1'" >&2; usage 1 ;;
  esac
done

# --- validation -----------------------------------------------------------
if [[ -z "$REPO" ]]; then
  echo "ERROR: --repo <owner/name> is required" >&2
  usage 1
fi
if ! [[ "$REPO" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]]; then
  echo "ERROR: --repo must look like owner/name, got '$REPO'" >&2
  exit 1
fi
if ! [[ "$SAMPLES" =~ ^[0-9]+$ ]] || [[ "$SAMPLES" -lt 1 ]]; then
  echo "ERROR: --samples must be a positive integer, got '$SAMPLES'" >&2
  exit 1
fi

# now_ms — milliseconds since epoch, portable enough for GNU date.
now_ms() { date +%s%3N; }

# --- comment propagation measurement --------------------------------------
# Posts a uniquely-tagged comment to the PR, then polls the comment LIST until
# the tag appears, recording the create→visible lag. Prints one summary line
# per sample plus an aggregate (min/median/max) over the samples.
measure_comment_propagation() {
  # --dry-run is prerequisite-free (it makes zero network calls and needs no
  # --pr); the --pr requirement only binds the real measurement path.
  if ! $DRY_RUN && [[ -z "$PR" ]]; then
    echo "ERROR: comment measurement requires --pr <N>" >&2
    exit 1
  fi
  echo "## comment-creation propagation lag (samples=$SAMPLES, repo=$REPO, pr=${PR:-<dry-run>})"
  local lags=()
  local i tag t_post t_seen lag found
  for i in $(seq 1 "$SAMPLES"); do
    tag="adr237-probe-${i}-$(now_ms)"
    if $DRY_RUN; then
      echo "[dry-run] would POST comment tagged '$tag' then poll list until visible"
      continue
    fi
    t_post=$(now_ms)
    gh api "repos/$REPO/issues/$PR/comments" -f body="event-channel ADR probe — $tag (safe to delete)" \
      --jq '.id' >/dev/null
    # Poll the list (NOT a direct GET by id — we measure list propagation,
    # which is the eventual-consistency surface a reconciler would read).
    found=false
    while true; do
      if gh api "repos/$REPO/issues/$PR/comments?per_page=100" --jq '.[].body' \
           2>/dev/null | grep -qF "$tag"; then
        t_seen=$(now_ms)
        found=true
        break
      fi
      # Bail after ~30s to avoid an unbounded loop on API trouble.
      if (( $(now_ms) - t_post > 30000 )); then
        echo "WARN: sample $i did not propagate within 30s" >&2
        break
      fi
      sleep 0.25
    done
    if $found; then
      lag=$(( t_seen - t_post ))
      lags+=("$lag")
      printf 'sample %d: %d ms\n' "$i" "$lag"
    fi
  done
  if [[ ${#lags[@]} -gt 0 ]] && ! $DRY_RUN; then
    printf '%s\n' "${lags[@]}" | sort -n | awk '
      { a[NR]=$1; sum+=$1 }
      END {
        n=NR;
        med = (n%2) ? a[(n+1)/2] : (a[n/2]+a[n/2+1])/2;
        printf "aggregate: n=%d min=%d ms median=%.0f ms max=%d ms mean=%.0f ms\n",
               n, a[1], med, a[n], sum/n;
      }'
  fi
}

# --- check-run latency + permission probe ---------------------------------
# Attempts a single check-run creation against --sha. Records latency on
# success; on 403/422 records that the token is NOT permitted to create
# check-runs (the PAT-mode / missing-checks:write case).
measure_check_run() {
  local sha="${SHA:-}"
  if [[ -z "$sha" && -n "$PR" ]] && ! $DRY_RUN; then
    sha=$(gh api "repos/$REPO/pulls/$PR" --jq '.head.sha' 2>/dev/null || true)
  fi
  echo "## check-run creation latency + permission probe (repo=$REPO, sha=${sha:-<none>})"
  if $DRY_RUN; then
    echo "[dry-run] would POST repos/$REPO/check-runs name=adr237-probe head_sha=<sha> status=completed"
    return 0
  fi
  if [[ -z "$sha" ]]; then
    echo "ERROR: check-run measurement requires --sha <commit> or --pr <N>" >&2
    exit 1
  fi
  local t0 t1 rc out
  t0=$(now_ms)
  set +e
  out=$(gh api "repos/$REPO/check-runs" -X POST \
        -f name="adr237-probe" -f head_sha="$sha" \
        -f status="completed" -f conclusion="neutral" 2>&1)
  rc=$?
  set -e
  t1=$(now_ms)
  if [[ $rc -eq 0 ]]; then
    printf 'check-run created in %d ms (token IS permitted: App with checks:write)\n' "$(( t1 - t0 ))"
  else
    echo "check-run creation REJECTED (token NOT permitted): $out"
    echo "→ this is the hard PAT-mode / missing-checks:write constraint the ADR records."
  fi
}

# --- main -----------------------------------------------------------------
if $CHECK_ONLY; then
  measure_check_run
elif $COMMENT_ONLY; then
  measure_comment_propagation
else
  measure_comment_propagation
  echo
  measure_check_run
fi
