#!/usr/bin/env python3
import ast, gzip, io, json, lzma, os, re, shlex, shutil, struct, subprocess, sys
import tarfile, tempfile, time, urllib.request

ALPINE, PYVER_ALPINE = "v3.20", "3.12"
DEB_SUITE, PYVER_DEB = "bookworm", "3.11"
ARCH = "x86_64"
CACHE = None

DEFAULTS = {
    "core": "alpine",           # alpine | debian
    "compressing": "normal",    # slim | normal | full
    "ui": False,                # boot into an X11 session (tkinter works)
    "net": False,               # DHCP at boot (forced on when slim/normal need downloads)
    "gpudrivers": False,        # open-source GPU drivers + firmware
    "serial": False,            # also print on serial port (QEMU testing)
    "shell": False,             # shell after MAIN ends (else power off)
    "bash": True,               # GNU bash on Alpine (Debian always has it)
    "cmdline": "",              # extra kernel parameters
    "packages": "",             # extra OS packages, comma separated
    "main": "", "setup": "", "require": "", "version": "",
    "iso_name": "OUT.iso", "build_folder": "build",
}
BOOLS = {"ui", "net", "gpudrivers", "serial", "shell", "bash"}
ALIASES = {"requre": "require", "requires": "require", "iso": "iso_name",
           "isoname": "iso_name", "build": "build_folder", "gpu": "gpudrivers"}

BASH_PKGS = ["bash", "coreutils", "grep", "sed", "findutils"]
APK_UI = ["python3-tkinter", "xorg-server", "xinit", "xf86-video-fbdev",
          "xf86-video-vesa", "xf86-input-libinput", "eudev", "font-dejavu"]
APK_GPU = ["eudev", "libdrm", "mesa-dri-gallium", "mesa-egl", "mesa-gl", "mesa-gbm",
           "mesa-vulkan-ati", "mesa-vulkan-intel", "vulkan-loader"]
FIRMWARE = ["linux-firmware-amdgpu", "linux-firmware-radeon",
            "linux-firmware-i915", "linux-firmware-nvidia"]
DEB_BASE = ["python3", "bash", "coreutils", "grep", "sed", "findutils", "kmod", "busybox-static"]
DEB_UI = ["python3-tk", "xserver-xorg-core", "xinit", "xserver-xorg-video-fbdev",
          "xserver-xorg-video-vesa", "xserver-xorg-input-libinput", "fonts-dejavu-core", "udev"]
DEB_GPU = ["udev", "libdrm2", "libgl1-mesa-dri", "mesa-vulkan-drivers"]
DEB_SKIP = {"dpkg", "debconf", "debconf-2.0", "ucf", "perl-base"}

IMPORT_TO_PIP = {"PIL": "pillow", "cv2": "opencv-python-headless", "yaml": "pyyaml",
                 "sklearn": "scikit-learn", "bs4": "beautifulsoup4",
                 "dateutil": "python-dateutil", "serial": "pyserial",
                 "dotenv": "python-dotenv"}

# Runs inside the ISO at Python start-up (PYTHONPATH): os.exec / os.stream / os.apt
SITECUSTOMIZE = '''import os, subprocess, sys

class _Result:
    def __init__(self, returncode, stdout):
        self.returncode, self.stdout = returncode, stdout
    def __bool__(self):
        return self.returncode == 0

def _popen(cmd, **kw):
    if isinstance(cmd, str) and os.path.exists("/bin/bash"):
        kw.setdefault("executable", "/bin/bash")
    return subprocess.Popen(cmd, shell=isinstance(cmd, str), text=True, bufsize=1,
                            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, **kw)

# os.exec("cmd") returns a result (.stdout, .returncode) and prints nothing.
# A bare statement  os.exec("cmd")  prints live (py2iso rewrites it to exec_show).
# show=True forces printing even when assigned; quiet=True forces silence.
# on_line=fn: fn(line) per line   check=True: raise on failure
# interactive=True: real terminal (htop, nano); output is not captured
def _exec(cmd, show=False, quiet=False, capture=False, check=False,
          on_line=None, interactive=False, **kw):
    if interactive:
        if isinstance(cmd, str) and os.path.exists("/bin/bash"):
            kw.setdefault("executable", "/bin/bash")
        r = subprocess.run(cmd, shell=isinstance(cmd, str), **kw)
        if check and r.returncode:
            raise subprocess.CalledProcessError(r.returncode, cmd)
        return _Result(r.returncode, "")
    p = _popen(cmd, **kw)
    out = []
    for line in p.stdout:
        out.append(line)
        if show and not quiet:
            sys.stdout.write(line)
            sys.stdout.flush()
        if on_line:
            on_line(line.rstrip("\\n"))
    p.wait()
    if check and p.returncode:
        raise subprocess.CalledProcessError(p.returncode, cmd, "".join(out))
    return _Result(p.returncode, "".join(out))

# for line in os.stream("cmd"): ...   yields each line as it appears (never prints)
def _stream(cmd, **kw):
    p = _popen(cmd, **kw)
    for line in p.stdout:
        yield line.rstrip("\\n")
    p.wait()

# os.apt("htop", "curl") = install; os.apt("htop", remove=True) = remove (Alpine core)
def _apt(*pkgs, remove=False, **kw):
    pre = "apt-get update -qq && " if os.path.exists("/var/lib/dpkg/status") and not remove else ""
    return _exec(pre + "apt-get %s -y %s" % ("remove" if remove else "install", " ".join(pkgs)), **kw)

os.exec, os.stream, os.apt = _exec, _stream, _apt
os.exec_show = lambda cmd, **kw: _exec(cmd, **{"show": True, **kw})
os.apt_show = lambda *p, **kw: _apt(*p, **{"show": True, **kw})
'''

