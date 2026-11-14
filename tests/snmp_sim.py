#!/usr/bin/env python3
"""Minimal SNMPv1/v2c agent for QuMeter tests. Independent BER implementation."""
import argparse
import socket
import struct
import sys
import time

# Values are (tag, payload_bytes) or helpers below.
TAG_SEQ = 0x30
TAG_INT = 0x02
TAG_OCT = 0x04
TAG_NULL = 0x05
TAG_OID = 0x06
TAG_CTR32 = 0x41
TAG_GET = 0xA0
TAG_GETNEXT = 0xA1
TAG_GETRESP = 0xA2
TAG_NOSUCH_OBJ = 0x80
TAG_NOSUCH_INST = 0x81
TAG_ENDOFMIB = 0x82


def enc_len(n):
    if n < 128:
        return bytes([n])
    body = n.to_bytes((n.bit_length() + 7) // 8, "big") or b"\x00"
    return bytes([0x80 | len(body)]) + body


def tlv(tag, val):
    return bytes([tag]) + enc_len(len(val)) + val


def enc_int(v):
    if v == 0:
        body = b"\x00"
    else:
        length = max(1, (v.bit_length() + 8) // 8)
        body = v.to_bytes(length, "big", signed=True)
        # trim redundant leading sign bytes
        while len(body) > 1 and ((body[0] == 0 and body[1] < 0x80) or (body[0] == 0xFF and body[1] >= 0x80)):
            body = body[1:]
    return tlv(TAG_INT, body)


def enc_ctr32(v):
    body = v.to_bytes((v.bit_length() + 8) // 8 or 1, "big", signed=False)
    if body[0] & 0x80:
        body = b"\x00" + body
    return tlv(TAG_CTR32, body)


def enc_oid(oid):
    parts = [int(x) for x in oid.strip(".").split(".")]
    out = bytes([parts[0] * 40 + parts[1]])
    for arc in parts[2:]:
        if arc < 128:
            out += bytes([arc])
        else:
            chunks = []
            v = arc
            chunks.append(v & 0x7F)
            v >>= 7
            while v:
                chunks.append((v & 0x7F) | 0x80)
                v >>= 7
            out += bytes(reversed(chunks))
    return tlv(TAG_OID, out)


def enc_oct(s):
    if isinstance(s, str):
        s = s.encode("ascii")
    return tlv(TAG_OCT, s)


def read_len(buf, i):
    lb = buf[i]
    i += 1
    if lb < 128:
        return lb, i
    n = lb & 0x7F
    val = int.from_bytes(buf[i:i + n], "big")
    return val, i + n


def read_tlv(buf, i):
    tag = buf[i]
    ln, j = read_len(buf, i + 1)
    val = buf[j:j + ln]
    return tag, val, j + ln


def dec_oid(data):
    first = data[0]
    if first >= 80:
        arcs = [2, first - 80]
    else:
        arcs = [first // 40, first % 40]
    i = 1
    while i < len(data):
        v = 0
        while True:
            b = data[i]
            i += 1
            v = (v << 7) | (b & 0x7F)
            if b < 128:
                break
        arcs.append(v)
    return ".".join(str(a) for a in arcs)


def dec_int(data):
    return int.from_bytes(data, "big", signed=True)


def oid_key(oid):
    return tuple(int(x) for x in oid.strip(".").split("."))


def default_mib():
    # Printer-like HP device used by the end-to-end tests.
    roman = b"\x01\x15"
    mib = {
        "1.3.6.1.2.1.1.1.0": enc_oct("HP Color LaserJet E57540"),
        "1.3.6.1.2.1.1.5.0": enc_oct("TEST-PRINTER"),
        "1.3.6.1.2.1.25.3.2.1.3.1": enc_oct("HP Color LaserJet E57540"),
        "1.3.6.1.2.1.43.5.1.1.16.1": enc_oct("E57540"),
        "1.3.6.1.2.1.43.5.1.1.17.1": enc_oct("TESTSN001"),
        "1.3.6.1.4.1.11.2.3.9.4.2.1.1.3.2.0": enc_oct(roman + b"HP Color LaserJet E57540"),
        "1.3.6.1.4.1.11.2.3.9.4.2.1.1.3.3.0": enc_oct(roman + b"HPFALLBACK"),
        "1.3.6.1.2.1.43.10.2.1.4.1.1": enc_ctr32(123456),
        "1.3.6.1.4.1.11.2.3.9.4.2.1.4.1.2.6.0": enc_int(100000),
        "1.3.6.1.4.1.11.2.3.9.4.2.1.4.1.2.7.0": enc_int(23456),
    }
    return mib


def fallback_mib():
    # No Printer-MIB serial at .17.1; only the HP private serial. No color/mono.
    mib = {
        "1.3.6.1.2.1.1.1.0": enc_oct("HP LaserJet 600 M603"),
        "1.3.6.1.2.1.25.3.2.1.3.2": enc_oct("HP LaserJet 600 M603"),  # not at index 1, forces walk
        "1.3.6.1.2.1.43.10.2.1.4.1.1": enc_ctr32(7777),
        "1.3.6.1.4.1.11.2.3.9.4.2.1.1.3.3.0": enc_oct(b"\x01\x15HPFB999"),
    }
    return mib


def bind_value(oid, encoded):
    return tlv(TAG_SEQ, enc_oid(oid) + encoded)


def next_oid(mib, oid):
    keys = sorted(mib.keys(), key=oid_key)
    target = oid_key(oid)
    for k in keys:
        if oid_key(k) > target:
            return k
    return None


def handle(packet, mib, community):
    tag, msg, _ = read_tlv(packet, 0)
    if tag != TAG_SEQ:
        return None
    i = 0
    _, ver_b, i = read_tlv(msg, i)
    _, comm_b, i = read_tlv(msg, i)
    pdu_tag, pdu, _ = read_tlv(msg, i)
    if comm_b.decode("ascii", "replace") != community:
        return None
    j = 0
    _, rid_b, j = read_tlv(pdu, j)
    _, err_b, j = read_tlv(pdu, j)
    _, eidx_b, j = read_tlv(pdu, j)
    _, vbl, j = read_tlv(pdu, j)
    rid = dec_int(rid_b)
    out_binds = b""
    k = 0
    while k < len(vbl):
        _, bind, k = read_tlv(vbl, k)
        b = 0
        _, oid_b, b = read_tlv(bind, b)
        _, _val, b = read_tlv(bind, b)
        oid = dec_oid(oid_b)
        if pdu_tag == TAG_GETNEXT:
            nxt = next_oid(mib, oid)
            if nxt is None:
                out_binds += bind_value(oid, tlv(TAG_ENDOFMIB, b""))
            else:
                out_binds += bind_value(nxt, mib[nxt])
        else:
            if oid in mib:
                out_binds += bind_value(oid, mib[oid])
            else:
                out_binds += bind_value(oid, tlv(TAG_NOSUCH_OBJ, b""))
    body = enc_int(rid) + enc_int(0) + enc_int(0) + tlv(TAG_SEQ, out_binds)
    pdu_out = tlv(TAG_GETRESP, body)
    return tlv(TAG_SEQ, enc_int(dec_int(ver_b)) + tlv(TAG_OCT, comm_b) + pdu_out)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--host", default="127.0.0.1")
    ap.add_argument("--port", type=int, default=11611)
    ap.add_argument("--community", default="public")
    ap.add_argument("--profile", choices=["default", "fallback"], default="default")
    ap.add_argument("--ready-file", default="")
    args = ap.parse_args()
    mib = default_mib() if args.profile == "default" else fallback_mib()
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.bind((args.host, args.port))
    if args.ready_file:
        with open(args.ready_file, "w") as f:
            f.write("ready {0} {1}\n".format(args.host, args.port))
    sys.stderr.write("snmp_sim listening on {0}:{1} profile={2}\n".format(args.host, args.port, args.profile))
    sys.stderr.flush()
    while True:
        data, addr = sock.recvfrom(65535)
        try:
            resp = handle(data, mib, args.community)
        except Exception as ex:
            sys.stderr.write("parse error from {0}: {1}\n".format(addr, ex))
            continue
        if resp:
            sock.sendto(resp, addr)


if __name__ == "__main__":
    main()
