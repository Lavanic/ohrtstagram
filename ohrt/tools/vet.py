#!/usr/bin/env python3
"""Checks a decrypted Instagram IPA against Apple's own signature.

  vet.py <ipa>

An App Store app is signed by Apple, and the signature stays inside a
decrypted copy. It seals, with hashes:

  - every file in the bundle (pictures, plists, strings, nested frameworks)
  - every page of every binary, including the header that lists which
    libraries the app loads

So this can prove that nothing was added, removed or changed, with one
exception. Apple's page hashes were taken over the encrypted code, so the
decrypted code itself (the part FairPlay protected) has nothing left to be
compared with. Everything around it is checked; the code inside that range
is reported as "cannot be checked", never as verified.

Exit status 0 means every check that can be made passed.
"""
import hashlib
import os
import plistlib
import re
import struct
import subprocess
import sys
import tempfile
import zipfile

HERE = os.path.dirname(os.path.abspath(__file__))
APPLE_ROOT = os.path.join(HERE, "apple-root-ca.pem")

MH_MAGIC_64 = 0xFEEDFACF
FAT_MAGIC = 0xCAFEBABE
CPU_ARM64 = 0x0100000C
LC_SEGMENT_64 = 0x19
LC_CODE_SIGNATURE = 0x1D
LC_ENCRYPTION_INFO_64 = 0x2C
LC_LOAD_DYLIB = 0xC
LC_LOAD_WEAK_DYLIB = 0x80000018

CSMAGIC_SUPERBLOB = 0xFADE0CC0
CSMAGIC_CODEDIRECTORY = 0xFADE0C02
CSMAGIC_BLOBWRAPPER = 0xFADE0B01
SLOT_CODEDIRECTORY = 0
SLOT_ALTERNATE_FIRST = 0x1000
SLOT_ALTERNATE_LAST = 0x1005
SLOT_CMS = 0x10000

HASHES = {1: hashlib.sha1, 2: hashlib.sha256, 3: hashlib.sha256, 4: hashlib.sha384}
SPECIAL = {1: "Info.plist", 2: "requirements", 3: "resources seal", 5: "entitlements", 7: "entitlements (DER)"}


class Problem(Exception):
    pass


def macho_slice(data):
    """(offset, size) of the arm64 Mach-O in `data`, which may be a fat file."""
    if len(data) < 32:
        raise Problem("too small to be a binary")
    if struct.unpack_from(">I", data)[0] == FAT_MAGIC:
        for index in range(struct.unpack_from(">I", data, 4)[0]):
            cpu, _, offset, size, _ = struct.unpack_from(">5I", data, 8 + index * 20)
            if cpu == CPU_ARM64:
                return offset, size
        raise Problem("no arm64 slice")
    if struct.unpack_from("<I", data)[0] != MH_MAGIC_64:
        raise Problem("not a 64-bit Mach-O")
    return 0, len(data)


def is_macho(data):
    if len(data) < 4:
        return False
    return struct.unpack_from(">I", data)[0] == FAT_MAGIC or struct.unpack_from("<I", data)[0] == MH_MAGIC_64


