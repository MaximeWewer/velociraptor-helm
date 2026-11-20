#!/usr/bin/env bash
# Render the chart's PrometheusRule and run the promtool unit tests against it.
# Needs: helm, yq (mikefarah v4 or python-yq), docker (or promtool on PATH).
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT
helm template velociraptor "$ROOT/chart" -n dfir \
  --set prometheusRule.enabled=true --set serviceMonitor.enabled=true \
  --show-only templates/prometheusrule.yaml > "$WORK/pr.yaml"
if yq --version 2>&1 | grep -q mikefarah; then yq '.spec' "$WORK/pr.yaml" > "$WORK/rules.yaml"
else yq -y '.spec' "$WORK/pr.yaml" > "$WORK/rules.yaml"; fi
cp "$ROOT/ci/prometheus/rules-test.yaml" "$WORK/"
chmod -R a+rX "$WORK"
if command -v promtool >/dev/null; then
  (cd "$WORK" && promtool check rules rules.yaml && promtool test rules rules-test.yaml)
else
  docker run --rm --user 0 -v "$WORK:/w:ro" -w /w --entrypoint sh prom/prometheus:latest \
    -c 'promtool check rules rules.yaml && promtool test rules rules-test.yaml'
fi
