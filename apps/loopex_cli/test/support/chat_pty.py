import base64
import errno
import json
import os
import pty
import select
import signal
import sys
import termios


def emit(value):
    print(json.dumps(value), flush=True)


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
