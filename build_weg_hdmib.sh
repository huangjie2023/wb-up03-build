#!/bin/bash
# Builds WhateverGreen with the HDMIB module (HDMI on DDI B for Intel Ice Lake).
# Usage:   bash build_weg_hdmib.sh [--debug]       (run it in the folder that contains kern_igfx_hdmib.hpp)
#          WEG_REF=<commit|tag> LILU_REF=<commit|tag> bash build_weg_hdmib.sh      (optional: pin upstream versions)
# Works on an Intel Mac or Apple Silicon (the kext is always x86_64). Needs full Xcode (not only the Command Line Tools).
# Result:  ./WhateverGreen-HDMIB.kext     (nothing in your EFI is touched)
# Last compile-checked against: WhateverGreen 093e76f (2026-09-27) + Lilu 0249c3a (2026-10-26).
set -e
CONF=Release; [ "$1" = "--debug" ] && CONF=Debug
HERE="$(cd "$(dirname "$0")" && pwd)"
W="$HERE/build_hdmib"
[ -f "$HERE/kern_igfx_hdmib.hpp" ] || { echo "kern_igfx_hdmib.hpp must be next to this script"; exit 1; }
rm -rf "$W"; mkdir -p "$W"; cd "$W"

xcodebuild -version >/dev/null 2>&1 || { echo "Full Xcode is required (not only the Command Line Tools). Try: sudo xcode-select -s /Applications/Xcode.app/Contents/Developer"; exit 1; }

clone() { git clone -q https://github.com/acidanthera/$1.git; [ -n "$2" ] && git -C $1 checkout -q "$2"; true; }
clone Lilu "$LILU_REF"; clone MacKernelSDK; clone WhateverGreen "$WEG_REF"
echo "Lilu $(git -C Lilu rev-parse --short HEAD)  WhateverGreen $(git -C WhateverGreen rev-parse --short HEAD)"

# 1) Lilu (Debug) with its SDK
cp -R MacKernelSDK Lilu/MacKernelSDK
( cd Lilu && xcodebuild -project Lilu.xcodeproj -scheme Lilu -configuration Debug -sdk macosx \
    ARCHS=x86_64 ONLY_ACTIVE_ARCH=NO CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO build \
    SYMROOT="$W/lilu_out" >/dev/null )
cp -R "$W/lilu_out/Debug/Lilu.kext" WhateverGreen/Lilu.kext
cp -R MacKernelSDK WhateverGreen/MacKernelSDK

# 2) Add the module to WhateverGreen (three edits to kern_igfx.cpp)
cp "$HERE/kern_igfx_hdmib.hpp" WhateverGreen/WhateverGreen/
F=WhateverGreen/WhateverGreen/kern_igfx.cpp
perl -0pi -e 's/(#include "kern_igfx\.hpp"\n)/$1#include "kern_igfx_hdmib.hpp"\n/' "$F"
# up02: inject the connector DeviceProperties before WhateverGreen reads them (default-on, no config patch needed)
perl -0pi -e 's/(\t\tapplyFramebufferPatch = loadPatchesFromDevice\()/\t\tHDMIB::injectDeviceProperties(info->videoBuiltin);\n\n$1/' "$F"
perl -0pi -e 's/(\t\tif \(applyFramebufferPatch \|\| dumpFramebufferToDisk \|\| dumpPlatformTable \|\| hdmiAutopatch\) \{\n\t\t\tframebufferStart)/\t\tHDMIB::install(patcher, index, address, size);\n\n$1/' "$F"

# up02: 02id-only platform-table lookup. Stock findFramebufferId scans one PAGE_SIZE; on Darwin 25 the
# ICLLP entry #20 (0x8A5C0002) is at offset 5600, past that page, so the lookup returned null and no HDMI
# connector was created. Scan one fixed 8 KiB window and match 0x8A5C0002 directly (one occurrence only).
cat > "$W/find_framebuffer_id.cpp" <<'FBIDEOF'
uint8_t *IGFX::findFramebufferId(uint32_t framebufferId, uint8_t *startingAddress, size_t maxSize) {
	(void)framebufferId;
	(void)maxSize;
	uint32_t *p = reinterpret_cast<uint32_t *>(startingAddress);
	uint32_t *end = reinterpret_cast<uint32_t *>(startingAddress + 0x2000);
	for (; p < end; p++)
		if (*p == 0x8A5C0002u)
			return reinterpret_cast<uint8_t *>(p);
	return nullptr;
}
FBIDEOF
FBID_NEW="$W/find_framebuffer_id.cpp" perl -0777 -i -pe '
	BEGIN { open(my $fh, "<", $ENV{FBID_NEW}) or die "cannot read the replacement text"; local $/; $new = <$fh>; }
	s{uint8_t \*IGFX::findFramebufferId\(uint32_t framebufferId, uint8_t \*startingAddress, size_t maxSize\) \{.*?\n\}}{$new}s;
' "$F"

[ "$(grep -c 'HDMIB::install' "$F")" = "1" ] && [ "$(grep -c 'kern_igfx_hdmib.hpp' "$F")" = "1" ] \
  && [ "$(grep -c 'HDMIB::injectDeviceProperties' "$F")" = "1" ] \
  && [ "$(grep -c '0x8A5C0002u' "$F")" = "1" ] \
  || { echo "ERROR: the edits to kern_igfx.cpp could not be applied (this WhateverGreen version differs). See README.md, 'Hooking into WhateverGreen'."; exit 1; }

# 3) WhateverGreen
( cd WhateverGreen && xcodebuild -project WhateverGreen.xcodeproj -scheme WhateverGreen -configuration $CONF -sdk macosx \
    ARCHS=x86_64 ONLY_ACTIVE_ARCH=NO CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO build \
    SYMROOT="$W/weg_out" )
rm -rf "$HERE/WhateverGreen-HDMIB.kext"
cp -R "$W/weg_out/$CONF/WhateverGreen.kext" "$HERE/WhateverGreen-HDMIB.kext"
echo
echo "DONE: $HERE/WhateverGreen-HDMIB.kext   (kext version: $(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$HERE/WhateverGreen-HDMIB.kext/Contents/Info.plist" 2>/dev/null))"
echo "Use it INSTEAD of the stock WhateverGreen.kext (never both), and add the boot-arg -igfxhdmib."
