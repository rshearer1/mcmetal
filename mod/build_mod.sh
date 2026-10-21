#!/bin/bash
# Builds the mcmetal mod jar: drop it in a NeoForge 1.21.1 mods folder and the game runs on Metal, no JVM arguments.
#   bash mod/build_mod.sh LIBRARIES OUT.jar [NATIVES_DIR]
# LIBRARIES is a Minecraft libraries folder with NeoForge 21.1 installed (compile-time API jars come from it);
# NATIVES_DIR (default build/) holds libmcmetal.dylib and libglfw.dylib. Needs a JDK 21.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
LIB=$1; OUT=$(cd "$(dirname "$2")" && pwd)/$(basename "$2"); NAT=${3:-$HERE/../build}
cp_of() { find "$LIB" -path "*/$1/*" -name '*.jar' ! -name '*sources*' | sort -V | tail -1; }
CP=$(cp_of net/neoforged/fancymodloader/loader):$(cp_of cpw/mods/modlauncher):$(cp_of org/ow2/asm/asm-tree):$(cp_of org/ow2/asm/asm)
W=$(mktemp -d)
javac --release 21 -nowarn -cp "$CP" -d "$W/classes" $(find "$HERE/src" -name '*.java')
cp -r "$HERE/resources/." "$W/classes/"
mkdir -p "$W/classes/natives"
cp "$NAT/libmcmetal.dylib" "$NAT/libglfw.dylib" "$W/classes/natives/"
printf 'Automatic-Module-Name: mcmetal.loader\nImplementation-Title: mcmetal\n' > "$W/manifest"
jar --create --file "$OUT" --manifest "$W/manifest" -C "$W/classes" .
rm -rf "$W"
echo "built $OUT ($(du -h "$OUT" | cut -f1))"
