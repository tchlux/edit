"""Exercise chat panes, live tools, streaming, and exact save/reopen through Edit's terminal."""
import json
import os
import pty
import select
import signal
import subprocess
import sys
import tempfile
import threading
import time
from pathlib import Path
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

binary = Path("edit").resolve()
live = "--live" in sys.argv
sent = []
release = threading.Event()
hold = threading.Event()


# Emit an SSE response for one round of a synthetic agent session.
#
# Arguments:
#   self (Fixture): the current HTTP connection
#
# Returns:
#   (None): writes response records to the editor
#
class Fixture(BaseHTTPRequestHandler):
    def do_POST(self) -> None:
        body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        sent.append(body)
        assert self.path == "/v1/chat/completions" and body["stream"] and len(body["tools"]) == 5
        paused = body["messages"][-1]["content"] == "interrupt me"
        if paused and sum(r["messages"][-1]["content"] == "interrupt me" for r in sent) == 1:
            self.send_response(503)
            self.send_header("Retry-After", "1")
            self.end_headers()
            self.wfile.write(b'{"guidance":{"retryable":true}}')
            return
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.end_headers()
        events = []
        reason = "stop"
        source = str(root / "example.c")
        if paused:
            delta = {"reasoning_content": "Still thinking.", "tool_calls": [
                {"index": 0, "id": "pending", "type": "function",
                 "function": {"name": "create_buffer", "arguments": '{"name":"never.c","text":"never"}'}}]}
            self.wfile.write(b"data: " + json.dumps({"choices": [{"delta": delta}]}).encode() + b"\n\n")
            hold.wait(15)
            return
        if len(sent) == 1:
            events.append({"reasoning_content": "Reading the open document."})
            calls = [("list_buffers", {}), ("read_buffer", {"name": source}),
                     ("edit_buffer", {"name": source, "old_text": "old", "new_text": "new"}),
                     ("create_buffer", {"name": "created.c", "text": "created\n"}), ("edit_help", {})]
            for index, (name, args) in enumerate(calls):
                raw = json.dumps(args)
                events.append({"tool_calls": [{"index": index, "id": f"call_{index}",
                                              "type": "function", "function": {"name": name, "arguments": raw[:1]}}]})
                events.append({"tool_calls": [{"index": index, "function": {"arguments": raw[1:]}}]})
            reason = "tool_calls"
        else:
            events.extend([{"reasoning_content": "Looking back."}, {"content": "Round finished."}])
        for delta in events:
            frame = {"model": "fixture", "choices": [{"delta": delta, "finish_reason": None}]}
            self.wfile.write(b"data: " + json.dumps(frame).encode() + b"\n\n")
            if len(sent) == 1 and "reasoning_content" in delta:
                release.wait(8)
        self.wfile.write(b'data: {"choices":[{"delta":{},"finish_reason":"' + reason.encode() + b'"}]}\n\ndata: [DONE]\n\n')


# Drain terminal redraws until a visible marker arrives.
#
# Arguments:
#   marker (bytes): bytes expected in the terminal output
#   timeout (int): maximum wait in seconds
#
# Returns:
#   (bytes): the matching sequence of frames
#
def wait(marker: bytes, timeout: int = 10) -> bytes:
    data = bytearray()
    end = time.monotonic() + timeout
    while time.monotonic() < end:
        if select.select([fd], [], [], 0.2)[0]:
            chunk = os.read(fd, 65536)
            if not chunk:
                break
            data.extend(chunk)
            if marker in data:
                return bytes(data)
    raise AssertionError((marker, bytes(data[-2500:])))


# Launch the ordinary editor against one file with isolated session settings.
#
# Arguments:
#   path (Path): document or saved conversation
#
# Returns:
#   (tuple): editor process and its terminal master
#
def launch(path: Path | None) -> tuple:
    master, slave = pty.openpty()
    import termios
    termios.tcsetwinsize(slave, (35, 160))
    editor = subprocess.Popen([binary] + ([path] if path else []), cwd=root, env=env, stdin=slave, stdout=slave, stderr=slave)
    os.close(slave)
    return editor, master


