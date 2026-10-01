#!/usr/bin/env python3
# Development tool. The real patcher lives in the app (NtdllPatcher.swift).
# This is the original Python version, kept for validating patches against
# new CrossOver builds.
import hashlib
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from resolve import PE, resolve, shell_vars  # noqa: E402

# A new build needs its ntdll hash added here and in build-ntdll.sh.
PAYLOAD_BY_CLEAN_SHA = {
    "04c7200b6645decb7c2d1ba6b0195abc9af83257072558d11aa72cc067ac3377": "detour2.bin",
    "94cc7c14c1e9dcf58ef501015c115f8405c73b2a65cefe31faa5d9e47f36e58b": "detour32.bin",
    "f4fa556a3dc20f6e966a803f5de554359227a61a24cd5b5a2ad88a427ceeec58": "detour2-fex.bin",
    "09474795d6f306163cebab6429819999fcff50e07dbc4b067a90ec4f74a3a7d7": "detour32-fex.bin",
    "7823d71fbce6c9947163bf8b96beb299eabb02878245bcaf6759f2a22e81f071": "detour64-fex.bin",
}

UNAMBIGUOUS_PAYLOAD = {0xaa64: "detour64-fex.bin"}
KNOWN_MACHINES = (0x8664, 0x14c, 0xaa64)


def default_payload(src, machine):
    with open(src, "rb") as f:
        digest = hashlib.sha256(f.read()).hexdigest()
    if digest in PAYLOAD_BY_CLEAN_SHA:
        return PAYLOAD_BY_CLEAN_SHA[digest]
    if machine in UNAMBIGUOUS_PAYLOAD:
        return UNAMBIGUOUS_PAYLOAD[machine]
    raise SystemExit(f"{src}: sha256 {digest} matches no known clean ntdll, and machine "
                     f"{machine:#x} has more than one detour, pass payload.bin as the "
                     f"third argument")


def main():
    if len(sys.argv) < 2:
        raise SystemExit(f"usage: {sys.argv[0]} <src ntdll.dll> [dst] [payload.bin]")
    src = sys.argv[1]
    dst = sys.argv[2] if len(sys.argv) > 2 else "ntdll.dll.patched"
    here = os.path.dirname(os.path.abspath(__file__))

    r = resolve(src)
    v = shell_vars(src)
    if r['machine'] not in KNOWN_MACHINES:
        raise SystemExit(f"{src}: machine {r['machine']:#x} carries no detour")
    payload_path = sys.argv[3] if len(sys.argv) > 3 \
        else os.path.join(here, default_payload(src, r['machine']))
    detour = open(payload_path, "rb").read()
    payload_rva = int(v['NP_PAYLOAD_RVA'], 16)
    fill = r['fill']
    sites = r.get('sites') or [r]

    pe = PE(src)
    d = bytearray(pe.d)
    cave_off = pe.off(payload_rva)

    if any(b != fill for b in d[cave_off:cave_off + len(detour)]):
        raise SystemExit(f"cave at {cave_off:#x} is not {fill:#02x} pad for {len(detour)} bytes")
    d[cave_off:cave_off + len(detour)] = detour

    hooks = []
    for site in sites:
        bm_off = pe.off(site['hookRVA'])
        stolen = bytes.fromhex(site['stolen'])
        if d[bm_off:bm_off + len(stolen)] != stolen:
            raise SystemExit(f"unexpected hook site at {site['hookRVA']:#x}: "
                             f"{d[bm_off:bm_off + len(stolen)].hex()}")
        if r['machine'] == 0xaa64:
            rel = payload_rva - site['hookRVA']
            if rel % 4 or not -(1 << 27) <= rel < (1 << 27):
                raise SystemExit(f"cave is {rel:#x} from the hook, out of bl range")
            patch = (0x94000000 | ((rel >> 2) & 0x03ffffff)).to_bytes(4, 'little')
        else:
            # E9 rel32 to the shim at the payload start
            rel = payload_rva - (site['hookRVA'] + 5)
            patch = b"\xE9" + rel.to_bytes(4, 'little', signed=True) + b"\xCC" * (len(stolen) - 5)
        assert len(patch) == len(stolen)
        d[bm_off:bm_off + len(patch)] = patch
        hooks.append((site, bm_off, rel, stolen))

    # patch in memory and write once, like a pro
    tmp = dst + ".tmp"
    with open(tmp, "wb") as f:
        f.write(d)
    os.replace(tmp, dst)

    print(f"patched {src} -> {dst}")
    print(f"  payload {os.path.basename(payload_path)}, {len(detour)} bytes at rva "
          f"{payload_rva:#x} (off {cave_off:#x}), cave pad {fill:#02x}")
    for site, bm_off, rel, stolen in hooks:
        print(f"  hook {site['hookRVA']:#x} (off {bm_off:#x}) branch rel {rel:#x} to cave "
              f"entry, stolen {stolen.hex()}")


if __name__ == "__main__":
    main()
