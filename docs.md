

# PY2ISO Documentation

PY2ISO packages a Python project into a bootable ISO image. Each project must include a manifest in its root directory named **`py2iso.txt`** or **`py2iso.md`**.

The manifest uses simple `key = value` syntax to describe how the application is built, packaged, and executed.

## Contents

- [Manifest example](#manifest-example)
- [Configuration reference](#configuration-reference)
- [Command-line usage](#command-line-usage)
- [CLI shortcuts](#cli-shortcuts)
- [Runtime API](#runtime-api)

## Manifest example

Create `py2iso.txt` in your project root:

```ini
main = main.py
setup = setup.py
version = 1.0.0
iso_name = my_app.iso
core = alpine
compressing = normal
ui = false
net = true
packages = sqlite3, curl
require = pip:requests, pip:numpy, hf://bartowski/Llama-3-8B-Instruct-GGUF/llama-3-8b-instruct-q4_k_m.gguf
```

Example project layout:

```text
my_app/
├── py2iso.txt
├── main.py
├── setup.py
└── requirements.txt
```

`main` is required. The other values are optional and can be adjusted for your project.

## Configuration reference

Options can be set in the manifest or overridden with command-line arguments when running `py2iso`.

| Option | Default | Allowed values / type | Description |
|---|---|---|---|
| `main` | `""` | Filename (`str`) | **Required.** Entry-point script executed automatically when the ISO boots. |
| `setup` | `""` | Filename (`str`) | Optional script run during first-boot setup, after pip packages and Hugging Face assets are downloaded. |
| `require` | `""` | Comma-separated list | External dependencies: `pip:` packages, local file/folder paths, or Hugging Face model/dataset URLs using `hf://`. |
| `core` | `alpine` | `alpine`, `debian` | Base Linux distribution used for the initramfs root environment. |
| `compressing` | `normal` | `slim`, `normal`, `full` | Controls build size and feature-inclusion tier. |
| `ui` | `false` | `true`, `false` | Boots into an X11 graphical session with Tkinter support enabled. |
| `net` | `false` | `true`, `false` | Enables DHCP networking at boot. Automatically enabled if dependencies require external downloads. |
| `gpudrivers` | `false` | `true`, `false` | Includes open-source GPU drivers and firmware, including Mesa, Vulkan, and vendor firmware for AMD, Intel, and Nvidia. |
| `serial` | `false` | `true`, `false` | Sends kernel logs and console output to the serial port, useful for QEMU testing and headless debugging. |
| `shell` | `false` | `true`, `false` | Opens an interactive shell after the main script terminates instead of automatically powering off. |
| `bash` | `true` | `true`, `false` | Includes GNU Bash on Alpine builds. Debian includes Bash by default. |
| `packages` | `""` | Comma-separated list | Additional operating-system packages installed from the base distribution's repositories. |
| `iso_name` | `OUT.iso` | Filename (`str`) | Output ISO filename. |
| `build_folder` | `build` | Directory path | Temporary workspace used during the build. |

### The `require` field

Use `require` to declare dependencies that are not simply operating-system packages.

```ini
require = pip:requests, pip:numpy
```

Hugging Face assets can be specified with an `hf://` reference:

```ini
require = hf://bartowski/Llama-3-8B-Instruct-GGUF/llama-3-8b-instruct-q4_k_m.gguf
```

Local files or folders can also be included in the comma-separated list. Ensure the syntax and paths match what your installed PY2ISO version supports.

## Command-line usage

Pass a project directory to `py2iso`. Command-line options can override values from the manifest.

### Build with Debian and full compression

```sh
py2iso ./my_app --debian --compressing=full
```

### Override the ISO name and enable UI and networking

```sh
py2iso ./my_app --iso_name=app_live.iso --ui=true --net=true
```

### CLI shortcuts

| Shortcut | Effect |
|---|---|
| `--alpine` | Select Alpine as the base distribution. |
| `--debian` | Select Debian as the base distribution. |
| `--slim` | Select the slim compression tier. |
| `--normal` | Select the normal compression tier. |
| `--full` | Select the full compression tier. |

## Runtime API

Inside Python scripts running in the ISO environment, PY2ISO injects utility functions into the `os` module through `sitecustomize`.

### `os.exec(cmd, ...)`

Executes a shell command.

**Stream output live:**

```python
os.exec("apt-get update")
```

Bare calls stream output to standard output.

**Capture output in a result object:**

```python
res = os.exec("ls")
print(res.returncode)
print(res.stdout)
```

When the result is assigned to a variable, output is captured silently by default. The result object contains `.returncode` and `.stdout`.

Supported options:

| Option | Purpose |
|---|---|
| `show=True` | Force live output even when assigning the result to a variable. |
| `quiet=True` | Suppress output. |
| `check=True` | Raise `CalledProcessError` if the command exits with a non-zero status. |
| `interactive=True` | Allocate a real terminal session for interactive tools such as `htop`, `nano`, or text-based editors. |

### `os.stream(cmd)`

Yields command output one line at a time without printing it automatically.

```python
for line in os.stream("tail -f /var/log/syslog"):
    print("Log entry:", line)
```

Use this when your program needs to process command output as it arrives.

### `os.apt(*pkgs, remove=False)`

Manages operating-system packages at runtime. PY2ISO maps package operations to `apk` on Alpine and `apt-get` on Debian.

**Install packages:**

```python
os.apt("htop", "curl")
```

**Remove a package:**

```python
os.apt("curl", remove=True)
```

Package names must be available in the configured distribution's repositories.

## Tips and troubleshooting

- Confirm that the file is named `py2iso.txt` or `py2iso.md` and is in the project root.
- Ensure the `main` entry-point file exists.
- Check that dependency names, local paths, and Hugging Face references are valid.
- Enable `net = true` when your application needs network access at runtime. Build-time dependency downloads may also require networking during setup.
- Use `serial = true` and `shell = true` when debugging boot or runtime problems.
- Choose `core = alpine` or `core = debian` based on the packages and tools your application needs.

---

<div align="center">

**PY2ISO** · *From Python project to bootable ISO*

[Repository](https://github.com/ksvij00/py2iso) · [Install](install.md) · [Issues](https://github.com/ksvij00/py2iso/issues)

</div>