with tempfile.TemporaryDirectory() as directory:
    root = Path(directory).resolve()
    env = dict(os.environ, HOME=directory, EDIT_SESSION=str(root / "snapshot"), EDIT_RECENT=str(root / "recent"), EDIT_ASPELL="/nonexistent")
    system = "Use the editor tools. Report the literal requested result."
    (root / ".agents.md").write_text(system)
    doc = root / "example.c"
    doc.write_text("old\n")
    if live and "EDIT_COMPLETION_URL" not in env:
        config = Path.home() / ".edit/completion-url"
        (root / ".edit").mkdir(exist_ok=True)
        (root / ".edit/completion-url").write_bytes(config.read_bytes())
    if not live:
        server = ThreadingHTTPServer(("127.0.0.1", 0), Fixture)
        threading.Thread(target=server.serve_forever, daemon=True).start()
        env["EDIT_COMPLETION_URL"] = f"http://127.0.0.1:{server.server_port}/v1/chat/completions"
    proc, fd = launch(doc)
    try:
        wait(b"C-h help")
        os.write(fd, b"\x06\x1bxchat\r")
        frame = wait(b"C-c C-c send")
        assert b"example.c" in frame and b"System" in frame and b"chat-" in frame
        prompt = b"Use list_buffers then read_buffer on example.c. Reply with the buffer contents."
        if live:
            prompt = (b"Use editor tools to read example.c, replace old with new, create created.c with text hello, "
                      b"and consult edit_help for the save shortcut. Reply when done.")
        os.write(fd, prompt + b"\x03\x03")
        if not live:
            wait(b"Reading the open document.")
            os.write(fd, b"\x03p")
            release.set()
            os.write(fd, b"\x1b>")
            wait(b"Round finished.")
        else:
            frame = wait(b"Tool result", 210)
            if b"chat finished" not in frame:
                wait(b"chat finished", 210)
        os.write(fd, b"\x18\x13")
        wait(b"saved")
        archive, = root.glob("*.editchat")
        raw = archive.read_bytes()
        assert raw.startswith(b"Edit chat 1\n")
        saved = json.loads(raw.split(b"\n", 1)[1])
        if live:
            print([(m["role"], m.get("content", "")[:100]) for m in saved["messages"] if m["role"] != "system"])
            names = {call["function"]["name"] for msg in saved["messages"] for call in msg.get("tool_calls", [])}
            assert {"read_buffer", "edit_buffer", "create_buffer", "edit_help"} <= names, names
            assert any(m.get("reasoning_content") for m in saved["messages"])
            os.write(fd, b"\x18o\x18\x13")
            wait(b"saved")
            assert doc.read_text().strip() == "new", doc.read_text()
            os.write(fd, b"\x18b")
            wait(b"opened created.c")
            os.write(fd, b"\x18\x13")
            wait(b"saved")
            assert (root / "created.c").read_text().strip() == "hello", (root / "created.c").read_bytes()
        else:
            history = sent[1]["messages"]
            assert history[0]["content"] == system and history[1]["content"] == prompt.decode()
            assert history[2]["reasoning_content"] == "Reading the open document."
            assert len(history[2]["tool_calls"]) == 5
            assert "cursor 1" in history[3]["content"] and history[4]["content"] == "old\n", history
            assert history[5]["content"] == "Applied in Edit." and history[6]["content"] == "Created in Edit.", history
            assert "chat-clear" in history[7]["content"]
            # Save the edited source through the left pane; chat focus was preserved.
            os.write(fd, b"\x18o\x18\x13")
            wait(b"saved")
            assert doc.read_text() == "new\n"
            os.write(fd, b"\x18odrafted follow up\x1bxchat-save-as\r")
            wait(b"save chat as:")
            archive = root / "my-conversation"
            os.write(fd, str(archive).encode() + b"\r")
            wait(b"saved")
            assert json.loads(archive.read_bytes().split(b"\n",1)[1])["draft"] == "drafted follow up"
            proc.kill()
            proc.wait()
            os.close(fd)
            (root / ".agents.md").write_text("different prompt")
            proc, fd = launch(archive)
            wait(b"C-h help")
            os.write(fd, b"!\x03\x03")
            wait(b"chat running")
            deadline = time.monotonic() + 10
            while len(sent) < 3 and time.monotonic() < deadline:
                select.select([], [], [], 0.02)
            assert sent[2]["messages"][:-1] == saved["messages"]
            assert sent[2]["messages"][-1]["content"] == "drafted follow up!"
            assert sent[2]["model"] == "fixture"
            assert sent[2]["tools"] == saved["tools"] and sent[2]["reasoning_effort"] == saved["reasoning_effort"]
            wait(b"Round finished.")
            os.write(fd, b"\x1bxchat-clear\r")
            wait(b"chat context cleared")
            os.write(fd, b"\x18\x13")
            wait(b"saved")
            cleared = json.loads(archive.read_bytes().split(b"\n",1)[1])
            assert cleared["messages"] == saved["messages"][:1]
            os.write(fd, b"\x1bxchat-new\r")
            wait(b"C-c C-c send")
            os.write(fd, b"\x18\x13")
            wait(b"saved")
            files = sorted(root.glob("*.editchat"))
            assert len(files) == 2
            os.write(fd, b"interrupt me\x03\x03")
            wait(b"retrying")
            wait(b"Still thinking.")
            os.write(fd, b"\x18\x13")
            wait(b"saved")
            partial = json.loads(files[-1].read_bytes().split(b"\n",1)[1])["messages"][-1]
            assert partial["partial"] and partial["tool_calls"][0]["id"] == "pending"
            os.write(fd, b"\x07")
            wait(b"chat canceled")
            hold.set()
            count = len(sent)
            # A window snapshot also preserves the conversation and draft.
            os.write(fd, b"unsent draft")
            wait(b"unsent draft")
            proc.send_signal(signal.SIGTERM)
            wait(b"\x1b[?1049l")
            assert proc.wait(timeout=5) == 0
            os.close(fd)
            proc, fd = launch(None)
            wait(b"unsent draft")
            os.write(fd, b"\x18\x13")
            wait(b"saved")
            restored = json.loads(files[-1].read_bytes().split(b"\n",1)[1])
            assert restored["draft"] == "unsent draft" and restored["messages"][-1]["partial"] == "Canceled."
            assert len(sent) == count and not (root / "never.c").exists()
            os.write(fd, b"\x03\x03")
            wait(b"chat finished")
            replay = sent[-1]["messages"]
            assert replay[-2]["reasoning_content"] == "Still thinking." and "never.c" in replay[-2]["content"]
            assert "tool_calls" not in replay[-2] and replay[-1]["content"] == "unsent draft"
    finally:
        release.set()
        hold.set()
        proc.kill()
        proc.wait()
        os.close(fd)
        if not live:
            server.shutdown()
            server.server_close()
print("chat checks passed")
