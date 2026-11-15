#!/usr/bin/env python3
"""Checks a tweak's hooks against the Instagram build they are meant for.

  hookaudit.py [--all] <source file or dir>...

Every `%hook Class` in the Logos sources names a class inside Instagram and
every method in it names a selector. Instagram renames and removes both all
the time, and a hook whose class or selector is gone does nothing, silently.

This looks each one up in the index made by `classdump.py build` and says:

  gone     the class is not in the app, or none of the hook's methods are
  partly   some of the hook's methods are not on the class any more
  types    a method is there, but takes or returns something else than the
           hook declares (an object where the hook says integer, and so on),
           which is the kind of mismatch that crashes
  ok       everything the hook names is on the class or one it inherits from

It also lists classes the code looks up by name (%c(...), NSClassFromString,
objc_getClass) that no longer exist, methods it calls by name
(NSSelectorFromString, OhrtCall) that no class in the app has, and entries
of the table in ohrt/src/OhrtNeeds.m, which the tweak checks again on the
phone, that this version does not meet.

A hook that passes can still be wrong: a method that kept its name may do
something else now. Only the phone settles that.

Exit status is 1 if anything is gone, partly gone or mistyped.
"""
import os
import re
import sqlite3
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
SDK = os.path.expanduser(os.environ.get("THEOS", "~/theos") + "/sdks/iPhoneOS16.2.sdk/System/Library/Frameworks")
SYSTEM_FRAMEWORKS = ("UIKit", "Foundation", "QuartzCore", "AVFoundation", "AVKit", "WebKit", "Photos", "PhotosUI",
                     "CoreGraphics", "SafariServices", "QuickLook", "MessageUI", "StoreKit", "UserNotifications")

sys.path.insert(0, HERE)
from classdump import db_path, pinned_version, split_types  # noqa: E402

HOOK = re.compile(r"^[ \t]*%hook[ \t]+([A-Za-z_$][A-Za-z0-9_.$]*)", re.M)
END = re.compile(r"^[ \t]*%end\b", re.M)
METHOD = re.compile(r"^[ \t]*(%new[^\n]*?)?[ \t]*([-+])[ \t]*\(((?:[^()]|\([^()]*\))*)\)[ \t]*([^{;]*?)[ \t\n]*\{", re.M)
ARGUMENT = re.compile(r"([A-Za-z_][A-Za-z0-9_]*)?[ \t\n]*:[ \t\n]*\(((?:[^()]|\([^()]*\))*)\)[ \t\n]*[A-Za-z_][A-Za-z0-9_]*")
BY_NAME = re.compile(r"(?:OhrtCall(?:Bool|Void)?\([^;\n]*?,\s*@\"|NSSelectorFromString\(\s*@\")([A-Za-z_][A-Za-z0-9_:]*)\"")
NEED = re.compile(r"OHRT_NEED(_CLASS)?\(\s*\"([^\"]+)\",\s*\"([^\"]+)\",\s*\"([^\"]+)\"\s*\)")
LOOKUP = re.compile(r"(?:%c\(\s*|NSClassFromString\(\s*@\"|objc_getClass\(\s*\"|objc_lookUpClass\(\s*\")([A-Za-z_$][A-Za-z0-9_.$]*)")

STRUCTS = {"CGRect", "CGPoint", "CGSize", "UIEdgeInsets", "NSRange", "CGAffineTransform", "CMTime", "CGVector",
           "NSDirectionalEdgeInsets", "UIOffset", "CATransform3D", "CMTimeRange"}
INTEGERS = {"int", "long", "short", "char", "unsigned", "signed", "NSInteger", "NSUInteger", "int64_t", "uint64_t",
            "int32_t", "uint32_t", "size_t", "ssize_t", "uint8_t", "int8_t", "uint16_t", "int16_t", "CFIndex"}
FLOATS = {"double", "float", "CGFloat", "NSTimeInterval", "CFTimeInterval", "CFAbsoluteTime"}
BOOLS = {"BOOL", "_Bool", "bool", "Boolean"}


def strip_comments(text):
    text = re.sub(r"/\*.*?\*/", lambda match: re.sub(r"[^\n]", " ", match.group(0)), text, flags=re.S)
    return re.sub(r"//[^\n]*", "", text)


def declared_kind(text):
    """The register class a C type in a hook's declaration ends up in."""
    text = re.sub(r"\b(const|nullable|nonnull|_Nullable|_Nonnull|__unsafe_unretained|__weak|__strong|__kindof|struct|enum)\b", " ", text)
    text = re.sub(r"<[^<>]*>", "", text).strip()
    if "^" in text:
        return "object"  # a block
    words = text.replace("*", " ").split()
    if not words:
        return None
    stars = text.count("*")
    base = words[0]
    if stars == 0:
        if base == "void":
            return "void"
        if base in ("id", "instancetype", "Class"):
            return "object"
        if base == "SEL":
            return "pointer"
        if base in BOOLS or base in INTEGERS:
            return "integer"
        if base in FLOATS:
            return "float"
        if base in STRUCTS:
            return "struct"
        return None  # a typedef we cannot see through
    if stars == 1 and base not in ("void", "char") and base not in INTEGERS and base not in FLOATS \
            and base not in STRUCTS and base not in BOOLS:
        return "object"
    return "pointer"


