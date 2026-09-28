#!/usr/bin/env python3
"""Run the attended release check with a controlling terminal and exact answers.

The release check's first attended case opens /dev/tty. A FIFO connected to
script(1)'s stdin cannot supply that terminal on Darwin. This controller owns
the PTY master, while the child check and its descendants own the slave.
"""

import argparse
import errno
import os
import pty
import re
import select
import signal
import sys
import time


FIRST = (
    b"Authorize pinned public skill import: "
    b"source=https://github.com/openai/skills.git "
    b"rev=49f948faa9258a0c61caceaf225e179651397431 "
    b"path=skills/.curated/security-threat-model. Type yes and press Enter."
)
SECOND = re.compile(
    rb"Admit exact public skill manifest: "
    rb"source=https://github\.com/openai/skills\.git "
    rb"digest=[0-9a-f]{64}\. Type yes and press Enter\."
)
NOTICE_PREFIXES = (
    b"Authorize pinned public skill import:",
    b"Admit exact public skill manifest:",
)
KEY_NAMES = (
    "LOOPEX_PROVIDER_API_KEY",
    "OPENAI_API_KEY",
    "ANTHROPIC_API_KEY",
    "OPENROUTER_API_KEY",
)
MARKERS = (b"[REDACTED]", b"<REDACTED>", b"{REDACTED}", b"~REDACTED~")


def replacement_for(keys):
    # A key cannot cross the marker boundary when neither marker edge byte
    # occurs in any key. A marker must also contain no whole key of its own.
    for marker in (*MARKERS, *(bytes((byte,)) for byte in range(33, 127)), b"\0"):
        if all(
            key not in marker and marker[:1] not in key and marker[-1:] not in key
            for key in keys
        ):
            return marker
    raise ValueError("credential_value_unredactable")


def extract_authority(context_path, anchor):
    with open(context_path, "rb") as context_file:
        context = context_file.read()
    marker = f'<a id="{anchor}"></a>'.encode("ascii")
    starts = [
        match.start()
        for match in re.finditer(rb"(?m)^<a id=\"[^\"]+\"></a>(?:\r?\n|$)", context)
        if context.startswith(marker, match.start())
        and context[match.start() + len(marker) : match.end()] in (b"\n", b"\r\n", b"")
    ]
    if len(starts) != 1:
        return 1
    end = re.search(rb"(?m)^<a id=\"", context[starts[0] + len(marker) :])
    stop = starts[0] + len(marker) + end.start() if end else len(context)
    selected = context[starts[0] : stop]
    if b"\0" in selected:
        return 1
    write_all(sys.stdout.fileno(), selected)
    return 0


class Redactor:
    """Keep enough trailing bytes to cover a key split between PTY reads."""

    def __init__(self, keys):
        self.keys = sorted((key for key in keys if key), key=len, reverse=True)
        self.width = max((len(key) for key in self.keys), default=1)
        self.pending = b""
        self.replacement = replacement_for(self.keys)

    def feed(self, data, final=False):
        content = self.pending + data
        safe = len(content) if final else max(0, len(content) - self.width + 1)
        cursor = 0
        output = bytearray()
        while cursor < safe:
            matches = [(content.find(key, cursor), key) for key in self.keys]
            matches = [(position, key) for position, key in matches if position >= 0]
            if not matches:
                output.extend(content[cursor:safe])
                cursor = safe
                break
            position, key = min(matches, key=lambda item: (item[0], -len(item[1])))
            if position >= safe:
                output.extend(content[cursor:safe])
                cursor = safe
                break
            output.extend(content[cursor:position])
            output.extend(self.replacement)
            cursor = position + len(key)
        self.pending = content[cursor:]
        return bytes(output)


class Notices:
    def __init__(self):
        self.pending = bytearray()
        self.discard_long_line = False
        self.answers = 0
        self.failure = None

    def feed(self, data):
        for byte in data:
            if byte == 10:
                if not self.discard_long_line:
                    line = bytes(self.pending)
                    self._line(line[:-1] if line.endswith(b"\r") else line)
                self.pending.clear()
                self.discard_long_line = False
            elif not self.discard_long_line:
                self.pending.append(byte)
                if len(self.pending) > 8192:
                    if any(self.pending.startswith(prefix) for prefix in NOTICE_PREFIXES):
                        self.failure = "malformed_notice"
                    self.pending.clear()
                    self.discard_long_line = True

    def _line(self, line):
        first = line == FIRST
        second = SECOND.fullmatch(line) is not None
        if first and self.answers == 0:
            self.answers = 1
            return
        if second and self.answers == 1:
            self.answers = 2
            return
        if first or second or any(line.startswith(prefix) for prefix in NOTICE_PREFIXES):
            self.failure = "unexpected_or_malformed_notice"


def write_all(fd, data):
    while data:
        data = data[os.write(fd, data) :]


def credential_keys():
    keys = []
    for name in KEY_NAMES:
        value = os.environ.get(name, "")
        if "\n" in value or "\r" in value:
            raise ValueError("credential_value_unredactable")
        if value:
            keys.append(os.fsencode(value))
    return keys


def check_no_keys(path):
    try:
        with open(path, "rb") as source:
            data = source.read()
        return 1 if any(key in data for key in credential_keys()) else 0
    except (OSError, ValueError):
        return 1


