#!/bin/bash
# Builds the mcmetal mod jar: drop it in a NeoForge 1.21.1 mods folder and the game runs on Metal, no JVM arguments.
#   bash mod/build_mod.sh LIBRARIES OUT.jar [NATIVES_DIR]
# LIBRARIES is a Minecraft libraries folder with NeoForge 21.1 installed (compile-time API jars come from it);
# NATIVES_DIR (default build/) holds libmcmetal.dylib and libglfw.dylib. Needs a JDK 21, or else zip plus the
# committed mod/prebuilt/mcmetal-classes.jar. `bash mod/build_mod.sh LIBRARIES --prebuilt` refreshes that jar.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
LIB=$1
if [ "$2" = --prebuilt ]; then # class jar without natives, committed for machines without a JDK
    CP0=$(find "$LIB" -path "*/net/neoforged/fancymodloader/loader/*" -name '*.jar' ! -name '*sources*' | sort -V | tail -1)
    CP0=$CP0:$(find "$LIB" -path "*/cpw/mods/modlauncher/*" -name '*.jar' | sort -V | tail -1)
    CP0=$CP0:$(find "$LIB" -path "*/org/ow2/asm/asm-tree/*" -name '*.jar' | sort -V | tail -1):$(find "$LIB" -path "*/org/ow2/asm/asm/*" -name '*.jar' | sort -V | tail -1)
    CP0=$CP0:$(find "$LIB" -path "*/org/lwjgl/lwjgl/*" -name 'lwjgl-3*.jar' ! -name '*natives*' ! -name '*sources*' | sort -V | tail -1)
    CP0=$CP0:$(find "$LIB" -path "*/org/lwjgl/lwjgl-opengl/*" -name '*.jar' ! -name '*natives*' ! -name '*sources*' | sort -V | tail -1)
    CP0=$CP0:$(find "$LIB" -path "*/org/joml/joml/*" -name '*.jar' ! -name '*sources*' | sort -V | tail -1)
    W=$(mktemp -d)
    javac --release 21 -nowarn -d "$W/stubs" $(find "$HERE/stubs" -name '*.java') -cp "$CP0"
    javac --release 21 -nowarn -cp "$CP0:$W/stubs" -d "$W/classes" $(find "$HERE/src" -name '*.java')
    cp -r "$HERE/resources/." "$W/classes/"
    printf 'Automatic-Module-Name: mcmetal.loader\nImplementation-Title: mcmetal\n' > "$W/manifest"
    mkdir -p "$HERE/prebuilt"
    jar --create --file "$HERE/prebuilt/mcmetal-classes.jar" --manifest "$W/manifest" -C "$W/classes" .
    rm -rf "$W"
    echo "built $HERE/prebuilt/mcmetal-classes.jar"
    exit 0
fi
OUT=$(cd "$(dirname "$2")" && pwd)/$(basename "$2"); NAT=${3:-$HERE/../build}
cp_of() { find "$LIB" -path "*/$1/*" -name '*.jar' ! -name '*sources*' | sort -V | tail -1; }
CP=$(cp_of net/neoforged/fancymodloader/loader):$(cp_of cpw/mods/modlauncher):$(cp_of org/ow2/asm/asm-tree):$(cp_of org/ow2/asm/asm)
# the GPU culling hooks (src/mcmetal/loader/sodium) also see LWJGL, JOML and stand-ins for Sodium/Iris (stubs/,
# signatures only, compiled separately and left out of the jar)
CP=$CP:$(find "$LIB" -path "*/org/lwjgl/lwjgl/*" -name 'lwjgl-3*.jar' ! -name '*natives*' ! -name '*sources*' | sort -V | tail -1)
CP=$CP:$(find "$LIB" -path "*/org/lwjgl/lwjgl-opengl/*" -name '*.jar' ! -name '*natives*' ! -name '*sources*' | sort -V | tail -1)
CP=$CP:$(cp_of org/joml/joml)
W=$(mktemp -d)
mkdir -p "$W/classes"
if javac -version >/dev/null 2>&1 && jar --version >/dev/null 2>&1; then # macOS ships /usr/bin stubs without a JDK
    javac --release 21 -nowarn -cp "$CP" -d "$W/stubs" $(find "$HERE/stubs" -name '*.java')
    javac --release 21 -nowarn -cp "$CP:$W/stubs" -d "$W/classes" $(find "$HERE/src" -name '*.java')
    cp -r "$HERE/resources/." "$W/classes/"
    printf 'Automatic-Module-Name: mcmetal.loader\nImplementation-Title: mcmetal\n' > "$W/manifest"
    mkdir -p "$W/classes/natives"
    cp "$NAT/libmcmetal.dylib" "$NAT/libglfw.dylib" "$W/classes/natives/"
    jar --create --file "$OUT" --manifest "$W/manifest" -C "$W/classes" .
else
    # only a Java runtime here (e.g. a launcher's JRE on a Mac): start from the committed class jar
    # (mod/prebuilt/mcmetal-classes.jar, rebuilt with `bash mod/build_mod.sh LIBRARIES - ` on a JDK) and add natives
    echo "no javac/jar: using mod/prebuilt/mcmetal-classes.jar"
    cp "$HERE/prebuilt/mcmetal-classes.jar" "$OUT"
    mkdir -p "$W/natives"
    cp "$NAT/libmcmetal.dylib" "$NAT/libglfw.dylib" "$W/natives/"
    (cd "$W" && zip -q -r "$OUT" natives)
fi
rm -rf "$W"
echo "built $OUT ($(du -h "$OUT" | cut -f1))"
