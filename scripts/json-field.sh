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
# input. The scan is linear in the document, and at most one field is decoded, so a
# tool call carrying a large file body costs one pass rather than one pass per
# character of it.
#
# Escapes are resolved, including `\uXXXX` and surrogate pairs. They were once
# left escaped, on the reasoning that a visibly unresolved escape beats a plausible
# wrong character. That was wrong in the direction that matters: a hook matching on
# a command never saw `\u0024HOME` as `$HOME`, so an ordinary JSON spelling of a
# protected path walked past the guard. Keys are decoded too, and a duplicate key
# takes the last occurrence, both matching a real parser.
#
# Decoding happens once, on the value actually returned, and writes decoded pieces
# straight out rather than building a string. Decoding every candidate and
# accumulating by concatenation was quadratic: a few large escaped values pushed a
# hook past its configured timeout, and a timed-out hook exits 124, which does not
# block.
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

# The program is a separate file so its apostrophes are ordinary characters and
# `awk -f` can parse it directly; see json-field.awk.
here="$(CDPATH= cd -P -- "$(dirname -- "$0")" && pwd)"
program="$here/json-field.awk"
if [ ! -r "$program" ]; then
  echo "json-field.sh: cannot read $program" >&2
  exit 66
fi

# The awk program constructs UTF-8 one byte at a time. GNU awk in a multibyte
# locale re-encodes each numeric byte passed through `%c`, producing mojibake;
# byte locale keeps GNU and BSD awk on the same representation. Literal UTF-8
# input remains byte-identical because the scanner copies non-escape runs.
export LC_ALL=C

exec awk -v object="$object" -v fields="$fields" -f "$program"
