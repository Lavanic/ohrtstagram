#!/usr/bin/env python3
"""Tampers with a real Instagram IPA in ways a bad copy might, and checks
that ohrt/tools/vet.py refuses every one.

  vet_test.py <decrypted instagram ipa>

Each case is a cut-down copy of the IPA (the app's binary, one framework and
a handful of files) with one thing changed. The untouched cut-down copy has
to pass, or the cases prove nothing. The last case changes a byte inside the
range FairPlay encrypted; vet.py cannot see that, says so itself, and the
test holds it to that.
"""
import os
import plistlib
import shutil
import struct
import subprocess
import sys
import tempfile
import warnings
import zipfile

HERE = os.path.dirname(os.path.abspath(__file__))
VET = os.path.join(HERE, "..", "tools", "vet.py")
APP = "Payload/Instagram.app/"


def load_base(ipa):
    """A few of the IPA's files, enough to exercise every check."""
    with zipfile.ZipFile(ipa) as archive:
        names = archive.namelist()
        frameworks = sorted({name.split("/")[3] for name in names if name.startswith(APP + "Frameworks/") and name.count("/") > 3})
        # The smallest two frameworks: one to tamper with, one to swap in.
        sizes = {}
        for framework in frameworks:
            binary = APP + "Frameworks/" + framework + "/" + framework.rsplit(".", 1)[0]
            if binary in names:
                sizes[framework] = archive.getinfo(binary).file_size
        small = sorted(sizes, key=sizes.get)[:2]
        wanted = {APP + "Info.plist", APP + "Instagram", APP + "_CodeSignature/CodeResources", APP + "PkgInfo"}
        for framework in small:
            wanted |= {name for name in names if name.startswith(APP + "Frameworks/" + framework + "/") and not name.endswith("/")}
        extras = [name for name in names if name.startswith(APP) and name.endswith((".strings", ".json")) and name.count("/") == 3][:3]
        wanted |= set(extras)
        files = {name: archive.read(name) for name in wanted if name in names}
    return files, small, extras


def write(path, files, extra_entries=()):
    # One case writes the same name twice on purpose.
    warnings.simplefilter("ignore", UserWarning)
    with zipfile.ZipFile(path, "w", zipfile.ZIP_STORED) as archive:
        for name, data in files.items():
            archive.writestr(name, data)
        for info, data in extra_entries:
            archive.writestr(info, data)


def vet(path):
    result = subprocess.run([sys.executable, "-I", VET, path], capture_output=True, text=True)
    return result.returncode, result.stdout + result.stderr


def macho_fields(data):
    """(offset of the first byte after the load commands, cryptoff, cryptsize, signature offset)."""
    count = struct.unpack_from("<I", data, 16)[0]
    at, crypt, signature = 32, None, None
    for _ in range(count):
        command, size = struct.unpack_from("<II", data, at)
        if command == 0x2C:
            crypt = struct.unpack_from("<II", data, at + 8)
        elif command == 0x1D:
            signature = struct.unpack_from("<I", data, at + 8)[0]
        at += size
    return at, crypt, signature


def flipped(data, offset):
    changed = bytearray(data)
    changed[offset] ^= 0xFF
    return bytes(changed)


def main():
    if len(sys.argv) != 2:
        print(__doc__.strip(), file=sys.stderr)
        return 2
    base, frameworks, extras = load_base(sys.argv[1])
    binary = base[APP + "Instagram"]
    header_end, crypt, signature = macho_fields(binary)
    first, second = frameworks
    first_binary = APP + "Frameworks/" + first + "/" + first.rsplit(".", 1)[0]
    second_binary = APP + "Frameworks/" + second + "/" + second.rsplit(".", 1)[0]

    def with_change(name, data):
        files = dict(base)
        files[name] = data
        return files, ()

    link = zipfile.ZipInfo(APP + "link")
    link.external_attr = 0o120777 << 16
    twice = zipfile.ZipInfo(APP + "PkgInfo")
    info = plistlib.loads(base[APP + "Info.plist"])
    renamed = dict(info, CFBundleDisplayName="Instagram!")

    # (what is done, the files, extra entries, must vet.py refuse it)
    cases = [
        ("nothing changed", dict(base), (), False),
        ("a resource file edited", *with_change(extras[0], base[extras[0]] + b" "), True),
        ("a file added", *with_change(APP + "added.txt", b"hello"), True),
        ("a dylib added", *with_change(APP + "Frameworks/added.dylib", base[first_binary]), True),
        ("Info.plist edited", *with_change(APP + "Info.plist", plistlib.dumps(renamed, fmt=plistlib.FMT_BINARY)), True),
        ("the list of sealed files edited", *with_change(APP + "_CodeSignature/CodeResources", base[APP + "_CodeSignature/CodeResources"].replace(b"<key>files2</key>", b"<key>files3</key>")), True),
        ("a load command edited", *with_change(APP + "Instagram", flipped(binary, header_end - 9)), True),
        ("a byte of data after the code edited", *with_change(APP + "Instagram", flipped(binary, crypt[0] + crypt[1] + 0x8000)), True),
        ("the signature's own bytes edited", *with_change(APP + "Instagram", flipped(binary, signature + 64)), True),
        ("one framework's binary swapped for another's", *with_change(first_binary, base[second_binary]), True),
        ("a framework's binary edited after its code", *with_change(first_binary, flipped(base[first_binary], len(base[first_binary]) // 2 + 0x4000)), None),
        ("a symbolic link added", dict(base), ((link, b"/etc/passwd"),), True),
        ("a second entry for the same file", dict(base), ((twice, b"APPL????"),), True),
        ("a byte of decrypted code edited (the known blind spot)", *with_change(APP + "Instagram", flipped(binary, crypt[0] + crypt[1] // 2)), False),
    ]

    work = tempfile.mkdtemp(prefix="vet-test-")
    failures = 0
    try:
        for label, files, extra_entries, must_refuse in cases:
            path = os.path.join(work, "case.ipa")
            write(path, files, extra_entries)
            status, output = vet(path)
            refused = status != 0
            if must_refuse is None:
                # Depends on where the byte lands; only reported.
                print(f"  note  {label}: {'refused' if refused else 'passed'}")
            elif refused == must_refuse:
                print(f"  ok    {label}: {'refused' if refused else 'passed'}")
            else:
                failures += 1
                print(f"  FAIL  {label}: {'refused' if refused else 'passed'}, expected {'refused' if must_refuse else 'passed'}")
                print("        " + "\n        ".join(output.strip().splitlines()[-6:]))
            os.remove(path)
    finally:
        shutil.rmtree(work, ignore_errors=True)
    print("vet: all cases behaved" if not failures else f"vet: {failures} case(s) did not")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
