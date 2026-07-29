#!/bin/bash
# Four-way version sync check for the codebase-scribe plugin: both plugin.json
# manifests and both marketplace.json entries for "codebase-scribe" must declare
# the identical version string. Exits 0 only when all four manifests are present,
# parseable, and agree; exits non-zero otherwise, always printing a cause
# (missing, unreadable, or mismatched).
#
# The manifests are parsed with Python's `json` module — a real JSON parser, so
# layout is irrelevant: pretty-printed or compact, nested sub-objects inline or
# in block form, braces sharing lines with content, keys in any order. This
# replaces an earlier grep/sed extractor that bounded entries by line shape and
# was wrong three times over (unbounded forward scan, then brace-alone-line
# bounding, then inline nested objects); line-oriented tools cannot bound a JSON
# value, and no further guard on them would have fixed that. Python is required:
# if no interpreter is found, or a file does not parse, or the codebase-scribe
# entry (or its version key) is absent, the script exits non-zero with the
# reason — it never falls back to guessing and never silently succeeds.
#
# Layout assumption: this script assumes the monorepo layout (a plugin.json
# under plugins/codebase-scribe/, plus root marketplace.json files three
# directories up). Run against a standalone plugin install without the
# marketplace root, the two marketplace.json checks will report MISSING — that
# is expected for this maintainer tool, not a bug.
set -u

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/../../.." && pwd)"

plugin_json="$repo_root/plugins/codebase-scribe/.claude-plugin/plugin.json"
cursor_plugin_json="$repo_root/plugins/codebase-scribe/.cursor-plugin/plugin.json"
claude_marketplace="$repo_root/.claude-plugin/marketplace.json"
cursor_marketplace="$repo_root/.cursor-plugin/marketplace.json"

# A version must be three dot-separated numeric fields end to end, with an
# optional SemVer pre-release and/or build-metadata suffix — the parser returns
# whatever string the manifest holds, so this catches a value that is
# well-formed JSON but not a version (e.g. "" or "latest"). The expression is
# anchored at BOTH ends on purpose: with only a leading anchor, any string
# merely starting with three numeric fields passed, so all four manifests could
# agree on "1.3.0garbage" and the check would report a valid release. The
# suffixes spell out "non-empty identifier, then dot-separated more of the same"
# rather than putting "." inside one character class: the class form made the
# dot an ordinary suffix character, so "1.3.0-." and "1.3.0+." — a suffix marker
# and no identifier at all — were accepted as versions.
version_shape='^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z-]+(\.[0-9A-Za-z-]+)*)?(\+[0-9A-Za-z-]+(\.[0-9A-Za-z-]+)*)?$'

python_bin=""
for cand in python3 python py; do
  command -v "$cand" >/dev/null 2>&1 || continue
  if [ "$cand" = "py" ]; then
    if "$cand" -3 -c 'import json' >/dev/null 2>&1; then python_bin="$cand -3"; break; fi
  else
    if "$cand" -c 'import json' >/dev/null 2>&1; then python_bin="$cand"; break; fi
  fi
done
if [ -z "$python_bin" ]; then
  echo "FAIL: no working Python interpreter found (tried python3, python, py -3)"
  echo "      check-sync.sh parses the manifests with Python's json module and cannot run without one."
  exit 1
fi

# Reads one version string from a manifest and prints it on stdout. Prints the
# reason on stderr and exits non-zero when the file does not parse, the
# codebase-scribe entry is absent or duplicated, or the version key is missing
# or not a string. $1 = "plugin" | "marketplace", $2 = path.
read_version='
import json, sys

mode, path = sys.argv[1], sys.argv[2]

def fail(msg):
    sys.stderr.write(msg + "\n")
    raise SystemExit(1)

