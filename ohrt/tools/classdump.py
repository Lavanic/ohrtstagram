#!/usr/bin/env python3
"""Reads the Objective-C classes out of a decrypted Instagram IPA.

  classdump.py build <ipa>      index every class, method, ivar and property
  classdump.py class <name>     print one class the way a header would
  classdump.py find  <regex>    class names that match
  classdump.py sel   <regex>    methods that match, with their classes

A tweak hooks Instagram by class and selector name, and those names are all
there is to go on: there are no headers. This turns the binary's own
metadata into something that can be searched, so a hook is written against
what the app really contains and not against what an older version had.

The index is a SQLite file, packages/classes-<version>.sqlite. Queries use
the version named in ohrt/instagram-version; set OHRT_IG=<version> to ask
another one.
"""
import os
import plistlib
import re
import sqlite3
import struct
import sys
import zipfile

HERE = os.path.dirname(os.path.abspath(__file__))
PACKAGES = os.path.normpath(os.path.join(HERE, "..", "..", "packages"))


def pinned_version():
    override = os.environ.get("OHRT_IG")
    if override:
        return override
    with open(os.path.join(HERE, "..", "instagram-version")) as handle:
        return handle.read().strip()


def db_path(version=None):
    return os.path.join(PACKAGES, f"classes-{version or pinned_version()}.sqlite")

MH_MAGIC_64 = 0xFEEDFACF
FAT_MAGIC = 0xCAFEBABE
CPU_ARM64 = 0x0100000C
LC_SEGMENT_64 = 0x19
LC_DYLD_CHAINED_FIXUPS = 0x80000034

RELATIVE_METHODS = 0x80000000
DIRECT_SELECTORS = 0x40000000


def arm64(data):
    if struct.unpack_from(">I", data)[0] == FAT_MAGIC:
        for index in range(struct.unpack_from(">I", data, 4)[0]):
            cpu, _, offset, size, _ = struct.unpack_from(">5I", data, 8 + index * 20)
            if cpu == CPU_ARM64:
                return data[offset:offset + size]
        return None
    return data if struct.unpack_from("<I", data)[0] == MH_MAGIC_64 else None