# apt-style front end for apk (Alpine core only)
APT = '''#!/bin/sh
cmd="$1"; shift
pk=""
for a in "$@"; do
  case "$a" in -*) continue;; esac
  case "$a" in
    build-essential) a=build-base;;
    python3-pip) a=py3-pip;;
    libssl-dev) a=openssl-dev;;
  esac
  pk="$pk $a"
done
case "$cmd" in
  update) echo "indexes are fetched automatically on install" ;;
  upgrade|full-upgrade|dist-upgrade) apk upgrade --no-cache ;;
  install) apk add --no-cache $pk ;;
  remove|purge|autoremove) apk del $pk ;;
  search) apk search $pk ;;
  show|info) apk info -a $pk ;;
  list) apk list $pk ;;
  *) echo "apt: unsupported command '$cmd' (install remove update upgrade search show list)"; exit 1 ;;
esac
'''

# First-boot script inside the ISO: runtime downloads, then your SETUP file
BOOT = '''import importlib, json, os, runpy, subprocess, sys
cfg = json.load(open("/app/_pyos.json"))
os.chdir("/app")
if cfg["pip"]:
    print("[pyos] installing python packages", flush=True)
    subprocess.call([sys.executable, "-m", "pip", "install", "--no-cache-dir",
                     "--break-system-packages", "--target", "/app/_libs"] + cfg["pip"])
    importlib.invalidate_caches()
if cfg["hf"]:
    from huggingface_hub import hf_hub_download, snapshot_download
    for s in cfg["hf"]:
        print("[pyos] downloading", s["repo_id"], flush=True)
        try:
            kw = dict(repo_id=s["repo_id"], repo_type=s["repo_type"],
                      revision=s["revision"], cache_dir="/app/hf/hub")
            if s["filename"]:
                hf_hub_download(filename=s["filename"], **kw)
            else:
                snapshot_download(**kw)
        except Exception as e:
            print("[pyos] download failed:", e, flush=True)
if cfg["setup"]:
    runpy.run_path("/app/" + cfg["setup"], run_name="__main__")
'''

# DHCP script used by udhcpc (busybox) on both cores
UDHCPC = """#!/bin/sh
case "$1" in
  bound|renew)
    ip addr flush dev "$interface" 2>/dev/null
    ip addr add "$ip/${mask:-24}" dev "$interface"
    [ -n "$router" ] && ip route add default via "${router%% *}" dev "$interface"
    : > /etc/resolv.conf
    for d in $dns; do echo "nameserver $d" >> /etc/resolv.conf; done ;;
esac
exit 0
"""


# ------------------------------------------------------------ small helpers
def get(url, cache=False):
    path = os.path.join(CACHE, re.sub(r"[^\w.-]+", "_", url)[-200:]) if (cache and CACHE) else None
    if path and os.path.exists(path):
        return open(path, "rb").read()
    print("GET", url)
    for attempt in range(3):
        try:
            with urllib.request.urlopen(url, timeout=60) as r:
                data = r.read()
            break
        except Exception as e:
            if attempt == 2:
                sys.exit(f"download failed: {url} ({e})")
            time.sleep(2)
    if path:
        os.makedirs(CACHE, exist_ok=True)
        open(path, "wb").write(data)
    return data


def run(args):
    print("+", " ".join(shlex.quote(a) for a in args))
    subprocess.run(args, check=True)


def uniq(seq):
    return list(dict.fromkeys(seq))


def csv(text):
    return [x.strip() for x in text.split(",") if x.strip()]


def resolve(folder, p):
    return os.path.normpath(os.path.join(folder, p))


def rel(folder, path):
    r = os.path.relpath(path, folder)
    return (os.path.basename(path) if r.startswith("..") else r).replace(os.sep, "/")


# -------------------------------------------------- manifest + command line
def norm_key(k):
    k = k.strip().lower().replace("-", "_").replace(" ", "_")
    return ALIASES.get(k, k)


def to_bool(k, v):
    s = str(v).strip().lower()
    if s in ("true", "yes", "1", "on"):
        return True
    if s in ("false", "no", "0", "off"):
        return False
    sys.exit(f"{k.upper()} must be TRUE or FALSE, got '{v}'")


def read_manifest(folder):
    names = {f.lower(): f for f in os.listdir(folder)}
    for n in ("py2iso.txt", "py2iso.md"):
        if n in names:
            path = os.path.join(folder, names[n])
            break
    else:
        sys.exit(f"no py2iso.txt or py2iso.md found in {folder}")
    print("manifest:", path)
    m = {}
    for raw in open(path, encoding="utf-8").read().splitlines():
        line = raw.strip().lstrip("-*").strip()
        if not line or line[0] in "#`[]" or "=" not in line:
            continue
        k, _, v = line.partition("=")
        v = v.strip()
        if len(v) >= 2 and v[0] == v[-1] and v[0] in "\"'":
            v = v[1:-1]
        m[norm_key(k)] = v.strip()
    return m


def parse_cli(args):
    o, i = {}, 0
    while i < len(args):
        a = args[i]
        if not a.startswith("--"):
            sys.exit(f"unexpected argument '{a}' (options start with --)")
        k, eq, v = a[2:].partition("=")
        k = norm_key(k)
        if k in ("alpine", "debian"):
            o["core"] = k
        elif k in ("slim", "normal", "full"):
            o["compressing"] = k
        else:
            if not eq:
                if i + 1 < len(args) and not args[i + 1].startswith("--"):
                    i += 1
                    v = args[i]
                else:
                    v = "true"
            o[k] = v
        i += 1
    return o


def settings(folder, cli):
    c = dict(DEFAULTS)
    for src in (read_manifest(folder), cli):        # cli overrides manifest
        for k, v in src.items():
            if k not in DEFAULTS:
                print(f"warning: unknown option '{k}' ignored")
                continue
            c[k] = to_bool(k, v) if k in BOOLS else str(v).strip()
    for k, allowed in (("core", ("alpine", "debian")), ("compressing", ("slim", "normal", "full"))):
        c[k] = c[k].lower()
        if c[k] not in allowed:
            sys.exit(f"{k.upper()} must be one of: {', '.join(allowed)} (got '{c[k]}')")
    if not c["main"]:
        sys.exit("MAIN is required in the manifest")
    return c


