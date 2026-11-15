#!/usr/bin/env python3
"""Shows what one Instagram method does, without running it.

  calls.py '-[IGTabBarController _directInboxButtonPressed]'
  calls.py '+[IGMainAppSurfaceIntent directInbox]'
  calls.py --raw '-[...]'        also list calls into unnamed functions
  calls.py --to <selector>       the methods that send a message
  calls.py --uses <string>       the methods that refer to a string constant

It reads the method's machine code out of the decrypted IPA and lists, in
order, the messages it sends, the strings and classes it refers to and the
system functions it calls. That is enough to answer the questions a hook
depends on: which initialiser a screen uses, what a flag is compared with,
what a method does before it returns.

It is a reading of straight-line code, not a decompiler: it does not follow
branches or say which object a message goes to.

Uses the IPA and the index for the version in ohrt/instagram-version
(OHRT_IG=<version> for another); run `classdump.py build <ipa>` first.
"""
import glob
import os
import re
import sqlite3
import struct
import sys
import zipfile

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from classdump import PACKAGES, Image, arm64, db_path, pinned_version  # noqa: E402

RET = 0xD65F03C0
NOISE = re.compile(r"^_(objc_(retain|release|autorelease|storeStrong|storeWeak|loadWeak|destroyWeak|copyWeak|unsafeClaim|opt_self|alloc_init|alloc|opt_new|msgSend|claimAutoreleasedReturnValue)"
                   r"|swift_(retain|release|bridgeObject|unknownObject|beginAccess|endAccess|isUniquelyReferenced|once)"
                   r"|__stack_chk|memcpy|memset|bzero|free|malloc)")


def sign(value, bits):
    return value - (1 << bits) if value & (1 << (bits - 1)) else value


class Code(Image):
    def __init__(self, data):
        super().__init__(data)
        self.ranges = {name: (address, address + length) for name, (address, length, _) in self.sections.items()}

    def end_of(self, start, limit):
        """Where the function that begins at `start` ends.

        The binary is stripped of its function table, so this walks the
        code: a function is over at a return or a jump away that no branch
        inside it has jumped past. `limit` is the next method known to
        start after this one.
        """
        furthest = start
        address = start
        while address < limit:
            word = self.word(address)
            if word is None:
                break
            target = None
            if word & 0xFF000010 == 0x54000000 or word & 0x7E000000 == 0x34000000:  # b.cond, cbz/cbnz
                target = address + sign((word >> 5) & 0x7FFFF, 19) * 4
            elif word & 0x7E000000 == 0x36000000:  # tbz/tbnz
                target = address + sign((word >> 5) & 0x3FFF, 14) * 4
            elif word & 0xFC000000 == 0x14000000:  # b
                target = address + sign(word & 0x3FFFFFF, 26) * 4
                inside = start <= target < limit and self.section_of(target) == "__text" and abs(target - address) < 0x10000
                if not inside:
                    target = None
                    if address >= furthest:
                        return address + 4
            if target is not None and target > furthest:
                furthest = target
            if (word == RET or word & 0xFFFFFC1F == 0xD61F0000) and address >= furthest:  # ret, br
                return address + 4
            address += 4
        return limit

    def section_of(self, address):
        for name, (low, high) in self.ranges.items():
            if low <= address < high:
                return name
        return None

    def word(self, address):
        at = self.offset(address)
        return None if at is None else struct.unpack_from("<I", self.data, at)[0]

    def cfstring(self, address):
        text = self.string(self.pointer(address + 16))
        return text

    def describe(self, address):
        """What an address the code refers to is."""
        section = self.section_of(address)
        if section == "__cstring":
            return f'"{self.string(address)}"'
        if section == "__cfstring":
            return f'@"{self.cfstring(address)}"'
        if section == "__objc_methname":
            return f"@selector({self.string(address)})"
        if section == "__objc_selrefs":
            return f"@selector({self.string(self.pointer(address))})"
        if section in ("__objc_classrefs", "__objc_superrefs"):
            target = self.pointer(address)
            return f"class {self.class_name(target)}"
        if section in ("__got", "__auth_got", "__la_symbol_ptr"):
            target = self.pointer(address)
            return f"{target}" if isinstance(target, str) else None
        if section == "__objc_ivar":
            return None
        return None

    def stub_selector(self, address):
        """The selector an objc_msgSend stub sends, or None."""
        first, second = self.word(address), self.word(address + 4)
        if first is None or second is None:
            return None
        if first & 0x9F000000 != 0x90000000 or second & 0xFFC00000 != 0xF9400000:
            return None
        page = (address & ~0xFFF) + (sign((((first >> 5) & 0x7FFFF) << 2) | ((first >> 29) & 3), 21) << 12)
        return self.string(self.pointer(page + ((second >> 10) & 0xFFF) * 8))

    def stub_symbol(self, address):
        """The imported function a symbol stub jumps to, or None."""
        first, second = self.word(address), self.word(address + 4)
        if first is None or second is None:
            return None
        if first & 0x9F000000 != 0x90000000 or second & 0xFFC00000 != 0xF9400000:
            return None
        page = (address & ~0xFFF) + (sign((((first >> 5) & 0x7FFFF) << 2) | ((first >> 29) & 3), 21) << 12)
        target = self.pointer(page + ((second >> 10) & 0xFFF) * 8)
        return target if isinstance(target, str) else None


