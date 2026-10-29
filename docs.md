# py2iso documentation

py2iso turns a Python project folder into a bootable ISO. The ISO starts a minimal Linux system and runs your `MAIN` program right after power-on, with no desktop and no login.

## Quick start

```bash
p2i cook ./myproj                  # uses py2iso.txt in ./myproj
p2i cook ./myproj --debian --full  # command-line options override the manifest
```

The result is written to `<project>/<BUILD_FOLDER>/<ISO_NAME>`, which defaults to `myproj/build/OUT.iso`.

Test it:

```bash
qemu-system-x86_64 -cdrom myproj/build/OUT.iso -m 2048
```

## Command

```
p2i cook <folder> [core] [compressing] [--ui[=true|false]] [--key=value ...]
```

`cook` is the only command. `<folder>` must contain `py2iso.txt` or `py2iso.md`. If both exist, `py2iso.txt` wins.

Settings come from three places, in this order of priority:

1. Command-line options
2. The manifest
3. Built-in defaults

## Launch options

### Core: the base system

| Option | Meaning |
|---|---|
| `--alpine` | Alpine Linux base. Small (tens of MB), uses musl libc. Default. |
| `--debian` | Debian bookworm base. Larger, uses glibc, so more Python wheels install. |

Manifest equivalent: `CORE=Alpine` or `CORE=Debian`.

### Compressing: what is packaged and what is downloaded

| Option | Python libraries | Hugging Face files | Network needed at boot |
|---|---|---|---|
| `--slim` | Downloaded on first boot | Downloaded on first boot | Yes |
| `--normal` | Packaged in the ISO | Downloaded on first boot | Only if `REQUIRE` has Hugging Face links |
| `--full` | Packaged in the ISO | Downloaded at build time and packaged | No |

Manifest equivalent: `COMPRESSING=Slim`, `COMPRESSING=Normal`, or `COMPRESSING=Full`. Default is Normal.

`--slim` and `--normal` turn networking on automatically when they need it.

### UI

| Option | Meaning |
|---|---|
| `--ui` or `--ui=true` | Boot into an X11 graphical session. Tkinter windows work. |
| `--ui=false` | Text console only. Default. |

Manifest equivalent: `UI=TRUE` or `UI=FALSE`.

### Other command-line options

Any manifest key can also be given as `--key=value`. Boolean options accept `true`, `false`, `yes`, `no`, `1`, `0`, `on`, and `off`. Boolean flags with no value mean `true`.

| Option | Default | Effect |
|---|---|---|
| `--net` | off | Brings up networking with DHCP at boot. Needed for `os.apt()` at runtime. |
| `--gpudrivers` | off | Adds open-source GPU drivers (Mesa, libdrm) and firmware. |
| `--serial` | off | Also prints to the serial port. Use it with `-nographic` for testing. |
| `--shell` | off | Opens a shell after `MAIN` ends instead of powering off. |
| `--bash` | on | Installs GNU bash on the Alpine core. Debian always has bash. |
| `--cmdline="..."` | empty | Extra kernel parameters, for example `--cmdline="noapic"`. |
| `--packages="a,b"` | empty | Extra OS packages, comma separated. |

Unknown options print a warning and are ignored.

## The manifest: `py2iso.txt`

Create this file in your project folder.

```
py2iso
CORE=Alpine
COMPRESSING=Normal
UI=FALSE
REQUIRE="utils.py, data, https://huggingface.co/org/model, pip:rich"
SETUP="setup.py"
MAIN="main.py"
VERSION="0.1"
ISO_NAME="demo.iso"
BUILD_FOLDER="build"
```

### Format rules

- The first line may be `py2iso`. It is ignored.
- Each setting is `KEY=value`, one per line.
- Keys and values are case-insensitive. `main=`, `MAIN=`, and `Main=` are the same.
- Quotes around values are optional. Use them when a value contains spaces or commas.
- Lines starting with `#` are comments. Lines that start with `-` or `*` (markdown bullets) are read as normal settings.
- Lines without `=` are ignored.
- `py2iso.md` uses the same format, so markdown bullets and code fences around the settings are fine.

### Keys

| Key | Required | Default | Description |
|---|---|---|---|
| `MAIN` | Yes | none | Entry-point file, relative to the project folder. It runs at boot. |
| `SETUP` | No | none | A file that runs once on first boot, before `MAIN`. Relative path. |
| `REQUIRE` | No | none | Comma-separated extra items to include (see below). |
| `CORE` | No | `Alpine` | `Alpine` or `Debian`. |
| `COMPRESSING` | No | `Normal` | `Slim`, `Normal`, or `Full`. |
| `UI` | No | `FALSE` | `TRUE` or `FALSE`. |
| `VERSION` | No | empty | Shown at boot as `PyOS <version>`. |
| `ISO_NAME` | No | `OUT.iso` | Output file name. `.iso` is added if missing. |
| `BUILD_FOLDER` | No | `build` | Where the build and output go, relative to the project folder. |
| `NET` | No | `FALSE` | Brings up networking at boot. |
| `GPUDRIVERS` | No | `FALSE` | Adds GPU drivers and firmware. |
| `SERIAL` | No | `FALSE` | Serial console output, for testing. |
| `SHELL` | No | `FALSE` | Shell after `MAIN`. |
| `BASH` | No | `TRUE` | Bash on the Alpine core. |
| `CMDLINE` | No | empty | Extra kernel parameters. |
| `PACKAGES` | No | empty | Extra OS packages, comma separated. |

Aliases: `REQURE` is accepted for `REQUIRE`, `ISO` for `ISO_NAME`, `BUILD` for `BUILD_FOLDER`, and `GPU` for `GPUDRIVERS`.

