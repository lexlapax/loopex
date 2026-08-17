#!/usr/bin/env bash
# Reads one string field from a client tool-call document on standard input.
#
# CONCEPT
#
# Client hooks receive a tool call as a JSON document and act on one field of it.
# They need that field without a dependency outside the enduring development
# baseline, and without paying a language runtime's startup cost on every tool
# call: a guard that runs before every file read must be effectively free.
#
# Usage: json-field.sh <object> <field> [<field> ...]
#
# The object is the containing member -- `tool_input` for every current hook --
# and the fields are tried in order. The first field present with a string value
# is printed; nothing is printed when none is.
#
# TECHNICAL DEPTH
#
# Path aware, not a text search. JSON string tokens are enumerated left to right,
# and the container depth between them is counted, so a token is correctly
# classified as a key or a value and a field is only read from the object the
# caller named. A key that merely appears inside some other string, or inside a
# different object that happens to use the same member name, is not matched.
#
# That matters because the alternative -- searching for the field name anywhere --
# would read a path out of an unrelated payload and make a guard fire on the wrong
# input. The scan is linear in the document, and only the requested fields are
# unescaped, so a tool call carrying a large file body costs one pass rather than
# one pass per character of it.
#
# Escapes are resolved except `\uXXXX`, which is left in its escaped form rather
# than approximated: a guard comparing paths is better served by a visibly
# unresolved escape than by a plausible wrong character.
set -euo pipefail

if [ "$#" -lt 2 ]; then
  echo "usage: json-field.sh <object> <field> [<field> ...]" >&2
  exit 64
fi

object="$1"
shift
fields="$1"
shift
for field in "$@"; do
  fields="$fields,$field"
done

exec awk -v object="$object" -v fields="$fields" '
function depth_delta(text,   copy, opened, closed) {
  copy = text
  opened = gsub(/[{[]/, "", copy)
  copy = text
  closed = gsub(/[}\]]/, "", copy)
  return opened - closed
}

function unescape(text,   out, index_, char_, next_) {
  out = ""
  index_ = 1
  while (index_ <= length(text)) {
    char_ = substr(text, index_, 1)
    if (char_ != "\\") {
      out = out char_
      index_ = index_ + 1
      continue
    }
    next_ = substr(text, index_ + 1, 1)
    if (next_ == "n") { out = out "\n" }
    else if (next_ == "t") { out = out "\t" }
    else if (next_ == "r") { out = out "\r" }
    else if (next_ == "b") { out = out "\b" }
    else if (next_ == "f") { out = out "\f" }
    else if (next_ == "u") { out = out "\\u" }
    else { out = out next_ }
    index_ = index_ + 2
  }
  return out
}

BEGIN {
  count = split(fields, wanted, ",")
  for (i = 1; i <= count; i++) {
    requested[wanted[i]] = 1
  }
}

{ buffer = buffer $0 "\n" }

END {
  position = 1
  depth = 0
  while (1) {
    tail = substr(buffer, position)
    if (match(tail, /"([^"\\]|\\.)*"/) == 0) {
      break
    }
    depth = depth + depth_delta(substr(tail, 1, RSTART - 1))
    token = substr(tail, RSTART + 1, RLENGTH - 2)
    position = position + RSTART + RLENGTH - 1
    following = substr(buffer, position)
    if (match(following, /^[ \t\r\n]*:/) != 0) {
      key[depth] = token
      continue
    }
    if (depth == 2 && key[1] == object && (key[2] in requested) && !(key[2] in found)) {
      found[key[2]] = unescape(token)
    }
  }
  for (i = 1; i <= count; i++) {
    if (wanted[i] in found) {
      printf "%s", found[wanted[i]]
      exit 0
    }
  }
}
'
