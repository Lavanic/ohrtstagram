#!/usr/bin/env python3
"""Reads and checks IPA files for ohrt/build.sh, without a Mac.

  ipa.py version  <ipa>                     print the app's marketing version
  ipa.py precheck <ipa>                     fail if the app is still encrypted
  ipa.py add      <ipa> <file> <path>       add a file inside the .app
  ipa.py settings <folder> <version> <instagram version>
                                            write our page for the Settings app
  ipa.py icons    <png> <folder>            write the app icon at every size
  ipa.py check    <ipa> <name> <bundle-id> [--settings] <dylib>...
                                            verify a built IPA and describe it
"""
import plistlib
import struct
import sys
import zipfile

LC_LOAD_DYLIB = 0xC
LC_LOAD_WEAK_DYLIB = 0x80000018
LC_ENCRYPTION_INFO_64 = 0x2C
MH_MAGIC_64 = 0xFEEDFACF
FAT_MAGIC = 0xCAFEBABE
CPU_ARM64 = 0x0100000C


def die(message):
    print(f"error: {message}", file=sys.stderr)
    sys.exit(1)


def app_root(archive):
    for name in archive.namelist():
        parts = name.split("/")
        if len(parts) >= 2 and parts[0] == "Payload" and parts[1].endswith(".app"):
            return f"Payload/{parts[1]}/"
    die("no Payload/*.app in the IPA")


def info_plist(archive, root):
    return plistlib.loads(archive.read(root + "Info.plist"))


def arm64_slice(data):
    """The arm64 Mach-O inside `data`, which may be a fat file."""
    if struct.unpack_from(">I", data)[0] == FAT_MAGIC:
        count = struct.unpack_from(">I", data, 4)[0]
        for index in range(count):
            cpu, _, offset, size, _ = struct.unpack_from(">5I", data, 8 + index * 20)
            if cpu == CPU_ARM64:
                return data[offset:offset + size]
        die("no arm64 slice in the main binary")
    return data


def load_commands(data):
    """Yields (command, payload) for each load command of a 64-bit Mach-O."""
    data = arm64_slice(data)
    if struct.unpack_from("<I", data)[0] != MH_MAGIC_64:
        die("the main binary is not a 64-bit Mach-O")
    count = struct.unpack_from("<I", data, 16)[0]
    offset = 32
    for _ in range(count):
        command, size = struct.unpack_from("<II", data, offset)
        yield command, data[offset:offset + size]
        offset += size


def linked_libraries(data):
    names = []
    for command, payload in load_commands(data):
        if command in (LC_LOAD_DYLIB, LC_LOAD_WEAK_DYLIB):
            start = struct.unpack_from("<I", payload, 8)[0]
            names.append(payload[start:].split(b"\0", 1)[0].decode())
    return names


def encrypted(data):
    for command, payload in load_commands(data):
        if command == LC_ENCRYPTION_INFO_64:
            return struct.unpack_from("<I", payload, 16)[0] != 0
    return False


def main_binary(archive, root):
    return archive.read(root + info_plist(archive, root)["CFBundleExecutable"])


def command_version(path):
    with zipfile.ZipFile(path) as archive:
        print(info_plist(archive, app_root(archive)).get("CFBundleShortVersionString", "unknown"))


def command_precheck(path):
    with zipfile.ZipFile(path) as archive:
        names = archive.namelist()
        root = app_root(archive)
        info = info_plist(archive, root)
        if info.get("CFBundleIdentifier") != "com.burbn.instagram":
            die(f"this is {info.get('CFBundleIdentifier')}, not Instagram")
        if encrypted(main_binary(archive, root)):
            die("this IPA is still encrypted (straight from the App Store). It has to be a decrypted one.")
        if "iTunesMetadata.plist" in names:
            print("note: the IPA carries iTunesMetadata.plist, which names the Apple account it was bought with", file=sys.stderr)


def command_add(path, source, inside):
    with zipfile.ZipFile(path, "a", zipfile.ZIP_DEFLATED) as archive:
        archive.write(source, app_root(archive) + inside)


SWITCHES = [
    ("Following feed", "ohrt_following_feed"),
    ("Caught up wall", "ohrt_wall"),
    ("DM mode", "ohrt_dm_mode"),
    ("Grayscale", "ohrt_grayscale"),
]


def command_settings(folder, version, instagram):
    """Writes Settings.bundle: the app's page in the iPhone's Settings app.

    It is the one place the tweak can be switched off from when the app
    itself will not start.
    """
    import os
    specifiers = [
        {"Type": "PSGroupSpecifier", "Title": "If the app will not start",
         "FooterText": "Starts ohrtstagram as plain Instagram, so you can get to its settings (on your profile, hold the "
                       "three lines at the top right, or hold four fingers anywhere) and turn off what broke it. "
                       "Switch this off again afterwards."},
        {"Type": "PSToggleSwitchSpecifier", "Title": "Start with everything off", "Key": "ohrt_force_safe", "DefaultValue": False},
        {"Type": "PSGroupSpecifier", "Title": "Focus",
         "FooterText": "The same switches as in the app. A change here takes effect the next time the app starts."},
    ]
    specifiers += [{"Type": "PSToggleSwitchSpecifier", "Title": title, "Key": key, "DefaultValue": False} for title, key in SWITCHES]
    specifiers += [
        {"Type": "PSGroupSpecifier"},
        {"Type": "PSTitleValueSpecifier", "Title": "Version", "Key": "ohrt_version_shown",
         "DefaultValue": f"{version} on Instagram {instagram}"},
    ]
    os.makedirs(folder, exist_ok=True)
    with open(os.path.join(folder, "Root.plist"), "wb") as handle:
        plistlib.dump({"Title": "ohrtstagram", "PreferenceSpecifiers": specifiers}, handle)