# ---------------------------------------------------------- REQUIRE parsing
def parse_hf(url):
    u = re.sub(r"^hf://", "https://huggingface.co/", url.strip())
    u = re.sub(r"^(https?://)?(www\.)?(huggingface\.co|hf\.co)/", "", u).split("?")[0].split("#")[0]
    parts = [x for x in u.split("/") if x]
    if not parts:
        sys.exit(f"bad Hugging Face link: {url}")
    rtype = "model"
    if parts[0] in ("datasets", "spaces"):
        rtype, parts = parts[0][:-1], parts[1:]
    if len(parts) >= 2 and parts[1] not in ("tree", "blob", "resolve"):
        repo, rest = "/".join(parts[:2]), parts[2:]
    else:
        repo, rest = parts[0], parts[1:]
    rev = fn = None
    if len(rest) >= 2 and rest[0] in ("tree", "blob", "resolve"):
        rev = rest[1]
        if rest[0] != "tree" and len(rest) > 2:
            fn = "/".join(rest[2:])
    return {"repo_id": repo, "repo_type": rtype, "revision": rev, "filename": fn}


def parse_require(folder, text):
    pip, hf, paths = [], [], []
    for item in csv(text):
        if item.lower().startswith("pip:"):
            pip.append(item[4:].strip())
        elif re.match(r"(hf://|(https?://)?(www\.)?(huggingface\.co|hf\.co)/)", item.lower()):
            hf.append(parse_hf(item))
        else:
            p = resolve(folder, item)
            if not os.path.exists(p):
                sys.exit(f"REQUIRE: not found: {item}")
            paths.append(p)
    return pip, hf, paths


# ------------------------------------------------------- code scanning/edits
def py_files(paths, skip):
    for p in paths:
        if os.path.isdir(p):
            for r, dirs, fs_ in os.walk(p):
                dirs[:] = [d for d in dirs if d not in ("__pycache__", ".git")
                           and os.path.join(r, d) != skip]
                for f in fs_:
                    if f.endswith(".py"):
                        yield os.path.join(r, f)
        elif p.endswith(".py"):
            yield p


def imports_of(path):
    try:
        tree = ast.parse(open(path, encoding="utf-8").read())
    except (SyntaxError, UnicodeDecodeError):
        print("warning: could not scan", path)
        return set()
    out = set()
    for n in ast.walk(tree):
        if isinstance(n, ast.Import):
            out |= {a.name.split(".")[0] for a in n.names}
        elif isinstance(n, ast.ImportFrom) and n.level == 0 and n.module:
            out.add(n.module.split(".")[0])
    return out


def local_names(dirs, paths):
    names = set()
    def add_dir(d):
        for e in os.listdir(d):
            names.add(e[:-3] if e.endswith(".py") else e)
    for d in dirs:
        add_dir(d)
    for p in paths:
        if os.path.isdir(p):
            names.add(os.path.basename(p))
            add_dir(p)
        else:
            names.add(os.path.splitext(os.path.basename(p))[0])
    return names


def mark_bare_exec(code):
    """Bare statements os.exec(...)/os.apt(...) print; assigned or used ones stay silent."""
    lines, spots = code.split("\n"), []
    for n in ast.walk(ast.parse(code)):
        f = getattr(n.value, "func", None) if isinstance(n, ast.Expr) else None
        if (isinstance(f, ast.Attribute) and f.attr in ("exec", "apt")
                and isinstance(f.value, ast.Name) and f.value.id == "os"):
            spots.append((f.end_lineno - 1, f.end_col_offset))
    for ln, col in sorted(spots, reverse=True):
        b = lines[ln].encode()
        lines[ln] = (b[:col] + b"_show" + b[col:]).decode()
    return "\n".join(lines)


def emit_script(fs, src, dst):
    code = open(src, encoding="utf-8").read()
    try:
        code = mark_bare_exec(code)
    except SyntaxError as e:
        sys.exit(f"{src}: {e}")
    fs.file(dst, 0o644, code.encode())


# ------------------------------------- in-memory filesystem + cpio initramfs
class FS:
    """Entries: path -> [kind, mode, data, mtime]; kind d/f/l/c. data: bytes,
    ("host", path), symlink target, or (major, minor)."""
    def __init__(self):
        self.e, self.t0 = {}, int(time.time())

    def mkdirs(self, path, mode=None):
        cur = ""
        for part in [p for p in path.split("/") if p]:
            cur = f"{cur}/{part}" if cur else part
            if cur not in self.e:
                self.e[cur] = ["d", 0o755, None, self.t0]
        if mode is not None and cur and self.e[cur][0] == "d":
            self.e[cur][1] = mode

    def _put(self, path, entry):
        self.mkdirs(path.rpartition("/")[0])
        self.e[path] = entry

    def file(self, path, mode, data, mtime=None):
        self._put(path, ["f", mode, data, mtime or self.t0])

    def symlink(self, path, target):
        self._put(path, ["l", 0o777, target, self.t0])

    def node(self, path, mode, major, minor):
        self._put(path, ["c", mode, (major, minor), self.t0])

    def rm(self, prefix):
        for k in [k for k in self.e if k == prefix or k.startswith(prefix + "/")]:
            del self.e[k]

    def extract(self, t, remap=None):
        """Unpack an open tarfile (apk/deb data) into the in-memory tree."""
        def norm(n):
            p = "/".join(s for s in n.replace("\\", "/").split("/") if s not in ("", "."))
            return remap(p) if (remap and p) else p
        for m in t:
            p = norm(m.name)
            if not p or ("/" not in m.name.strip("./") and m.name.lstrip("./").startswith(".")
                         and m.name.startswith(".") and not m.name.startswith("./")):
                continue                    # apk control files (.PKGINFO, .SIGN..., scripts)
            if m.isdir():
                self.mkdirs(p, m.mode & 0o7777)
            elif m.isreg():
                self.file(p, m.mode & 0o7777, t.extractfile(m).read(), int(m.mtime))
            elif m.issym():
                self.symlink(p, m.linkname)
            elif m.islnk():
                src = self.e.get(norm(m.linkname))
                if src and src[0] == "f":
                    self.file(p, src[1], src[2], src[3])