class MachO:
    def __init__(self, data):
        self.offset, self.size = macho_slice(data)
        self.data = data[self.offset:self.offset + self.size]
        self.crypt = None  # (cryptoff, cryptsize, cryptid, file offset of the cryptid field)
        self.signature = None  # (dataoff, datasize)
        self.libraries = []
        self.segments = []  # (name, file offset, file size, [(section, offset, size)])
        count = struct.unpack_from("<I", self.data, 16)[0]
        at = 32
        for _ in range(count):
            command, size = struct.unpack_from("<II", self.data, at)
            if command == LC_SEGMENT_64:
                name = self.data[at + 8:at + 24].split(b"\0", 1)[0].decode(errors="replace")
                fileoff, filesize = struct.unpack_from("<QQ", self.data, at + 40)
                sections = []
                for index in range(struct.unpack_from("<I", self.data, at + 64)[0]):
                    base = at + 72 + index * 80
                    section = self.data[base:base + 16].split(b"\0", 1)[0].decode(errors="replace")
                    section_size, section_offset = struct.unpack_from("<Q", self.data, base + 40)[0], struct.unpack_from("<I", self.data, base + 48)[0]
                    # Zero-fill sections take no room in the file.
                    if section_offset and (struct.unpack_from("<I", self.data, base + 64)[0] & 0xFF) not in (1, 12, 18):
                        sections.append((section, section_offset, section_size))
                self.segments.append((name, fileoff, filesize, sections))
            elif command == LC_ENCRYPTION_INFO_64:
                cryptoff, cryptsize, cryptid = struct.unpack_from("<III", self.data, at + 8)
                self.crypt = (cryptoff, cryptsize, cryptid, at + 16)
            elif command == LC_CODE_SIGNATURE:
                self.signature = struct.unpack_from("<II", self.data, at + 8)
            elif command in (LC_LOAD_DYLIB, LC_LOAD_WEAK_DYLIB):
                start = struct.unpack_from("<I", self.data, at + 8)[0]
                self.libraries.append(self.data[at + start:at + size].split(b"\0", 1)[0].decode(errors="replace"))
            at += size

    def stray_code(self):
        """Bytes sitting where the encrypted part of the code segment should be empty.

        The header, which the signature does cover, fixes where every section
        of code starts and ends. The gaps between them are padding, and
        padding is zeros. Anything else there is the classic place to hide
        added code in a binary whose size cannot change.
        """
        if not self.crypt:
            return []
        crypt_start, crypt_end = self.crypt[0], self.crypt[0] + self.crypt[1]
        found = []
        for name, fileoff, filesize, sections in self.segments:
            if name != "__TEXT":
                continue
            edges = sorted((offset, offset + size) for _, offset, size in sections)
            gaps = [(a_end, b_start) for (_, a_end), (b_start, _) in zip(edges, edges[1:])]
            if edges:
                gaps.append((edges[-1][1], fileoff + filesize))
            for start, end in gaps:
                start, end = max(start, crypt_start), min(end, crypt_end)
                if end > start and self.data[start:end].strip(b"\0"):
                    found.append((start, end - start))
        return found

    def as_signed(self):
        """The bytes as Apple signed them: with the 'encrypted' flag set again."""
        if not self.crypt or self.crypt[2] != 0:
            return self.data
        patched = bytearray(self.data)
        struct.pack_into("<I", patched, self.crypt[3], 1)
        return bytes(patched)

    def blobs(self):
        if not self.signature:
            raise Problem("no code signature at all")
        start, size = self.signature
        blob = self.data[start:start + size]
        magic, _, count = struct.unpack_from(">III", blob)
        if magic != CSMAGIC_SUPERBLOB:
            raise Problem("the code signature is not in Apple's format")
        found = {}
        for index in range(count):
            kind, offset = struct.unpack_from(">II", blob, 12 + index * 8)
            length = struct.unpack_from(">I", blob, offset + 4)[0]
            found[kind] = blob[offset:offset + length]
        return found


class CodeDirectory:
    def __init__(self, blob):
        self.blob = blob
        (magic, _, self.version, _, self.hash_offset, ident_offset, self.special_count, self.code_count,
         self.code_limit, self.hash_size, self.hash_type, _, page_shift, _) = struct.unpack_from(">9IBBBBI", blob)
        if magic != CSMAGIC_CODEDIRECTORY:
            raise Problem("unexpected code directory")
        if self.hash_type not in HASHES:
            raise Problem(f"unknown hash type {self.hash_type}")
        self.page_size = 1 << page_shift if page_shift else 0
        self.identifier = blob[ident_offset:].split(b"\0", 1)[0].decode(errors="replace")
        self.team = None
        if self.version >= 0x20200:
            team_offset = struct.unpack_from(">I", blob, 48)[0]
            if team_offset:
                self.team = blob[team_offset:].split(b"\0", 1)[0].decode(errors="replace")
        if self.version >= 0x20300:
            limit64 = struct.unpack_from(">Q", blob, 56)[0]
            if limit64:
                self.code_limit = limit64

    def digest(self, data):
        return HASHES[self.hash_type](data).digest()[:self.hash_size]

    def code_slot(self, index):
        at = self.hash_offset + index * self.hash_size
        return self.blob[at:at + self.hash_size]

    def special_slot(self, number):
        if number > self.special_count:
            return None
        at = self.hash_offset - number * self.hash_size
        slot = self.blob[at:at + self.hash_size]
        return None if slot == bytes(self.hash_size) else slot

    def cdhash(self):
        return self.digest(self.blob)[:20]