class Image:
    """One Mach-O, with what is needed to follow pointers inside it."""

    def __init__(self, data):
        self.data = data
        self.segments = []  # (vmaddr, vmsize, fileoff, filesize)
        self.sections = {}  # name -> (vmaddr, size, fileoff)
        self.pointer_format = None
        self.imports = []
        self.base = 0
        count = struct.unpack_from("<I", data, 16)[0]
        at = 32
        for _ in range(count):
            command, size = struct.unpack_from("<II", data, at)
            if command == LC_SEGMENT_64:
                name = data[at + 8:at + 24].split(b"\0", 1)[0]
                vmaddr, vmsize, fileoff, filesize = struct.unpack_from("<4Q", data, at + 24)
                self.segments.append((vmaddr, vmsize, fileoff, filesize))
                if name == b"__TEXT":
                    self.base = vmaddr
                for index in range(struct.unpack_from("<I", data, at + 64)[0]):
                    start = at + 72 + index * 80
                    section = data[start:start + 16].split(b"\0", 1)[0].decode(errors="replace")
                    address, length = struct.unpack_from("<QQ", data, start + 32)
                    offset = struct.unpack_from("<I", data, start + 48)[0]
                    self.sections.setdefault(section, (address, length, offset))
            elif command == LC_DYLD_CHAINED_FIXUPS:
                self._read_fixups(struct.unpack_from("<I", data, at + 8)[0])
            at += size
        self._strings = {}

    def _read_fixups(self, start):
        data = self.data
        _, starts, imports, symbols, count, import_format, _ = struct.unpack_from("<7I", data, start)
        segment_count = struct.unpack_from("<I", data, start + starts)[0]
        for index in range(segment_count):
            offset = struct.unpack_from("<I", data, start + starts + 4 + index * 4)[0]
            if offset:
                self.pointer_format = struct.unpack_from("<H", data, start + starts + offset + 6)[0]
                break
        size = {1: 4, 2: 8, 3: 16}.get(import_format)
        if size is None:
            return
        for index in range(count):
            at = start + imports + index * size
            if import_format == 3:
                name_offset = struct.unpack_from("<Q", data, at)[0] >> 32
            else:
                name_offset = struct.unpack_from("<I", data, at)[0] >> 9
            end = data.index(b"\0", start + symbols + name_offset)
            self.imports.append(data[start + symbols + name_offset:end].decode(errors="replace"))

    def offset(self, address):
        for vmaddr, vmsize, fileoff, filesize in self.segments:
            if vmaddr <= address < vmaddr + vmsize:
                delta = address - vmaddr
                return fileoff + delta if delta < filesize else None
        return None

    def pointer(self, address):
        """What the pointer stored at `address` refers to.

        Returns an address inside this image, the name of an imported
        symbol, or None.
        """
        at = self.offset(address)
        if at is None:
            return None
        raw = struct.unpack_from("<Q", self.data, at)[0]
        if raw == 0:
            return None
        if self.pointer_format in (2, 6):
            if raw >> 63:
                ordinal = raw & 0xFFFFFF
                return self.imports[ordinal] if ordinal < len(self.imports) else None
            target = (raw & 0xFFFFFFFFF) | (((raw >> 36) & 0xFF) << 56)
            return target + self.base if self.pointer_format == 6 else target
        if self.pointer_format is None:
            return raw
        return None

    def string(self, address):
        if not isinstance(address, int):
            return None
        cached = self._strings.get(address)
        if cached is None:
            at = self.offset(address)
            if at is None:
                return None
            end = self.data.find(b"\0", at, at + 4096)
            if end == -1:
                return None
            cached = self._strings[address] = self.data[at:end].decode(errors="replace")
        return cached

    def u32(self, address):
        at = self.offset(address)
        return None if at is None else struct.unpack_from("<I", self.data, at)[0]

    def i32(self, address):
        at = self.offset(address)
        return None if at is None else struct.unpack_from("<i", self.data, at)[0]

    def pointers_in(self, section):
        if section not in self.sections:
            return
        address, length, _ = self.sections[section]
        for index in range(length // 8):
            yield self.pointer(address + index * 8)

    def methods(self, address):
        """(selector, type encoding) for each entry of a method list."""
        if not isinstance(address, int) or address & 1:
            return
        header, count = self.u32(address), self.u32(address + 4)
        if header is None or count is None or count > 100000:
            return
        entry_size = header & 0xFFFC
        entry = address + 8
        for _ in range(count):
            if header & RELATIVE_METHODS:
                name_at = entry + self.i32(entry)
                name = self.string(name_at) if header & DIRECT_SELECTORS else self.string(self.pointer(name_at))
                types = self.string(entry + 4 + self.i32(entry + 4))
            else:
                name = self.string(self.pointer(entry))
                types = self.string(self.pointer(entry + 8))
            if name:
                yield name, types or ""
            entry += entry_size

    def ivars(self, address):
        if not isinstance(address, int):
            return
        entry_size, count = self.u32(address), self.u32(address + 4)
        if not entry_size or count is None or count > 100000:
            return
        for index in range(count):
            entry = address + 8 + index * entry_size
            name = self.string(self.pointer(entry + 8))
            if name:
                yield name, self.string(self.pointer(entry + 16)) or ""

    def properties(self, address):
        if not isinstance(address, int):
            return
        entry_size, count = self.u32(address), self.u32(address + 4)
        if not entry_size or count is None or count > 100000:
            return
        for index in range(count):
            entry = address + 8 + index * entry_size
            name = self.string(self.pointer(entry))
            if name:
                yield name, self.string(self.pointer(entry + 8)) or ""

    def class_ro(self, class_address):
        data = self.pointer(class_address + 32)
        return data & ~7 if isinstance(data, int) else None

    def class_name(self, reference):
        """The name of a class given a pointer to it or an imported symbol."""
        if isinstance(reference, str):
            return re.sub(r"^_OBJC_(META)?CLASS_\$_", "", reference)
        if isinstance(reference, int):
            ro = self.class_ro(reference)
            if ro is not None:
                return self.string(self.pointer(ro + 24))
        return None


SWIFT_NAME = re.compile(r"^_Tt(?:C|GC)(\d+)")


def swift_alias(name):
    """`_TtC6Module5Class` as `Module.Class`, which is how Logos is given it."""
    if not name.startswith("_TtC"):
        return None
    rest, parts = name[4:], []
    while rest and rest[0].isdigit():
        digits = re.match(r"\d+", rest).group(0)
        length = int(digits)
        parts.append(rest[len(digits):len(digits) + length])
        rest = rest[len(digits) + length:]
    return ".".join(parts) if len(parts) == 2 and not rest else None


def read_image(image, label, rows):
    classes, methods, ivars, properties = rows
    seen = set()
    for section in ("__objc_classlist", "__objc_nlclslist"):
        for address in image.pointers_in(section):
            if not isinstance(address, int) or address in seen:
                continue
            seen.add(address)
            ro = image.class_ro(address)
            if ro is None:
                continue
            name = image.string(image.pointer(ro + 24))
            if not name:
                continue
            classes.append((name, image.class_name(image.pointer(address + 8)), label, swift_alias(name)))
            for selector, types in image.methods(image.pointer(ro + 32)):
                methods.append((name, "-", selector, types, None))
            meta = image.pointer(address)
            meta_ro = image.class_ro(meta) if isinstance(meta, int) else None
            if meta_ro is not None:
                for selector, types in image.methods(image.pointer(meta_ro + 32)):
                    methods.append((name, "+", selector, types, None))
            for ivar, kind in image.ivars(image.pointer(ro + 48)):
                ivars.append((name, ivar, kind))
            for prop, attributes in image.properties(image.pointer(ro + 64)):
                properties.append((name, prop, attributes))

    for section in ("__objc_catlist", "__objc_catlist2", "__objc_nlcatlist"):
        for address in image.pointers_in(section):
            if not isinstance(address, int):
                continue
            category = image.string(image.pointer(address)) or ""
            name = image.class_name(image.pointer(address + 8))
            if not name:
                continue
            for selector, types in image.methods(image.pointer(address + 16)):
                methods.append((name, "-", selector, types, category))
            for selector, types in image.methods(image.pointer(address + 24)):
                methods.append((name, "+", selector, types, category))
            for prop, attributes in image.properties(image.pointer(address + 40)):
                properties.append((name, prop, attributes))


def build(ipa):
    rows = ([], [], [], [])
    with zipfile.ZipFile(ipa) as archive:
        info = next(name for name in archive.namelist() if re.fullmatch(r"Payload/[^/]+\.app/Info\.plist", name))
        path = db_path(plistlib.loads(archive.read(info))["CFBundleShortVersionString"])
        for entry in archive.infolist():
            if entry.is_dir() or entry.file_size < 4096 or ".appex/" in entry.filename:
                continue
            with archive.open(entry) as handle:
                head = handle.read(4)
            if len(head) < 4 or (struct.unpack(">I", head)[0] != FAT_MAGIC and struct.unpack("<I", head)[0] != MH_MAGIC_64):
                continue
            data = arm64(archive.read(entry))
            if data is None:
                continue
            label = entry.filename.rsplit("/", 1)[-1]
            before = len(rows[0])
            read_image(Image(data), label, rows)
            print(f"  {label}: {len(rows[0]) - before} classes")

    os.makedirs(PACKAGES, exist_ok=True)
    if os.path.exists(path):
        os.remove(path)
    db = sqlite3.connect(path)
    db.executescript("""
        create table classes (name text, super text, image text, alias text);
        create table methods (class text, kind text, sel text, types text, category text);
        create table ivars (class text, name text, type text);
        create table props (class text, name text, attrs text);
    """)
    classes, methods, ivars, properties = rows
    db.executemany("insert into classes values (?,?,?,?)", classes)
    db.executemany("insert into methods values (?,?,?,?,?)", methods)
    db.executemany("insert into ivars values (?,?,?)", ivars)
    db.executemany("insert into props values (?,?,?)", properties)
    db.executescript("""
        create index classes_name on classes (name);
        create index classes_alias on classes (alias);
        create index methods_class on methods (class);
        create index methods_sel on methods (sel);
        create index ivars_class on ivars (class);
        create index props_class on props (class);
    """)
    db.commit()
    print(f"{len(classes)} classes, {len(methods)} methods, {len(ivars)} ivars, {len(properties)} properties -> {os.path.relpath(path)}")


def open_db(path=None):
    path = path or db_path()
    if not os.path.exists(path):
        sys.exit(f"no index at {path}; run: classdump.py build <ipa>")
    db = sqlite3.connect(path)
    db.create_function("regexp", 2, lambda pattern, value: value is not None and re.search(pattern, value) is not None)
    return db


def resolve(db, name):
    """The stored name of a class given its plain or `Module.Class` name."""
    row = db.execute("select name from classes where name = ? or alias = ? limit 1", (name, name)).fetchone()
    return row[0] if row else None


def ancestors(db, name):
    """`name` and its superclasses, as far as the app's own classes go."""
    chain = []
    while name and name not in chain:
        chain.append(name)
        row = db.execute("select super from classes where name = ? limit 1", (name,)).fetchone()
        if row is None:
            break
        name = row[0]
    return chain


TYPE_NAMES = {"v": "void", "@": "id", "B": "BOOL", "c": "BOOL", "q": "long long", "Q": "unsigned long long", "i": "int",
              "I": "unsigned int", "d": "double", "f": "float", ":": "SEL", "#": "Class", "*": "char *", "s": "short",
              "S": "unsigned short", "l": "long", "L": "unsigned long", "C": "unsigned char", "@?": "id /* block */"}


def split_types(encoding):
    """An Objective-C type encoding as a list of types: return type first."""
    types, at = [], 0
    while at < len(encoding):
        start = at
        while at < len(encoding) and encoding[at] in "rnNoORV":
            at += 1
        if at >= len(encoding):
            break
        char = encoding[at]
        if char in "{(":
            depth, close = 0, {"{": "}", "(": ")"}[char]
            while at < len(encoding):
                if encoding[at] == char:
                    depth += 1
                elif encoding[at] == close:
                    depth -= 1
                    if depth == 0:
                        break
                at += 1
            at += 1
        elif char == "^":
            while at < len(encoding) and encoding[at] == "^":
                at += 1
            if at < len(encoding) and encoding[at] in "{(":
                rest = split_types(encoding[at:])
                at += len(rest[0]) if rest else 1
            else:
                at += 1
        elif char == "@":
            at += 1
            if at < len(encoding) and encoding[at] == "?":
                at += 1
            elif at < len(encoding) and encoding[at] == '"':
                at = encoding.index('"', at + 1) + 1
        elif char == "[":
            at = encoding.index("]", at) + 1
        else:
            at += 1
        types.append(encoding[start:at])
        while at < len(encoding) and encoding[at].isdigit():
            at += 1
    return types


def readable(code):
    code = code.lstrip("rnNoORV")
    if code in TYPE_NAMES:
        return TYPE_NAMES[code]
    if code.startswith('@"'):
        return code[2:-1] + " *"
    if code.startswith("{"):
        return "struct " + re.match(r"\{([^=}]*)", code).group(1)
    if code.startswith("^"):
        return readable(code[1:]) + " *"
    return code


def declaration(kind, selector, encoding):
    types = split_types(encoding)
    result = readable(types[0]) if types else "?"
    arguments = [readable(code) for code in types[3:]]
    parts = selector.split(":")
    if ":" not in selector:
        return f"{kind} ({result}){selector};"
    pieces = [f"{part}:({arguments[index] if index < len(arguments) else '?'})arg{index + 1}"
              for index, part in enumerate(parts[:-1])]
    return f"{kind} ({result}){' '.join(pieces)};"


def show_class(db, wanted):
    name = resolve(db, wanted)
    if name is None:
        sys.exit(f"no class named {wanted}")
    row = db.execute("select super, image, alias from classes where name = ?", (name,)).fetchone()
    chain = ancestors(db, name)
    last = db.execute("select super from classes where name = ?", (chain[-1],)).fetchone()
    tail = [last[0]] if last and last[0] and last[0] not in chain else []
    print(f"// {row[1]}" + (f"   ({row[2]})" if row[2] else ""))
    print(f"@interface {' : '.join(chain + tail)}")
    for ivar, kind in db.execute("select name, type from ivars where class = ?", (name,)):
        print(f"    {readable(kind) if kind else '?'} {ivar};")
    for prop, attributes in db.execute("select name, attrs from props where class = ? order by name", (name,)):
        kind = attributes.split(",", 1)[0][1:]
        print(f"@property {readable(kind) if kind else '?'} {prop};")
    for kind, selector, types, category in db.execute(
            "select kind, sel, types, category from methods where class = ? order by kind, sel", (name,)):
        print(declaration(kind, selector, types) + (f"  // ({category})" if category else ""))
    print("@end")


def main(argv):
    if len(argv) < 3:
        print(__doc__.strip(), file=sys.stderr)
        return 2
    command, argument = argv[1], argv[2]
    if command == "build":
        build(argument)
    elif command == "class":
        show_class(open_db(), argument)
    elif command == "find":
        for name, parent, image in open_db().execute(
                "select name, super, image from classes where name regexp ? order by name", (argument,)):
            print(f"{name} : {parent}" + ("" if image == "Instagram" else f"   [{image}]"))
    elif command == "sel":
        for cls, kind, selector in open_db().execute(
                "select class, kind, sel from methods where sel regexp ? order by sel, class", (argument,)):
            print(f"{kind}[{cls} {selector}]")
    else:
        print(__doc__.strip(), file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
