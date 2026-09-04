#!/usr/bin/env python3
"""
test_hfloat.py - exercise the hfloat_test UART register interface.

    python test_hfloat.py [PORT] [BAUD]

Defaults: COM8 4.8e6 (Titanium).  Both boards run the core at 120 MHz
and the link at the same 4.8 MBaud:  python test_hfloat.py COM6 4.8e6

Self-contained - needs only pyserial (`pip install pyserial`).  Speaks the
fpga_communication serial protocol directly: 1-byte command, 2-byte
address, 4-byte data, big-endian.  Response frames are read as 7 bytes
and the last 4 are the data word.

Register map (see top_test_hfloat.vhd):
    1  id 0x0000FACE                                RO
    2  git hash                                     RO
    3  loopback                                     RW
    4  read-strobe counter                          RO
    16 FMA operand a  (IEEE-754 binary32)           RW
    17 FMA operand b                                RW
    18 FMA operand c                                RW
    19 FMA result a*b+c  - multiply_add(hfloat)      RO
    20 soft FMA pipeline latency, clock edges       RO
    21 write -> run the soft FMA latency probe      WO
    22 FMA result a*b+c  - multiply_add(fast_hfloat) RO
    23 fast FMA pipeline latency, clock edges       RO
    27 write -> run the fast FMA latency probe      WO
    24 FMA result a*b+c  - Agilex native_fp32       RO   (0 on Titanium)
    25 native FMA pipeline latency                  RO   (0 on Titanium)
    26 write -> run the native FMA latency probe    WO
    32 float->fixed input  (IEEE-754 binary32)      RW
    33 float->fixed radix   (default 10)            RW
    34 float->fixed result = trunc(x * 2**radix)    RO   (signed)
    40 divide operand a  (IEEE-754 binary32)        RW
    41 divide operand b  (IEEE-754 binary32)        RW
    42 divide result a/b - float_divide(lut)        RO

Exit status: 0 = all passed, 1 = one or more failed.
"""
import struct
import sys
import time

try:
    import serial
except ImportError:
    sys.exit("this script needs pyserial:  pip install pyserial")

CMD_READ, CMD_WRITE = 0x02, 0x04
FRAME_LEN = 7          # [len|00|00|d3|d2|d1|d0]


class Uart:
    def __init__(self, port, baud):
        self.s = serial.Serial(port, baud, timeout=0.25)
        self.s.reset_input_buffer()
        self.s.reset_output_buffer()

    def close(self):
        self.s.close()

    def read(self, addr):
        self.s.reset_input_buffer()
        self.s.write(bytes([CMD_READ, (addr >> 8) & 0xFF, addr & 0xFF]))
        f = self.s.read(FRAME_LEN)
        if len(f) != FRAME_LEN:
            raise TimeoutError(f"short read at addr {addr}: {f.hex()}")
        return int.from_bytes(f[3:], "big")

    def write(self, addr, value):
        value &= 0xFFFFFFFF
        # one write() call - do not split (USB may gap the frame)
        self.s.write(bytes([CMD_WRITE, (addr >> 8) & 0xFF, addr & 0xFF])
                     + value.to_bytes(4, "big"))
        self.s.flush()


def f2i(x):
    return struct.unpack("!I", struct.pack("!f", x))[0]


def i2f(x):
    return struct.unpack("!f", struct.pack("!I", x))[0]


class Runner:
    def __init__(self):
        self.passed = self.failed = 0

    def check(self, name, ok, detail=""):
        print(f"  [{'PASS' if ok else 'FAIL'}] {name}" + (f"  - {detail}" if detail else ""))
        if ok:
            self.passed += 1
        else:
            self.failed += 1

    def info(self, msg):
        print(f"  [info] {msg}")


def close_enough(a, b):
    if b == 0.0:
        return abs(a) < 1e-6
    return abs(a - b) <= 1e-3 * max(1.0, abs(b))


def test_link(u, r):
    print("link / id / git hash")
    v = u.read(1)
    r.check("addr 1 == 0x0000FACE", v == 0x0000FACE, f"read 0x{v:08X}")
    r.check("addr 2 git hash non-zero", u.read(2) != 0, f"0x{u.read(2):08X}")


def test_loopback(u, r):
    print("loopback register (addr 3)")
    for p in (0x00000000, 0xFFFFFFFF, 0xDEADBEEF, 0x12345678, 0xA5A5A5A5):
        u.write(3, p)
        g = u.read(3)
        r.check(f"0x{p:08X}", g == p, f"read 0x{g:08X}")


def test_counter(u, r):
    print("read-strobe counter (addr 4)")
    seq = [u.read(4) for _ in range(5)]
    deltas = [(b - a) & 0xFFFFFFFF for a, b in zip(seq, seq[1:])]
    r.check("increments by 1 per read", all(d == 1 for d in deltas), f"{seq}")


FMA_CASES = [
    (1.5, 2.0, 0.5),
    (3.0, 3.0, 1.0),
    (-2.5, 4.0, 10.0),
    (0.25, -8.0, 100.0),
    (123.0, 0.0, -1.0),
    (0.1, 10.0, 0.0),
    (1000.0, 1000.0, -1_000_000.0),
]


