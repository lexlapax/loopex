# Reads one string field from a client tool-call document on standard input.
#
# Concept: the program the wrapper runs. It lives in its own file so that its
# text is program text, not a shell word.
#
# Technical depth: this was a single-quoted argument inside json-field.sh, which
# made every apostrophe in it a quote terminator and hid the whole program from
# `bash -n`. That took the tooling down twice -- once on a `continue` used outside
# a loop, once on an apostrophe in a comment -- and in both cases the shell
# reported the wrapper as valid. As a separate file it is ordinary awk: `awk -f`
# parses it, apostrophes are just characters, and a syntax error is found by
# checking this file rather than by a guard failing closed on every tool call.

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

# Concept: one string from its pieces, joined once.
# Technical depth: joining once costs the length of the result; joining as pieces
# arrive costs it again for every piece. The piece count is bounded above, so this
# is bounded work rather than input-driven work.
function join_pieces(n,   i_, out_) {
  if (n <= 1) { return pieces[1] }
  out_ = pieces[1]
  for (i_ = 2; i_ <= n; i_++) { out_ = out_ "\"" pieces[i_] }
  return out_
}

# Concept: did this record end with an escaped quote?
# Technical depth: with the quote as the record separator, a trailing odd number of
# backslashes means the separator that followed was escaped and the string has not
# actually closed. Counted from the end, so the cost is the length of the backslash
# run rather than the length of the record.
function odd_backslashes(text,   i_, run_) {
  run_ = 0
  i_ = length(text)
  while (i_ >= 1 && substr(text, i_, 1) == "\\") {
    run_++
    i_--
  }
  return run_ % 2
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
  RS = "\""
  inside = 0
  depth = 0
  pending = 0
  count = split(fields, wanted, ",")
  longest_wanted = length(object)
  for (i = 1; i <= count; i++) {
    requested[wanted[i]] = 1
    if (length(wanted[i]) > longest_wanted) { longest_wanted = length(wanted[i]) }
  }
}

# Concept: one forward pass that never copies the remaining document.
# Technical depth: the previous scanner took substr(buffer, position) for every
# token, so each token copied the rest of the input and a document with many
# fields was quadratic -- 16,000 short fields took over ten seconds, and a hook
# past its timeout exits 124, which does not block. Three superlinear paths were
# found here in three reviews (a large value, a large key, many fields), each
# fixed where it was demonstrated. This removes the class instead: awk splits the
# input on the quote character itself, so the work is linear in the input by
# construction and no position arithmetic over the whole buffer exists to be slow.
#
# Records alternate outside/inside string. A record ending in an odd number of
# backslashes means the quote that followed was escaped, so the string continues.
{
  if (inside) {
    # Pieces are counted and measured, not concatenated as they arrive. Splitting
    # on the quote made the SCAN linear, but every escaped quote still extended a
    # growing string, so a value with half a million of them was quadratic again --
    # about thirty seconds, past the hook timeout, where exit 124 does not block.
    #
    # A string that exceeds either bound is marked oversize and its pieces are
    # dropped. That is safe because of what the bounds are for: a key that long
    # cannot be one of the short names being looked for, and a value that long is
    # not a command or a path. If an oversize string turns out to BE a requested
    # value, the reader fails closed rather than returning a truncated one.
    piece_count++
    piece_bytes += length($0) + 1
    if (piece_count > 4096 || piece_bytes > 65536) {
      oversize = 1
    } else {
      pieces[piece_count] = $0
    }
    if (odd_backslashes($0)) {
      next
    }
    inside = 0
    pending = 1
    pending_oversize = oversize
    pending_token = oversize ? "" : join_pieces(piece_count)
  } else {
    if (pending) {
      # A colon after the closed string makes it a key; anything else a value.
      if ($0 ~ /^[ \t\r\n]*:/) {
        key[depth] = decoded_key(pending_token)
        # A repeated parent starts a fresh object, and a real parser uses the LAST
        # one. Carrying values found under an earlier parent let a document put a
        # harmless object first and have the guard judge that instead of the one
        # that counts -- the same last-wins rule that already applies to duplicate
        # fields, missed one level up.
        if (depth == 1 && key[1] == object) { delete found }
        # A requested key seen again starts a new binding. Only a STRING value set
        # `found`, so a later null, number, object or array left the earlier string
        # in place -- and a document could pin a harmless value with a non-string
        # duplicate, which a real parser would have discarded. Clearing on the key
        # rather than on the value makes last-wins hold for every value type.
        if (depth == 2 && key[1] == object && (key[2] in requested)) { delete found[key[2]] }
      } else if (depth == 2 && key[1] == object && (key[2] in requested) && pending_oversize) {
        # A flag, not `exit`. Calling exit here enters END, whose unconditional
        # `exit 0` overrode the status -- so the reader announced it could not read
        # the field and then reported success, and the guard allowed the call.
        printf "json-field.sh: %s is too large to read safely\n", key[2] > "/dev/stderr"
        unreadable = 1
      } else if (depth == 2 && key[1] == object && (key[2] in requested)) {
        # The RAW token is stored; at most one is decoded, at output.
        found[key[2]] = pending_token
      }
      pending = 0
    }
    depth = depth + depth_delta($0)
    inside = 1
    piece_count = 0
    piece_bytes = 0
    oversize = 0
  }
}

END {
  # A string closing at end of input has no following record to classify it.
  # The oversize check is repeated here deliberately: this branch binds the value
  # without going through the classifier above, so omitting it let a truncated
  # document -- one whose requested value has its closing quote as the last byte of input --
  # bind the empty string and exit 0, and the guard allowed the call. Malformed
  # input is exactly where failing closed matters.
  if (pending && depth == 2 && key[1] == object && (key[2] in requested)) {
    if (pending_oversize) {
      printf "json-field.sh: %s is too large to read safely\n", key[2] > "/dev/stderr"
      unreadable = 1
    } else {
      found[key[2]] = pending_token
    }
  }

  if (unreadable) { exit 65 }

  for (i = 1; i <= count; i++) {
    if (wanted[i] in found) {
      emit_unescaped(found[wanted[i]])
      exit 0
    }
  }
  exit 0
}
