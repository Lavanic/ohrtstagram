#!/usr/bin/env python3
"""Checks a tweak's hooks against the Instagram binary they are meant for.

  hookaudit.py <instagram.ipa> <tweak source dir> [more source dirs...]

Every `%hook Class` in the Logos sources names a class inside Instagram, and
every method in it names a selector. Instagram renames and removes both all
the time, and a hook whose class or selector is gone does nothing, silently.
This reads the class and selector names out of the decrypted binaries and
reports which hooks still have something to attach to.

It is a necessary check, not a sufficient one: a selector is looked for
anywhere in the app, not on the one class, and a method that still exists
may no longer do what the hook assumes.
"""
import os
import plistlib
import re
import struct
import sys
import zipfile

MH_MAGIC_64 = 0xFEEDFACF
FAT_MAGIC = 0xCAFEBABE
CPU_ARM64 = 0x0100000C
LC_SEGMENT_64 = 0x19


def arm64(data):
    if struct.unpack_from(">I", data)[0] == FAT_MAGIC:
        for index in range(struct.unpack_from(">I", data, 4)[0]):
            cpu, _, offset, size, _ = struct.unpack_from(">5I", data, 8 + index * 20)
            if cpu == CPU_ARM64:
                return data[offset:offset + size]
        return None
    return data if struct.unpack_from("<I", data)[0] == MH_MAGIC_64 else None


def section_strings(data, wanted):
    """NUL-separated strings of the named __TEXT sections."""
    found = {name: set() for name in wanted}
    count = struct.unpack_from("<I", data, 16)[0]
    at = 32
    for _ in range(count):
        command, size = struct.unpack_from("<II", data, at)
        if command == LC_SEGMENT_64:
            for index in range(struct.unpack_from("<I", data, at + 64)[0]):
                base = at + 72 + index * 80
                name = data[base:base + 16].split(b"\0", 1)[0].decode(errors="replace")
                if name in found:
                    length, offset = struct.unpack_from("<Q", data, base + 40)[0], struct.unpack_from("<I", data, base + 48)[0]
                    for piece in data[offset:offset + length].split(b"\0"):
                        if piece:
                            found[name].add(piece.decode(errors="replace"))
        at += size
    return found


def names_in_app(ipa):
    classes, selectors, swift = set(), set(), set()
    with zipfile.ZipFile(ipa) as archive:
        for entry in archive.infolist():
            if entry.is_dir() or entry.file_size < 4096:
                continue
            with archive.open(entry) as handle:
                head = handle.read(4)
            if len(head) < 4 or (struct.unpack(">I", head)[0] != FAT_MAGIC and struct.unpack("<I", head)[0] != MH_MAGIC_64):
                continue
            data = arm64(archive.read(entry))
            if data is None:
                continue
            found = section_strings(data, ("__objc_classname", "__cstring", "__objc_methname", "__swift5_reflstr", "__swift5_typeref"))
            # Newer builds keep class names among the ordinary C strings.
            classes |= found["__objc_classname"]
            classes |= {text for text in found["__cstring"] if len(text) < 200 and re.fullmatch(r"[A-Za-z_$][A-Za-z0-9_$.]*", text)}
            selectors |= found["__objc_methname"]
            # Swift types with no Objective-C name still leave their plain
            # names in the reflection strings.
            swift |= found["__swift5_reflstr"]
            for blob in found["__swift5_typeref"]:
                swift.update(re.findall(r"[A-Za-z_][A-Za-z0-9_]{3,}", blob))
    return classes, selectors, swift


def mangled(name):
    """`Module.Class` as the runtime stores it: _TtC6Module5Class."""
    if "." not in name:
        return name
    module, _, cls = name.partition(".")
    return f"_TtC{len(module)}{module}{len(cls)}{cls}"


HOOK = re.compile(r"^%hook\s+([A-Za-z_][A-Za-z0-9_.$]*)")
METHOD = re.compile(r"^\s*[-+]\s*\(")


def selector_of(declaration):
    """`- (void)a:(int)x b:(id)y {` gives `a:b:`."""
    body = re.sub(r"\([^()]*(\([^()]*\)[^()]*)*\)", " ", declaration)
    body = body.split("{", 1)[0].strip().lstrip("-+").strip().rstrip(";")
    parts = re.findall(r"([A-Za-z_][A-Za-z0-9_]*)\s*:", body)
    if parts:
        return "".join(part + ":" for part in parts)
    words = re.findall(r"[A-Za-z_][A-Za-z0-9_]*", body)
    return words[0] if words else None


def hooks_in(path):
    """Yields (class, [selectors]) for each %hook block in a Logos file."""
    current, selectors, new = None, [], False
    with open(path, errors="replace") as handle:
        for line in handle:
            stripped = line.strip()
            match = HOOK.match(stripped)
            if match:
                current, selectors = match.group(1), []
                continue
            if current is None:
                continue
            if stripped.startswith("%end"):
                yield current, selectors
                current = None
                continue
            if stripped.startswith("%new"):
                # A method the tweak adds; nothing in the app to find.
                new = True
                stripped = stripped[4:].strip()
                if not METHOD.match(stripped):
                    continue
            if METHOD.match(stripped):
                if not new:
                    selector = selector_of(stripped)
                    if selector:
                        selectors.append(selector)
                new = False


def main():
    ipa, roots = sys.argv[1], sys.argv[2:]
    classes, selectors, swift = names_in_app(ipa)
    with zipfile.ZipFile(ipa) as archive:
        info = next(name for name in archive.namelist() if re.fullmatch(r"Payload/[^/]+\.app/Info\.plist", name))
        version = plistlib.loads(archive.read(info)).get("CFBundleShortVersionString")
    print(f"Instagram {version}: {len(classes)} class names, {len(selectors)} selectors")

    def class_exists(name):
        if name.startswith(("UI", "NS", "CA", "AV", "WK", "SF", "PH", "MK", "CL", "UN", "_UI")):
            return True  # Apple's, not Instagram's
        if mangled(name) in classes or name in classes:
            return True
        return "." in name and name.split(".", 1)[1] in swift

    for root in roots:
        files = []
        for folder, _, names in os.walk(root):
            files += [os.path.join(folder, name) for name in names if name.endswith((".x", ".xm"))]
        total = alive = dead_class = dead_selector = 0
        dead = []
        for path in sorted(files):
            for cls, wanted in hooks_in(path):
                total += 1
                relative = os.path.relpath(path, root)
                if not class_exists(cls):
                    dead_class += 1
                    dead.append(f"class gone      {cls}  ({relative})")
                    continue
                missing = [selector for selector in wanted if selector not in selectors]
                if wanted and len(missing) == len(wanted):
                    dead_selector += 1
                    dead.append(f"selectors gone  {cls}: {', '.join(missing[:3])}  ({relative})")
                else:
                    alive += 1
                    if missing:
                        dead.append(f"partly          {cls}: missing {', '.join(missing[:3])}  ({relative})")
        print(f"\n{root}: {total} hooks in {len(files)} files")
        print(f"  {alive} still attach, {dead_class} name a class that is gone, {dead_selector} have no selector left")
        for line in dead:
            print("    " + line)


if __name__ == "__main__":
    if len(sys.argv) < 3:
        print(__doc__.strip(), file=sys.stderr)
        sys.exit(2)
    main()
