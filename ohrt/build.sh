#!/usr/bin/env bash
# Builds the ohrtstagram IPA on Linux.
#
# Upstream's build.sh assumes a Mac in small ways (a case-insensitive disk,
# compiler-rt in the toolchain, the ipapatch binary). This does the same job
# with what runs here: Theos with its Linux toolchain, cyan to inject, and
# python for the checks.
#
#   ohrt/build.sh                 build the tweak and inject it into the IPA
#   ohrt/build.sh --tweak-only    build the dylibs and stop (needs no IPA)
#
# The hooks are written for one Instagram version, named in
# ohrt/instagram-version. The IPA is yours to supply, decrypted, as
# packages/com.burbn.instagram_<version>.ipa. Nothing here downloads one.
# ohrt/tools/vet.py checks one against Apple's signature.
#
# Options:
#   --ipa <file>          use this IPA instead of looking in packages/
#   --name <name>         name under the icon            (default: ohrtstagram)
#   --bundle-id <id>      bundle identifier              (default: dev.ohrt.ohrtstagram)
#   --icon <png>          app icon                       (default: ohrt/brand/icon-1024.png)
#   --keep-extensions     leave Instagram's app extensions in. A free Apple
#                         account cannot sign them, so they are removed by default.
#   --flex                add FLEX, the in-app inspector, for working out hooks
#   --stock               upstream's sources only: nothing from ohrt/src, and
#                         nothing left out
#   --quick               reuse object files from the last build
#   --tweak-only          stop after building the dylibs

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

export THEOS="${THEOS:-$HOME/theos}"
TOOLCHAIN="$THEOS/toolchain/linux/iphone/bin"
SDK="iPhoneOS16.2.sdk"

NAME="ohrtstagram"
BUNDLE_ID="dev.ohrt.ohrtstagram"
ICON="$ROOT/ohrt/brand/icon-1024.png"
IPA=""
KEEP_EXTENSIONS=0
WITH_FLEX=0
STOCK=0
QUICK=0
TWEAK_ONLY=0

say() { printf '\033[1;32m==>\033[0m %s\n' "$*"; }
die() { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

while [ $# -gt 0 ]; do
    case "$1" in
        --ipa) IPA="${2:?--ipa needs a file}"; shift ;;
        --name) NAME="${2:?--name needs a value}"; shift ;;
        --bundle-id) BUNDLE_ID="${2:?--bundle-id needs a value}"; shift ;;
        --icon) ICON="${2:?--icon needs a file}"; shift ;;
        --keep-extensions) KEEP_EXTENSIONS=1 ;;
        --flex) WITH_FLEX=1 ;;
        --stock) STOCK=1 ;;
        --quick) QUICK=1 ;;
        --tweak-only) TWEAK_ONLY=1 ;;
        -h|--help) sed -n '2,28p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) die "unknown option: $1" ;;
    esac
    shift
done

[ -x "$TOOLCHAIN/clang" ] || die "no Theos toolchain at $TOOLCHAIN"
[ -d "$THEOS/sdks/$SDK" ] || die "no $SDK in $THEOS/sdks"
[ -n "$(ls -A modules/FLEXing 2>/dev/null)" ] || die "submodules are missing: git submodule update --init --recursive"
[ -f ohrt/modules/zxPluginsInject/fishhook/fishhook.c ] || die "submodules are missing: git submodule update --init --recursive"

VERSION="$(sed -n 's/^#define OHRT_VERSION @"\(.*\)"$/\1/p' ohrt/src/Ohrt.h)"
[ -n "$VERSION" ] || die "no OHRT_VERSION in ohrt/src/Ohrt.h"
PIN="$(tr -d '[:space:]' < ohrt/instagram-version)"

# ohrt/exclude.txt names the upstream files we do not build. They stay in the
# tree untouched, so pulling from upstream never conflicts on them.
excluded() {
    [ "$STOCK" -eq 0 ] && [ -f ohrt/exclude.txt ] && grep -v -E '^\s*(#|$)' ohrt/exclude.txt | sed 's/[[:space:]]*#.*$//' | grep -q -x -F "$1"
}

