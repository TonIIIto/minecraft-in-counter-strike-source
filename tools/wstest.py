"""Tiny WebSocket client (stdlib only) for the Minecraft link: sends messages, prints what comes back.
usage: python -I wstest.py '{"t":"blocksync","r":48}' [seconds]"""
import base64
import os
import socket
import struct
import sys
import time

msgs = [sys.argv[1]] if len(sys.argv) > 1 else ['{"t":"blocksync","r":48}']
seconds = float(sys.argv[2]) if len(sys.argv) > 2 else 3.0

s = socket.create_connection(("127.0.0.1", 25599), timeout=3)
key = base64.b64encode(os.urandom(16)).decode()
s.sendall(("GET / HTTP/1.1\r\nHost: 127.0.0.1:25599\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
           "Sec-WebSocket-Key: %s\r\nSec-WebSocket-Version: 13\r\n\r\n" % key).encode())
buf = b""
while b"\r\n\r\n" not in buf:
    buf += s.recv(4096)
buf = buf.split(b"\r\n\r\n", 1)[1]


def send(text):
    data = text.encode()
    mask = os.urandom(4)
    n = len(data)
    head = bytes([0x81])
    if n < 126:
        head += bytes([0x80 | n])
    elif n < 65536:
        head += bytes([0x80 | 126]) + struct.pack(">H", n)
    else:
        head += bytes([0x80 | 127]) + struct.pack(">Q", n)
    s.sendall(head + mask + bytes(b ^ mask[i % 4] for i, b in enumerate(data)))


def frames():
    global buf
    while True:
        while len(buf) < 2:
            buf += s.recv(65536)
        n = buf[1] & 0x7F
        off = 2
        if n == 126:
            while len(buf) < 4:
                buf += s.recv(65536)
            n = struct.unpack(">H", buf[2:4])[0]
            off = 4
        elif n == 127:
            while len(buf) < 10:
                buf += s.recv(65536)
            n = struct.unpack(">Q", buf[2:10])[0]
            off = 10
        while len(buf) < off + n:
            buf += s.recv(65536)
        payload, buf = buf[off:off + n], buf[off + n:]
        yield payload.decode(errors="replace")


for m in msgs:
    send(m)
end = time.time() + seconds
s.settimeout(0.5)
try:
    for f in frames():
        print(len(f), f[:400])
        if time.time() > end:
            break
except (socket.timeout, TimeoutError):
    pass