def add_host_file(fs, dst, p):
    st = os.stat(p)
    fs.file(dst, 0o755 if st.st_mode & 0o111 else 0o644, ("host", p), int(st.st_mtime))


def add_tree(fs, src, dst, skip=""):
    fs.mkdirs(dst)
    for r, dirs, files in os.walk(src):
        rp = os.path.relpath(r, src)
        base = dst if rp == "." else dst + "/" + rp.replace(os.sep, "/")
        for d in list(dirs):
            p = os.path.join(r, d)
            if d in ("__pycache__", ".git") or p == skip:
                dirs.remove(d)
            elif os.path.islink(p):
                dirs.remove(d)
                fs.symlink(f"{base}/{d}", os.readlink(p))
            else:
                fs.mkdirs(f"{base}/{d}")
        for f in files:
            p = os.path.join(r, f)
            if f.endswith(".pyc"):
                continue
            if os.path.islink(p):
                fs.symlink(f"{base}/{f}", os.readlink(p))
            else:
                add_host_file(fs, f"{base}/{f}", p)


def write_cpio(fs, out):
    n = [0]
    with gzip.open(out, "wb", compresslevel=6) as z:
        def head(name, mode, mtime, size, rdev=(0, 0)):
            n[0] += 1
            nm = name.encode() + b"\0"
            nlink = 2 if mode & 0o170000 == 0o040000 else 1
            h = "070701" + "".join("%08X" % v for v in (
                n[0], mode, 0, 0, nlink, max(0, int(mtime)), size, 0, 0, rdev[0], rdev[1], len(nm), 0))
            z.write(h.encode() + nm + b"\0" * (-(110 + len(nm)) % 4))
        for path in sorted(fs.e):
            kind, mode, data, mt = fs.e[path]
            if kind == "d":
                head(path, 0o040000 | mode, mt, 0)
            elif kind == "c":
                head(path, 0o020000 | mode, mt, 0, data)
            elif kind == "l":
                b = data.encode()
                head(path, 0o120777, mt, len(b))
                z.write(b + b"\0" * (-len(b) % 4))
            elif isinstance(data, tuple):                   # host file, streamed
                size = os.path.getsize(data[1])
                head(path, 0o100000 | mode, mt, size)
                with open(data[1], "rb") as f:
                    shutil.copyfileobj(f, z, 1 << 20)
                z.write(b"\0" * (-size % 4))
            else:
                head(path, 0o100000 | mode, mt, len(data))
                z.write(data + b"\0" * (-len(data) % 4))
        head("TRAILER!!!", 0, 0, 0)


# ------------------------------------------------------ package repositories
class Alpine:
    def __init__(self, ver):
        self.base = f"https://dl-cdn.alpinelinux.org/alpine/{ver}"
        self.pk, self.prov = {}, {}
        for r in ("main", "community"):
            idx = tarfile.open(fileobj=io.BytesIO(get(f"{self.base}/{r}/{ARCH}/APKINDEX.tar.gz")), mode="r:gz")
            for blk in idx.extractfile("APKINDEX").read().decode().split("\n\n"):
                d = {}
                for line in blk.splitlines():
                    if len(line) > 2 and line[1] == ":":
                        d[line[0]] = line[2:]
                if "P" not in d or d["P"] in self.pk:
                    continue
                d["repo"], d["raw"] = r, blk.strip()
                self.pk[d["P"]] = d
                for p in d.get("p", "").split():
                    self.prov.setdefault(re.split(r"[<>=~]", p)[0], []).append(d["P"])

    def find(self, n):
        if n in self.pk:
            return self.pk[n]
        c = self.prov.get(n)
        return self.pk[max(c, key=lambda x: int(self.pk[x].get("k", 0)))] if c else None

    def resolve(self, names, have, nodeps=()):
        out, todo = {}, list(names)
        while todo:
            n = re.split(r"[<>=~]", todo.pop(0))[0]
            if n.startswith("!") or n in have:
                continue
            p = self.find(n)
            if not p:
                print(f"warning: Alpine package not found: {n}")
                continue
            if p["P"] in out or p["P"] in have:
                continue
            out[p["P"]] = p
            if p["P"] not in nodeps:
                todo += p.get("D", "").split()
        return list(out.values())

    def fetch(self, p):
        return get(f"{self.base}/{p['repo']}/{ARCH}/{p['P']}-{p['V']}.apk", True)

    def install(self, pkgs, fs, remap=None):
        for p in pkgs:
            with tarfile.open(fileobj=io.BytesIO(self.fetch(p)), mode="r:gz") as t:
                fs.extract(t, remap)


def installed_set(fs):
    names, ent = set(), fs.e.get("lib/apk/db/installed")
    for line in (ent[2].decode().splitlines() if ent else []):
        if line.startswith("P:"):
            names.add(line[2:])
        elif line.startswith("p:"):
            names |= {re.split(r"[<>=~]", x)[0] for x in line[2:].split()}
    return names


def record_installed(fs, pkgs, world):
    """Register packages in apk's database so a runtime `apk add` knows them."""
    db = fs.e["lib/apk/db/installed"]
    cur = db[2].decode()
    db[2] = (cur + ("" if cur.endswith("\n\n") else "\n") + "\n\n".join(p["raw"] for p in pkgs) + "\n\n").encode()
    w = fs.e.get("etc/apk/world")
    old = w[2].decode().split() if w else []
    fs.file("etc/apk/world", 0o644, ("\n".join(uniq(old + world)) + "\n").encode())