def encoded_kind(code):
    code = code.lstrip("rnNoORV")
    if not code:
        return None
    first = code[0]
    if first == "v":
        return "void"
    if first in "@#":
        return "object"
    if first in "BcCqQiIlLsS":
        return "integer"
    if first in "df":
        return "float"
    if first in "{(":
        return "struct"
    if first in "^*:[":
        return "pointer"
    return None


def hooks_in(path):
    """Yields (class, line, [(kind, selector, return type, [argument types])]) per %hook block."""
    with open(path, errors="replace") as handle:
        text = strip_comments(handle.read())
    for match in HOOK.finditer(text):
        end = END.search(text, match.end())
        body = text[match.end():end.start() if end else len(text)]
        methods = []
        for method in METHOD.finditer(body):
            if method.group(1):
                continue  # %new: a method the tweak adds, nothing in the app to find
            rest = method.group(4).strip()
            arguments = ARGUMENT.findall(rest)
            if arguments:
                selector = "".join(name + ":" for name, _ in arguments)
                types = [kind for _, kind in arguments]
            else:
                selector, types = rest.split()[0] if rest.split() else "", []
            if selector:
                methods.append((method.group(2), selector, method.group(3), types))
        yield match.group(1), text.count("\n", 0, match.start()) + 1, methods


class App:
    def __init__(self, path):
        if not os.path.exists(path):
            sys.exit(f"no index at {path}; run: ohrt/tools/classdump.py build <ipa>")
        self.db = sqlite3.connect(path)
        self._system = None

    def resolve(self, name):
        row = self.db.execute("select name from classes where name = ? or alias = ? limit 1", (name, name)).fetchone()
        return row[0] if row else None

    def chain(self, name):
        """The class and its superclasses, and the first one outside the app."""
        chain = []
        while name and name not in chain:
            row = self.db.execute("select super from classes where name = ? limit 1", (name,)).fetchone()
            if row is None:
                return chain, name
            chain.append(name)
            name = row[0]
        return chain, None

    def method(self, chain, kind, selector):
        for name in chain:
            row = self.db.execute("select types from methods where class = ? and kind = ? and sel = ? limit 1",
                                  (name, kind, selector)).fetchone()
            if row:
                return row[0]
        return None

    def anywhere(self, selector):
        return self.db.execute("select count(distinct class) from methods where sel = ?", (selector,)).fetchone()[0]

    def system_has(self, selector):
        """True if Apple's headers declare a method that starts like this one."""
        if self._system is None:
            pieces = []
            for framework in SYSTEM_FRAMEWORKS:
                folder = os.path.join(SDK, framework + ".framework", "Headers")
                if os.path.isdir(folder):
                    for name in os.listdir(folder):
                        if name.endswith(".h"):
                            with open(os.path.join(folder, name), errors="replace") as handle:
                                pieces.append(handle.read())
            self._system = "\n".join(pieces)
        first = selector.split(":")[0]
        tail = ":" if ":" in selector else r"\b"
        if re.search(r"\)\s*" + re.escape(first) + tail, self._system):
            return True
        # Properties declare their accessors without spelling them out.
        name = first
        if selector.count(":") == 1 and first.startswith("set") and len(first) > 3:
            name = first[3].lower() + first[4:]
        elif ":" in selector:
            return False
        return re.search(r"@property[^;]*\b(?:%s|[gs]etter\s*=\s*%s)\b[^;]*;" % (re.escape(name), re.escape(first)),
                         self._system) is not None


def own_classes():
    """Classes the tweak defines itself, which it may also hook."""
    names = set()
    root = os.path.normpath(os.path.join(HERE, "..", ".."))
    for folder in ("src", os.path.join("ohrt", "src")):
        for path, _, files in os.walk(os.path.join(root, folder)):
            for name in files:
                if name.endswith((".m", ".mm", ".x", ".xm")):
                    with open(os.path.join(path, name), errors="replace") as handle:
                        names.update(re.findall(r"^@implementation\s+([A-Za-z_][A-Za-z0-9_]*)", handle.read(), re.M))
    return names


OWN = own_classes()


