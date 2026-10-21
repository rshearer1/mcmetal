#!/usr/bin/env python3
"""Bare Minecraft 1.21.1 + NeoForge + Sodium + Iris test instance, for the Metal layer. macOS or Linux.

  python3 -I bare_mc.py setup WORK
  python3 -I bare_mc.py launch WORK [--world NAME] [--java PATH] [--gl LIB] [--glfw LIB] [--xmx 4G] [-- extra JVM args]

--gl LIB   -> -Dorg.lwjgl.opengl.libname=LIB  (our libmcmetal.dylib)
--glfw LIB -> -Dorg.lwjgl.glfw.libname=LIB    (our patched GLFW)
Everything lives under WORK; no launcher, no Modrinth App files are touched. Needs Java 21 (pass --java if
`java` on PATH isn't 21). Game log: WORK/client.log, pid: WORK/client.pid.
"""
import concurrent.futures as cf, hashlib, json, os, platform, shutil, subprocess, sys, urllib.request

MC, NEOFORGE = "1.21.1", "21.1.259"
MANIFEST = "https://piston-meta.mojang.com/mc/game/version_manifest_v2.json"
NF_INSTALLER = f"https://maven.neoforged.net/releases/net/neoforged/neoforge/{NEOFORGE}/neoforge-{NEOFORGE}-installer.jar"
MODS = [
    ("https://cdn.modrinth.com/data/AANobbMI/versions/uMOpc5uV/sodium-neoforge-0.8.13%2Bmc1.21.1.jar",
     "sodium-neoforge-0.8.13+mc1.21.1.jar", "1757289be21ed18db5b0d90703fa3db1b2de5693"),
    ("https://cdn.modrinth.com/data/YL57xq9U/versions/KduFYu4t/iris-neoforge-1.8.14-beta.1%2Bmc1.21.1.jar",
     "iris-neoforge-1.8.14-beta.1+mc1.21.1.jar", "1bd129cf7bce65d6b1c0543045f0620c98a0f885"),
]
COMPLEMENTARY = ("https://cdn.modrinth.com/data/HVnmMxH1/versions/Bqen1mJX/ComplementaryReimagined_r5.9.3.zip",
                 "ComplementaryReimagined_r5.9.3.zip", "838139b54cddb56b2e83cd260d8efd960ac536d6")
OS = "osx" if platform.system() == "Darwin" else "linux"


def sha1_of(path):
    h = hashlib.sha1()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def fetch(url, dest, sha1=None):
    if os.path.exists(dest) and (sha1 is None or sha1_of(dest) == sha1):
        return dest
    os.makedirs(os.path.dirname(dest), exist_ok=True)
    tmp = dest + ".part"
    for attempt in range(4):
        try:
            with urllib.request.urlopen(url, timeout=120) as r, open(tmp, "wb") as f:
                shutil.copyfileobj(r, f)
            break
        except Exception:
            if attempt == 3:
                raise
    if sha1 and sha1_of(tmp) != sha1:
        raise RuntimeError(f"hash mismatch for {url}")
    os.replace(tmp, dest)
    return dest


def rules_ok(rules):
    if not rules:
        return True
    ok = False
    for r in rules:
        if "features" in r:
            continue
        o = r.get("os", {})
        if o.get("name") not in (None, OS):
            continue
        if o.get("arch") == "x86":
            continue
        ok = r["action"] == "allow"
    return ok


def setup(work, java):
    mc, game = os.path.join(work, "mc"), os.path.join(work, "game")
    man = json.load(urllib.request.urlopen(MANIFEST))
    ventry = next(v for v in man["versions"] if v["id"] == MC)
    vjson = json.load(open(fetch(ventry["url"], f"{mc}/versions/{MC}/{MC}.json")))
    jobs = []
    for lib in vjson["libraries"]:
        art = lib.get("downloads", {}).get("artifact")
        if art and rules_ok(lib.get("rules")):
            jobs.append((art["url"], f"{mc}/libraries/{art['path']}", art["sha1"]))
    cl = vjson["downloads"]["client"]
    jobs.append((cl["url"], f"{mc}/versions/{MC}/{MC}.jar", cl["sha1"]))
    ai = vjson["assetIndex"]
    aidx = json.load(open(fetch(ai["url"], f"{mc}/assets/indexes/{ai['id']}.json", ai["sha1"])))
    for obj in aidx["objects"].values():
        h = obj["hash"]
        jobs.append((f"https://resources.download.minecraft.net/{h[:2]}/{h}", f"{mc}/assets/objects/{h[:2]}/{h}", h))
    print(f"vanilla: {len(jobs)} files", flush=True)
    with cf.ThreadPoolExecutor(16) as ex:
        list(ex.map(lambda j: fetch(*j), jobs))
    if not os.path.exists(f"{mc}/versions/neoforge-{NEOFORGE}/neoforge-{NEOFORGE}.json"):
        inst = fetch(NF_INSTALLER, f"{mc}/neoforge-{NEOFORGE}-installer.jar")
        lp = f"{mc}/launcher_profiles.json"
        if not os.path.exists(lp):
            json.dump({"profiles": {}}, open(lp, "w"))
        subprocess.run([java, "-jar", inst, "--install-client", mc], check=True, cwd=mc)
    for url, name, sha in MODS:
        fetch(url, os.path.join(game, "mods", name), sha)
    url, name, sha = COMPLEMENTARY
    fetch(url, os.path.join(game, "shaderpacks", name), sha)
    json.dump({"mc": MC, "neoforge": NEOFORGE, "assetIndex": ai["id"]}, open(os.path.join(work, "install.json"), "w"))
    print("setup done", flush=True)