def _fma(u, a, b, c):
    u.write(16, f2i(a))
    u.write(17, f2i(b))
    u.write(18, f2i(c))
    time.sleep(0.02)


def test_fma_soft(u, r):
    print("soft FMA  (addr 16-19, hVHDL multiply_add(hfloat))   a*b + c")
    for a, b, c in FMA_CASES:
        _fma(u, a, b, c)
        got = i2f(u.read(19))
        exp = a * b + c
        r.check(f"{a} * {b} + {c}", close_enough(got, exp), f"got {got}, expected {exp}")


def test_fma_fast(u, r):
    print("fast FMA  (addr 16-18 in, 22 out, hVHDL multiply_add(fast_hfloat))   a*b + c")
    for a, b, c in FMA_CASES:
        _fma(u, a, b, c)
        got = i2f(u.read(22))
        exp = a * b + c
        r.check(f"{a} * {b} + {c}", close_enough(got, exp), f"got {got}, expected {exp}")


def test_fma_native(u, r):
    print("native FMA  (addr 24, Agilex native_fp32)   a*b + c")
    _fma(u, 1.0, 1.0, 0.0)
    if u.read(24) == 0 and i2f(u.read(24)) != 1.0:
        r.info("addr 24 reads 0 - native path not present (Titanium build), skipping")
        return
    for a, b, c in FMA_CASES:
        _fma(u, a, b, c)
        got = i2f(u.read(24))
        exp = a * b + c
        r.check(f"{a} * {b} + {c}", close_enough(got, exp), f"got {got}, expected {exp}")


def test_fma_latency(u, r):
    print("FMA pipeline latency probes (addr 20/21 soft, 23/27 fast, 25/26 native)")
    u.write(21, 1)
    time.sleep(0.05)
    lat = [u.read(20) for _ in range(3)]
    r.check("soft latency stable & sane", len(set(lat)) == 1 and 0 < lat[0] < 64, f"{lat}")
    u.write(27, 1)
    time.sleep(0.05)
    flat = [u.read(23) for _ in range(3)]
    r.check("fast latency stable & sane", len(set(flat)) == 1 and 0 < flat[0] < 64, f"{flat}")
    u.write(26, 1)
    time.sleep(0.05)
    nlat = [u.read(25) for _ in range(3)]
    if all(x in (0, 0xFFFFFFFF) for x in nlat):
        r.info(f"native latency {nlat} - native path absent or probe not applicable")
    else:
        r.check("native latency stable & sane", len(set(nlat)) == 1 and 0 < nlat[0] < 64, f"{nlat}")


def test_float_to_fixed(u, r):
    print("float -> fixed  (addr 32 in, 33 radix, 34 result = trunc(x * 2**radix))")
    import math
    for x, radix in [(1.0, 10), (0.5, 10), (0.1, 10), (0.25, 12), (-0.5, 11),
                     (2.0, 10), (1.0 / 3.0, 10), (2 ** -10, 10)]:
        u.write(33, radix)
        u.write(32, f2i(x))
        time.sleep(0.02)
        got = u.read(34)
        if got >= 2 ** 31:
            got -= 2 ** 32
        exp = math.trunc(x * (2 ** radix))
        r.check(f"{x:+.5f} @ radix {radix}", abs(got - exp) <= 1, f"got {got}, expected {exp}")
    u.write(33, 10)


def test_divide(u, r):
    print("divide  (addr 40 a, 41 b, 42 result = a/b, float_divide(lut))")
    for a, b in [(1.0, 1.0), (8.0, 2.0), (-8.0, 2.0), (8.0, -2.0), (-8.0, -2.0),
                 (1.0, 8.0), (3.0, 7.0), (22.0, 7.0), (1.0e6, 1.0e-6),
                 (1.0e-6, 1.0e6), (0.1, 0.3), (-123.456, 78.9)]:
        u.write(40, f2i(a))
        u.write(41, f2i(b))
        time.sleep(0.02)
        got = i2f(u.read(42))
        exp = a / b
        rel_err = abs(got - exp) / max(abs(exp), 1e-30)
        r.check(f"{a:+.6g} / {b:+.6g}", rel_err < 2e-3, f"got {got:.6g}, expected {exp:.6g}, rel_err {rel_err:.2e}")


def main():
    port = sys.argv[1] if len(sys.argv) > 1 else "COM8"
    baud = eval(sys.argv[2]) if len(sys.argv) > 2 else 4.8e6
    print(f"hfloat_test register test  -  {port} @ {baud:g} baud\n")
    try:
        u = Uart(port, baud)
    except serial.SerialException as e:
        sys.exit(f"could not open {port}: {e}")

    r = Runner()
    try:
        for t in (test_link, test_loopback, test_counter,
                  test_fma_soft, test_fma_fast, test_fma_native, test_fma_latency,
                  test_float_to_fixed, test_divide):
            t(u, r)
            print()
    except (TimeoutError, serial.SerialException) as e:
        print(f"\n  [FAIL] communication error: {e}")
        r.failed += 1
    finally:
        u.close()

    print(f"result: {r.passed}/{r.passed + r.failed} passed")
    sys.exit(0 if r.failed == 0 else 1)


if __name__ == "__main__":
    main()