# json.load keeps the LAST of a set of duplicate keys and says nothing, so a
# manifest carrying two "version" fields reads as unambiguous here while another
# JSON consumer may take the first or reject the file outright. This script
# already refuses two marketplace entries named codebase-scribe as ambiguous;
# duplicate keys are the same ambiguity one level down, so they are refused too,
# at every object level rather than only the top.
def reject_duplicate_keys(pairs):
    seen = set()
    for key, _ in pairs:
        if key in seen:
            fail("duplicate \"%s\" key in a JSON object - the manifest is ambiguous" % key)
        seen.add(key)
    return dict(pairs)

try:
    with open(path, encoding="utf-8") as handle:
        data = json.load(handle, object_pairs_hook=reject_duplicate_keys)
except ValueError as exc:
    fail("not valid JSON (%s)" % exc)
except OSError as exc:
    fail("could not be read (%s)" % exc)

if not isinstance(data, dict):
    fail("top-level JSON value is %s, expected an object" % type(data).__name__)

if mode == "plugin":
    entry = data
else:
    plugins = data.get("plugins")
    if not isinstance(plugins, list):
        fail("no top-level \"plugins\" array")
    matches = [p for p in plugins if isinstance(p, dict) and p.get("name") == "codebase-scribe"]
    if not matches:
        fail("no plugins[] entry named \"codebase-scribe\"")
    if len(matches) > 1:
        fail("%d plugins[] entries named \"codebase-scribe\" - the manifest is ambiguous" % len(matches))
    entry = matches[0]

version = entry.get("version")
if not isinstance(version, str):
    fail("\"version\" is missing or not a string (got %r)" % (version,))
print(version)
'

version_from_plugin_json() {
  $python_bin -c "$read_version" plugin "$1"
}

version_from_marketplace() {
  $python_bin -c "$read_version" marketplace "$1"
}

status=0
incomplete=0
# Initialized to empty rather than merely declared: under `set -u`, `declare -a
# v` leaves v unbound, so "${#versions[@]}" below aborts with "unbound variable"
# on the all-four-unreadable path — which the anchored version_shape above makes
# reachable for the first time.
declare -a labels=() versions=()

check() {
  local label="$1" file="$2" extractor="$3" value rc
  if [ ! -f "$file" ]; then
    echo "MISSING: $label ($file)"
    status=1
    incomplete=1
    return
  fi
  # stderr is folded into the value so the parser's own reason can be reported.
  value="$("$extractor" "$file" 2>&1)"
  rc=$?
  if [ $rc -ne 0 ] || [ -z "$value" ] || ! [[ "$value" =~ $version_shape ]]; then
    echo "UNREADABLE: could not extract a version from $label ($file): ${value:-no output}"
    status=1
    incomplete=1
    return
  fi
  labels+=("$label")
  versions+=("$value")
  echo "$label: $value"
}

check "plugin.json (Claude Code)" "$plugin_json" version_from_plugin_json
check "plugin.json (Cursor)" "$cursor_plugin_json" version_from_plugin_json
check "marketplace.json (Claude Code)" "$claude_marketplace" version_from_marketplace
check "marketplace.json (Cursor)" "$cursor_marketplace" version_from_marketplace

# Compare whatever versions WERE successfully extracted, regardless of whether
# another manifest was missing/unreadable — a missing file should not suppress
# learning whether the rest agree.
mismatch=0
if [ "${#versions[@]}" -gt 0 ]; then
  first="${versions[0]}"
  for i in "${!versions[@]}"; do
    if [ "${versions[$i]}" != "$first" ]; then
      echo "MISMATCH: ${labels[$i]}=${versions[$i]} != ${labels[0]}=$first"
      mismatch=1
      status=1
    fi
  done
fi

if [ "$status" -eq 0 ]; then
  echo "OK: all four manifests agree on version $first"
elif [ "$incomplete" -eq 1 ] && [ "$mismatch" -eq 1 ]; then
  echo "FAIL: one or more manifests could not be read, and the ones that were read do not agree"
elif [ "$incomplete" -eq 1 ]; then
  echo "FAIL: one or more manifests could not be read (see MISSING/UNREADABLE above)"
else
  echo "FAIL: version mismatch across codebase-scribe manifests"
fi

exit "$status"
