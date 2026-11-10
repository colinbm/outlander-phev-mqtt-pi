#!/usr/bin/env python3
"""Minimal MQTT 3.1.1 subscriber for quick checks (no dependencies).

Usage: MQTT_USERNAME=… MQTT_PASSWORD=… mqttsub.py HOST[:PORT] TOPIC_FILTER SECONDS
Prints retained and live messages for SECONDS. Leave the env vars unset for a broker
without a login.
"""
import os, socket, struct, sys, time
if len(sys.argv) != 4:
    sys.exit(__doc__.strip())
server, filt, secs = sys.argv[1], sys.argv[2], float(sys.argv[3])
host, _, port = server.partition(":")
user, pw = os.environ.get("MQTT_USERNAME", ""), os.environ.get("MQTT_PASSWORD", "")
def s(b): return struct.pack("!H", len(b)) + b
def pkt(t, body):
    n, rl = len(body), b""
    while True:
        d, n = n % 128, n // 128
        rl += bytes([d | (0x80 if n else 0)])
        if not n: return bytes([t]) + rl + body
sock = socket.create_connection((host, int(port or 1883)), 5)
sock.sendall(pkt(0x10, s(b"MQTT") + bytes([4, 0x02 | (0x80 if user else 0) | (0x40 if pw else 0)]) + struct.pack("!H", 60) + s(b"check-%d" % time.time()) + (s(user.encode()) if user else b"") + (s(pw.encode()) if pw else b"")))
sock.sendall(pkt(0x82, struct.pack("!H", 1) + s(filt.encode()) + b"\x00"))
buf, end = b"", time.time() + secs
sock.settimeout(1)
while time.time() < end:
    try:
        d = sock.recv(65536)
        if not d: break
        buf += d
    except socket.timeout:
        continue
    while len(buf) >= 2:
        mul, rl, i = 1, 0, 1
        while i < len(buf):
            b = buf[i]; rl += (b & 127) * mul; mul *= 128; i += 1
            if not b & 128: break
        if len(buf) < i + rl: break
        t, body, buf = buf[0], buf[i:i+rl], buf[i+rl:]
        if t >> 4 == 3:
            tl = struct.unpack("!H", body[:2])[0]
            print("%s%s = %s" % ("[retained] " if t & 1 else "", body[2:2+tl].decode(), body[2+tl:].decode(errors="replace")[:100]), flush=True)
