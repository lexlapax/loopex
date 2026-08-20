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
  # Nothing to decode is the overwhelmingly common case, and the loop below costs a
  # string copy per character. Returning early keeps ordinary input linear.
  if (index(text, "\\") == 0) { return text }
  index_ = 1
  while (index_ <= length(text)) {
    char_ = substr(text, index_, 1)
    if (char_ != "\\") {
      out = out char_
      index_ = index_ + 1
      continue
    }
    next_ = substr(text, index_ + 1, 1)
    if (next_ == "u") {
      # A \uXXXX escape is decoded, not passed through. Leaving it escaped was a
      # real detection loss: a hook matching on a command never saw \u0024HOME as
      # $HOME, so an ordinary JSON spelling of a protected path walked past the
      # filesystem guard. That is a representation the client may legitimately
      # send, not source obfuscation a reviewer could be asked to judge.
      code_ = hexval(substr(text, index_ + 2, 4))
      if (code_ < 0) {
        out = out "\\u"
        index_ = index_ + 2
        continue
      }
      # A high surrogate followed by a low surrogate is one code point.
      if (code_ >= 55296 && code_ <= 56319 && substr(text, index_ + 6, 2) == "\\u") {
        low_ = hexval(substr(text, index_ + 8, 4))
        if (low_ >= 56320 && low_ <= 57343) {
          out = out utf8(65536 + (code_ - 55296) * 1024 + (low_ - 56320))
          index_ = index_ + 12
          continue
        }
      }
      # A lone surrogate is not a code point, and encoding one yields invalid UTF-8
      # that a real parser rejects outright. It becomes U+FFFD so the field stays
      # well formed and the surrounding text is still matchable, instead of
      # emitting bytes no consumer can decode.
      if (code_ >= 55296 && code_ <= 57343) {
        out = out utf8(65533)
        index_ = index_ + 6
        continue
      }
      out = out utf8(code_)
      index_ = index_ + 6
      continue
    }
    if (next_ == "n") { out = out "\n" }
    else if (next_ == "t") { out = out "\t" }
    else if (next_ == "r") { out = out "\r" }
    else if (next_ == "b") { out = out "\b" }
    else if (next_ == "f") { out = out "\f" }
    else { out = out next_ }
    index_ = index_ + 2
  }
  return out
}

# Concept: four hex digits to a number, or -1 when they are not hex.
function hexval(digits_,   i_, char_, value_, total_) {
  if (length(digits_) != 4) { return -1 }
  total_ = 0
  for (i_ = 1; i_ <= 4; i_++) {
    char_ = tolower(substr(digits_, i_, 1))
    value_ = index("0123456789abcdef", char_) - 1
    if (value_ < 0) { return -1 }
    total_ = total_ * 16 + value_
  }
  return total_
}

# Concept: a code point as UTF-8 bytes.
# Technical depth: encoded by arithmetic rather than by sprintf("%c") above the
# ASCII range, because awk implementations disagree about what %c does with a
# value over 127. A NUL becomes U+FFFD rather than being dropped: dropping it
# silently shortened the field, which no real parser does and which hid that the
# input contained one at all. Emitting a real NUL is not an option either, since
# it truncates the field for every downstream consumer.
function utf8(code_) {
  if (code_ < 0) { return "" }
  if (code_ == 0) { return sprintf("%c%c%c", 239, 191, 189) }
  if (code_ < 128) { return sprintf("%c", code_) }
  if (code_ < 2048) {
    return sprintf("%c%c", 192 + int(code_ / 64), 128 + (code_ % 64))
  }
  if (code_ < 65536) {
    return sprintf("%c%c%c", 224 + int(code_ / 4096), \
      128 + int((code_ % 4096) / 64), 128 + (code_ % 64))
  }
  return sprintf("%c%c%c%c", 240 + int(code_ / 262144), \
    128 + int((code_ % 262144) / 4096), 128 + int((code_ % 4096) / 64), 128 + (code_ % 64))
}