# Ours go last. Hooks are installed in link order and the last one installed
# on a method runs first, so where upstream and ohrt/src hook the same
# method, ours is the outer one: it sees upstream's result.
sources() {
    find src -type f \( -iname '*.x' -o -iname '*.xm' -o -iname '*.m' \) | sort | while read -r file; do
        excluded "$file" || echo "$file"
    done
    ls modules/JGProgressHUD/*.m
    find ohrt/linux -type f -name '*.m'
    if [ "$STOCK" -eq 0 ] && [ -d ohrt/src ]; then
        find ohrt/src -type f \( -iname '*.x' -o -iname '*.xm' -o -iname '*.m' \) | sort
    fi
}
FILES="$(sources | tr '\n' ' ')"

# The parts of our code that are plain C are tested here, on this machine.
if [ "$STOCK" -eq 0 ] && command -v cc >/dev/null; then
    say "Running tests"
    TESTS="$(mktemp -d)"
    for test in ohrt/tests/*_test.c; do
        cc -Wall -o "$TESTS/test" "$test" -lm && "$TESTS/test" || die "$test failed"
    done
    rm -rf "$TESTS"
fi

if [ "$QUICK" -eq 0 ]; then
    make clean >/dev/null 2>&1 || true
    rm -rf .theos
fi

say "Building the tweak ($(echo "$FILES" | wc -w) files)"
# Variables given on the command line win over the Makefile's, which is how
# the source list is replaced without editing upstream's Makefile.
make -j"$(nproc)" DEBUG=0 FINALPACKAGE=1 "SCInsta_FILES=$FILES" >/dev/null
TWEAK=".theos/obj/SCInsta.dylib"
[ -f "$TWEAK" ] || die "SCInsta.dylib was not built"

say "Building the sideload fix"
# Instagram asks for its App Store keychain group and app group by name. A
# sideloaded copy is signed for neither, and without this it cannot keep a
# login. Upstream gets the same library prebuilt inside ipapatch; here it is
# built from its source.
FIX_DIR="ohrt/modules/zxPluginsInject"
[ "$QUICK" -eq 1 ] || rm -rf "$FIX_DIR/.theos"
make -C "$FIX_DIR" -j"$(nproc)" DEBUG=0 FINALPACKAGE=1 TARGET=iphone:clang:16.2:14.0 >/dev/null
FIX="$FIX_DIR/.theos/obj/zxPluginsInject.dylib"
[ -f "$FIX" ] || die "zxPluginsInject.dylib was not built"

FLEX_DYLIB=""
if [ "$WITH_FLEX" -eq 1 ]; then
    say "Building FLEX"
    # FLEX needs the same stand-in as the tweak (see ohrt/linux). It is handed
    # the object the tweak build just made, so nothing is added to the
    # submodule's tree.
    SHIM="$(find "$ROOT/.theos/obj/arm64/ohrt/linux" -name 'availability_shim.m.*.o' | head -n 1)"
    [ -n "$SHIM" ] || die "the availability shim object is missing"
    [ "$QUICK" -eq 1 ] || rm -rf modules/FLEXing/libflex/.theos
    make -C modules/FLEXing/libflex -j"$(nproc)" DEBUG=0 FINALPACKAGE=1 ARCHS=arm64 \
        TARGET=iphone:clang:16.2:16.2 "libFLEX_OBJ_FILES=$SHIM" >/dev/null
    FLEX_DYLIB="modules/FLEXing/libflex/.theos/obj/libFLEX.dylib"
    [ -f "$FLEX_DYLIB" ] || die "libFLEX.dylib was not built"
fi

# Our hooks are checked against the pinned Instagram before anything is
# packaged: a class or method that is not there fails the build here, not
# silently on the phone.
audit() {
    local index="packages/classes-$PIN.sqlite"
    if [ ! -f "$index" ]; then
        local source
        source="$(find packages -maxdepth 1 -name "com.burbn.instagram*${PIN}*.ipa" | sort | tail -n 1)"
        if [ -z "$source" ]; then
            printf '\033[1;33mwarning:\033[0m no Instagram %s IPA in packages/, so the hooks were not checked\n' "$PIN" >&2
            return 0
        fi
        say "Indexing Instagram $PIN"
        python3 ohrt/tools/classdump.py build "$source" >/dev/null
    fi
    say "Checking our hooks against Instagram $PIN"
    python3 ohrt/tools/hookaudit.py ohrt/src || die "ohrt/src hooks something Instagram $PIN does not have"
}
[ "$STOCK" -eq 1 ] || audit

if [ "$TWEAK_ONLY" -eq 1 ]; then
    say "Built $TWEAK"
    exit 0
fi

command -v cyan >/dev/null || die "cyan is not installed (pipx install https://github.com/asdfzxcvbn/pyzule-rw/archive/main.zip)"
[ -f "$ICON" ] || die "no icon at $ICON"

if [ -z "$IPA" ]; then
    # Outputs of earlier builds live in packages/ too and are never the input.
    IPA="$(find packages -maxdepth 1 -name "com.burbn.instagram*${PIN}*.ipa" | sort | tail -n 1)"
    [ -n "$IPA" ] || die "put a decrypted Instagram $PIN IPA at packages/com.burbn.instagram_$PIN.ipa"
fi
[ -f "$IPA" ] || die "no such IPA: $IPA"

python3 "$ROOT/ohrt/tools/ipa.py" precheck "$IPA"
IG_VERSION="$(python3 "$ROOT/ohrt/tools/ipa.py" version "$IPA")"
[ "$IG_VERSION" = "$PIN" ] || printf '\033[1;33mwarning:\033[0m this is Instagram %s; the hooks are written for %s\n' "$IG_VERSION" "$PIN" >&2
KIND="ohrtstagram"
[ "$STOCK" -eq 0 ] || KIND="ohrtstagram-stock"
[ "$WITH_FLEX" -eq 0 ] || KIND="$KIND-flex"
OUT="packages/${KIND}_v${VERSION}_IG_v${IG_VERSION}.ipa"
rm -f "$OUT"

say "Injecting into Instagram $IG_VERSION"
# Upstream also passes -d, which lists the app's Documents folder in Files
# and over USB. Without an app group to use, the sideload fix keeps
# Instagram's shared data in that folder, so it stays closed here.
FLAGS=(-u -c 9 -n "$NAME" -b "$BUNDLE_ID")
[ "$KEEP_EXTENSIONS" -eq 1 ] || FLAGS+=(-e)
INJECT=("$TWEAK")
[ -z "$FLEX_DYLIB" ] || INJECT+=("$FLEX_DYLIB")
STAGE="$(mktemp -d)"
# The icon at every size. cyan's own option writes a single 120 pixel
# picture, which a 3x screen stretches.
python3 "$ROOT/ohrt/tools/ipa.py" icons "$ICON" "$STAGE/icons"
INJECT+=("$STAGE"/icons/*.png)
FLAGS+=(-l "$STAGE/icons/icons.plist")
if [ "$STOCK" -eq 0 ]; then
    # Our page in the iPhone's Settings app, in place of Instagram's, which
    # only shows a version. It can switch the tweak off when the app itself
    # will not start.
    python3 "$ROOT/ohrt/tools/ipa.py" settings "$STAGE/Settings.bundle" "$VERSION" "$IG_VERSION"
    INJECT+=("$STAGE/Settings.bundle")
fi
# With the extensions gone the sideload fix only has the app to go into, so
# cyan injects it. With them kept, ipapatch puts it into the app and into
# each extension instead.
[ "$KEEP_EXTENSIONS" -eq 1 ] || INJECT+=("$FIX")
cyan -i "$IPA" -o "$OUT" -f "${INJECT[@]}" "${FLAGS[@]}"
rm -rf "$STAGE"

if [ "$KEEP_EXTENSIONS" -eq 1 ]; then
    command -v ipapatch >/dev/null || die "--keep-extensions needs ipapatch on PATH"
    ipapatch --input "$OUT" --inplace --noconfirm --dylib "$FIX"
fi

EXPECT=(SCInsta.dylib zxPluginsInject.dylib)
[ "$STOCK" -eq 1 ] || EXPECT=(--settings "${EXPECT[@]}")
[ -z "$FLEX_DYLIB" ] || EXPECT+=(libFLEX.dylib)
python3 "$ROOT/ohrt/tools/ipa.py" check "$OUT" "$NAME" "$BUNDLE_ID" "${EXPECT[@]}"
say "Done: $ROOT/$OUT"
