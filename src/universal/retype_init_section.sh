#!/bin/sh

# Stockfish, a UCI chess playing engine derived from Glaurung 2.1
# Copyright (C) 2004-2026 The Stockfish developers (see AUTHORS file)
#
# Stockfish is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# Stockfish is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program.  If not, see <http://www.gnu.org/licenses/>.

# Retype a tier's renamed initializer section to plain data, so the final link
# keeps it as __DATA,<section> for entry_x86.cpp to find with getsectiondata(),
# and dyld does not run it.
#
# `ld -r -rename_section` changes the name and keeps the section type,
# S_MOD_INIT_FUNC_POINTERS. A linker that collects initializers by type -- Xcode
# 26's ld-1267 does -- folds every tier's section into __TEXT,__init_offsets, so
# dyld runs all of them at load, the AVX-512 tiers' included, and the slice dies
# of SIGILL before main on any CPU without AVX-512.
#
# Usage: retype_init_section.sh <macho_object> <section>

set -eu

OBJ="$1"
SECT="$2"

die() { echo "retype_init_section: $*" >&2; exit 1; }

# Hex of a name NUL-padded to 16 bytes, as section_64 stores sectname and segname
name16() {
    h=$(printf '%s' "$1" | xxd -p | tr -d '\n')
    [ ${#h} -le 32 ] || die "name longer than 16 bytes: $1"
    while [ ${#h} -lt 32 ]; do h="${h}00"; done
    echo "$h"
}

[ "$(xxd -p -l 4 "$OBJ")" = cffaedfe ] || die "$OBJ is not a 64-bit Mach-O"

needle="$(name16 "$SECT")$(name16 __DATA)"

# Search only the load commands, which follow the 32-byte mach_header_64 and
# hold the section headers, and only at byte-aligned hex positions
sizeofcmds=$(od -An -tu4 -j20 -N4 "$OBJ" | tr -d ' ')
pos=$(xxd -p -l $((32 + sizeofcmds)) "$OBJ" | tr -d '\n' | awk -v n="$needle" '{
    s = $0; o = 0
    while ((p = index(s, n)) > 0) {
        if ((o + p) % 2 == 1) { print (o + p - 1) / 2; exit }
        o += p; s = substr(s, p + 1)
    }
}')
[ -n "$pos" ] || die "no section __DATA,$SECT in $OBJ"

# section_64.flags is at offset 64, and its low byte is the section type
flags=$((pos + 64))
case $(xxd -s "$flags" -l 1 -p "$OBJ") in
    00) ;;
    09) printf '\000' | dd of="$OBJ" bs=1 seek="$flags" conv=notrunc 2>/dev/null ;;
    *)  die "__DATA,$SECT in $OBJ has a section type other than S_MOD_INIT_FUNC_POINTERS" ;;
esac