def verify_cms(cms, signed_content):
    """Checks Apple's signature over a code directory. Returns the signers' names."""
    with tempfile.TemporaryDirectory() as work:
        cms_path, content_path = os.path.join(work, "cms.der"), os.path.join(work, "content.bin")
        with open(cms_path, "wb") as handle:
            handle.write(cms)
        with open(content_path, "wb") as handle:
            handle.write(signed_content)
        # The certificates are checked up to Apple's root. Their dates are
        # not: a signing certificate expires, the app it signed does not.
        result = subprocess.run(
            ["openssl", "cms", "-verify", "-inform", "DER", "-in", cms_path, "-content", content_path, "-binary",
             "-CAfile", APPLE_ROOT, "-purpose", "any", "-no_check_time", "-out", os.devnull],
            capture_output=True, text=True)
        if result.returncode != 0:
            raise Problem("Apple's signature does not verify: " + (result.stderr.strip().splitlines() or ["unknown"])[-1])
        names = subprocess.run(["openssl", "pkcs7", "-inform", "DER", "-in", cms_path, "-print_certs", "-noout"],
                               capture_output=True, text=True).stdout
    return re.findall(r"subject=.*?CN\s*=\s*([^,\n]+)", names)


def signed_cdhashes(cms):
    """The code directory hashes listed inside the signed part of the signature."""
    start = cms.find(b"<?xml")
    end = cms.find(b"</plist>", start)
    if start == -1 or end == -1:
        return []
    try:
        return [bytes(value) for value in plistlib.loads(cms[start:end + 8]).get("cdhashes", [])]
    except Exception:
        return []


def check_binary(name, data, bundle_files):
    """Verifies one binary. Returns (report lines, problems, cdhashes)."""
    lines, problems = [], []
    macho = MachO(data)
    blobs = macho.blobs()
    if SLOT_CODEDIRECTORY not in blobs:
        raise Problem("no code directory")
    directories = [CodeDirectory(blobs[SLOT_CODEDIRECTORY])]
    for slot in range(SLOT_ALTERNATE_FIRST, SLOT_ALTERNATE_LAST + 1):
        if slot in blobs:
            directories.append(CodeDirectory(blobs[slot]))

    if SLOT_CMS not in blobs or len(blobs[SLOT_CMS]) <= 8:
        raise Problem("the signature is ad hoc (no certificate): this binary was re-signed by someone")
    cms = blobs[SLOT_CMS][8:]
    signers = verify_cms(cms, directories[0].blob)
    if not any("Apple iPhone OS Application Signing" in signer for signer in signers):
        problems.append(f"signed, but not by the App Store ({', '.join(signers)})")
    listed = signed_cdhashes(cms)
    for directory in directories[1:]:
        if directory.cdhash() not in listed:
            problems.append("an alternate code directory is not covered by Apple's signature")

    signed = macho.as_signed()
    crypt_start, crypt_end = (macho.crypt[0], macho.crypt[0] + macho.crypt[1]) if macho.crypt else (0, 0)
    best = directories[-1]
    for directory in directories:
        matched = unverifiable = decrypted_but_matching = 0
        bad = []
        for index in range(directory.code_count):
            start = index * directory.page_size
            end = min(start + directory.page_size, directory.code_limit)
            in_crypt = start < crypt_end and end > crypt_start
            same = directory.digest(signed[start:end]) == directory.code_slot(index)
            if same:
                matched += 1
                decrypted_but_matching += in_crypt
            elif in_crypt:
                unverifiable += 1
            else:
                bad.append(index)
        if directory is best:
            total = directory.code_count
            lines.append(f"pages: {matched} of {total} match Apple's hashes, {unverifiable} are decrypted code that cannot be checked"
                         + (f", {len(bad)} DO NOT MATCH" if bad else ""))
        if bad:
            problems.append(f"{len(bad)} page(s) outside the encrypted range were changed (first at offset {bad[0] * directory.page_size:#x})")

        for number, label in SPECIAL.items():
            expected = directory.special_slot(number)
            if expected is None:
                continue
            if number == 1:
                content = bundle_files.get("Info.plist")
            elif number == 3:
                content = bundle_files.get("_CodeSignature/CodeResources")
            else:
                content = blobs.get(number)
            if content is None:
                problems.append(f"{label} is sealed by the signature but missing")
            elif directory.digest(content) != expected:
                problems.append(f"{label} does not match the signature")

    stray = macho.stray_code()
    if stray:
        problems.append(f"data in {len(stray)} gap(s) of the decrypted code that should be empty padding (first at {stray[0][0]:#x}, {stray[0][1]} bytes)")
    if macho.crypt is None:
        lines.append("never encrypted")
    elif macho.crypt[2] != 0:
        problems.append("still encrypted")
    lines.insert(0, f"signed by {signers[0] if signers else '?'}, team {best.team}, id {best.identifier}")
    return lines, problems, [directory.cdhash() for directory in directories], macho