def main():
    if len(sys.argv) == 4 and sys.argv[1] == "--extract-context":
        return extract_authority(sys.argv[2], sys.argv[3])
    if len(sys.argv) == 3 and sys.argv[1] == "--check-no-keys":
        return check_no_keys(sys.argv[2])
    if sys.argv[1:] == ["--redact-stdin"]:
        try:
            redactor = Redactor(credential_keys())
        except ValueError:
            print("attended-pty: credential_value_unredactable", file=sys.stderr)
            return 1
        while True:
            data = os.read(sys.stdin.fileno(), 65536)
            if not data:
                break
            write_all(sys.stdout.fileno(), redactor.feed(data))
        write_all(sys.stdout.fileno(), redactor.feed(b"", final=True))
        return 0

    parser = argparse.ArgumentParser()
    parser.add_argument("--output", required=True)
    parser.add_argument("--check", required=True)
    args = parser.parse_args()

    try:
        redactor = Redactor(credential_keys())
    except ValueError:
        print("attended-pty: credential_value_unredactable", file=sys.stderr)
        return 1
    notices = Notices()
    interrupted = None
    child_status = None
    child_pid = None
    master_fd = None
    failure = None
    stop_started = None
    sent_answers = 0
    started = time.monotonic()
    output_fd = os.open(args.output, os.O_WRONLY | os.O_APPEND | getattr(os, "O_NOFOLLOW", 0))
    stdout_open = True

    def publish(data):
        nonlocal stdout_open
        if not data:
            return
        write_all(output_fd, data)
        if stdout_open:
            try:
                write_all(sys.stdout.fileno(), data)
            except OSError as error:
                if error.errno != errno.EPIPE:
                    raise
                stdout_open = False

    def forward(signum, _frame):
        nonlocal interrupted
        if interrupted is None:
            interrupted = (signum, time.monotonic())
        if child_pid is not None:
            try:
                os.killpg(child_pid, signum)
            except ProcessLookupError:
                pass

    old_handlers = {
        signum: signal.signal(signum, forward)
        for signum in (signal.SIGHUP, signal.SIGINT, signal.SIGTERM)
    }
    try:
        child_pid, master_fd = pty.fork()
        if child_pid == 0:
            try:
                os.execv("/bin/bash", ["bash", args.check])
            except OSError:
                os._exit(127)

        # Terminal echo cannot masquerade as a notice because the exact notice
        # parser sees one complete line and the only sent text is "yes".
        os.set_blocking(master_fd, False)
        eof_at = None
        child_exited_at = None
        while True:
            if child_status is None:
                waited, status = os.waitpid(child_pid, os.WNOHANG)
                if waited:
                    child_status = status
                    child_exited_at = time.monotonic()

            stop_at = interrupted[1] if interrupted is not None else stop_started
            if stop_at is not None and child_status is None and time.monotonic() - stop_at >= 3:
                try:
                    os.killpg(child_pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass

            if child_status is not None and child_exited_at is not None:
                if time.monotonic() - child_exited_at >= 2 and eof_at is None:
                    failure = failure or "terminal_not_closed"
                    try:
                        os.killpg(child_pid, signal.SIGKILL)
                    except ProcessLookupError:
                        pass
                    break

            ready, _, _ = select.select([master_fd], [], [], 0.1)
            if ready:
                try:
                    data = os.read(master_fd, 65536)
                except OSError as error:
                    if error.errno != errno.EIO:
                        raise
                    data = b""
                if not data:
                    eof_at = time.monotonic()
                    if child_status is not None:
                        break
                else:
                    notices.feed(data)
                    publish(redactor.feed(data))
                    if notices.failure is not None and stop_started is None:
                        failure = notices.failure
                        stop_started = time.monotonic()
                        try:
                            os.killpg(child_pid, signal.SIGTERM)
                        except ProcessLookupError:
                            pass
                    elif notices.failure is None and notices.answers > sent_answers:
                        write_all(master_fd, b"yes\n")
                        sent_answers += 1
            if eof_at is not None and child_status is not None:
                break

        publish(redactor.feed(b"", final=True))
        if child_status is None:
            _, child_status = os.waitpid(child_pid, 0)
        if os.WIFEXITED(child_status):
            release_exit = os.WEXITSTATUS(child_status)
        elif os.WIFSIGNALED(child_status):
            release_exit = 128 + os.WTERMSIG(child_status)
        else:
            release_exit = "unavailable"
        if interrupted is not None:
            failure = failure or "interrupted"
        if sent_answers != 2:
            failure = failure or "missing_attended_notice"
        if release_exit != 0:
            failure = failure or "release_check_failed"
        summary = (
            f"\nRELEASE_EXIT={release_exit}\nATTENDED_ANSWERS={sent_answers}\n"
            f"DURATION_S={int(time.monotonic() - started)}\n"
        )
        if failure:
            summary += f"ATTENDED_FAILURE={failure}\n"
        publish(redactor.feed(summary.encode("ascii"), final=True))
        return 0 if failure is None else 1
    except BaseException:
        summary = (
            f"\nRELEASE_EXIT=unavailable\nATTENDED_ANSWERS={sent_answers}\n"
            f"DURATION_S={int(time.monotonic() - started)}\n"
            "ATTENDED_FAILURE=controller_failed\n"
        )
        try:
            publish(redactor.feed(summary.encode("ascii"), final=True))
        except OSError:
            pass
        return 1
    finally:
        for signum, handler in old_handlers.items():
            signal.signal(signum, handler)
        if child_pid not in (None, 0) and child_status is None:
            try:
                os.killpg(child_pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            try:
                os.waitpid(child_pid, 0)
            except ChildProcessError:
                pass
        if master_fd is not None:
            os.close(master_fd)
        os.close(output_fd)


if __name__ == "__main__":
    sys.exit(main())