class Debian:
    def __init__(self, suite):
        self.base = "https://deb.debian.org/debian"
        self.pk, self.prov = {}, {}
        txt = lzma.decompress(get(f"{self.base}/dists/{suite}/main/binary-amd64/Packages.xz")).decode("utf-8", "replace")
        for blk in txt.split("\n\n"):
            d = {}
            for line in blk.splitlines():
                if line[:1] not in (" ", "\t", ""):
                    k, _, v = line.partition(":")
                    d[k] = v.strip()
            n = d.get("Package")
            if not n or n in self.pk:
                continue
            self.pk[n] = d
            for p in d.get("Provides", "").split(","):
                m = re.match(r"[\w.+-]+", p.strip())
                if m:
                    self.prov.setdefault(m.group(), []).append(n)

    def find(self, n):
        if n in self.pk:
            return self.pk[n]
        return self.pk[self.prov[n][0]] if n in self.prov else None

    def resolve(self, names):
        out, todo = {}, list(names)
        while todo:
            n = todo.pop(0)
            if n in DEB_SKIP:
                continue
            p = self.find(n)
            if not p:
                print(f"warning: Debian package not found: {n}")
                continue
            if p["Package"] in out or p["Package"] in DEB_SKIP:
                continue
            out[p["Package"]] = p
            for fld in ("Pre-Depends", "Depends"):
                for grp in p.get(fld, "").split(","):
                    for alt in grp.split("|"):
                        m = re.match(r"[\w.+-]+", alt.strip())
                        if m and self.find(m.group()):
                            todo.append(m.group())
                            break
        return list(out.values())

    def install(self, pkgs, fs):
        for p in pkgs:
            data = get(f"{self.base}/{p['Filename']}", True)
            if data[:8] != b"!<arch>\n":
                sys.exit(f"bad .deb: {p['Package']}")
            i = 8
            while i + 60 <= len(data):
                name = data[i:i + 16].decode().strip().rstrip("/")
                size = int(data[i + 48:i + 58])
                body = data[i + 60:i + 60 + size]
                i += 60 + size + size % 2
                if name.startswith("data.tar"):
                    if name.endswith(".zst"):
                        sys.exit(f"{p['Package']} uses zstd; use Python 3.14+ or --alpine")
                    with tarfile.open(fileobj=io.BytesIO(body), mode="r:*") as t:
                        fs.extract(t, usrmerge)
                    break


def usrmerge(p):
    return "usr/" + p if p.split("/")[0] in ("bin", "sbin", "lib", "lib64") else p


def deb_fixups(fs):
    """Things dpkg maintainer scripts would normally do."""
    for d in ("proc", "sys", "dev", "run", "root", "etc", "mnt", "var/tmp"):
        fs.mkdirs(d)
    fs.mkdirs("tmp", 0o1777)
    have = lambda a: f"usr/bin/{a}" in fs.e or f"usr/sbin/{a}" in fs.e
    for a in ("mount", "umount", "ip", "udhcpc", "poweroff", "reboot"):
        if not have(a):
            fs.symlink(f"usr/sbin/{a}", "/usr/bin/busybox")
    for a in ("modprobe", "insmod", "rmmod", "lsmod", "depmod"):
        if not have(a):
            fs.symlink(f"usr/sbin/{a}", "/usr/bin/kmod")
    if "usr/bin/sh" not in fs.e:
        fs.symlink("usr/bin/sh", "bash")
    if "usr/bin/python3" not in fs.e:
        py = sorted(k for k in fs.e if re.fullmatch(r"usr/bin/python3\.\d+", k))
        if py:
            fs.symlink("usr/bin/python3", os.path.basename(py[-1]))
    fs.file("etc/passwd", 0o644, b"root:x:0:0:root:/root:/bin/bash\n")
    fs.file("etc/group", 0o644, b"root:x:0:\n")
    certs = b"".join(v[2] for k, v in sorted(fs.e.items()) if v[0] == "f" and isinstance(v[2], bytes)
                     and k.startswith("usr/share/ca-certificates/") and k.endswith(".crt"))
    if certs:
        fs.file("etc/ssl/certs/ca-certificates.crt", 0o644, certs)


def install_core(fs, alp, c):
    """Fill fs with the chosen userland. Returns the kernel image bytes."""
    ui, gpu, slim = c["ui"], c["gpudrivers"], c["compressing"] == "slim"
    nodeps = {"linux-lts", *FIRMWARE}
    if c["core"] == "alpine":
        yml = get(f"{alp.base}/releases/{ARCH}/latest-releases.yaml").decode()
        name = re.search(r"file:\s*(alpine-minirootfs-[\d.]+-%s\.tar\.gz)" % ARCH, yml).group(1)
        with tarfile.open(fileobj=io.BytesIO(get(f"{alp.base}/releases/{ARCH}/{name}", True)), mode="r:gz") as t:
            fs.extract(t)
        pk = uniq(["python3", "linux-lts"] + (BASH_PKGS if c["bash"] else []) + (APK_UI if ui else [])
                  + (APK_GPU + FIRMWARE if gpu else []) + (["py3-pip"] if slim else []) + csv(c["packages"]))
        pkgs = alp.resolve(pk, installed_set(fs), nodeps)
        alp.install(pkgs, fs)
        record_installed(fs, pkgs, pk)
    else:
        for a, b in (("bin", "usr/bin"), ("sbin", "usr/sbin"), ("lib", "usr/lib"), ("lib64", "usr/lib64")):
            fs.mkdirs(b)
            fs.symlink(a, b)
        deb = Debian(DEB_SUITE)
        pk = uniq(DEB_BASE + (["ca-certificates"] if c["net"] else []) + (["python3-pip"] if slim else [])
                  + (DEB_UI if ui else []) + (DEB_GPU if gpu else []) + csv(c["packages"]))
        deb.install(deb.resolve(pk), fs)
        # the Linux kernel (and firmware) come from Alpine's linux-lts: small, with modules
        alp.install(alp.resolve(["linux-lts"] + (FIRMWARE if gpu else []), set(), nodeps), fs, usrmerge)
        deb_fixups(fs)
    if "boot/vmlinuz-lts" not in fs.e:
        sys.exit("kernel not found after install")
    kernel = fs.e.pop("boot/vmlinuz-lts")[2]
    fs.rm("boot")
    if not any(k.endswith("/modules.dep") for k in fs.e):
        print("note: kernel modules have no modules.dep; /init will run depmod at boot")
    return kernel


