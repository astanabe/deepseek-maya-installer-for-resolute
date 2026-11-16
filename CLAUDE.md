# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project status

`install-deepseek-maya.sh` is implemented but **has never been run on real hardware** (the development machine has no supported GPU). Everything after the prompts (apt, the service user, Maya's setup, systemd, ufw, the final tests, `--uninstall`) is untested; what was checked on the development machine is listed in README "Verification". `README.md` is the source of truth for behavior, options, defaults, file layout and procedure. Keep it in sync when the implementation changes, including its "Verification" section and the "Status" note at its top.

Everything the installer assumes about Project Maya comes from reading the documentation and source of Maya v1.1.63 (`README.md`, `docs/SETUP.md`, `docs/MODELS.md`, `docs/MEMORY.md`, `docs/DOCKER.md`, parts of `docs/SETTINGS.md`, `maya.py`, `setup.py`, `serve/server.py`, `serve/frontend.py`, `tools/calibrate_ds4.py`, `tools/ds4/download_gguf.json`), not from running it. Treat the items under "Assumptions to confirm on the first run" below and in README "Verification" as unverified.

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
- **Thinking**: `--thinking none|low|medium|high|xhigh|max|1-100`, default `high`; `auto` is deliberately not offered. Maya's setup has no option for it and rewrites `"reasoning_effort": "high"` on every run, so the installer sets `reasoning_effort` in `maya-ds4.json` after each setup run (a number as a JSON number). `thinking_budget` is left alone. **A level saved in the web page wins and is only reported**: a holder of the API key can save settings for all users (`POST /settings`, a management request); Maya keeps them in `maya-ds4.shared-settings.json` beside the configuration (`serve/server.py`: `set_shared`, `with_shared`, `svc.shared_path`) and fills that level into every request that names none, before the configuration's `reasoning_effort`; `/health` still shows the configuration's. The installer never edits or deletes that file (it was saved on purpose, a re-run without `--thinking` would undo it with the value from `install.conf`, and it holds `max_tokens`, `temperature` and others too): `check_thinking`, at the end of `smoke_test`, reads `GET /settings` (`defaults.reasoning_effort`, always a word) and warns when it differs from `--thinking`, or when it cannot be read; `thinking_word` makes `medium` equal to `high` and `xhigh` to `max`, as Maya treats them for DeepSeek, and a number given with `--thinking` never equals a saved word. `install_maya` carries the file over with `maya-ds4.json` when it replaces a tree. glm-maya does the same.
- **Drafting**: `skip` (default; no drafter, nothing measured; Maya's `--drafting off`), `measure`, `on`. **`measure` must really measure, or the installer stops**: Maya's speed calibration (`maya.py`: `speed_calibration_ds4`, `busy_gpus`) does nothing but warn when the configuration's GPU has more than 1024 MiB in use, a failure of it does not stop the setup either, and the setup exits 0; under systemd it is never made up for (`unattended_start`). `gpu_busy_check` (after the services are stopped, before `install_maya`) warns and asks with `warn_continue`, and `setup_maya` stops unless the configuration has `installer.speed_calibration.kept` (`dspark` or `none`; `failed` holds the reason when the measurement broke off). That key proves a measurement in this run because Maya writes `installer` anew on every setup (`write_config_ds4`) and `keep_drafting`, which writes `kept` with `"skipped": "chosen"`, runs only for `on` and `off`. Stopping was chosen although the state left behind is harmless (a new configuration has `--dspark none`; one written over an earlier one keeps that one's `--dspark`, `keep_args`): on a re-run the result would be "as before" while the summary and `install.conf` say `measure`. glm-maya does the same (there an unmeasured drafter stays on).
- **Ports**: nginx TCP 58080, Maya 127.0.0.1:58081.
- **Conversations kept**: `MAYA_DS4_SLOT_KEEP=1` (through the setup's `--env`). `MAYA_DS4_KEEP_THINKING` is not set.
- **API key**: Maya always has a key (generated once, kept on re-run, in `/etc/deepseek-maya/maya.env`), and nginx adds it per path and method as in the README table. **Management requests never get the key added and there is no option to change that**; any path not listed is passed with the client's own headers, so unknown paths fail safe. The key is never written into the site file (`include /etc/deepseek-maya/nginx-key.conf`, root 0600) and never passed on a command line. Model management is off (`MAYA_MODEL_MANAGEMENT=0`).
- **nginx details that matter**: `proxy_set_header Host $http_host` (Maya compares `Origin` with `Host` including the port); where the key is added, the client's `Authorization` is replaced and `x-api-key` removed; several paths get the key for `GET` only; if `nginx -t` fails, the site link is removed before aborting so that other sites are not affected.
- **Coexistence**: with glm-maya (`../glm-maya-installer-for-resolute/`, TCP 48080/48081) and qwen-strata (TCP 38080/38081) on one host, but only one of the three runs at a time. The two others are listed in `DSMAYAINS_EXCLUSIVE_UNITS` (`glm-maya.service qwen-strata.service`): `Conflicts=` names both in the unit, `disable_exclusive_units` stops and disables each of them before Maya's setup (not a unit start, so `Conflicts=` does not act there) when it is running, starting, waiting for a restart or enabled (`unit_in_use`; the summary lists them via `exclusive_units_in_use`), and `--uninstall` only prints how to enable them again. The glm-maya and qwen-strata installers do the same to the respective other two units, so the one installed last runs; keep the three sides symmetric (condition, moment of the stop, wording of the summary and of the `--uninstall` hint; the three installers use the same function names with their own prefix). While `glm-maya` or `qwen-strata` runs, `gpu_ranked` counts its GPU memory as in use, so a first non-interactive installation may pick the other GPU (the one plamo uses). With plamo-3-translate: the unit is ordered `After=plamo-3-translate-llama.service plamo-3-translate-uwsgi.service`, because Maya pins nearly all RAM that is free at its start. plamo's llama unit stays "activating" until its model is loaded (`ExecStartPost=` polling `/health`), so the `After=` really waits for the load; a consequence is that any start of `deepseek-maya` (also `systemctl restart` in `start_services`, which announces it) blocks while the plamo llama unit is activating, without a time limit. The plamo uWSGI unit does not wait for the llama unit; it is in our `After=` because it is cheap and takes its RAM first too. plamo's side must not name our unit. Other installers' units are only named in `[Unit]` and stopped/disabled; never edit or remove their files.
- **Uninstall** removes the unit, the nginx site, the logrotate file, `/etc/deepseek-maya`, the installer's ufw rules and destdir (only if the marker `.deepseek-maya-installation` is present); apt packages, nginx and the service user stay.
- TLS and exposure to the internet are out of scope.

## Open points for later

- **`MAYA_DS4_KEEP_THINKING=1`**: not set for now. Maya's `docs/SETTINGS.md` ("DeepSeek: conversations kept") says a chat without tools needs it in addition to `MAYA_DS4_SLOT_KEEP=1` to reuse a kept conversation: DeepSeek's own serving drops an earlier turn's reasoning at the next user turn, so every turn renders a history that differs from the state in the engine and nothing is reused. Requests that carry tools keep their thinking already, so agent traffic is unaffected. The cost is longer prompts and a departure from DeepSeek's own behavior. Decide after measuring on real hardware how much of a web chat's prompt is re-read with and without it; if it is adopted, add it to the setup's `--env` options, or make it an option.

## Code conventions

- Every shell variable of the installer — globals, arrays and `local`s — is prefixed with `DSMAYAINS_`. User-facing environment variables are prefixed with `DSMAYA_`. Exceptions: bash builtins, `DEBIAN_FRONTEND`, the variables Maya itself reads (`MAYA_*`), and the key names inside `install.conf` and associative arrays. Do not source external files into the installer's shell (`install.conf` and `os-release` are parsed).
- The file must not execute when sourced (`main` runs only if `BASH_SOURCE[0] == $0`), so that functions can be exercised from a test script as a normal user.
- Yes/no questions ask again on invalid input; other invalid answers stop the installer in validation.

## Installer procedure (order matters)

1. Resolve values, stop early if no usable GPU (`require_gpu`), prompts, `validate`, GPU / interface / ufw prompts, summary
2. `preflight`: ports (allowed to be held only by our own unit, or by nginx for a web port that was ours), destdir, home directory of an existing user, AVX2, driver (below 580 stops) and compute capability (below 7.5 stops; not reported: warning), disk, memory
3. apt (missing packages only; stops if no `nvcc` is found afterwards) → 4. service user, destdir (marker, `models/`, `chown -R`) → 5. stop the unit, stop and disable `glm-maya.service` and `qwen-strata.service` (each if in use), `gpu_busy_check` (`--drafting measure` only) → 6. `install_maya` (extract beside the tree, then move) → 7. API key files
8. `setup_maya` (one run of `maya.sh --setup ...` as the service user, its output kept in `project-maya/maya-setup.log` by `tee` running as that user), then `set_thinking`
9. Unit, logrotate, nginx site (`nginx -t`), enable and start → 10. ufw, `install.conf` (saved before the tests on purpose) → 11. `/health` wait (up to 60 minutes), tests through nginx, `check_thinking`, offer to delete other quantizations

Things that are easy to break:

- **`setup_maya` must keep `--setup`, `--port`, `--drafting` and `--download-model`** (the comment above the function says what happens without each), and must not trust the exit code: Maya's setup exits 0 after doing nothing. The checks afterwards are: `maya-ds4.json` written in this run (mtime), `installer.ds4_quant` equal to the selected quantization, `build/maya-ds4` executable, `<models>/DeepSeek-V4.1-Flash-1017-GGUF/<quant>/maya-ds4/ds4.txt` present, and with `--drafting measure` `installer.speed_calibration.kept` present.
- **`set_thinking` runs after every setup run** and also removes `api_key` from `maya-ds4.json`: `maya.py` passes a key from the configuration to the server on the command line, where it would take the place of `MAYA_API_KEY` from `maya.env`.
- **`nginx_location`**: modes `add`, `get` (key for `GET` only, through `map $request_method`), `chat`, `pass`; every location has a URI in `proxy_pass`, also the one prefix location (`/v1/responses/`), so that Maya is sent the normalized path nginx matched and `..` cannot borrow the key.
- `run_as` builds the environment with `env -i` (`HOME USER LOGNAME PATH LANG TERM MAYA_UPDATE_CHECK=0 PYTHONUNBUFFERED=1`).
- `cleanup_old_models` deletes only `<models>/DeepSeek-V4.1-Flash-1017-GGUF/<other quantization>/`; `dspark/`, `vision/` and `Engram-*` are shared (hard links, or symbolic links when linking failed, in which case the folder is not offered).

## Testing

There is no test suite. The file is not executed when sourced, so functions can be exercised from a test script as a normal user. All of the following was done (results in README "Verification"); the test scripts were written in a temporary directory and are not kept, so recreate them when the code they cover changes:

- `bash -n install-deepseek-maya.sh`; `shellcheck install-deepseek-maya.sh` (0.11 is installed on the development machine; keep it free of findings).
- Settings and GPU logic: source the script, set `DSMAYAINS_INTERACTIVE`, put a fake `nvidia-smi` in `PATH` that answers the four `--query-gpu=` forms used (`index,pci.bus_id`; `pci.bus_id,memory.total,memory.used,name`; `pci.bus_id,compute_cap`; `driver_version`), override `net_interfaces` and `ufw_active`, then call `parse_args` → `resolve_values` → `require_gpu` → `prompt_values` → `validate` → `prompt_gpus` → `prompt_interfaces`, and `preflight`.
- Generated files and Maya's setup: the paths under `/etc` are `readonly`, so test with a copy of the script made by `sed 's#="/etc/#="<scratch>/etc/#'`; override `chown`, `port_free`, `curl`, `mktemp` and `run_as` (without `runuser`); use a fake release archive whose `maya.sh` records its arguments and environment and writes `maya-ds4.json`, `build/maya-ds4` and the pack, with modes for the failures. `systemd-analyze verify` on the unit.
- Drafting and the saved thinking level (105 checks): `gpu_busy_check` with `gpu_candidates` overridden (the limit, the three ways `warn_continue` ends, another GPU busy); `setup_maya` with `run_as`, `wait_port_free` and `gpu_index` overridden and a fake `maya.sh` whose `maya-ds4.json` has `installer.speed_calibration` measured (`kept` `dspark` / `none`), `failed`, chosen (`skipped`) or missing, for `measure`, `skip` and `on`; `check_thinking` against a small Python server answering `GET /settings` (wants the `Authorization` header; nothing saved, each level, `medium`/`high` and `xhigh`/`max` in both directions, a number, 401, not JSON, no server); `install_maya` with `curl` and `mktemp` overridden and a fake archive, replacing a tree that has `maya-ds4.shared-settings.json`, has none, or has a symbolic link of that name.
- Unit and coexistence: override `service_exists` and `systemctl` (`is-enabled`, `show`, `disable`), call `unit_in_use` / `exclusive_units_in_use` / `disable_exclusive_units` / `show_summary` (with `gpu_label`, `interfaces_label` and `ufw_label` overridden and `DSMAYAINS_VAL` filled by hand) for each of the two other units and for both together, and the hint loop at the end of `do_uninstall` (extract it from `declare -f do_uninstall`; do not run `do_uninstall`); render `write_unit` to a scratch file (`DSMAYAINS_UNIT_DIR` is readonly: rewrite the target in `declare -f write_unit`) and run `systemd-analyze verify` on it (only the missing `maya.sh` may be reported). 199 checks: each unit alone in every state, both together, a failing `systemctl disable`, the `--uninstall` hint.
- nginx: print `nginx_site`, run a private nginx (`nginx -c <conf>` with `pid` and temp paths in a scratch directory) in front of a small Python server that enforces the key like Maya (exempt `GET /`, `/web/`, `/fonts/`, `/health`; `Authorization: Bearer` or `x-api-key`; 403 for a `POST` whose `Origin` is not the `Host`) and echoes the path and headers it received; check the four `--web-api-key` / `--agent-api-key` combinations per path class, with no key, a placeholder key, the real key, page-like requests, `GET` against `POST`, and path tricks (`..`, `%2e%2e`, `%2f`, `//`, trailing slash). Repeat it after any change to the site.
- The checks to run on real hardware are listed in README "Verification".

## First run on real hardware

Planned machine: Ryzen Threadripper PRO 3995WX, 512 GB DDR4-3200, GeForce RTX 5080 Ti 12 GB. Run in this order and record the results in README "Verification" and its "Status" note:

1. `sudo bash install-deepseek-maya.sh` interactively with the defaults (`Maya-S`, 512K). It compiles the engine and downloads about 350 GB; expect hours. If it stops, the message of `die` names the step; re-running resumes the downloads.
2. `systemctl status deepseek-maya`, `journalctl -u deepseek-maya`, `<destdir>/project-maya/maya-ds4.log`, `curl http://127.0.0.1:58080/health`.
3. From another host: the web chat (PC and phone), a coding agent through `/v1/chat/completions` and `/v1/messages` with a placeholder key.
4. Re-run with the same settings (the API key must stay the same), with 256K, 768K and 1M, with `--thinking 42` and `none`, with the four key combinations, with `--drafting measure`, with another `--quant`, then `--uninstall` and a fresh install.
5. With glm-maya, qwen-strata and plamo-3-translate installed: installing any one of `deepseek-maya`, `glm-maya` and `qwen-strata` stops and disables the other two, `systemctl start` of one stops the one that is running, only the enabled one starts at boot, plamo on the other GPU, and after a reboot `deepseek-maya` starts only when `plamo-3-translate-llama.service` has become active, i.e. has loaded its model (`systemd-analyze critical-chain deepseek-maya.service`, journal timestamps).

### Assumptions to confirm on the first run

If one of them is wrong, the installer most likely stops in `install_packages`, `setup_maya` or `smoke_test`; fix the installer and the README, not the symptom.

- `apt-get install --no-install-recommends cuda-toolkit-13` installs `nvcc` (as `/usr/local/cuda-13.1/bin/nvcc`), and Maya finds it without `--nvcc`.
- The tag archive extracts to one top-level folder (`--strip-components=1`), contains `VERSION` with `1.1.63`, and `maya.sh` is executable.
- `maya.sh --setup --yes --plain --no-start --download-model ...` asks nothing with standard input from `/dev/null`, accepts `--model DeepSeek-V4.1-Flash-1017` together with `--ds4-quant`, accepts `--context 786432`, exits 0 at the end and writes `maya-ds4.json` with `installer.ds4_quant` as given.
- The model folder is `<models>/DeepSeek-V4.1-Flash-1017-GGUF/<quantization name>` with the pack in `maya-ds4/` (`maya.py`, `ds4_model_dir`), for Maya's own quantizations too.
- `maya.sh --config <file> --port N --plain` under the unit: starts the server on 127.0.0.1, reads `MAYA_API_KEY`, `MAYA_UPDATE_CHECK` and `MAYA_MODEL_MANAGEMENT` from the environment, stops within `TimeoutStopSec=600` with `KillMode=mixed`.
- `/health` answers only when the engine is ready and has `"status": "ok"`, `"unloaded": false`, `max_context`, `model` and `defaults.reasoning_effort`; `/v1/models` has `data[0].context_length`; `GET /status` is 401 without the key and 200 with it. How `/health` words a numeric thinking level is not known, which is why `smoke_test` only shows it.
- The thinking words (`none`, `low`, `medium`, `high`, `xhigh`, `max`) and a JSON number are accepted as `reasoning_effort` at start.
- `GET /settings` with the key answers 200 with `{"shared": ..., "defaults": {...}}`, and `defaults.reasoning_effort` is the level saved in the web page (if it cannot be read, `check_thinking` says so at every installation).
- With `--drafting measure`, a measurement leaves `installer.speed_calibration.kept` in `maya-ds4.json` and a skipped one leaves no `speed_calibration` (if the key is named differently, every `measure` run stops in `setup_maya`); the GPU the installer looks at in `gpu_busy_check` is the one Maya looks at, and 1024 MiB is Maya's limit.
- The list of paths the web page needs (`nginx_site`) is complete: watch the browser's network tab with `--web-api-key` off; no "API key needed" message may appear while chatting.
- Real browsers over plain HTTP send `Origin` on the chat POST, so that the `map` recognises the page when the two key settings differ.
- GPU numbering: the PCI address selected is the GPU Maya loads.
- Whether a change of the quantization downloads the Q6_K Engram tables (161 GB) again, and whether `cleanup_old_models` may delete the old folder without breaking the new one.
- The logrotate rule works (`logrotate -d /etc/logrotate.d/deepseek-maya`).
- Whether llama-server of plamo has really taken all its RAM and GPU memory when its `/health` returns 200 (the moment our unit may start).