def launch(work, java, world, gl, glfw, xmx, extra):
    inst = json.load(open(os.path.join(work, "install.json")))
    mc, game = os.path.join(work, "mc"), os.path.join(work, "game")
    libdir = os.path.join(mc, "libraries")
    nfid = f"neoforge-{inst['neoforge']}"
    nf = json.load(open(f"{mc}/versions/{nfid}/{nfid}.json"))
    van = json.load(open(f"{mc}/versions/{inst['mc']}/{inst['mc']}.json"))
    cp, seen = [], set()
    for lib in nf["libraries"] + van["libraries"]:
        if not rules_ok(lib.get("rules")):
            continue
        parts = lib["name"].split(":")
        key = (parts[0], parts[1], parts[3] if len(parts) > 3 else "")
        art = lib.get("downloads", {}).get("artifact")
        if key in seen or not art:
            continue
        seen.add(key)
        p = os.path.join(libdir, art["path"])
        if os.path.exists(p):
            cp.append(p)
    subs = {
        "${library_directory}": libdir, "${classpath_separator}": ":", "${version_name}": nfid,
        "${natives_directory}": os.path.join(work, "natives"), "${launcher_name}": "mcmetal-test",
        "${launcher_version}": "1", "${classpath}": ":".join(cp), "${auth_player_name}": "MetalTest",
        "${version_type}": "release", "${game_directory}": game, "${assets_root}": os.path.join(mc, "assets"),
        "${assets_index_name}": inst["assetIndex"], "${auth_uuid}": "00000000000000000000000000000001",
        "${auth_access_token}": "0", "${clientid}": "0", "${auth_xuid}": "0", "${user_type}": "legacy",
    }

    def expand(items):
        out = []
        for a in items:
            if isinstance(a, dict):
                if not rules_ok(a.get("rules")):
                    continue
                vals = a["value"] if isinstance(a["value"], list) else [a["value"]]
            else:
                vals = [a]
            for v in vals:
                for k, s in subs.items():
                    v = v.replace(k, s)
                out.append(v)
        return out

    jvm = ["-Xmx" + xmx, "-Xms1G"]
    if gl:
        jvm.append("-Dorg.lwjgl.opengl.libname=" + os.path.abspath(gl))
    if glfw:
        jvm.append("-Dorg.lwjgl.glfw.libname=" + os.path.abspath(glfw))
    jvm += extra + expand(van["arguments"]["jvm"]) + expand(nf["arguments"]["jvm"])
    gargs = expand(van["arguments"]["game"]) + expand(nf["arguments"]["game"]) + ["--width", "1280", "--height", "720"]
    if world:
        gargs += ["--quickPlaySingleplayer", world]
    os.makedirs(os.path.join(work, "natives"), exist_ok=True)
    log = open(os.path.join(work, "client.log"), "w")
    env = dict(os.environ)
    if gl:  # our patched GLFW finds libmcmetal through this
        env.setdefault("MCMETAL_LIB", os.path.abspath(gl))
    proc = subprocess.Popen([java] + jvm + [nf["mainClass"]] + gargs, cwd=game, stdout=log,
                            stderr=subprocess.STDOUT, start_new_session=True, env=env)
    open(os.path.join(work, "client.pid"), "w").write(str(proc.pid))
    print(f"client pid {proc.pid}, log {work}/client.log", flush=True)


def opt(name, default=None):
    return sys.argv[sys.argv.index(name) + 1] if name in sys.argv else default


if __name__ == "__main__":
    cmd, work = sys.argv[1], os.path.abspath(sys.argv[2])
    java = opt("--java", "java")
    extra = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
    if cmd == "setup":
        setup(work, java)
    else:
        launch(work, java, opt("--world"), opt("--gl"), opt("--glfw"), opt("--xmx", "4G"), extra)
