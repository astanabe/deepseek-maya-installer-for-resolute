# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project status

The repository is at the specification stage. `README.md` is the agreed specification and the source of truth for behavior, options, defaults, file layout and procedure. The installer `install-deepseek-maya.sh` **does not exist yet**, and there is no build, lint or test tooling. Keep `README.md` in sync when the implementation changes, including its "Verification" section and the "Status" note at its top.

Everything the specification says about Project Maya comes from reading the documentation and source of Maya v1.1.63 (`README.md`, `docs/SETUP.md`, `docs/MODELS.md`, `docs/MEMORY.md`, `docs/DOCKER.md`, parts of `docs/SETTINGS.md`, `maya.py`, `setup.py`, `serve/server.py`, `tools/ds4/download_gguf.json`), not from running it. The development machine has no supported GPU. Treat the items in README "Verification" as unverified assumptions.

## Purpose

A single-file bash installer that sets up DeepSeek-V4.1-Flash-1017 with Project Maya v1.1.63 (https://github.com/mw00/project-maya/releases/tag/v1.1.63) as a service on **Ubuntu 26.04 LTS (Resolute Raccoon)**, x86_64, Server or Desktop (WSL is detected and refused). Clients are web browsers and coding agents on an intranet. The main requirement is the selectable maximum context: 512K by default, or 256K, 768K, 1M.

It is modelled on `../qwen-strata-installer-for-resolute/` (https://github.com/astanabe/qwen-strata-installer-for-resolute): port its structure and functions (settings resolution, GPU and interface selection, ufw handling, nginx site, API key files, uninstall) and keep the two recognisably parallel. Read its `install-qwen-strata.sh` and `CLAUDE.md` before implementing.

```
sudo bash install-deepseek-maya.sh              # interactive
sudo bash install-deepseek-maya.sh --quant ...  # non-interactive
sudo bash install-deepseek-maya.sh --uninstall
```

## Architecture (request path)

```
browser / coding agent
  → nginx (TCP 58080, selected interfaces; site deepseek-maya, no default_server)
    → Maya server (127.0.0.1:58081; deepseek-maya.service, service user)
      → maya-ds4 engine (child process)
```

destdir (default `/opt/deepseek-maya`) is the home directory of the service user (default `dsmaya`) and entirely owned by it. Maya's tree is `<destdir>/project-maya`, the models are in `<destdir>/models`. Maya writes its configuration (`maya-ds4.json`), logs and `.venv` inside its own tree, so `maya.sh` must always run as the service user.

## How Maya differs from Strata (the reference installer's engine)

- **Source only, compiled on the host.** There are no release binaries. Maya's setup (`maya.sh`, a wrapper that creates `.venv` and runs `maya.py`) fetches the llama.cpp source as a zip, compiles `build/maya-ds4` with `nvcc` and `g++`, downloads the model with pinned sizes and SHA-256, builds a pack and writes `maya-ds4.json`. The installer delegates all of this to one non-interactive setup run.
- **No two-step start.** `--no-start` makes the setup stop before starting the model, so the model is loaded once, by systemd.
- **Driver floor** follows the toolkit: Maya requires NVIDIA driver 580 or later when built with CUDA 13 (525 otherwise). CUDA 13 cannot compile for compute capability below 7.5.
- **Context**: Maya's setup offers 32K to 1M in powers of two; `--context N` passes any integer through unchecked. 786432 (768K) relies on that.
- **API key**: one key (or a comma-separated list), read from `--api-key`, `MAYA_API_KEY` or the config's `api_key`. When set, every POST and almost every GET needs it; exempt are `/`, `/web/`, `/fonts/` and `/health`. Without a key, management is allowed only from `127.0.0.1`, which behind nginx means everyone. Maya also refuses POSTs whose `Origin` does not equal `Host`.

## Design decisions (agreed with the user; don't change without asking)

- **Maya is pinned to v1.1.63** and obtained as the GitHub tag archive with `curl` over HTTPS. The archive is **not** checksum-verified (the user's decision; GitHub does not guarantee that generated archives stay byte-identical). **`git` must not be required or installed.** `MAYA_UPDATE_CHECK=0`; updating Maya means updating the installer.
- **CUDA toolkit**: `cuda-toolkit-13` from the standard Ubuntu repository (`multiverse`), installed by the installer. GPU drivers are never installed. The default `g++` is used; `g++-14` with Maya's `--host-compiler` is only a documented fallback.
- **NVIDIA only** (RTX 20 series or newer). AMD and Intel Arc are out of scope for now; do not add ROCm handling.
- **One GPU only** (`--gpu PCI`; default: largest memory, most free memory, lowest PCI address). Multi-GPU operation is out of scope for now.
- **API surface**: the Anthropic-compatible API stays documented and supported as Maya provides it; gaps in Maya's APIs (e.g. no `/v1/messages/count_tokens`) are Maya's to fix, the installer does not work around them.
- **Context**: exactly four choices, 262144, 524288 (default), 786432, 1048576. Maya's smaller sizes are not offered. 768K is labelled as untested by Maya.
- **Quantization**: all of Maya's own and all of Unsloth's: `Maya-XS`, `Maya-S` (default), `UD-IQ1_S`, `UD-IQ1_M`, `UD-IQ2_XXS`, `UD-Q2_K_XL`, `UD-IQ3_XXS`, `UD-IQ3_S`, `UD-Q3_K_XL`, `UD-Q4_K_XL`, `UD-Q8_K_XL`. `Maya-M` is not published in v1.1.63; EXL3 and abliterated files are not offered.
- **Options**: asked: `--destdir --user --quant --gpu --ctx-size --thinking --drafting --web-port --interfaces --web-api-key --agent-api-key --open-ports`; never asked: `--parallel` (default 1), `--vision`/`--no-vision` (default on), `--maya-port`. There is **no license confirmation** (model and quantizations are MIT).
- **Thinking**: `--thinking none|low|medium|high|xhigh|max|1-100`, default `high`; `auto` is deliberately not offered. Maya's setup has no option for it and rewrites `"reasoning_effort": "high"` on every run, so the installer sets `reasoning_effort` in `maya-ds4.json` after each setup run (a number as a JSON number). `thinking_budget` is left alone.
- **Drafting**: `skip` (default; no drafter, nothing measured; Maya's `--drafting off`), `measure`, `on`.
- **Ports**: nginx TCP 58080, Maya 127.0.0.1:58081.
- **Conversations kept**: `MAYA_DS4_SLOT_KEEP=1` (through the setup's `--env`). `MAYA_DS4_KEEP_THINKING` is not set.
- **API key**: Maya always has a key (generated once, kept on re-run, in `/etc/deepseek-maya/maya.env`), and nginx adds it per path and method as in the README table. **Management requests never get the key added and there is no option to change that**; any path not listed is passed with the client's own headers, so unknown paths fail safe. The key is never written into the site file (`include /etc/deepseek-maya/nginx-key.conf`, root 0600) and never passed on a command line. Model management is off (`MAYA_MODEL_MANAGEMENT=0`).
- **nginx details that matter**: `proxy_set_header Host $http_host` (Maya compares `Origin` with `Host` including the port); where the key is added, the client's `Authorization` is replaced and `x-api-key` removed; several paths get the key for `GET` only; if `nginx -t` fails, the site link is removed before aborting so that other sites are not affected.
- **Coexistence**: with qwen-strata on one host but never running together: stop and disable `qwen-strata.service` before starting, `Conflicts=qwen-strata.service` in the unit, and `--uninstall` only prints how to enable it again. With plamo-3-translate: the unit is ordered `After=` its two services, because Maya pins nearly all RAM that is free at its start.
- **Uninstall** removes the unit, the nginx site, the logrotate file, `/etc/deepseek-maya`, the installer's ufw rules and destdir (only if the marker `.deepseek-maya-installation` is present); apt packages, nginx and the service user stay.
- TLS and exposure to the internet are out of scope.

## Open points for later

- **`MAYA_DS4_KEEP_THINKING=1`**: not set for now. Maya's `docs/SETTINGS.md` ("DeepSeek: conversations kept") says a chat without tools needs it in addition to `MAYA_DS4_SLOT_KEEP=1` to reuse a kept conversation: DeepSeek's own serving drops an earlier turn's reasoning at the next user turn, so every turn renders a history that differs from the state in the engine and nothing is reused. Requests that carry tools keep their thinking already, so agent traffic is unaffected. The cost is longer prompts and a departure from DeepSeek's own behavior. Decide after measuring on real hardware how much of a web chat's prompt is re-read with and without it; if it is adopted, add it to the setup's `--env` options, or make it an option.

## Code conventions

- Every shell variable of the installer — globals, arrays and `local`s — is prefixed with `DSMAYAINS_`. User-facing environment variables are prefixed with `DSMAYA_`. Exceptions: bash builtins, `DEBIAN_FRONTEND`, the variables Maya itself reads (`MAYA_*`), and the key names inside `install.conf` and associative arrays. Do not source external files into the installer's shell (`install.conf` and `os-release` are parsed).
- The file must not execute when sourced (`main` runs only if `BASH_SOURCE[0] == $0`), so that functions can be exercised from a test script as a normal user.
- Yes/no questions ask again on invalid input; other invalid answers stop the installer in validation.

## Testing

There is no test suite. Once the installer exists: `bash -n install-deepseek-maya.sh` and `shellcheck install-deepseek-maya.sh`; settings and GPU logic by sourcing the script with a fake `nvidia-smi` in `PATH`; the nginx site by running a private nginx in front of a small server that enforces the key like Maya (see the reference repository's `CLAUDE.md`, "Testing", for the method). The checks to run on real hardware are listed in README "Verification".