def omitted(path, rules):
    """True if the seal's own rules leave this path out."""
    chosen, weight = None, -1
    for pattern, rule in rules.items():
        try:
            if not re.search(pattern, path):
                continue
        except re.error:
            continue
        this = rule.get("weight", 1) if isinstance(rule, dict) else 1
        if this > weight:
            chosen, weight = rule, this
    return isinstance(chosen, dict) and bool(chosen.get("omit"))


def check_bundle(archive, root, label, report, failures, depth=0):
    """Verifies one bundle (the app, a framework, an extension) and what is nested in it."""
    names = [name for name in archive.namelist() if name.startswith(root) and not name.endswith("/")]
    files = {name[len(root):]: name for name in names}
    read = lambda rel: archive.read(files[rel]) if rel in files else None

    info_data = read("Info.plist")
    if info_data is None:
        failures.append(f"{label}: no Info.plist")
        return None
    info = plistlib.loads(info_data)
    executable = info.get("CFBundleExecutable")
    binary = read(executable) if executable else None
    if binary is None:
        failures.append(f"{label}: its executable is missing")
        return None

    seal_data = read("_CodeSignature/CodeResources")
    sealed_context = {"Info.plist": info_data, "_CodeSignature/CodeResources": seal_data}
    try:
        lines, problems, cdhashes, macho = check_binary(label, binary, sealed_context)
    except Problem as problem:
        failures.append(f"{label}: {problem}")
        return None
    report.append(("  " * depth) + f"{label}: " + "; ".join(lines))
    failures.extend(f"{label}: {problem}" for problem in problems)

    if seal_data is None:
        return cdhashes
    seal = plistlib.loads(seal_data)
    sealed = seal.get("files2") or {}
    rules = seal.get("rules2") or seal.get("rules") or {}

    nested = sorted(path for path, entry in sealed.items() if isinstance(entry, dict) and "cdhash" in entry)
    covered = set()
    changed, missing, keys, decrypted = [], [], 0, []
    for path, entry in sealed.items():
        if isinstance(entry, dict) and "cdhash" in entry:
            continue
        covered.add(path)
        if isinstance(entry, dict) and "symlink" in entry:
            continue
        content = read(path)
        if content is None:
            # FairPlay's key files: a decrypted copy has no use for them.
            if "SC_Info/" in path:
                keys += 1
            elif not (isinstance(entry, dict) and entry.get("optional")):
                missing.append(path)
            continue
        expected = entry.get("hash2") if isinstance(entry, dict) else None
        if expected is not None:
            same = hashlib.sha256(content).digest() == bytes(expected)
        else:
            legacy = entry.get("hash") if isinstance(entry, dict) else entry
            same = legacy is None or hashlib.sha1(content).digest() == bytes(legacy)
        if same:
            continue
        # A binary that was encrypted cannot match a hash of the whole
        # file once it is decrypted. It carries a signature of its own,
        # which is checked page by page instead.
        if is_macho(content[:4096]):
            decrypted.append(path)
        else:
            changed.append(path)

    extra = []
    for rel in files:
        if rel in covered or rel == executable or rel.startswith("_CodeSignature/"):
            continue
        if any(rel.startswith(path + "/") for path in nested):
            continue
        # FairPlay's key files. Apple adds them after signing, and a
        # decrypted copy has no use for them.
        if rel.startswith("SC_Info/") or omitted(rel, rules):
            continue
        extra.append(rel)

    indent = "  " * (depth + 1)
    report.append(f"{indent}{len(covered)} sealed files: {len(covered) - len(changed) - len(missing) - keys - len(decrypted)} match"
                  + (f", {len(decrypted)} are decrypted binaries checked below" if decrypted else "")
                  + (f", {keys} FairPlay key files removed" if keys else "")
                  + (f", {len(changed)} CHANGED" if changed else "") + (f", {len(missing)} missing" if missing else "")
                  + (f", {len(extra)} NOT IN THE SEAL" if extra else ""))
    for path in decrypted:
        folder = path.rsplit("/", 1)[0] + "/" if "/" in path else ""
        context = {"Info.plist": read(folder + "Info.plist"), "_CodeSignature/CodeResources": read(folder + "_CodeSignature/CodeResources")}
        try:
            lines, problems, _, _ = check_binary(path, read(path), context)
            report.append(f"{indent}{path}: " + "; ".join(lines))
            failures.extend(f"{path}: {problem}" for problem in problems)
        except Problem as problem:
            failures.append(f"{path}: {problem}")
    for path in changed[:8]:
        failures.append(f"{label}: changed file {path}")
    for path in extra[:8]:
        failures.append(f"{label}: file that Apple did not sign: {path}")
    if missing:
        # Thinning for a device removes pictures; nothing dangerous, but
        # worth knowing.
        report.append(f"{indent}missing, e.g. {', '.join(missing[:4])}")

    for path in nested:
        inner = check_bundle(archive, root + path + "/", path, report, failures, depth + 1) if (path + "/Info.plist") in files else None
        if inner is None and (path + "/Info.plist") not in files:
            # A bare dylib, sealed by its own code directory.
            content = read(path)
            if content is None:
                failures.append(f"{label}: nested code {path} is missing")
                continue
            try:
                lines, problems, inner, _ = check_binary(path, content, {})
                report.append(f"{indent}{path}: " + "; ".join(lines))
                failures.extend(f"{path}: {problem}" for problem in problems)
            except Problem as problem:
                failures.append(f"{path}: {problem}")
                continue
        if inner is not None and bytes(sealed[path]["cdhash"]) not in inner:
            failures.append(f"{label}: {path} is not the one Apple sealed into the app")

    # Binaries the seal does not know about are exactly how a tampered copy
    # carries its payload.
    for rel, name in files.items():
        if rel == executable or rel in covered or any(rel.startswith(path + "/") or rel == path for path in nested):
            continue
        if is_macho(archive.read(name)[:4096]) and f"{label}: file that Apple did not sign: {rel}" not in failures:
            failures.append(f"{label}: unsealed binary {rel}")

    if depth == 0:
        unexpected = [lib for lib in macho.libraries if not lib.startswith(("/System/", "/usr/lib/", "@rpath/", "@executable_path/", "@loader_path/"))]
        if unexpected:
            failures.append(f"{label}: loads from an unusual place: {', '.join(unexpected)}")
    return cdhashes


