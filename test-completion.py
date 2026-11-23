"""Exercise Edit's completion keybinding through a real terminal. Pass --live to use Light."""
import json
import os
import pty
import select
import subprocess
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from tempfile import TemporaryDirectory


# Wait for a visible frame from the editor.
#
# Arguments:
#   fd (int): terminal master
#   needle (bytes): expected text
#   timeout (float): seconds to wait
#
# Returns:
#   (None): raises on timeout
#
def wait_for(fd: int, needle: bytes, timeout: float = 8) -> None:
    seen = bytearray()
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if select.select([fd], [], [], 0.2)[0]:
            seen.extend(os.read(fd, 65536))
            if b"Could not connect" in seen or b"Couldn't connect" in seen:
                raise ConnectionError("Edit could not connect to Light")
            if needle in seen:
                return
    raise AssertionError(f"Missing {needle!r} in {seen[-2000:]!r}")


requests = []
outcomes = iter(["cold", "success", "hold", "truncated", "cold"])
release = threading.Event()


class Light(BaseHTTPRequestHandler):
    # Serve the next recorded Light response, splitting a UTF-8 code point across writes.
    #
    # Returns:
    #   (None): writes one response to the HTTP stream
    #
    def do_POST(self) -> None:
        assert self.path == "/v1/chat/completions"
        body = self.rfile.read(int(self.headers["Content-Length"]))
        requests.append(json.loads(body))
        outcome = next(outcomes)
        if outcome == "cold":
            self.send_response(503)
            self.send_header("Retry-After", "1")
            self.end_headers()
            self.wfile.write(b'{"guidance":{"retryable":true}}')
            return
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.end_headers()
        self.wfile.write(b'data: {"choices":[{"delta":{"reasoning_content":"hidden"}}]}\n\n')
        event = 'data: {"choices":[{"delta":{"content":" α"}}]}\r\n\r\n'.encode()
        split = event.index("α".encode()) + 1
        self.wfile.write(event[:split])
        time.sleep(0.03)
        self.wfile.write(event[split:])
        if outcome == "hold":
            release.wait(5)
        if outcome == "success":
            self.wfile.write(b'data: {"choices":[{"delta":{"content":"\\n  \\"b\\""}}]}\n\ndata: [DONE]\n\n')


live = sys.argv[1:] == ["--live"]
binary = Path(os.environ.get("EDIT_TEST_BINARY", "./edit")).resolve()
with TemporaryDirectory() as directory:
    root = Path(directory)
    path = root / "square.c"
    before = "".join(f"// before-{i:02}\n" for i in range(40))
    after = "".join(f"// after-{i:02}\n" for i in range(25))
    path.write_text("int square(int x) { return ; }\n" if live else before + "old!\n" + after)
    env = dict(os.environ, HOME=directory, EDIT_RECENT=str(root / "recent"), EDIT_SESSION="")
    # Keep the test's kill ring private, including when running outside the sandbox.
    (root / "pbcopy").write_text('#!/bin/sh\ncat > "$HOME/clip"\n')
    (root / "pbcopy").chmod(0o755)
    env["PATH"] = directory + os.pathsep + env["PATH"]
    if live and "EDIT_COMPLETION_URL" not in env:
        config = Path.home() / ".edit/completion-url"
        (root / ".edit").mkdir(exist_ok=True)
        (root / ".edit/completion-url").write_bytes(config.read_bytes())
    if not live:
        server = ThreadingHTTPServer(("127.0.0.1", 0), Light)
        threading.Thread(target=server.serve_forever, daemon=True).start()
        env["EDIT_COMPLETION_URL"] = f"http://127.0.0.1:{server.server_port}/v1/chat/completions"
    master, slave = pty.openpty()
    proc = subprocess.Popen([binary, path], stdin=slave, stdout=slave, stderr=slave, env=env)
    os.close(slave)
    try:
        wait_for(master, b"C-h help")
        if live:
            # Move before the semicolon and request a real completion.
            os.write(master, b"\x06" * path.read_bytes().index(b";") + b"\x03\x03")
            wait_for(master, b"completion finished", 220)
            os.write(master, b"\x18\x13")
            wait_for(master, b"saved")
            result = path.read_text()
            assert "".join(result.split()) in ("intsquare(intx){returnx*x;}",
                                               "intsquare(intx){return(x*x);}"), result
            # Compile and run the inserted code to verify this live sample.
            program = result + "int main(void) { return square(7) != 49; }\n"
            subprocess.run(["cc", "-x", "c", "-", "-o", str(root / "square")],
                           input=program, text=True, check=True)
            subprocess.run([root / "square"], check=True)
            print(result.rstrip())
        else:
            # Select backwards so point and the insertion end differ.
            os.write(master, b"\x0e" * 40 + b"\x06\x06\x06\x00\x02\x02\x02\x03\x03")
            wait_for(master, b"completion finished")
            os.write(master, b"\x18\x13")
            wait_for(master, b"saved")
            assert path.read_text() == before + 'old α\n  "b"!\n' + after
            assert (root / "clip").read_text() == "old"
            assert requests[0] == requests[1]
            prompt = requests[0]["messages"][0]["content"]
            assert "<CURSOR>old!" in prompt and "selection:\n```\nold\n```" in prompt
            assert all(word in prompt for word in ("square.c", "before-09", "before-20", "after-19"))
            assert all(word not in prompt for word in ("before-10", "before-19", "after-20"))
            assert requests[0]["stream"] and requests[0]["reasoning_effort"] == "none"
            os.write(master, b"\x1f\x18\x13")
            wait_for(master, b"saved")
            assert path.read_text() == before + "old!\n" + after

            # Type while the next stream is open. The keystroke must survive cancellation.
            os.write(master, b"\x07\x01\x03\x03")
            wait_for(master, "α".encode())
            os.write(master, b"Z\x18\x13")
            wait_for(master, b"saved")
            release.set()
            assert path.read_text() == before + "Z αold!\n" + after
            os.write(master, b"\x03\x03")
            wait_for(master, b"completion stream interrupted")

            # Cancel a cold request via the named command, then check the read-only guard.
            os.write(master, b"\x1bxinsert-completion\r")
            wait_for(master, b"retrying in 1s")
            os.write(master, b"\x07\x03\x12\x03\x03")
            wait_for(master, b"read only")
            assert len(requests) == 5
        os.write(master, b"\x18\x03\x18\x03")
        wait_for(master, b"\x1b[?1049l")
        assert proc.wait(timeout=5) == 0
    finally:
        release.set()
        proc.kill()
        proc.wait()
        os.close(master)
        if not live:
            server.shutdown()
            server.server_close()
