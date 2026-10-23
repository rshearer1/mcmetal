#!/bin/bash
# The biome cache against Minecraft's own getBiome (see BiomeCheck.java).  bash tests/biome/check.sh WORK
# WORK is a bare_mc.py install (WORK/mc/libraries). Needs a JDK 21.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
LIB=$1/mc/libraries
CP=$(find "$LIB" -name '*.jar' ! -name '*sources*' ! -name '*natives*' ! -name '*-slim.jar' ! -name '*-extra.jar' | tr '\n' ':')
W=$(mktemp -d)
javac --release 21 -nowarn -cp "$CP" -d "$W" "$HERE/../../mod/src/mcmetal/loader/biome/BiomeHooks.java" "$HERE/BiomeCheck.java"
java -cp "$W:$CP" BiomeCheck
rm -rf "$W"