# ------------------------------------------------- libs, Hugging Face, init
def pip_bundle(target, libs, core):
    if core == "debian":
        pv, plats = PYVER_DEB, ("manylinux_2_28", "manylinux2014")
    else:
        pv, plats = PYVER_ALPINE, ("musllinux_1_2", "musllinux_1_1")
    args = [sys.executable, "-m", "pip", "install", "--no-cache-dir", "--only-binary=:all:",
            "--target", target, "--implementation", "cp", "--python-version", pv]
    for p in plats:
        args += ["--platform", f"{p}_{ARCH}"]
    run(args + ["--platform", "any"] + libs)


def hf_bundle(cache_dir, specs):
    try:
        import huggingface_hub as hub
    except ImportError:
        run([sys.executable, "-m", "pip", "install", "-q", "huggingface_hub"])
        import huggingface_hub as hub
    for s in specs:
        print("HF", s["repo_id"])
        kw = dict(repo_id=s["repo_id"], repo_type=s["repo_type"], revision=s["revision"],
                  cache_dir=cache_dir)
        if s["filename"]:
            hub.hf_hub_download(filename=s["filename"], **kw)
        else:
            hub.snapshot_download(**kw)


def make_init(c, main_rel, has_boot):
    deb, ui, full = c["core"] == "debian", c["ui"], c["compressing"] == "full"
    sh = "/bin/bash" if (deb or c["bash"]) else "/bin/sh"
    tail = f"exec {sh}" if c["shell"] else "sleep 3\npoweroff -f"
    pre = "mkdir -p /run /tmp\nmount -t tmpfs tmpfs /run\nmount -t tmpfs tmpfs /tmp\n"
    if ui or c["gpudrivers"]:
        udevd = "/usr/lib/systemd/systemd-udevd" if deb else "/sbin/udevd"
        pre += (f"{udevd} --daemon\n"
                "udevadm trigger --type=subsystems --action=add\n"
                "udevadm trigger --type=devices --action=add\n"
                "udevadm settle --timeout=10\n")
    if c["net"]:
        pre += ("for m in virtio_net e1000 e1000e r8169 8139cp igb; do modprobe -q $m 2>/dev/null; done\n"
                "sleep 1\n"
                "for i in /sys/class/net/*; do n=${i##*/}; [ \"$n\" = lo ] && continue; "
                "ip link set $n up; udhcpc -i $n -q -n -t 3 -s /usr/share/udhcpc/pyos.script "
                "&& break; done\n")
    if has_boot:        # runs every boot: the system lives in RAM, so the marker is lost
        pre += "[ -f /etc/pyos.setup ] || { python3 /app/_pyos_boot.py; touch /etc/pyos.setup; }\n"
    m = shlex.quote("/app/" + main_rel)
    launch = (f"xinit /usr/bin/python3 {m} -- /usr/bin/Xorg :0 vt1 -nolisten tcp"
              if ui else f"python3 {m}")
    env = "HF_HOME=/app/hf" + (" HF_HUB_OFFLINE=1 TRANSFORMERS_OFFLINE=1" if full else "")
    return f"""#!/bin/sh
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
mount -t proc proc /proc
mount -t sysfs sys /sys
mount -t devtmpfs dev /dev
[ -f /lib/modules/$(uname -r)/modules.dep ] || depmod -a 2>/dev/null
for m in simpledrm usbhid xhci_pci ehci_pci hid_generic atkbd i8042; do modprobe -q $m 2>/dev/null; done
exec </dev/console >/dev/console 2>&1
export PYTHONPATH=/app/_libs:/app PYTHONUNBUFFERED=1 HOME=/root TERM=linux SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt {env} PYOS_VERSION={shlex.quote(c["version"])}
[ -n "$PYOS_VERSION" ] && echo "PyOS $PYOS_VERSION"
cd /app
{pre}{launch}
{tail}
"""


# ------------------------------------------- ISO9660 + El Torito (ISOLINUX)
def b16(n):
    return struct.pack("<H", n) + struct.pack(">H", n)


def b32(n):
    return struct.pack("<I", n) + struct.pack(">I", n)


def rec(ident, lba, size, flags):
    t, n = time.gmtime(), len(ident)
    r = (struct.pack("<BB", 33 + n + (n % 2 == 0), 0) + b32(lba) + b32(size)
         + bytes([t.tm_year - 1900, t.tm_mon, t.tm_mday, t.tm_hour, t.tm_min, t.tm_sec, 0])
         + struct.pack("<BBB", flags, 0, 0) + b16(1) + struct.pack("<B", n) + ident)
    return r + (b"\0" if n % 2 == 0 else b"")


def get_syslinux(alp):
    p = alp.find("syslinux")
    if not p:
        sys.exit("syslinux package not found in the Alpine index")
    out = {}
    with tarfile.open(fileobj=io.BytesIO(alp.fetch(p)), mode="r:gz") as t:
        for m in t:
            b = os.path.basename(m.name)
            if m.isreg() and b in ("isolinux.bin", "ldlinux.c32", "isohdpfx.bin") and b not in out:
                out[b] = t.extractfile(m).read()
    if "isolinux.bin" not in out or "ldlinux.c32" not in out:
        sys.exit("boot files missing from the syslinux package")
    return out