Unknown keys print a warning and are ignored.

### `REQUIRE` items

`REQUIRE` takes a comma-separated list. Each item is one of:

| Item | Example | What happens |
|---|---|---|
| Local file | `utils.py` | Copied into `/app/utils.py` in the ISO. |
| Local folder | `data` | Copied into `/app/data/`. Symlinks are kept. `__pycache__` and `.git` are skipped. |
| Hugging Face repo | `https://huggingface.co/org/model` | Downloaded and cached for `from_pretrained()`. |
| Hugging Face file | `https://huggingface.co/org/model/blob/main/file.bin` | Downloads just that file. |
| Hugging Face dataset | `https://huggingface.co/datasets/org/data` | Dataset repo. |
| Short form | `hf://org/model` | Same as the full repo link. |
| Pip package | `pip:rich` | Installed as a library, even if no import of it is found. |

Paths are relative to the project folder. A missing path stops the build with an error.

Hugging Face downloads use the `HF_TOKEN` environment variable on the build machine when a model is gated. In `--full` mode the files are packaged. In `--normal` and `--slim` mode they are downloaded on first boot.

### Example project

```
myproj/
  py2iso.txt
  main.py
  setup.py
  utils.py
  data/words.txt
```

`main.py`:

```python
import os
from utils import greet

def OS():
    serial = True          # build option, not copied into the ISO
    output = "demo.iso"    # build option

    print(greet())
    os.exec("uname -a")    # bare call: prints live
```

Only top-level variables inside `OS()` named `serial`, `shell`, `ui`, `net`, `gpudrivers`, `cmdline`, `packages`, `output`, and similar options are read as build options. Everything else in the function runs inside the ISO.

## Imports and libraries

py2iso reads the `import` statements in `MAIN`, `SETUP`, and every `.py` file under `REQUIRE`. Standard library modules are skipped. Other imports are mapped to PyPI names and installed.

Some common names are mapped automatically: `PIL` to `pillow`, `cv2` to `opencv-python-headless`, `yaml` to `pyyaml`, `sklearn` to `scikit-learn`, `bs4` to `beautifulsoup4`, `dateutil` to `python-dateutil`, `serial` to `pyserial`, and `dotenv` to `python-dotenv`.

Local modules you import are not installed from PyPI, because py2iso recognises them as local files or folders in the project.

Packages must have a wheel for the chosen core. Alpine uses musl wheels, so many compiled packages (for example torch) will not install there. Use `--debian` for those.

## Runtime helpers (inside the ISO)

These are available to every program in the ISO, without an import.

| Call | Behaviour |
|---|---|
| `os.exec("cmd")` | Runs a shell command. A bare statement prints output live. An assigned result stays silent. |
| `r = os.exec("cmd")` | Silent. `r.stdout` holds the output, `r.returncode` the exit code. Truthy on success. |
| `os.exec("cmd", show=True)` | Prints even when assigned. |
| `os.exec("cmd", quiet=True)` | Never prints. |
| `os.exec("cmd", on_line=fn)` | Calls `fn(line)` for each output line. |
| `os.exec("cmd", check=True)` | Raises an error on a non-zero exit code. |
| `os.exec("htop", interactive=True)` | Gives the command the real terminal. Output is not captured. |
| `for line in os.stream("cmd"):` | Yields lines as they appear. Never prints. |
| `os.apt("pkg", "pkg2")` | Installs packages. Needs `NET=TRUE`. |
| `os.apt("pkg", remove=True)` | Removes packages. |

The build rewrites bare `os.exec(...)` and `os.apt(...)` statements to their printing form, so the rule above applies at build time.

On the Alpine core, `os.apt` and the `apt` command translate to `apk`. Common Debian names are mapped (`build-essential` to `build-base`, `python3-pip` to `py3-pip`). On the Debian core, `os.apt` runs `apt-get`, which needs `NET=TRUE` and a reachable mirror.

## Setup file

`SETUP` runs once, before `MAIN`, on first boot. It runs with the same environment as `MAIN`, so it can install packages with `os.apt`, download data, and so on.

On every boot it runs again, because the system lives in RAM and the first-boot marker is lost at shutdown.

## Output

The build writes:

```
<project>/<BUILD_FOLDER>/<ISO_NAME>      the bootable ISO
<project>/<BUILD_FOLDER>/work/           temporary files, safe to delete
<project>/<BUILD_FOLDER>/cache/          downloaded packages, kept to speed up rebuilds
```

## Requirements

- Python 3.10 or newer, on macOS, Windows, or Linux
- Internet access during the build
- pip, for libraries (`python3 -m pip`)
- Optional: `huggingface_hub` for Hugging Face links (installed automatically when needed)

No Docker, root access, or external ISO tools are needed.

## Testing

Boot the ISO in QEMU:

```bash
qemu-system-x86_64 -cdrom build/OUT.iso -m 2048
```

For text output in a terminal, add `SERIAL=TRUE` to the manifest, rebuild, and run:

```bash
qemu-system-x86_64 -cdrom build/OUT.iso -m 2048 -nographic -no-reboot
```

Press `Ctrl-A` then `X` to quit. Use `-m 4096` or more for `--debian` and `--full`.

## Limits

- **BIOS boot only.** Legacy or CSM mode is needed on real PCs. UEFI-only machines are not supported yet.
- **Runs from RAM.** The whole system and any packaged models must fit in memory.
- **ISO size.** An ISO file cannot exceed 4 GiB. Use `--normal` or `--slim` for large models.
- **First-boot work repeats.** Downloads in Slim and Normal modes happen on every boot.
- **Experimental.** The pure-Python ISO writer and the Debian core are new.