# (points, scale, iPad only)
ICON_SIZES = [(20, 2, False), (20, 3, False), (29, 2, False), (29, 3, False), (40, 2, False), (40, 3, False),
              (60, 2, False), (60, 3, False), (76, 2, True), (83.5, 2, True)]


def command_icons(source, folder):
    """Writes the icon at each size iOS asks for, and the Info.plist keys that name them.

    cyan's own icon option writes one 120 pixel picture, which a 3x screen
    then stretches. The keys go in a plist for cyan to merge; they replace
    Instagram's, so its alternate icons go too.
    """
    import hashlib
    import os
    try:
        from PIL import Image
    except ImportError:
        die("making the icon needs Pillow (pacman -S python-pillow)")
    os.makedirs(folder, exist_ok=True)
    with open(source, "rb") as handle:
        # A new name for a new picture, so the phone does not show a cached one.
        prefix = "Ohrt" + hashlib.sha1(handle.read()).hexdigest()[:6] + "Icon"
    phone, pad = [], []
    with Image.open(source) as image:
        image = image.convert("RGB")
        for points, scale, pad_only in ICON_SIZES:
            base = f"{prefix}{points:g}x{points:g}"
            pixels = round(points * scale)
            suffix = "~ipad" if pad_only else ""
            image.resize((pixels, pixels), Image.LANCZOS).save(os.path.join(folder, f"{base}@{scale}x{suffix}.png"), "PNG")
            names = pad if pad_only else phone
            if base not in names:
                names.append(base)
    keys = {
        "CFBundleIcons": {"CFBundlePrimaryIcon": {"CFBundleIconFiles": phone, "CFBundleIconName": prefix}},
        "CFBundleIcons~ipad": {"CFBundlePrimaryIcon": {"CFBundleIconFiles": phone + pad, "CFBundleIconName": prefix}},
    }
    with open(os.path.join(folder, "icons.plist"), "wb") as handle:
        plistlib.dump(keys, handle)


def command_check(path, name, bundle_id, *dylibs):
    with zipfile.ZipFile(path) as archive:
        names = archive.namelist()
        root = app_root(archive)
        info = info_plist(archive, root)
        libraries = linked_libraries(main_binary(archive, root))

    problems = []
    if info.get("CFBundleDisplayName") != name:
        problems.append(f"the name is {info.get('CFBundleDisplayName')!r}, not {name!r}")
    if info.get("CFBundleIdentifier") != bundle_id:
        problems.append(f"the bundle id is {info.get('CFBundleIdentifier')!r}, not {bundle_id!r}")
    if "--settings" in dylibs:
        dylibs = [name for name in dylibs if name != "--settings"]
        try:
            with zipfile.ZipFile(path) as archive:
                page = plistlib.loads(archive.read(root + "Settings.bundle/Root.plist"))
            if not any(item.get("Key") == "ohrt_force_safe" for item in page.get("PreferenceSpecifiers", [])):
                problems.append("the Settings page has no switch to start with everything off")
        except KeyError:
            problems.append("the Settings page (Settings.bundle) is missing")
    injected = [lib for lib in libraries if lib.startswith("@")]
    for wanted in dylibs:
        if not any(lib.endswith("/" + wanted) for lib in injected):
            problems.append(f"the app does not load {wanted}")
        if not any(entry.endswith("/" + wanted) for entry in names):
            problems.append(f"{wanted} is not in the IPA")
    icon_files = ((info.get("CFBundleIcons") or {}).get("CFBundlePrimaryIcon") or {}).get("CFBundleIconFiles") or []
    for icon in icon_files:
        for scale in ("@2x", "@3x"):
            if not any(entry == f"{root}{icon}{scale}.png" for entry in names):
                problems.append(f"the icon {icon}{scale}.png named in Info.plist is not in the IPA")
    # The hooking library the tweak is linked against has to travel with it.
    if not any("CydiaSubstrate.framework/" in entry for entry in names):
        problems.append("CydiaSubstrate.framework (the hooking library) is not in the IPA")
    if any(lib.startswith("/Library/") for lib in libraries):
        problems.append("the app still links a jailbreak-only path: " + ", ".join(lib for lib in libraries if lib.startswith("/Library/")))

    extensions = sorted({entry.split(".appex/")[0].rsplit("/", 1)[-1] for entry in names if ".appex/" in entry})
    size = sum(1 for _ in names)
    print(f"  name        {info.get('CFBundleDisplayName')}")
    print(f"  bundle id   {info.get('CFBundleIdentifier')}")
    print(f"  Instagram   {info.get('CFBundleShortVersionString')} ({info.get('CFBundleVersion')})")
    print(f"  minimum iOS {info.get('MinimumOSVersion')}")
    print(f"  loads       {', '.join(lib.rsplit('/', 1)[-1] for lib in injected) or 'nothing injected'}")
    print(f"  extensions  {', '.join(extensions) if extensions else 'none'}")
    print(f"  files       {size}")
    for problem in problems:
        print(f"error: {problem}", file=sys.stderr)
    sys.exit(1 if problems else 0)


COMMANDS = {"version": command_version, "precheck": command_precheck, "add": command_add, "settings": command_settings,
            "icons": command_icons, "check": command_check}

if __name__ == "__main__":
    if len(sys.argv) < 3 or sys.argv[1] not in COMMANDS:
        print(__doc__.strip(), file=sys.stderr)
        sys.exit(2)
    COMMANDS[sys.argv[1]](*sys.argv[2:])