def vet(path):
    report, failures = [], []
    with zipfile.ZipFile(path) as archive:
        entries = archive.infolist()
        for entry in entries:
            if entry.filename.startswith("/") or ".." in entry.filename.split("/"):
                failures.append(f"archive entry escapes its folder: {entry.filename}")
        roots = sorted({"/".join(e.filename.split("/")[:2]) + "/" for e in entries
                        if e.filename.startswith("Payload/") and e.filename.split("/")[1].endswith(".app")})
        if len(roots) != 1:
            raise Problem(f"expected one app in Payload/, found {len(roots)}")
        root = roots[0]
        info = plistlib.loads(archive.read(root + "Info.plist"))
        report.append(f"{info.get('CFBundleIdentifier')} {info.get('CFBundleShortVersionString')} ({info.get('CFBundleVersion')}), "
                      f"minimum iOS {info.get('MinimumOSVersion')}, {len(entries)} entries")
        outside = sorted({e.filename.split("/")[0] for e in entries if not e.filename.startswith("Payload/")})
        if outside:
            report.append("outside the app: " + ", ".join(outside))
        check_bundle(archive, root, root.split("/")[1], report, failures)
    return report, failures


if __name__ == "__main__":
    if len(sys.argv) != 2:
        print(__doc__.strip(), file=sys.stderr)
        sys.exit(2)
    try:
        report, failures = vet(sys.argv[1])
    except Problem as problem:
        report, failures = [], [str(problem)]
    for line in report:
        print(line)
    if failures:
        print(f"\nFAILED, {len(failures)} problem(s):")
        for failure in failures[:40]:
            print("  - " + failure)
        sys.exit(1)
    print("\nPASSED: everything Apple's signature covers is intact.")
    print("The decrypted code itself is outside what the signature can prove (see the top of vet.py).")
