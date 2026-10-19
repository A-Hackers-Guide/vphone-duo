#!/bin/zsh
# vphone-tier: build
#
# Rebuild Resources/OpenAVB/OpenAVB.bin from OpenAVB's source, with any
# patches in Resources/OpenAVB/patches applied in order.
#
#   UpdateOpenAVB.sh            build the pinned commit and check it matches
#                               the checked-in image byte for byte
#   UpdateOpenAVB.sh <commit>   build another commit and replace the image,
#                               LICENSE and APSL-2.0.txt with what it builds
#
# A patch upstream has taken is deleted from patches/ when moving past it.
#
# Nothing here runs during the VPhone build: the image is checked in so the
# bundle needs no cross toolchain. The clone and the build happen in a
# temporary folder outside this repository. Needs git and
# `brew install llvm lld`. After replacing the image, update the commit,
# toolchain, SHA-256 and size in Resources/OpenAVB/README.md and the pinned
# commit below, then boot and restore a machine with it.
set -euo pipefail

repository="https://github.com/owngoal-dev/OpenAVB.git"
pinned="65a776e9ae00b2e1de22b18cbbad1359945d7277"

root="$(cd "${0:a:h}/../../.." && pwd)"
destination="$root/VPhoneExecutable/VPhoneVirtualization/Resources/OpenAVB"
commit="${1:-$pinned}"
llvm="${LLVM_PREFIX:-/opt/homebrew/opt/llvm/bin}"

for tool in "$llvm/clang" "$llvm/llvm-objcopy" /opt/homebrew/bin/ld.lld; do
    [[ -x "$tool" ]] || { print -u2 "Missing $tool (brew install llvm lld)"; exit 1; }
done

work="$(/usr/bin/mktemp -d)"
trap '/bin/rm -rf "$work"' EXIT
/usr/bin/git clone --quiet "$repository" "$work/OpenAVB"
/usr/bin/git -C "$work/OpenAVB" checkout --quiet --detach "$commit"
for patch in "$destination"/patches/*.patch(N); do
    /usr/bin/git -C "$work/OpenAVB" apply --whitespace=nowarn "$patch" || {
        print -u2 "${patch:t} does not apply to $commit; refresh it, or delete it if upstream has it"
        exit 1
    }
    print "patch   ${patch:t}"
done
/usr/bin/make -C "$work/OpenAVB" LLVM_PREFIX="$llvm" build/OpenAVB.bin >/dev/null

built="$work/OpenAVB/build/OpenAVB.bin"
print "commit  $(/usr/bin/git -C "$work/OpenAVB" rev-parse HEAD)"
print "sha256  $(/usr/bin/shasum -a 256 "$built" | /usr/bin/awk '{print $1}')"
print "size    $(/usr/bin/stat -f %z "$built")"
print "clang   $("$llvm/clang" --version | /usr/bin/head -1)"
print "ld.lld  $(/opt/homebrew/bin/ld.lld --version)"

if (( $# == 0 )); then
    /usr/bin/cmp "$built" "$destination/OpenAVB.bin" || {
        print -u2 "The pinned commit does not build the checked-in OpenAVB.bin with this toolchain."
        exit 1
    }
    print "OpenAVB.bin matches $pinned"
else
    /bin/cp "$built" "$destination/OpenAVB.bin"
    /bin/cp "$work/OpenAVB/LICENSE" "$destination/LICENSE"
    /bin/cp "$work/OpenAVB/LICENSES/APSL-2.0.txt" "$destination/APSL-2.0.txt"
    /bin/chmod 644 "$destination/OpenAVB.bin" "$destination/LICENSE" "$destination/APSL-2.0.txt"
    print "Replaced $destination/OpenAVB.bin; update README.md and the pinned commit."
fi
