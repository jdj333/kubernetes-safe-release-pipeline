#!/usr/bin/env bash
source "$(dirname "$0")/common.sh"
preflight
tag="${1:?usage: deploy.sh IMAGE_TAG APP_VERSION [VALUES_FILE]}"
version="${2:?APP_VERSION is required}"
[[ "$tag" =~ ^[a-zA-Z0-9_][a-zA-Z0-9_.-]{0,127}$ ]] || { echo 'Invalid image tag' >&2; exit 2; }
[[ "$version" =~ ^[a-zA-Z0-9][a-zA-Z0-9_.-]{0,49}$ ]] || { echo 'Invalid application version' >&2; exit 2; }
values_args=()
[[ $# -lt 3 ]] || values_args=(-f "$3")
helm lint "$CHART" "${values_args[@]}" --strict
# No arbitrary kubectl context, release, or namespace may be supplied to this lab.
k create namespace "$NAMESPACE" --dry-run=client -o yaml | k apply -f - >/dev/null
# Helm 4 lists all statuses by default (Helm 3's --all was removed).
releases="$(h list --filter "^${RELEASE}$" -o json)"
previous="$(python3 -c 'import json,sys; r=json.load(sys.stdin); assert not r or r[0]["status"]=="deployed", "Recover the existing failed/pending release first"; print(r[0]["revision"] if r else "")' <<< "$releases")"
old_version=""
if [[ -n "$previous" ]]; then
  old_version="$(h get values "$RELEASE" -o json | python3 -c 'import json,sys; print(json.load(sys.stdin)["app"]["version"])')"
  # Establish a genuinely working baseline before treating it as a recovery target.
  bash "$ROOT/scripts/smoke.sh" "$old_version"
fi
printf 'Known-good revision: %s\nKnown-good version: %s\n' "${previous:-none}" "${old_version:-none}" | tee "$ARTIFACTS/baseline.txt"
if ! h upgrade --install "$RELEASE" "$CHART" --reset-values \
    "${values_args[@]}" --set-string "image.tag=$tag" --set-string "app.version=$version" \
    --rollback-on-failure --wait --timeout "${RELEASE_TIMEOUT:-180s}" --history-max 20; then
  collect failed-upgrade
  if [[ -n "$previous" ]]; then
    # Helm performs the automatic rollback; independently verify its result.
    k rollout status "deployment/$RELEASE" --timeout=180s
    bash "$ROOT/scripts/smoke.sh" "$old_version"
    echo 'Upgrade rejected; automatic recovery verified.' >&2
  else
    echo 'First install failed; no prior revision exists. Inspect diagnostics.' >&2
  fi
  exit 1
fi
if k rollout status "deployment/$RELEASE" --timeout=180s && bash "$ROOT/scripts/smoke.sh" "$version"; then
  echo "RELEASE VERIFIED: $version"
else
  collect failed-smoke
  if [[ -n "$previous" ]]; then
    bash "$ROOT/scripts/recover.sh" "$previous"
  else
    echo 'First install failed smoke tests; no recovery target exists. Fix and redeploy or uninstall the lab release.' >&2
  fi
  # A recovered deployment is still a failed candidate release.
  exit 1
fi
