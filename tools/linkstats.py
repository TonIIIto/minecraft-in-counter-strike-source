"""Measures the Minecraft <-> CS:S link: frames/sec delivered, pose updates/sec, frame size, latency."""
import mmap
import struct
import time

fm = mmap.mmap(-1, 4096, tagname="Local\\MCPassthroughFrame")
pm = mmap.mmap(-1, 96, tagname="Local\\MCCssPose")


def frame():
    return struct.unpack_from("<q", fm, 32)[0]


def pose():
    return struct.unpack_from("<q", pm, 0)[0]


t0, f0, p0 = time.time(), frame(), pose()
time.sleep(3)
t1, f1, p1 = time.time(), frame(), pose()
slot = struct.unpack_from("<i", fm, 40)[0]
d = 256 + 128 * slot
mw, mh = struct.unpack_from("<ii", fm, d + 24)
print("MC frames/sec into CS:S: %.1f" % ((f1 - f0) / (t1 - t0)))
print("pose updates/sec: %.1f" % (((p1 - p0) / 2) / (t1 - t0)))
print("frame size: %d x %d" % (mw, mh))
x, y, z, yaw, pitch, roll, fov = struct.unpack_from("<dddffff", pm, 8)
print("camera MC coords: %.2f %.2f %.2f yaw %.1f pitch %.1f fov %.1f" % (x, y, z, yaw, pitch, fov))
cap, pub = struct.unpack_from("<qq", fm, d + 88)
print("frame age at publish (ms): %.1f" % ((pub - cap) / 1e6))