def audit_hook(app, cls, methods):
    """Returns (status, [notes])."""
    if cls in OWN:
        return "own", []
    name = app.resolve(cls)
    if name is None:
        if re.match(r"^(UI|NS|CA|AV|WK|SF|PH|MK|CL|UN|CK|_UI|QL|LS)[A-Z]", cls):
            return "system", []
        return "gone", ["the class is not in the app"]
    chain, outside = app.chain(name)
    notes, missing, mistyped = [], 0, 0
    for kind, selector, returns, arguments in methods:
        encoding = app.method(chain, kind, selector)
        if encoding is None:
            if outside and app.system_has(selector):
                continue  # inherited from Apple's class
            elsewhere = app.anywhere(selector)
            missing += 1
            notes.append(f"{kind}{selector} is not on the class" +
                         (f" (on {elsewhere} other classes)" if elsewhere else " (nor anywhere in the app)"))
            continue
        types = split_types(encoding)
        if len(types) < 3:
            continue
        pairs = [("returns", returns, types[0])] + [(f"argument {index + 1}", declared, code)
                                                   for index, (declared, code) in enumerate(zip(arguments, types[3:]))]
        for what, declared, code in pairs:
            ours, theirs = declared_kind(declared), encoded_kind(code)
            if ours and theirs and ours != theirs:
                mistyped += 1
                notes.append(f"{kind}{selector} {what}: the hook says `{declared.strip()}`, the app has `{code}`")
    if methods and missing == len(methods):
        return "gone", notes
    if missing:
        return "partly", notes
    if mistyped:
        return "types", notes
    return "ok", notes


def main(argv):
    arguments = argv[1:]
    show_all = False
    while arguments and arguments[0].startswith("--"):
        flag = arguments.pop(0)
        if flag == "--all":
            show_all = True
        else:
            print(__doc__.strip(), file=sys.stderr)
            return 2
    if not arguments:
        print(__doc__.strip(), file=sys.stderr)
        return 2

    app = App(db_path())
    files = []
    for root in arguments:
        if os.path.isdir(root):
            for folder, _, names in os.walk(root):
                files += [os.path.join(folder, name) for name in names if name.endswith((".x", ".xm", ".m", ".mm"))]
        else:
            files.append(root)

    counts = {"ok": 0, "system": 0, "own": 0, "types": 0, "partly": 0, "gone": 0}
    lookups_gone, calls_gone, needs_unmet, needs = [], [], [], 0
    for path in sorted(files):
        if path.endswith((".x", ".xm")):
            for cls, line, methods in hooks_in(path):
                status, notes = audit_hook(app, cls, methods)
                counts[status] += 1
                if status in ("ok", "system", "own") and not show_all:
                    continue
                print(f"{status:7s} {cls}  ({path}:{line})")
                for note in notes:
                    print(f"          {note}")
        with open(path, errors="replace") as handle:
            text = strip_comments(handle.read())
        for match in LOOKUP.finditer(text):
            cls = match.group(1)
            if app.resolve(cls) is None and not re.match(r"^(UI|NS|CA|AV|WK|SF|PH|MK|CL|UN|CK|_UI|QL|LS|FLEX|JG)[A-Z_]", cls):
                lookups_gone.append(f"{cls}  ({path}:{text.count(chr(10), 0, match.start()) + 1})")
        for match in NEED.finditer(text):
            on_class, feature, cls, selector = match.groups()
            needs += 1
            name = app.resolve(cls)
            chain, outside = app.chain(name) if name else ([], None)
            kind = "+" if on_class else "-"
            if name is None or (app.method(chain, kind, selector) is None and not (outside and app.system_has(selector))):
                needs_unmet.append(f"{feature}: {kind}[{cls} {selector}]  ({path}:{text.count(chr(10), 0, match.start()) + 1})")
        for match in BY_NAME.finditer(text):
            selector = match.group(1)
            if not app.anywhere(selector) and not app.system_has(selector):
                calls_gone.append(f"{selector}  ({path}:{text.count(chr(10), 0, match.start()) + 1})")

    if lookups_gone:
        print("\nlooked up by name, but not in the app:")
        for line in sorted(set(lookups_gone)):
            print("  " + line)
    if calls_gone:
        print("\ncalled by name, but on no class in the app:")
        for line in sorted(set(calls_gone)):
            print("  " + line)
    if needs_unmet:
        print("\nneeded by a feature, but not in the app:")
        for line in sorted(set(needs_unmet)):
            print("  " + line)
    total = sum(counts.values())
    print(f"\nInstagram {pinned_version()}, {total} hooks: {counts['ok']} ok, {counts['system']} on Apple's classes, {counts['own']} on the tweak's own, "
          f"{counts['types']} mistyped, "
          f"{counts['partly']} partly gone, {counts['gone']} gone")
    if needs:
        print(f"{needs} needs listed for the features, {needs - len(needs_unmet)} met")
    return 1 if counts["types"] or counts["partly"] or counts["gone"] or lookups_gone or calls_gone or needs_unmet else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