def is_frame_setup(word):
    """stp x29, x30, [sp, ...]: how a real function begins."""
    return word & 0xFFC07FFF in (0xA9007BFD, 0xA9807BFD)


def trace(code, db, image, start, raw=False):
    """What the function at `start` refers to and calls, in address order.

    Instagram is built with heavy outlining: a method is mostly calls into
    tiny shared fragments, and calls to far code go through three-instruction
    islands. Fragments are read in place, as if they had never been cut
    out, and islands are followed to where they land.
    """
    following = db.execute("select min(code) from methods where image = ? and code > ? and code < ?",
                           (image, start, start + 0x40000)).fetchone()[0]
    end = code.end_of(start, following or start + 0x40000)
    lines, pages = [], {}

    def island(target):
        first, second, third = code.word(target), code.word(target + 4), code.word(target + 8)
        if None in (first, second, third):
            return target
        if first & 0x9F00001F == 0x90000010 and second & 0xFFC003FF == 0x91000210 and third == 0xD61F0200:
            page = (target & ~0xFFF) + (sign((((first >> 5) & 0x7FFFF) << 2) | ((first >> 29) & 3), 21) << 12)
            return page + ((second >> 10) & 0xFFF)
        return target

    def is_fragment(target):
        for index in range(24):
            word = code.word(target + index * 4)
            if word is None or is_frame_setup(word):
                return False
            if word == RET or word & 0xFC000000 == 0x14000000:
                return True
        return False

    def refer(origin, address):
        section = code.section_of(address)
        if section == "__objc_ivar":
            row = db.execute("select class, name from ivars where image = ? and slot = ? limit 1", (image, address)).fetchone()
            what = f"ivar {row[1]}   ({row[0]})" if row else None
        else:
            what = code.describe(address)
        if what:
            lines.append((origin, what))

    def walk(address, stop, depth, origin):
        steps = 0
        while (address < stop if stop else steps < 96):
            word = code.word(address)
            if word is None:
                return
            here = address if depth == 0 else origin
            if word & 0x9F000000 == 0x90000000:  # adrp
                pages[word & 31] = (address & ~0xFFF) + (sign((((word >> 5) & 0x7FFFF) << 2) | ((word >> 29) & 3), 21) << 12)
            elif word & 0xFFC00000 == 0x91000000:  # add x, x, #imm
                if (word >> 5) & 31 in pages:
                    refer(here, pages[(word >> 5) & 31] + ((word >> 10) & 0xFFF))
                    pages.pop(word & 31, None)
            elif word & 0xFFC00000 == 0xF9400000:  # ldr x, [x, #imm]
                if (word >> 5) & 31 in pages:
                    refer(here, pages[(word >> 5) & 31] + ((word >> 10) & 0xFFF) * 8)
                pages.pop(word & 31, None)
            elif word & 0xFFC00000 in (0xB9800000, 0xB9400000):  # ldrsw / ldr w: ivar offsets
                if (word >> 5) & 31 in pages:
                    refer(here, pages[(word >> 5) & 31] + ((word >> 10) & 0xFFF) * 4)
                pages.pop(word & 31, None)
            elif word & 0x7C000000 == 0x14000000:  # b / bl
                is_call = bool(word & 0x80000000)
                target = address + sign(word & 0x3FFFFFF, 26) * 4
                local = depth == 0 and start <= target < end
                if not local:
                    target = island(target)
                    section = code.section_of(target)
                    if section == "__objc_stubs":
                        lines.append((here, f"[... {code.stub_selector(target)}]"))
                    elif section in ("__stubs", "__auth_stubs"):
                        symbol = code.stub_symbol(target)
                        if symbol and (raw or not NOISE.match(symbol)):
                            lines.append((here, f"{symbol}()"))
                    else:
                        row = db.execute("select class, kind, sel from methods where image = ? and code = ? limit 1",
                                         (image, target)).fetchone()
                        if row:
                            lines.append((here, f"{row[1]}[{row[0]} {row[2]}]   (called directly)"))
                        elif depth < 10 and is_fragment(target):
                            walk(target, None, depth + 1, here)
                        elif raw:
                            lines.append((here, f"sub_{target:x}()"))
                    if not is_call and depth > 0:
                        return
            elif word == RET and depth > 0:
                return
            address += 4
            steps += 1

    walk(start, end, 0, start)
    return lines, end - start


