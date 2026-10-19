#!/bin/zsh
# vphone-tier: build
#
# Rebuild Resources/OpenSEP/OpenSEP.bin from OpenSEP's source, with any
# patches in Resources/OpenSEP/patches applied in order.
#
#   UpdateOpenSEP.sh            build the pinned commit and check it matches
#                               the checked-in image byte for byte
#   UpdateOpenSEP.sh <commit>   build another commit and replace the image and
#                               LICENSE with what it builds
#
# A patch upstream has taken is deleted from patches/ when moving past it.
#
# Nothing here runs during the VPhone build: the image is checked in so the
# bundle needs no cross toolchain. The clone and the build happen in a
# temporary folder outside this repository. Needs git and
# `brew install llvm lld`; OpenSEP's `make verify` also wants uv and ripgrep,
# and is not run here. The build is `make build/OpenSEP.bin`, whose platform
# is vresearch1 (Virtualization.framework's AVPSEPBooter). After replacing the
# image, update the commit, toolchain, SHA-256 and size in
# Resources/OpenSEP/README.md and the pinned commit below, then restore and
# boot a machine with it.
set -euo pipefail

repository="https://github.com/owngoal-dev/OpenSEP.git"
pinned="8b1633f7e6606f0bc9e1422c93e8d2e056154d2f"

root="$(cd "${0:a:h}/../../.." && pwd)"
destination="$root/VPhoneExecutable/VPhoneVirtualization/Resources/OpenSEP"
commit="${1:-$pinned}"
llvm="${LLVM_PREFIX:-/opt/homebrew/opt/llvm/bin}"

for tool in "$llvm/clang" "$llvm/llvm-objcopy" /opt/homebrew/bin/ld.lld; do
    [[ -x "$tool" ]] || { print -u2 "Missing $tool (brew install llvm lld)"; exit 1; }
done

work="$(/usr/bin/mktemp -d)"
trap '/bin/rm -rf "$work"' EXIT
/usr/bin/git clone --quiet "$repository" "$work/OpenSEP"
/usr/bin/git -C "$work/OpenSEP" checkout --quiet --detach "$commit"
for patch in "$destination"/patches/*.patch(N); do
    /usr/bin/git -C "$work/OpenSEP" apply --whitespace=nowarn "$patch" || {
        print -u2 "${patch:t} does not apply to $commit; refresh it, or delete it if upstream has it"
        exit 1
    }
    print "patch   ${patch:t}"
done
/usr/bin/make -C "$work/OpenSEP" LLVM_PREFIX="$llvm" PLATFORM=vresearch1 build/OpenSEP.bin >/dev/null

built="$work/OpenSEP/build/OpenSEP.bin"
print "commit  $(/usr/bin/git -C "$work/OpenSEP" rev-parse HEAD)"
print "sha256  $(/usr/bin/shasum -a 256 "$built" | /usr/bin/awk '{print $1}')"
print "size    $(/usr/bin/stat -f %z "$built")"
print "clang   $("$llvm/clang" --version | /usr/bin/head -1)"
print "ld.lld  $(/opt/homebrew/bin/ld.lld --version)"

if (( $# == 0 )); then
    /usr/bin/cmp "$built" "$destination/OpenSEP.bin" || {
        print -u2 "The pinned commit does not build the checked-in OpenSEP.bin with this toolchain."
        exit 1
    }
    print "OpenSEP.bin matches $pinned"
else
    /bin/cp "$built" "$destination/OpenSEP.bin"
    /bin/cp "$work/OpenSEP/LICENSE" "$destination/LICENSE"
    /bin/chmod 644 "$destination/OpenSEP.bin" "$destination/LICENSE"
    print "Replaced $destination/OpenSEP.bin; update README.md and the pinned commit."
fi