def make_iso(out, kernel, initrd, sl, cmdline, serial, label="PYOS"):
    SEC = 2048
    cfg = (("SERIAL 0 115200\n" if serial else "") + "PROMPT 0\nTIMEOUT 1\nDEFAULT pyos\n"
           f"LABEL pyos\n  KERNEL /boot/vmlinuz.lts\n  APPEND initrd=/boot/initrd.gz {cmdline}\n")
    boot = bytearray(sl["isolinux.bin"])
    tree = {"BOOT": [("INITRD.GZ;1", initrd), ("VMLINUZ.LTS;1", kernel)],
            "ISOLINUX": [("ISOLINUX.BIN;1", boot), ("ISOLINUX.CFG;1", cfg.encode()),
                         ("LDLINUX.C32;1", sl["ldlinux.c32"])]}
    size_of = lambda s: os.path.getsize(s) if isinstance(s, str) else len(s)
    if size_of(initrd) >= 2 ** 32 - SEC:
        sys.exit("initramfs is larger than 4 GiB: too big for an ISO9660 file; use --slim or --normal")
    dirs, lba, loc = {"": 22, "BOOT": 23, "ISOLINUX": 24}, 25, {}
    for d, items in tree.items():
        for name, src in items:
            loc[(d, name)] = lba
            lba += max(1, -(-size_of(src) // SEC))
    total = lba
    blba = loc[("ISOLINUX", "ISOLINUX.BIN;1")]
    data = bytes(boot[64:])
    data += b"\0" * (-len(data) % 4)                 # boot-info table for isolinux.bin
    csum = sum(struct.unpack(f"<{len(data) // 4}I", data)) & 0xFFFFFFFF
    struct.pack_into("<IIII", boot, 8, 16, blba, len(boot), csum)

    def dirsec(me, parent, kids):
        body = rec(b"\0", me, SEC, 2) + rec(b"\1", parent, SEC, 2) + b"".join(kids)
        return body.ljust(SEC, b"\0")
    root = dirsec(22, 22, [rec(b"BOOT", 23, SEC, 2), rec(b"ISOLINUX", 24, SEC, 2)])
    subs = {d: dirsec(dirs[d], 22, [rec(n.encode(), loc[(d, n)], size_of(s), 0) for n, s in items])
            for d, items in tree.items()}

    def ptable(big):
        b = b""
        for ident, l in ((b"\0", 22), (b"BOOT", 23), (b"ISOLINUX", 24)):
            b += (struct.pack("<BB", len(ident), 0) + struct.pack(">I" if big else "<I", l)
                  + struct.pack(">H" if big else "<H", 1) + ident + (b"\0" if len(ident) % 2 else b""))
        return b
    ptl, ptm = ptable(False), ptable(True)

    pvd = bytearray(SEC)
    def put(o, b):
        pvd[o:o + len(b)] = b
    put(0, b"\x01CD001\x01")
    put(8, b" " * 32)
    put(40, label.encode().ljust(32))
    put(80, b32(total))
    put(120, b16(1)); put(124, b16(1)); put(128, b16(SEC)); put(132, b32(len(ptl)))
    put(140, struct.pack("<I", 20)); put(148, struct.pack(">I", 21))
    put(156, rec(b"\0", 22, SEC, 2))
    for o, n in ((190, 128), (318, 128), (446, 128), (574, 128), (702, 37), (739, 37), (776, 37)):
        put(o, b" " * n)
    now = time.strftime("%Y%m%d%H%M%S", time.gmtime()).encode() + b"00\x00"
    put(813, now); put(830, now); put(847, b"0" * 16 + b"\0"); put(864, now)
    put(881, b"\x01")

    br = (b"\0CD001\x01" + b"EL TORITO SPECIFICATION".ljust(32, b"\0") + b"\0" * 32
          + struct.pack("<I", 19)).ljust(SEC, b"\0")
    val = struct.pack("<BBH24sHBB", 1, 0, 0, b"", 0, 0x55, 0xAA)
    chk = (-sum(struct.unpack("<16H", val))) & 0xFFFF
    val = struct.pack("<BBH24sHBB", 1, 0, 0, b"", chk, 0x55, 0xAA)
    entry = struct.pack("<BBHBBHI", 0x88, 0, 0, 0, 0, 4, blba) + b"\0" * 20
    catalog = (val + entry).ljust(SEC, b"\0")
    term = b"\xffCD001\x01".ljust(SEC, b"\0")

    sysarea = bytearray(16 * SEC)                   # hybrid MBR so the ISO can also boot from USB
    code = sl.get("isohdpfx.bin", b"")[:432]
    if code:
        sysarea[:len(code)] = code
        struct.pack_into("<II", sysarea, 432, blba * 4, 0)
        struct.pack_into("<I", sysarea, 440, int(time.time()) & 0xFFFFFFFF)
        struct.pack_into("<B3sB3sII", sysarea, 446, 0x80, b"\x00\x01\x00", 0x17, b"\xfe\xff\xff", 0, total * 4)
        sysarea[510:512] = b"\x55\xaa"

    with open(out, "wb") as f:
        f.write(bytes(sysarea))
        for blk in (bytes(pvd), br, term, catalog, ptl.ljust(SEC, b"\0"), ptm.ljust(SEC, b"\0"),
                    root, subs["BOOT"], subs["ISOLINUX"]):
            f.write(blk)
        for d, items in tree.items():
            for name, src in items:
                n = 0
                if isinstance(src, str):
                    with open(src, "rb") as g:
                        while chunk := g.read(1 << 20):
                            f.write(chunk)
                            n += len(chunk)
                else:
                    f.write(bytes(src))
                    n = len(src)
                f.write(b"\0" * (max(1, -(-n // SEC)) * SEC - n))


# ------------------------------------------------------------------- cook
def cook(folder, cli):
    global CACHE
    folder = os.path.abspath(folder)
    if not os.path.isdir(folder):
        sys.exit(f"not a folder: {folder}")
    c = settings(folder, cli)
    comp, core = c["compressing"], c["core"]

    main = resolve(folder, c["main"])
    if not os.path.isfile(main):
        sys.exit(f"MAIN not found: {c['main']}")
    setup = resolve(folder, c["setup"]) if c["setup"] else ""
    if setup and not os.path.isfile(setup):
        sys.exit(f"SETUP not found: {c['setup']}")
    pip_extra, hf, paths = parse_require(folder, c["require"])

    if (comp == "slim" or (comp == "normal" and hf)) and not c["net"]:
        print("note: this compressing mode downloads at boot, enabling net")
        c["net"] = True

    build = resolve(folder, c["build_folder"])
    work, CACHE = os.path.join(build, "work"), os.path.join(build, "cache")
    iso = c["iso_name"] if c["iso_name"].lower().endswith(".iso") else c["iso_name"] + ".iso"
    out = os.path.join(build, iso)

    scan = [p for p in (main, setup) if p] + paths      # libraries from imports
    mods = set()
    for f in py_files(scan, build):
        mods |= imports_of(f)
    std = set(sys.stdlib_module_names) | {"__future__"}
    local = local_names({folder, os.path.dirname(main)} | ({os.path.dirname(setup)} if setup else set()), paths)
    libs = uniq(sorted({IMPORT_TO_PIP.get(m, m) for m in mods if m not in std and m not in local}) + pip_extra)
    hub = ["huggingface_hub"] if hf else []
    bundled = [] if comp == "slim" else uniq(libs + (hub if comp == "normal" else []))
    rt_pip = uniq(libs + hub) if comp == "slim" else []
    rt_hf = hf if comp != "full" else []
    main_rel, setup_rel = rel(folder, main), (rel(folder, setup) if setup else "")
    has_boot = bool(rt_pip or rt_hf or setup)

    print(f"core={core} compressing={comp} ui={c['ui']} net={c['net']} | libs={libs} | "
          f"hf={[h['repo_id'] for h in hf]} | main={main_rel} setup={setup_rel or '-'}")

    shutil.rmtree(work, ignore_errors=True)
    os.makedirs(work)
    fs, alp = FS(), Alpine(ALPINE)

    print(f"[1/7] {core} base system (pure-Python package install)")
    kernel = install_core(fs, alp, c)

    print("[2/7] Libraries:", "bundled" if bundled else "none bundled", "(installed at boot)" if rt_pip else "")
    fs.mkdirs("app/_libs")
    if bundled:
        tmp = os.path.join(work, "libs")
        os.makedirs(tmp)
        pip_bundle(tmp, bundled, core)
        add_tree(fs, tmp, "app/_libs")

    print("[3/7] Copying REQUIRE files, SETUP and MAIN")
    for p in paths:
        dst = "app/" + rel(folder, p)
        if os.path.isdir(p):
            add_tree(fs, p, dst, skip=build)
        else:
            add_host_file(fs, dst, p)
    emit_script(fs, main, "app/" + main_rel)
    if setup:
        emit_script(fs, setup, "app/" + setup_rel)

    print("[4/7] Hugging Face files:", "packaged" if (hf and comp == "full") else
          ("downloaded at boot" if hf else "none"))
    if hf and comp == "full":
        hdir = os.path.join(work, "hf")
        hf_bundle(os.path.join(hdir, "hub"), hf)
        add_tree(fs, hdir, "app/hf")

    print("[5/7] Helpers, boot config, /init")
    fs.file("app/sitecustomize.py", 0o644, SITECUSTOMIZE.encode())
    if has_boot:
        fs.file("app/_pyos.json", 0o644, json.dumps({"pip": rt_pip, "hf": rt_hf, "setup": setup_rel}).encode())
        fs.file("app/_pyos_boot.py", 0o644, BOOT.encode())
    fs.file("usr/share/udhcpc/pyos.script", 0o755, UDHCPC.encode())
    if core == "alpine":
        for n in ("apt", "apt-get"):
            fs.file(f"usr/local/bin/{n}", 0o755, APT.encode())
    for d in ("proc", "sys", "dev", "run", "root"):
        fs.mkdirs(d)
    fs.mkdirs("tmp", 0o1777)
    fs.node("dev/console", 0o600, 5, 1)
    fs.node("dev/null", 0o666, 1, 3)
    junk = ["var/cache", "usr/share/man", "usr/share/doc"]
    junk += ["var/lib/apt", "usr/share/locale"] if core == "debian" else []
    if not (c["ui"] or c["gpudrivers"]):
        junk.append("usr/lib/firmware" if core == "debian" else "lib/firmware")
    for p in junk:
        fs.rm(p)
    fs.file("init", 0o755, make_init(c, main_rel, has_boot).encode())

    print(f"[6/7] initramfs ({len(fs.e)} entries)")
    initrd = os.path.join(work, "initrd.gz")
    write_cpio(fs, initrd)

    print("[7/7] ISO (ISOLINUX, El Torito)")
    cmd = " ".join(x for x in ["console=tty0", "console=ttyS0" if c["serial"] else "", c["cmdline"],
                               "" if (c["ui"] and c["serial"]) else "quiet loglevel=3"] if x)
    make_iso(out, kernel, initrd, get_syslinux(alp), cmd, c["serial"])
    print("\nBuilt %s (%.1f MB)" % (out, os.path.getsize(out) / 1e6))


if __name__ == "__main__":
    if len(sys.argv) < 3 or sys.argv[1] != "cook" or sys.argv[2].startswith("-"):
        print(__doc__)
        sys.exit(1)
    cook(sys.argv[2], parse_cli(sys.argv[3:]))
