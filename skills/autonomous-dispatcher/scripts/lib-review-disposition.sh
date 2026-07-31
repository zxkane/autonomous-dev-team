#!/bin/bash
# Strict pre-fan-out review-disposition evidence (INV-147).

# The dispatcher and focused tests source this contract directly. Resolve the
# issue-provider seam here so latest_review_routing_evidence is independently
# callable without relying on caller source order.
if ! declare -F itp_list_comments >/dev/null 2>&1; then
  _lrd_self="${BASH_SOURCE[0]:-$0}"
  _lrd_dir="$(cd "$(dirname "$(readlink -f "$_lrd_self")")" && pwd 2>/dev/null)" || _lrd_dir=""
  if [[ -n "$_lrd_dir" && -r "${_lrd_dir}/lib-issue-provider.sh" ]]; then
    # shellcheck source=lib-issue-provider.sh
    source "${_lrd_dir}/lib-issue-provider.sh"
  fi
  unset _lrd_self _lrd_dir
fi

_review_normalize_full_head() {
  local head="${1:-}"
  [[ "$head" =~ ^[0-9a-fA-F]{40}$ ]] || return 1
  printf '%s' "${head,,}"
}

_review_disposition_marker() {
  local issue="${1:-}" head result="${3:-}"
  [[ "$issue" =~ ^[1-9][0-9]*$ ]] || return 1
  head="$(_review_normalize_full_head "${2:-}")" || return 1
  case "$result" in
    conflict-rebase|mergeable-unknown) ;;
    *) return 1 ;;
  esac
  printf '<!-- review-disposition: issue=%s head=%s phase=pre-fanout result=%s -->' \
    "$issue" "$head" "$result"
}

_review_auto_merge_conflict_marker() {
  local issue="${1:-}" head
  [[ "$issue" =~ ^[1-9][0-9]*$ ]] || return 1
  head="$(_review_normalize_full_head "${2:-}")" || return 1
  printf '<!-- auto-merge-conflict: issue=%s head=%s result=conflict-rebase -->' \
    "$issue" "$head"
}

_review_auto_merge_failure_marker() {
  local issue="${1:-}" head
  [[ "$issue" =~ ^[1-9][0-9]*$ ]] || return 1
  head="$(_review_normalize_full_head "${2:-}")" || return 1
  printf '<!-- auto-merge-failure: issue=%s head=%s -->' "$issue" "$head"
}

# _review_strict_self_comment_timeline <normalized-comments-json>
#
# Emits the one ordered comment timeline shared by routing-candidate selection
# and required-verdict freshness. Malformed rows cannot occupy an index in one
# consumer while being absent from the other.
_review_strict_self_comment_timeline() {
  jq -c '
    [
      .[]
      | select(.authorKind == "self")
      | select(.body | type == "string")
      | select((.createdAt | type) == "string")
    ]
    | sort_by(.createdAt, .id)
  ' 2>/dev/null <<<"${1:-[]}"
}

