import base64
import errno
import json
import os
import pty
import select
import signal
import sys
import termios
import time


def emit(value):
    print(json.dumps(value), flush=True)



def pipe_main(command):
    incoming_read, incoming_write = os.pipe()
    outgoing_read, outgoing_write = os.pipe()
    diagnostic_read, diagnostic_write = os.pipe()
    ready_read, ready_write = os.pipe()
    pid = os.fork()
    if pid == 0:
        os.setsid()
        os.dup2(incoming_read, 0)
        os.dup2(outgoing_write, 1)
        os.dup2(diagnostic_write, 2)
        for fd in [incoming_read, incoming_write, outgoing_read, outgoing_write,
                   diagnostic_read, diagnostic_write, ready_read]:
            os.close(fd)
        os.write(ready_write, b"ready")
        os.close(ready_write)
        os.execv(command[0], command)

    os.close(incoming_read)
    os.close(diagnostic_write)
    os.close(ready_write)
    assert os.read(ready_read, 5) == b"ready"
    os.close(ready_read)
    emit({"event": "started", "launcher": pid, "group": os.getpgid(pid)})
    pending = b""
    paused = False
    probe_deadline = None
    streams = {outgoing_read: "output", diagnostic_read: "diagnostic"}
    reaped = False
    code = None
    try:
        while streams or not reaped:
            if probe_deadline is not None:
                _, writable, _ = select.select([], [outgoing_write], [], 0)
                readable, _, _ = select.select([outgoing_read], [], [], 0)
                if not writable and readable:
                    emit({"event": "output_blocked", "kernel_writable": False,
                          "kernel_readable": True})
                    probe_deadline = None
                    os.close(outgoing_write)
                    outgoing_write = None
                elif time.monotonic() >= probe_deadline:
                    raise TimeoutError("actual stdout pipe did not become backpressured")

            reads = [sys.stdin.fileno()] + [fd for fd in streams
                      if not (paused and fd == outgoing_read)]
            readable, _, _ = select.select(reads, [], [], 0.01 if probe_deadline else 0.1)
            if sys.stdin.fileno() in readable:
                data = os.read(sys.stdin.fileno(), 65536)
                if not data:
                    raise EOFError("pipe fixture owner input closed")
                pending += data
                while b"\n" in pending:
                    line, pending = pending.split(b"\n", 1)
                    action = json.loads(line)
                    if action["action"] == "write":
                        data = base64.b64decode(action["bytes"], validate=True)
                        offset = 0
                        while offset < len(data):
                            offset += os.write(incoming_write, data[offset:])
                        emit({"event": "written", "bytes": len(data)})
                    elif action["action"] == "half_close":
                        os.close(incoming_write)
                        incoming_write = None
                        emit({"event": "half_closed"})
                    elif action["action"] == "pause_output":
                        paused = True
                        emit({"event": "output_paused"})
                    elif action["action"] == "probe_output":
                        assert paused and outgoing_write is not None
                        probe_deadline = time.monotonic() + 5.0
                    elif action["action"] == "resume_output":
                        paused = False
                        emit({"event": "output_resumed"})
                    elif action["action"] == "fill_input":
                        # Concept: observe kernel refusal without guessing pipe capacity.
                        # Technical depth: the producer writes finite real future lines
                        # until EAGAIN; no driver input or syscall is substituted.
                        os.set_blocking(incoming_write, False)
                        data = b"next prompt\n" * 128
                        total = 0
                        blocked = False
                        while total < 1_048_576:
                            try:
                                total += os.write(incoming_write, data)
                            except BlockingIOError:
                                blocked = True
                                break
                        emit({"event": "input_pressure", "blocked": blocked,
                              "written_bytes": total})
                    else:
                        raise ValueError("unrecognized pipe fixture action")
            for fd in readable:
                if fd not in streams:
                    continue
                data = os.read(fd, 65536)
                if data:
                    emit({"event": streams[fd], "bytes": base64.b64encode(data).decode("ascii")})
                else:
                    os.close(fd)
                    del streams[fd]
            if not reaped:
                waited, status = os.waitpid(pid, os.WNOHANG)
                if waited == pid:
                    reaped = True
                    code = os.waitstatus_to_exitcode(status)
                    if outgoing_write is not None:
                        os.close(outgoing_write)
                        outgoing_write = None
        try:
            os.killpg(pid, 0)
            group_gone = False
        except ProcessLookupError:
            group_gone = True
        emit({"event": "exited", "status": code, "group_gone": group_gone})
        sys.exit(code)
    finally:
        for fd in list(streams) + [incoming_write, outgoing_write]:
            if fd is not None:
                os.close(fd)
        if not reaped:
            try:
                os.killpg(pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            os.waitpid(pid, 0)

def pty_main():
    ready_read, ready_write = os.pipe()
    pid, fd = pty.fork()
    if pid == 0:
        os.close(ready_read)
        os.write(ready_write, b"ready")
        os.close(ready_write)
        os.execv(sys.argv[1], sys.argv[1:])

    os.close(ready_write)
    assert os.read(ready_read, 5) == b"ready"
    os.close(ready_read)

    attributes = termios.tcgetattr(fd)
    attributes[3] &= ~termios.ECHO
    termios.tcsetattr(fd, termios.TCSANOW, attributes)
    emit({"event": "started", "launcher": pid, "group": os.getpgid(pid)})
    pending = b""
    reaped = False
    try:
        while True:
            readable, _, _ = select.select([fd, sys.stdin.buffer], [], [])
            if sys.stdin.buffer in readable:
                data = os.read(sys.stdin.fileno(), 65536)
                if not data:
                    raise EOFError("PTY owner input closed")
                pending += data
                while b"\n" in pending:
                    line, pending = pending.split(b"\n", 1)
                    command = json.loads(line)
                    if command["action"] == "write":
                        os.write(fd, base64.b64decode(command["bytes"], validate=True))
                    elif command["action"] == "interrupt":
                        emit({"event": "interrupt", "isig": bool(termios.tcgetattr(fd)[3] & termios.ISIG),
                              "foreground": os.tcgetpgrp(fd)})
                        os.write(fd, b"\x03")
            if fd in readable:
                try:
                    data = os.read(fd, 65536)
                except OSError as error:
                    if error.errno != errno.EIO:
                        raise
                    break
                if not data:
                    break
                emit({"event": "output", "bytes": base64.b64encode(data).decode("ascii")})
        _, status = os.waitpid(pid, 0)
        reaped = True
        code = os.waitstatus_to_exitcode(status)
        try:
            os.killpg(pid, 0)
            group_gone = False
        except ProcessLookupError:
            group_gone = True
        emit({"event": "exited", "status": code, "group_gone": group_gone})
        sys.exit(code)
    finally:
        os.close(fd)
        if not reaped:
            try:
                os.killpg(pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            os.waitpid(pid, 0)


if len(sys.argv) > 1 and sys.argv[1] == "--pipe":
    pipe_main(sys.argv[2:])
else:
    pty_main()