def senders(code, db, image, selector):
    """The methods in one binary that send `selector`.

    Every branch in the binary is checked against the selector's stub and
    the islands that lead to it. A call made from an outlined fragment is
    traced back to whoever calls the fragment.
    """
    import bisect
    import numpy

    low, high = code.ranges["__objc_stubs"]
    stub = None
    for address in range(low, high, 12):
        if code.stub_selector(address) == selector:
            stub = address
            break

    text_low, text_high = code.ranges["__text"]
    start = code.offset(text_low)
    words = numpy.frombuffer(code.data, dtype="<u4", count=(text_high - text_low) // 4, offset=start)

    # Swift and C code load the selector themselves and call objc_msgSend:
    # an adrp to the selector's slot followed by a load from it.
    direct = []
    slot_low, slot_high = code.ranges["__objc_selrefs"]
    slot = None
    for address in range(slot_low, slot_high, 8):
        if code.string(code.pointer(address)) == selector:
            slot = address
            break
    if slot is not None:
        adrp = numpy.nonzero((words[:-1] & 0x9F000000) == 0x90000000)[0]
        load = words[adrp + 1]
        pair = ((load & 0xFFC00000) == 0xF9400000) & (((load >> 5) & 31) == (words[adrp] & 31))
        adrp, load = adrp[pair], load[pair]
        immediate = ((((words[adrp] >> 5) & 0x7FFFF).astype(numpy.int64) << 2) | ((words[adrp] >> 29) & 3).astype(numpy.int64))
        immediate = numpy.where(immediate & 0x100000, immediate - 0x200000, immediate)
        addresses = text_low + adrp.astype(numpy.int64) * 4
        loaded = (addresses & ~0xFFF) + (immediate << 12) + ((load >> 10) & 0xFFF).astype(numpy.int64) * 8
        direct = addresses[loaded == slot].tolist()
    if stub is None and not direct:
        return None
    index = numpy.nonzero((words & 0x7C000000) == 0x14000000)[0]
    offsets = (words[index] & 0x3FFFFFF).astype(numpy.int64)
    offsets = numpy.where(offsets & 0x2000000, offsets - 0x4000000, offsets)
    sites = text_low + index.astype(numpy.int64) * 4
    targets = sites + offsets * 4

    first = numpy.nonzero(((words[:-2] & 0x9F00001F) == 0x90000010) & ((words[1:-1] & 0xFFC003FF) == 0x91000210)
                          & (words[2:] == 0xD61F0200))[0]
    wanted = {stub} if stub is not None else set()
    for position in (first.tolist() if stub is not None else []):
        address = text_low + position * 4
        word, second = int(words[position]), int(words[position + 1])
        page = (address & ~0xFFF) + (sign((((word >> 5) & 0x7FFFF) << 2) | ((word >> 29) & 3), 21) << 12)
        if page + ((second >> 10) & 0xFFF) == stub:
            wanted.add(address)

    starts = [row[0] for row in db.execute("select distinct code from methods where image = ? and code > 0 order by code", (image,))]
    order = numpy.argsort(targets, kind="stable")
    sorted_targets = targets[order]

    def callers_of(addresses):
        found = []
        for address in addresses:
            left = numpy.searchsorted(sorted_targets, address, "left")
            right = numpy.searchsorted(sorted_targets, address, "right")
            found += sites[order[left:right]].tolist()
        return found

    names, seen = set(), set()
    pending = [(site, 0) for site in callers_of(wanted) + direct]
    while pending:
        site, depth = pending.pop()
        if site in seen:
            continue
        seen.add(site)
        position = bisect.bisect_right(starts, site) - 1
        owner = starts[position] if position >= 0 else None
        following = starts[position + 1] if position + 1 < len(starts) else text_high
        if owner is not None and site < code.end_of(owner, following):
            row = db.execute("select class, kind, sel from methods where image = ? and code = ? limit 1", (image, owner)).fetchone()
            names.add(f"{row[1]}[{row[0]} {row[2]}]")
            continue
        # Not in a method: an outlined fragment, which starts at the nearest
        # address before the call that something branches to, or a block or
        # plain function, which the compiler puts after the method it was
        # written in.
        left = numpy.searchsorted(sorted_targets, site - 128, "left")
        right = numpy.searchsorted(sorted_targets, site, "right")
        entries = sorted(set(sorted_targets[left:right].tolist()))
        callers = callers_of([entries[-1]]) if entries and depth < 4 else []
        if callers:
            pending += [(caller, depth + 1) for caller in callers]
        elif owner is not None:
            row = db.execute("select class, kind, sel from methods where image = ? and code = ? limit 1", (image, owner)).fetchone()
            names.add(f"{row[1]}[{row[0]} {row[2]}]   (in a block or function after it)")
    return sorted(names)


def users_of(code, db, image, text):
    """The methods in one binary that refer to the string constant `text`."""
    import bisect
    import numpy

    wanted = set()
    encoded = text.encode()
    for name in ("__cstring", "__objc_methname"):
        if name not in code.sections:
            continue
        address, length, offset = code.sections[name]
        blob = code.data[offset:offset + length]
        at = blob.find(b"\0" + encoded + b"\0")
        while at != -1:
            wanted.add(address + at + 1)
            at = blob.find(b"\0" + encoded + b"\0", at + 1)
    if "__cfstring" in code.sections:
        address, length, _ = code.sections["__cfstring"]
        for entry in range(address, address + length, 32):
            if code.pointer(entry + 16) in wanted:
                wanted.add(entry)
    if not wanted:
        return None

    text_low, text_high = code.ranges["__text"]
    words = numpy.frombuffer(code.data, dtype="<u4", count=(text_high - text_low) // 4, offset=code.offset(text_low))
    adrp = numpy.nonzero((words[:-1] & 0x9F000000) == 0x90000000)[0]
    add = words[adrp + 1]
    pair = ((add & 0xFFC00000) == 0x91000000) & (((add >> 5) & 31) == (words[adrp] & 31))
    adrp, add = adrp[pair], add[pair]
    immediate = ((((words[adrp] >> 5) & 0x7FFFF).astype(numpy.int64) << 2) | ((words[adrp] >> 29) & 3).astype(numpy.int64))
    immediate = numpy.where(immediate & 0x100000, immediate - 0x200000, immediate)
    addresses = text_low + adrp.astype(numpy.int64) * 4
    loaded = (addresses & ~0xFFF) + (immediate << 12) + ((add >> 10) & 0xFFF).astype(numpy.int64)
    sites = addresses[numpy.isin(loaded, numpy.array(sorted(wanted), dtype=numpy.int64))].tolist()

    starts = [row[0] for row in db.execute("select distinct code from methods where image = ? and code > 0 order by code", (image,))]
    names = set()
    for site in sites:
        position = bisect.bisect_right(starts, site) - 1
        if position < 0:
            continue
        owner = starts[position]
        following = starts[position + 1] if position + 1 < len(starts) else text_high
        row = db.execute("select class, kind, sel from methods where image = ? and code = ? limit 1", (image, owner)).fetchone()
        inside = site < code.end_of(owner, following)
        names.add(f"{row[1]}[{row[0]} {row[2]}]" + ("" if inside else "   (in a block or function after it)"))
    return sorted(names)


def load(image_name):
    version = pinned_version()
    matches = sorted(glob.glob(os.path.join(PACKAGES, f"com.burbn.instagram*{version}*.ipa")))
    if not matches:
        sys.exit(f"no Instagram {version} IPA in packages/")
    with zipfile.ZipFile(matches[-1]) as archive:
        for name in archive.namelist():
            if name.endswith("/" + image_name) and ".appex/" not in name:
                return Code(arm64(archive.read(name)))
    sys.exit(f"no binary named {image_name} in the IPA")


def main(argv):
    raw = "--raw" in argv
    wanted = [argument for argument in argv[1:] if not argument.startswith("--")]
    if ("--to" in argv or "--uses" in argv) and wanted:
        db = sqlite3.connect(db_path())
        search, verb = (senders, "send") if "--to" in argv else (users_of, "use")
        total = 0
        for image_name in ("Instagram", "FBSharedFramework"):
            names = search(load(image_name), db, image_name, wanted[0])
            for name in names or []:
                print(name)
            total += len(names or [])
        print(f"{total} methods {verb} {wanted[0]} in Instagram {pinned_version()}", file=sys.stderr)
        return 0
    match = re.fullmatch(r"\s*([-+])\[\s*(\S+)\s+(\S+)\s*\]\s*", wanted[0]) if wanted else None
    if not match:
        print(__doc__.strip(), file=sys.stderr)
        return 2
    kind, cls, selector = match.groups()
    db = sqlite3.connect(db_path())
    # A category can add a method from another binary than the class's own.
    row = db.execute("""select m.code, m.image, c.name from methods m join classes c on c.name = m.class
                        where (c.name = ? or c.alias = ?) and m.kind = ? and m.sel = ? limit 1""",
                     (cls, cls, kind, selector)).fetchone()
    if not row:
        sys.exit(f"no {kind}[{cls} {selector}] in Instagram {pinned_version()}")
    start, image_name, name = row
    code = load(image_name)
    lines, size = trace(code, db, image_name, start, raw)
    print(f"{kind}[{name} {selector}]   {image_name} {start:#x}, {size // 4} instructions")
    for address, text in lines:
        print(f"  +{address - start:<5d} {text}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