# _review_routing_candidates_from_comments <normalized-comments-json> <issue>
#
# Emits every valid strict-self Reviewed HEAD or pre-fan-out disposition,
# ordered by provider timestamp/id and annotated with its zero-based order.
_review_routing_candidates_from_comments() {
  local comments="${1:-[]}" issue="${2:-}" timeline
  [[ "$issue" =~ ^[1-9][0-9]*$ ]] || return 1
  timeline="$(_review_strict_self_comment_timeline "$comments")" || return 1

  jq -c --arg issue "$issue" '
    def disposition:
      ([
        .body
        | capture("^<!-- review-disposition: issue=(?<issue>[1-9][0-9]*) head=(?<head>[0-9a-f]{40}) phase=pre-fanout result=(?<result>conflict-rebase|mergeable-unknown) -->\\z")
      ] | first // null);
    def reviewed:
      ([
        .body
        | capture("Reviewed HEAD: `(?<head>[0-9a-fA-F]{7,40})`")
      ] | first // null);
    to_entries
    | [
      .[]
      | .key as $order
      | .value as $comment
      | ($comment | disposition) as $d
      | ($comment | reviewed) as $r
      | if $d != null and $d.issue == $issue then
          {
            order: $order,
            createdAt: $comment.createdAt,
            id: ($comment.id // 0),
            kind: "disposition",
            head: $d.head,
            result: $d.result
          }
        elif $r != null then
          {
            order: $order,
            createdAt: $comment.createdAt,
            id: ($comment.id // 0),
            kind: "reviewed-head",
            head: ($r.head | ascii_downcase),
            result: ""
          }
        else empty end
    ]
  ' 2>/dev/null <<<"$timeline"
}

# _review_routing_evidence_from_comments <normalized-comments-json> <issue> [head]
#
# Emits the newest valid candidate, optionally restricted to one normalized
# full HEAD, as:
#   {"kind":"reviewed-head|disposition","head":"...","result":"..."}
_review_routing_evidence_from_comments() {
  local comments="${1:-[]}" issue="${2:-}" head="${3:-}" candidates
  if [[ -n "$head" ]]; then
    head="$(_review_normalize_full_head "$head")" || return 1
  fi
  candidates="$(_review_routing_candidates_from_comments "$comments" "$issue")" \
    || return 1

  jq -c --arg head "$head" '
    [.[] | select($head == "" or .head == $head)]
    | last
    | if . == null then empty
      else {kind, head, result}
      end
  ' 2>/dev/null <<<"$candidates"
}

# _review_routing_evidence_boundary_from_comments <comments> <issue>
#
# Emits the order of the newest valid routing candidate, or -1 when none
# exists. Required verdict writes use this as a freshness boundary without
# duplicating the canonical tuple marker.
_review_routing_evidence_boundary_from_comments() {
  local candidates
  candidates="$(_review_routing_candidates_from_comments "${1:-[]}" "${2:-}")" \
    || return 1
  jq -r 'last | .order // -1' 2>/dev/null <<<"$candidates"
}

# latest_review_routing_evidence <issue> <head-out> <kind-out> <result-out> [head]
latest_review_routing_evidence() {
  local issue="$1" head_var="$2" kind_var="$3" result_var="$4"
  local current_head="${5:-}"
  local _lrr_comments evidence
  local _lrr_head="" _lrr_kind="" _lrr_result=""

  if ! _lrr_comments=$(ITP_REQUIRE_SELF_AUTHOR=1 \
      itp_list_comments "$issue" 2>/dev/null); then
    return 1
  fi

  evidence="$(_review_routing_evidence_from_comments \
    "$_lrr_comments" "$issue" "$current_head")" || return 1
  if [[ -n "$evidence" ]]; then
    _lrr_head=$(jq -r '.head // empty' <<<"$evidence")
    _lrr_kind=$(jq -r '.kind // empty' <<<"$evidence")
    _lrr_result=$(jq -r '.result // empty' <<<"$evidence")
  fi

  printf -v "$head_var" '%s' "$_lrr_head"
  printf -v "$kind_var" '%s' "$_lrr_kind"
  printf -v "$result_var" '%s' "$_lrr_result"
}

# _review_pr_recovery_comment_from_comments <pr-comments-object> <issue> <head> <mode>
#
# Emits the newest valid Auto-merge failed body. Canonical hidden markers must
# be the exact final line, binding the body to the current issue and full HEAD.
# `mode=conflict` accepts only the conflict-rebase marker; `mode=any` also
# accepts the generic merge-failure marker and marker-free legacy producers.
# A legacy body containing any case-insensitive marker lookalike is rejected so
# malformed, abbreviated, quoted, and wrong-issue markers cannot fall through.
_review_pr_recovery_comment_from_comments() {
  local comments="${1:-}" issue="${2:-}" head mode="${4:-any}"
  local conflict_marker failure_marker
  [[ "$issue" =~ ^[1-9][0-9]*$ ]] || return 1
  head="$(_review_normalize_full_head "${3:-}")" || return 1
  case "$mode" in
    any|conflict) ;;
    *) return 1 ;;
  esac
  conflict_marker="$(_review_auto_merge_conflict_marker "$issue" "$head")" \
    || return 1
  failure_marker="$(_review_auto_merge_failure_marker "$issue" "$head")" \
    || return 1

  jq -e 'type == "object" and (.comments | type == "array")' \
    >/dev/null 2>&1 <<<"$comments" || return 1
  jq -r \
    --arg conflict "$conflict_marker" \
    --arg failure "$failure_marker" \
    --arg mode "$mode" '
    [
      .comments[]
      | select(.body | type == "string")
      | select(.body | startswith("Auto-merge failed:"))
      | . as $comment
      | (.body | split("\n") | last) as $last
      | select(
          if $mode == "conflict" then
            $last == $conflict
          else
            $last == $conflict
            or $last == $failure
            or (
              (.body | ascii_downcase) as $lower
              | ($lower | contains("auto-merge-conflict") | not)
                and ($lower | contains("auto-merge-failure") | not)
            )
          end
        )
      | {
          body: .body,
          createdAt: (.createdAt // ""),
          id: (.id // 0)
        }
    ]
    | sort_by(.createdAt, .id)
    | last
    | .body // empty
  ' 2>/dev/null <<<"$comments"
}