# Concept: write the decoded bytes of a JSON string, without ever building the
# whole decoded string.
# Technical depth: awk string concatenation copies, so accumulating a result one
# piece at a time is quadratic. A 3.6 MB escaped value took 22 seconds, past the
# configured hook timeout -- and a timed-out hook exits 124, which does not
# block. Splitting on the escape character gives whole literal runs that are
# printed once each, so the work is linear in the input and the pieces are never
# joined. Correctness is unchanged: the same escapes are recognised, and a
# surrogate pair spanning two escapes is still combined.
function emit_unescaped(text,   n, parts, i, seg, lead, rest, code_, low_) {
  if (index(text, "\\") == 0) { printf "%s", text; return }
  n = split(text, parts, "\\")
  printf "%s", parts[1]
  i = 2
  while (i <= n) {
    seg = parts[i]
    if (seg == "") {
      # Two backslashes: one literal backslash, and the next piece is literal text.
      printf "%s", "\\"
      i++
      if (i <= n) { printf "%s", parts[i]; i++ }
      continue
    }
    lead = substr(seg, 1, 1)
    rest = substr(seg, 2)
    if (lead == "u") {
      code_ = hexval(substr(rest, 1, 4))
      rest = substr(rest, 5)
      if (code_ < 0) {
        printf "%s", "\\u" rest
        i++
        continue
      }
      if (code_ >= 55296 && code_ <= 56319 && i < n && substr(parts[i + 1], 1, 1) == "u") {
        low_ = hexval(substr(parts[i + 1], 2, 4))
        if (low_ >= 56320 && low_ <= 57343) {
          printf "%s", utf8(65536 + (code_ - 55296) * 1024 + (low_ - 56320))
          printf "%s", substr(parts[i + 1], 6)
          i = i + 2
          continue
        }
      }
      if (code_ >= 55296 && code_ <= 57343) { printf "%s", utf8(65533) }
      else { printf "%s", utf8(code_) }
      printf "%s", rest
      i++
      continue
    }
    if (lead == "n") { printf "%s", "\n" }
    else if (lead == "t") { printf "%s", "\t" }
    else if (lead == "r") { printf "%s", "\r" }
    else if (lead == "b") { printf "%s", "\b" }
    else if (lead == "f") { printf "%s", "\f" }
    else { printf "%s", lead }
    printf "%s", rest
    i++
  }
}

# Concept: a key, decoded only when it could possibly be one we want.
# Technical depth: keys must be decoded, because an escaped spelling of a field
# name is an ordinary JSON encoding and a guard that missed it was bypassed. But
# decoding is the quadratic path, and a document may carry an enormous key, which
# made the same timeout bypass available through the key instead of the value.
#
# The bound is exact rather than a guess. The shortest escape that yields one
# character is \uXXXX, six bytes, so a decoded key is never shorter than a sixth
# of its raw length. A raw key longer than six times the longest name we are
# looking for therefore cannot decode to one of them, and is rejected without
# decoding anything.
function decoded_key(token) {
  if (index(token, "\\") == 0) { return token }
  if (length(token) > 6 * longest_wanted) { return token }
  return unescape(token)
}

BEGIN {
  count = split(fields, wanted, ",")
  longest_wanted = length(object)
  for (i = 1; i <= count; i++) {
    requested[wanted[i]] = 1
    if (length(wanted[i]) > longest_wanted) { longest_wanted = length(wanted[i]) }
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
      # Keys are decoded like values. Storing them raw meant an ordinary escaped
      # spelling -- "comm\u0061nd" -- did not match the requested name, so a hook
      # read nothing and passed a command it would otherwise have blocked.
      key[depth] = decoded_key(token)
      continue
    }
    if (depth == 2 && key[1] == object && (key[2] in requested)) {
      # The RAW token is stored and decoded only if it is the one returned.
      # Decoding every candidate as it was scanned made a document with several
      # large escaped values quadratic: a 1 MB input took seconds, and past the
      # hook timeout the client sees exit 124, which does not block. Decoding at
      # most one value removes the amplification.
      #
      # A duplicate key takes the LAST occurrence, which is what a real parser
      # does. Keeping the first let a document put a decoy ahead of the real value.
      found[key[2]] = token
    }
  }
  for (i = 1; i <= count; i++) {
    if (wanted[i] in found) {
      emit_unescaped(found[wanted[i]])
      exit 0
    }
  }
}
'
