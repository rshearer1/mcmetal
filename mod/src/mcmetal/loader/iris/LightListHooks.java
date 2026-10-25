package mcmetal.loader.iris;

import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.HashSet;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

import net.irisshaders.iris.shaderpack.materialmap.BlockEntry;
import net.irisshaders.iris.shaderpack.materialmap.NamespacedId;

/**
 * One light list for every shader pack, on unless MCMETAL_LIGHT_LIST=0.
 *
 * Not used as a class: LightListTransformer copies these static methods into Iris's IdMap (names prefixed
 * "mcmetal$") and calls addLights(blockPropertiesMap) at the end of its constructor, once Iris has read the pack's
 * block.properties. Packs light only the blocks they name there, so modded lights (and, in SEUS PTGI E12, every light
 * newer than Minecraft 1.14) stay dark. Each light in mcmetal/lights.tsv that the pack does not name joins the id of
 * its colour's first vanilla twin (mcmetal/light-twins.tsv) that the pack does name, so the pack lights it the way it
 * lights that vanilla block. Blocks the pack names itself are left alone, and so are the pack's files: this is the
 * list Iris holds in memory. Iris skips names that aren't installed. Rows in <game>/mcmetal/lights.tsv add to or
 * replace the built-in list. Compiled against signature stubs in mod/stubs; no static initializer, lambdas or
 * nested classes (they would not be copied).
 */
public final class LightListHooks {
    private LightListHooks() {
    }

    public static void addLights(Map<Integer, List<BlockEntry>> map) {
        String list = System.getProperty("mcmetal.lights.list"), twinText = System.getProperty("mcmetal.lights.twins");
        if (map == null || map.isEmpty() || list == null || twinText == null)
            return;
        Path own = Path.of("mcmetal", "lights.tsv");
        try {
            if (Files.isRegularFile(own))
                list = list + "\n" + Files.readString(own);
        } catch (Exception e) {
            System.out.println("[mcmetal] light list: could not read " + own.toAbsolutePath() + ": " + e);
        }
        // the blocks the pack names, and the id of each one it names without states (or only as lit=true and the like)
        HashSet<String> named = new HashSet<>();
        HashMap<String, Integer> idOf = new HashMap<>();
        for (Map.Entry<Integer, List<BlockEntry>> e : map.entrySet())
            for (BlockEntry b : e.getValue()) {
                String name = b.id().getNamespace() + ":" + b.id().getName();
                named.add(name);
                boolean plain = true;
                for (String v : b.propertyPredicates().values())
                    plain &= v.equals("true");
                if (plain && !idOf.containsKey(name))
                    idOf.put(name, e.getKey()); // Iris keeps a block's first id, so the first one is the one it uses
            }
        // packs on Minecraft's old numeric ids (SEUS PTGI: torch 50, glowstone 89) glow only for a fixed set of them
        // and name other blocks too (end_rod 198 doesn't glow there), so only those ids count as twins
        Integer torchId = idOf.get("minecraft:torch"), glowId = idOf.get("minecraft:glowstone");
        boolean legacy = torchId != null && torchId == 50 && glowId != null && glowId == 89;
        if (legacy) {
            HashMap<String, Integer> lights = new HashMap<>();
            for (Map.Entry<String, Integer> e : idOf.entrySet()) {
                int id = e.getValue();
                if (id == 10 || id == 50 || id == 51 || id == 76 || id == 89 || id == 91 || id == 124 || id == 169)
                    lights.put(e.getKey(), id);
            }
            idOf = lights;
        }
        HashMap<String, String[]> twins = new HashMap<>();
        for (String line : twinText.split("\n")) {
            String[] f = line.split("\t");
            if (!line.startsWith("#") && f.length == 2)
                twins.put(f[0].trim(), f[1].trim().split(" +"));
        }
        LinkedHashMap<String, String[]> rows = new LinkedHashMap<>(); // later rows (the player's own file) win
        for (String line : list.split("\n")) {
            String[] f = line.split("\t");
            if (!line.startsWith("#") && f.length >= 4 && f[0].indexOf(':') > 0)
                rows.put(f[0].trim(), f);
        }
        HashMap<Integer, ArrayList<BlockEntry>> add = new HashMap<>();
        HashMap<String, Integer> perTwin = new HashMap<>();
        StringBuilder dump = new StringBuilder("# id\tblock\tstates\ttwin (MCMETAL_LIGHT_LIST_DUMP)\n");
        int added = 0, packNames = 0, noTwin = 0;
        for (String[] f : rows.values()) {
            String block = f[0].trim();
            if (named.contains(block)) {
                packNames++;
                continue;
            }
            String[] chain = twins.get(f[3].trim());
            if (chain == null)
                chain = twins.get("torch");
            Integer id = null;
            String twin = null;
            for (int i = 0; chain != null && i < chain.length && id == null; i++) {
                twin = chain[i].contains(":") ? chain[i] : "minecraft:" + chain[i];
                id = idOf.get(twin);
            }
            if (id == null) {
                noTwin++;
                continue;
            }
            int colon = block.indexOf(':');
            NamespacedId nid = new NamespacedId(block.substring(0, colon), block.substring(colon + 1));
            ArrayList<BlockEntry> to = add.get(id);
            if (to == null)
                add.put(id, to = new ArrayList<>());
            String states = f[1].trim();
            int eq = states.indexOf('=');
            if (eq < 0) {
                to.add(new BlockEntry(nid, Map.of()));
            } else {
                for (String v : states.substring(eq + 1).split(","))
                    to.add(new BlockEntry(nid, Map.of(states.substring(0, eq), v.trim())));
            }
            added++;
            dump.append(id).append('\t').append(block).append('\t').append(states).append('\t').append(twin).append('\n');
            Integer n = perTwin.get(twin);
            perTwin.put(twin, n == null ? 1 : n + 1);
        }
        for (Map.Entry<Integer, ArrayList<BlockEntry>> e : add.entrySet()) {
            ArrayList<BlockEntry> all = new ArrayList<>(map.get(e.getKey())); // the pack's own entries first
            all.addAll(e.getValue());
            map.put(e.getKey(), all);
        }
        String dumpTo = System.getenv("MCMETAL_LIGHT_LIST_DUMP"); // a file: what each listed light was given
        try {
            if (dumpTo != null && !dumpTo.isEmpty())
                Files.writeString(Path.of(dumpTo), dump);
        } catch (Exception e) {
            System.out.println("[mcmetal] light list: could not write " + dumpTo + ": " + e);
        }
        StringBuilder how = new StringBuilder();
        for (Map.Entry<String, Integer> e : perTwin.entrySet())
            how.append(how.length() == 0 ? "" : ", ").append(e.getValue()).append(" like ").append(e.getKey().replace("minecraft:", ""));
        System.out.println("[mcmetal] light list: " + added + " lights added to the shader pack's block ids (" + how + "); "
                + packNames + " the pack names itself" + (legacy ? " (old numeric ids, as SEUS PTGI)" : "") + (noTwin > 0 ? ", " + noTwin + " with no twin in the pack" : ""));
    }
}
