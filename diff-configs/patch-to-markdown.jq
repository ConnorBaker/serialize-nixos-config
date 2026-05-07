# Convert a JSON Patch (RFC 6902) document, as produced by `jd -f patch`,
# into a one-row-per-change markdown table.
#
# Invoke with two string arguments naming the columns:
#   jq -r --arg left LEFT_NAME --arg right RIGHT_NAME \
#     -f patch-to-markdown.jq < patch.json
#
# For a changed leaf jd emits a [test, remove, add] triple on the same
# path; for an added subtree just [add]; for a removed subtree just
# [remove]. We group by path, classify, and emit one markdown row per
# path.

# JSON Pointer unescape: ~1 → /, ~0 → ~. Then render as a dotted path
# (matching the `serialize` output format).
def prettyPath(p):
  p
  | split("/") | .[1:]           # drop the empty leading segment
  | map(gsub("~1"; "/") | gsub("~0"; "~"))
  | join(".");

# Truncate a rendered string to `max` chars, collapse newlines.
def trunc(s; max):
  (s | gsub("\n"; "␤") | gsub("\r"; ""))
  | if length > max then (.[:max - 1] + "…") else . end;

# Render a JSON value for a table cell. Objects/arrays are shown as
# compact JSON so the whole subtree fits on one line. Plain strings
# pass through (not quoted); everything else uses tojson. A missing
# value is represented by an empty cell.
def render(v):
  if v == "__MISSING__" then ""
  elif v | type == "string" then v
  else v | tojson
  end;

# Escape markdown table separator.
def mdesc(s): s | gsub("\\|"; "\\|");

# Input is the array of patch ops. Group by path, classify.
#
# jd emits several op patterns per path, depending on what changed:
#   scalar change:      [test, remove, add]
#   list-index replace: [test, add]          (no remove; `test` is old)
#   add-only:           [add]                (new path)
#   remove-only:        [remove]             (deleted path)
#   list-tail adjust:   [test]               (position marker; noise)
#
# We take the left (old) value from `remove` if present, else `test`.
# The right (new) value always comes from `add` when present. Rows with
# both missing are `[test]`-alone and get filtered out — those are jd's
# way of marking list positions and carry no information (the actual
# change is reported at sibling indices).
group_by(.path)
| map(
    . as $ops
    | ($ops | map(select(.op == "remove"))) as $rm
    | ($ops | map(select(.op == "add")))    as $ad
    | ($ops | map(select(.op == "test")))   as $ts
    | (if $rm != [] then $rm[0].value
       elif $ts != [] and $ad != [] then $ts[0].value
       else "__MISSING__" end) as $leftVal
    | (if $ad != [] then $ad[0].value else "__MISSING__" end) as $rightVal
    | {
        path: $ops[0].path,
        leftVal: $leftVal,
        rightVal: $rightVal,
        kind: (
          if $leftVal == "__MISSING__" and $rightVal == "__MISSING__" then "other"
          elif $leftVal == "__MISSING__" then "only-in-\($right)"
          elif $rightVal == "__MISSING__" then "only-in-\($left)"
          else "changed"
          end
        )
      }
  )
| map(select(.kind != "other"))
| "| Path | Kind | " + $left + " | " + $right + " |",
  "|---|---|---|---|",
  (.[] |
    "| " + mdesc(trunc(prettyPath(.path); 100)) +
    " | " + .kind +
    " | " + mdesc(trunc(render(.leftVal); 80)) +
    " | " + mdesc(trunc(render(.rightVal); 80)) +
    " |"
  )
