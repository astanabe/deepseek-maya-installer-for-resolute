# deepseek-maya-installer-for-resolute

DeepSeek-V4.1-Flash-1017 installer script for Ubuntu 26.04 LTS Resolute Raccoon (Server or Desktop), using the [Project Maya](https://github.com/mw00/project-maya) inference engine

The installer sets up Project Maya v1.1.63 and DeepSeek-V4.1-Flash-1017 as a systemd service behind nginx, for web browsers (PC and smartphone) and coding agents on an intranet. Compiling the engine, downloading the model and writing the engine configuration are left to Maya's own setup (`maya.sh`); this installer adds the CUDA toolkit and the other apt packages, the service user, the systemd unit, the nginx site, ufw rules, the selection of GPUs and network interfaces, and an uninstaller.

> **Status**: this document is the specification. The installer `install-deepseek-maya.sh` is not written yet, and nothing has been run on real hardware. See [Verification](#verification).

## Prerequisites

- Ubuntu 26.04 LTS (Resolute Raccoon), x86_64, Server or Desktop, with the `universe` and `multiverse` components enabled. Ubuntu on WSL is not supported (the installer detects it and stops).
  - On Desktop, the display also uses GPU memory, and the service stops while the machine is suspended.
- A CPU with AVX2
- Root privileges (`sudo`)
- Internet access to GitHub (Maya, llama.cpp source), Hugging Face (models), PyPI (Maya's Python packages) and the Ubuntu apt repositories
- An NVIDIA GPU of the RTX 20 series or newer (compute capability 7.5 or higher). Maya has no CPU-only engine. 12 GB of GPU memory or more is recommended. AMD GPUs and Intel Arc are not supported by this installer.
- **NVIDIA driver 580 or later, installed in advance**. The installer never installs GPU drivers. Install the driver and reboot (e.g. `sudo ubuntu-drivers install`), so that `nvidia-smi` works. The installer stops with an older driver, because the engine is compiled with CUDA 13.
- A fast NVMe SSD with room for the selected quantization, and enough memory for it (see [Quantization](#quantization)); the installer checks both and warns if they look insufficient. Part of every model (the Engram tables) is always read from the disk, so a hard disk is not suitable.

The CUDA toolkit is not a prerequisite: the installer installs `cuda-toolkit-13` from the Ubuntu repository.

## Usage

```
sudo bash install-deepseek-maya.sh                            # interactive install
sudo bash install-deepseek-maya.sh \
    --destdir /opt/deepseek-maya --quant Maya-S ...           # non-interactive install
sudo bash install-deepseek-maya.sh --uninstall                # uninstall
```

- Run as root. The installer is a single file and needs nothing else from this repository.
- Every prompt has a corresponding command-line option and environment variable. Only values that are not given are asked. When standard input is not a terminal, the defaults are used without prompting.
- Values are taken in this order: command-line option, environment variable, the previous installation (`/etc/deepseek-maya/install.conf`), default.
- Re-running the installer updates the existing installation in place: the systemd unit, the nginx site and the other generated files are overwritten; Maya's source tree and the compiled engine are reused when the pinned version is already installed; the model files already downloaded are checked and reused by Maya; the generated API key is kept. If the quantization changed, the installer offers to delete the model files of the other quantizations (only when run interactively).
- `--uninstall` stops and disables the service and removes the systemd unit, the nginx site configuration, `/etc/deepseek-maya`, the ufw rules added by the installer and destdir (with Maya and all downloaded files). apt packages (including the CUDA toolkit), nginx itself and the service user are kept.

### Options

Asked interactively when not given:

| Option | Environment variable | Default |
|---|---|---|
| `--destdir DIR` | `DSMAYA_DESTDIR` | `/opt/deepseek-maya` |
| `--user NAME` | `DSMAYA_USER` | `dsmaya` |
| `--quant Maya-XS\|Maya-S\|UD-IQ1_S\|UD-IQ1_M\|UD-IQ2_XXS\|UD-Q2_K_XL\|UD-IQ3_XXS\|UD-IQ3_S\|UD-Q3_K_XL\|UD-Q4_K_XL\|UD-Q8_K_XL` | `DSMAYA_QUANT` | `Maya-S` |
| `--gpu PCI` | `DSMAYA_GPU` | chosen as described below (asked when two or more GPUs are usable) |
| `--ctx-size 262144\|524288\|786432\|1048576` | `DSMAYA_CTX_SIZE` | `524288` |
| `--thinking none\|low\|medium\|high\|xhigh\|max\|1-100` | `DSMAYA_THINKING` | `high` |
| `--drafting skip\|measure\|on` | `DSMAYA_DRAFTING` | `skip` |
| `--web-port PORT` | `DSMAYA_WEB_PORT` | `58080` |
| `--interfaces all\|IF[,IF...]` | `DSMAYA_INTERFACES` | `all` (asked when two or more interfaces have addresses) |
| `--web-api-key` / `--no-web-api-key` | `DSMAYA_WEB_API_KEY` (`yes`/`no`) | `no` |
| `--agent-api-key` / `--no-agent-api-key` | `DSMAYA_AGENT_API_KEY` (`yes`/`no`) | `no` |
| `--open-ports` / `--no-open-ports` | `DSMAYA_OPEN_PORTS` (`yes`/`no`) | ask when ufw is active |

Never asked (option or environment variable only):

| Option | Environment variable | Default |
|---|---|---|
| `--parallel N` | `DSMAYA_PARALLEL` | `1` (1 to 8) |
| `--vision` / `--no-vision` | `DSMAYA_VISION` (`yes`/`no`) | `yes` |
| `--maya-port PORT` | `DSMAYA_MAYA_PORT` | `58081` |

Actions:

| Option | |
|---|---|
| `--yes` | answer yes to warnings, opening ufw ports and uninstalling |
| `--uninstall` | uninstall |
| `--help` | show the help |

GPU selection: the installer runs the model on one GPU. It lists the NVIDIA GPUs that answer to `nvidia-smi`, with their PCI addresses, total memory and memory in use, and asks which one to use when there are two or more. `--gpu` takes a PCI address as shown by `lspci -D` (e.g. `0000:03:00.0`). The default is the GPU with the largest memory, then the most free memory, then the lowest PCI address. So when another service (e.g. the llama-server of plamo-3-translate-installer-for-resolute) already uses one of two identical GPUs, the free one is the default. The PCI address is converted to the `nvidia-smi` number Maya takes at installation. Maya itself can split the model across several GPUs, but this installer does not offer that yet.

Context size: the maximum context length in tokens, one of four choices.

| `--ctx-size` | | GPU memory for the context, per conversation and GPU |
|---|---|---:|
| `262144` | 256K, the size Maya recommends when memory allows | about 0.27 GB |
| `524288` | 512K (default) | about 0.55 GB |
| `786432` | 768K. **Not one of Maya's own choices and not tested by the Maya project.** | about 0.82 GB |
| `1048576` | 1M, the model's own maximum | about 1.10 GB |

The memory is taken from the GPU memory that would otherwise hold experts (about 1.1 KB per position), so a longer context makes answers a little slower. Maya also notes that reading a very long prompt is slow, because part of the work grows with the square of its length. Maya's smaller choices (32K, 64K, 128K) are not offered by this installer.

Thinking: the thinking level a request gets when it names none. Users can still choose another level in the web page or per request.

| `--thinking` | |
|---|---|
| `none` | no thinking (Off in the page) |
| `low` | Low (DeepSeek's effort 50) |
| `medium` | the same as `high` |
| `high` | High (effort 75; default, and the default of Maya and of DeepSeek) |
| `xhigh` | the same as `max` |
| `max` | Max (effort 100) |
| a number from 1 to 100 | DeepSeek's own effort level. It is written into the prompt as a hint to the model; it is not a limit in tokens. |

Maya's limit on the thinking in tokens (`thinking_budget`: 32768, or 8192 with `Maya-XS`) is left at Maya's default. Maya's setting `auto` is not offered.

Drafting: DeepSeek's DSpark drafter proposes several tokens ahead and the model checks them; whether it is faster depends on the machine. `skip` (default) runs without the drafter and measures nothing. `measure` lets Maya's speed calibration measure it during the installation (5 to 30 minutes, the model is loaded several times) and keep it only if it is faster. `on` uses the drafter without measuring. A typical use is to install with `skip` first and to re-run with `--drafting measure` later.

Parallel requests: `--parallel N` lets Maya answer up to N requests at once. Each one keeps a whole context in GPU memory (the figures in the table above, times N).

Pictures: with `--vision` (default), Maya also downloads DeepSeek's vision tower (about 1 GB), so that pictures can be attached in the chat and sent through the APIs. It stays in RAM and borrows about 320 MB of GPU memory only while a picture is read. `--no-vision` leaves it out.

Network interfaces: when two or more network interfaces have global addresses (container/VM bridges such as `docker0`, `virbr0` and `lxdbr0` are ignored), the installer asks on which of them the web server accepts connections from other hosts (`all` or numbers). With selected interfaces, nginx listens on their current addresses plus `127.0.0.1` (and `::1`), and the ufw rules are limited to them (`ufw allow in on IF to any port PORT proto tcp`). The interface names are saved and the addresses are looked up at installation, so re-run the installer if an address changes. ufw rules added by an earlier run that are no longer wanted are removed.

API key: see [API key](#api-key).

### Files

```
<destdir>/                                  default /opt/deepseek-maya; home directory of the service user
  .deepseek-maya-installation               marker checked by --uninstall
  project-maya/                             Maya's source tree (extracted release archive)
    .venv/                                  Maya's Python environment
    third_party/                            llama.cpp source at Maya's pinned commit
    build/maya-ds4                          the compiled DeepSeek engine
    maya-ds4.json                           engine configuration written by Maya's setup
    maya-ds4.log                            engine log
    maya-setup.log                          log of Maya's setup
  models/                                   model files, one folder per quantization, with Maya's pack inside
/etc/deepseek-maya/
  install.conf                              settings of the installation
  maya.env                                  API key (MAYA_API_KEY) and Maya's switches (root and the service user only)
  nginx-key.conf                            the same key for nginx (root only)
/etc/systemd/system/deepseek-maya.service   maya.sh --config .../maya-ds4.json (127.0.0.1:58081)
/etc/nginx/sites-available/deepseek-maya    (linked from sites-enabled)
/etc/logrotate.d/deepseek-maya              rotation of the engine log
```

Maya's release archive (the archive of the tag v1.1.63) is downloaded from GitHub over HTTPS with `curl`; `git` is not needed. The installer does not verify the archive with a checksum. Everything else is downloaded and verified by Maya's setup: the llama.cpp source at a pinned commit, its Python packages from PyPI, and the model files from pinned Hugging Face revisions with fixed sizes and SHA-256 checksums.

## Models

- DeepSeek-V4.1-Flash-1017
  - https://huggingface.co/deepseek-ai/DeepSeek-V4.1-Flash-1017
  - Quantized by Project Maya: https://huggingface.co/peasantsmith/DeepSeek-V4.1-Flash-1017-Maya-GGUF
  - Quantized by Unsloth: https://huggingface.co/unsloth/DeepSeek-V4.1-Flash-1017-GGUF

## License

### License of this repository

The files in this repository (the installer and the documentation) are distributed under the MIT License. See [LICENSE](LICENSE).

### License of DeepSeek-V4.1-Flash-1017

The model files downloaded through the installer are not part of this repository. DeepSeek-V4.1-Flash-1017 is distributed by DeepSeek under the MIT License, and so are the quantized files of Project Maya and Unsloth that the installer offers. The installer therefore does not ask for a license confirmation.

- Project Maya itself is distributed under the MIT License; it is built on ggml / llama.cpp (MIT License).
- The CUDA toolkit installed from the Ubuntu `multiverse` component is NVIDIA's proprietary software under NVIDIA's own license.

## Engine

- Project Maya v1.1.63
  - https://github.com/mw00/project-maya/releases/tag/v1.1.63
- Maya publishes source only. The installer downloads the archive of the tag, and Maya's setup compiles the DeepSeek engine (`build/maya-ds4`) on the machine with `cuda-toolkit-13` (CUDA 13.1) and the default `g++` (15.2) of Ubuntu 26.04. This takes 10 to 30 minutes at the first installation.
- The version is pinned: Maya's update check is disabled (`MAYA_UPDATE_CHECK=0`), and the Update button of Maya's page cannot work without a git checkout. Updating Maya means updating this installer and re-running it.
- Maya's setup and `maya.sh` are always run as the service user, with destdir as its home directory.
- Maya's setup is run without starting the model (`--no-start`), so the model is loaded only once, by the systemd service.
- Conversations are kept (`MAYA_DS4_SLOT_KEEP=1`): the DeepSeek engine holds one conversation per parallel request, and without this setting a request that belongs to another conversation makes the engine read the whole prompt again from the first token. With it, a conversation that is replaced is set aside in RAM or under `models/` and taken back when it continues, so a web chat and a coding agent can take turns.
- Maya's model management (downloading, deleting and switching models through the page or the Ollama-style `/api/*` paths) is turned off (`MAYA_MODEL_MANAGEMENT=0`). The model is selected by the installer only.
- At start, the engine pins most of the free RAM (all but about 6 GB) and warms its caches; a start takes minutes.

## Quantization

Selected with `--quant`. The installer derives Maya's setup option from the name.

| `--quant` | Provider | Maya's setup option | Download | Memory for the whole model |
|---|---|---|---:|---:|
| `Maya-XS` | Project Maya | `--model deepseek-maya-xs` | 278 GB | 121 GB |
| `Maya-S` (default) | Project Maya | `--model deepseek-maya-s` | 340 GB | 186 GB |
| `UD-IQ1_S` | Unsloth | `--ds4-quant gguf-iq1_s` | 233 GB | 123 GB |
| `UD-IQ1_M` | Unsloth | `--ds4-quant gguf-iq1_m` | 250 GB | 140 GB |
| `UD-IQ2_XXS` | Unsloth | `--ds4-quant gguf-iq2_xxs` | 301 GB | 166 GB |
| `UD-Q2_K_XL` | Unsloth | `--ds4-quant gguf-q2_k_xl` | 335 GB | 200 GB |
| `UD-IQ3_XXS` | Unsloth | `--ds4-quant gguf-iq3_xxs` | 395 GB | 234 GB |
| `UD-IQ3_S` | Unsloth | `--ds4-quant gguf-iq3_s` | 424 GB | 263 GB |
| `UD-Q3_K_XL` | Unsloth | `--ds4-quant gguf-q3_k_xl` | 485 GB | 283 GB |
| `UD-Q4_K_XL` | Unsloth | `--ds4-quant gguf-q4` | 501 GB | not documented by Maya |
| `UD-Q8_K_XL` | Unsloth | `--ds4-quant gguf-q8` | 508 GB | about 306 GB |

- The figures are from Maya v1.1.63 (`tools/ds4/download_gguf.json`, `docs/MEMORY.md`).
- Download: the model files, including the Engram (n-gram) tables, which always stay on the SSD. Maya also fetches the DSpark drafter (about 8 GB; `Maya-XS` has its own of about 4 GB) and, with `--vision`, the vision tower (about 1 GB), and builds its pack (about 1 GB) inside the model folder. The installer checks for the download size plus about 20 GB of free disk space.
- Memory for the whole model: GPU memory and RAM together that hold every expert, the context aside. With less, Maya keeps as many experts as fit and reads the rest from the SSD, which is much slower. The installer says so when the machine has less, and warns and asks whether to continue when the machine has less than 32 GB of RAM, the minimum Maya names.
- `Maya-S` picks the same next token as the original model 92.6% of the time, as measured by the Maya project. `UD-Q8_K_XL` keeps DeepSeek's own formats and is the closest to the original.
- `UD-Q4_K_XL` is no longer in Maya's own list of choices, but Maya still accepts it.
- Maya's `Maya-M` is announced but not published in v1.1.63, so it is not offered.

## Architecture

```
web browser / coding agent
  → nginx (TCP 58080, on the selected network interfaces)
    → Maya server (127.0.0.1:58081; systemd unit deepseek-maya.service, service user)
      → Project Maya engine maya-ds4 (child process of the server; GPU)
```

- Maya's server provides the web chat page with its monitor (`/`), the OpenAI-compatible API (`/v1/chat/completions`, `/v1/responses`, `/v1/models`) and the Anthropic-compatible API (`/v1/messages`) on one port. There is no `/v1/completions`, no `/v1/messages/count_tokens` and no embeddings endpoint.
- nginx (`nginx-full` from apt) is the only part reachable from other hosts. The site `deepseek-maya` does not use `default_server`, so it can live beside other sites (e.g. plamo-3-translate-installer-for-resolute on TCP 18080 and 28080, qwen-strata-installer-for-resolute on TCP 38080). Responses are not buffered (streaming), the timeouts are 3660 seconds and request bodies may be up to 256 MiB (pictures and files are sent inline).
- The service runs as the user given at installation (default `dsmaya`). If the user does not exist, it is created as a system user without login and with destdir as its home directory. An existing user is used only if its home directory is destdir.
- systemd unit: `Type=simple`, `maya.sh --config <destdir>/project-maya/maya-ds4.json`, `EnvironmentFile=/etc/deepseek-maya/maya.env`, `LimitMEMLOCK=infinity` (the engine pins the experts in RAM), `TimeoutStartSec=infinity`, `TimeoutStopSec=600` (the engine saves its conversations and frees the GPU), `Restart=on-failure`, `RestartSec=30`. Sandboxing is light (`NoNewPrivileges`, `ProtectSystem=full`) until the service has been tested on real hardware.
- Logs: `journalctl -u deepseek-maya` (server) and `<destdir>/project-maya/maya-ds4.log` (engine; rotated weekly by logrotate with `copytruncate`).
- TLS is out of scope. The service is meant for an intranet, not for the internet.

### Coexistence with other services

- **qwen-strata-installer-for-resolute**: both can be installed on one host, but they are not meant to run at the same time. If `qwen-strata.service` exists, the installer stops and disables it before starting `deepseek-maya.service`, and the unit declares `Conflicts=qwen-strata.service`, so starting one stops the other. `--uninstall` does not enable `qwen-strata.service` again; it prints the command to do so (`sudo systemctl enable --now qwen-strata`).
- **plamo-3-translate-installer-for-resolute**: can run at the same time, on another GPU. Because Maya pins most of the RAM that is free when it starts, the unit is ordered after `plamo-3-translate-llama.service` and `plamo-3-translate-uwsgi.service`. Restarting the plamo services while Maya runs leaves them only the few GB Maya left free; restart `deepseek-maya` afterwards in that case.

### API key

Maya has a single API key that is either required for everything except the web page itself and `/health`, or not set at all. Without a key, Maya trusts requests from `127.0.0.1` for its management functions, and behind nginx every request comes from `127.0.0.1`. The installer therefore always sets a key in Maya (generated at the first installation, kept afterwards) and lets nginx add it to the requests that are meant to work without one. The key is never written into the nginx site file; nginx reads it from `/etc/deepseek-maya/nginx-key.conf`.

| Path | Default | Key required with |
|---|---|---|
| `/`, `/web/`, `/fonts/`, `/health` | passed on as is (Maya needs no key for them) | — |
| what the web page needs for chatting: `GET /metrics`, `POST /attach`, `POST /pdf`, `POST /api/tokens`, `GET /v1/strata/stream`, `POST /v1/strata/cancel`, and `GET` of `/settings`, `/mcp`, `/api/context`, `/api/thinking-budget`, `/api/turbo` and `/api/savings` (read-only) | nginx adds the key | `--web-api-key` |
| `/v1/chat/completions` (used by the web page and by agents) | nginx adds the key | `--web-api-key` for the web page, `--agent-api-key` for other clients |
| `/v1/messages`, `/v1/responses` and `/v1/responses/...`, `/v1/models`, `/models`, `/props`, `/tokenize`, `/detokenize` | nginx adds the key | `--agent-api-key` |
| everything else: management (`POST` of `/settings`, `/api/context`, `/api/port`, `/api/thinking-budget`, `/api/turbo`, `/api/update`, `/api/models/...`, `/api/savings/...`; `/status`, `/v1/status`, `/slots`, `/metrics/prometheus`, `/api/report`, ...) | passed on as is: **the key is always required** | — |

- Where nginx adds the key, it replaces the client's `Authorization` header and removes `x-api-key`, so that the placeholder key that SDKs and agents insist on sending does not cause a 401. With the defaults, coding agents can be configured with any non-empty string as the API key.
- With `--web-api-key`, enter the key in the settings of the web page. The same is needed to use the management functions of the page (context size, port, thinking budget, Turbo); without the key they fail, while chatting works.
- `/v1/chat/completions` is shared by the web page and the agents. When `--web-api-key` and `--agent-api-key` differ, nginx decides whether a request comes from the web page by the headers browsers add: `Sec-Fetch-Site: same-origin`, or, where the browser does not send `Sec-Fetch-Site` (browsers send it only to HTTPS and localhost origins, and this site is plain HTTP), an `Origin` header that equals the `Host` header. **Other clients can forge these headers**, so requiring the key on one side only guards against mistakes, not against users who want to get around it. Require it on both sides when that matters.
- Anyone who holds the key can change Maya's settings for all users, including the context size and the port (changing the port through the page breaks the service until the installer is re-run).
- Show the key: `sudo sed -n 's/^MAYA_API_KEY=//p' /etc/deepseek-maya/maya.env`

## Client

- Web browser (PC and smartphone): `http://<server>:58080/`
- Coding agent, OpenAI-compatible: base URL `http://<server>:58080/v1`
- Coding agent, Anthropic-compatible: base URL `http://<server>:58080` (e.g. Claude Code: `ANTHROPIC_BASE_URL=http://<server>:58080`)

The model name is reported by `/v1/models`, together with the context size (`context_length`). Thinking can be set to Off, Low, High or Max, in the page or per request; without that, the level given with `--thinking` applies. For reuse of a kept conversation, a client must send each assistant turn's `reasoning_content` back as it received it.

## Procedure

1. Ask the user for destdir (default `/opt/deepseek-maya`), user name (default `dsmaya`), quantization (default `Maya-S`), GPU (only if two or more are usable), context size (default 524288), thinking level (default `high`), drafting (default `skip`), web server port (default 58080), network interfaces to listen on (only if two or more have addresses), whether the web page and the agents need the API key (default no for both), and whether to open the port in ufw (only if ufw is active and the port is not allowed yet); show a summary
2. Check prerequisites: Ubuntu 26.04 on x86_64 and not WSL, AVX2, the NVIDIA driver (580 or later) and the selected GPU (compute capability 7.5 or higher), the ports are not in use, destdir is empty or a previous installation, the service user's home directory, free disk space and memory (warn and ask to continue if insufficient)
3. Install missing dependencies via apt: `cuda-toolkit-13 build-essential python3 python3-venv nginx-full curl ca-certificates tar pciutils`
4. Create the service user if needed and prepare destdir
5. Stop the existing `deepseek-maya` service; stop and disable `qwen-strata.service` if it exists (Maya's setup and the engine need the GPU and the RAM)
6. Download Maya's release archive and extract it into `<destdir>/project-maya` (skipped when the pinned version is already there)
7. Generate the API key, or reuse the existing one, and write `maya.env` and `nginx-key.conf`
8. Run Maya's setup once as the service user, without questions and without starting the model (`maya.sh --setup --yes --plain --no-start --download-model` with the model, GPU, context, port, drafting, parallel and vision options, `--models-dir <destdir>/models` and `--env MAYA_DS4_SLOT_KEEP=1`): it creates `.venv`, fetches the llama.cpp source, compiles the engine, downloads and checks the model, builds the pack and writes `maya-ds4.json`. Then set the thinking level in `maya-ds4.json` (`reasoning_effort`), because Maya's setup has no option for it and writes `high` on every run
9. Write the systemd unit, the nginx site and the logrotate configuration, test the nginx configuration (on failure the site is disabled again so that other sites are not affected), enable and start the service
10. Configure ufw as answered in step 1 (if ufw became active after step 1, ask here) and save `install.conf`
11. Test: wait until `/health` of Maya answers 200 with the model loaded, then check through nginx that `/health` works, that a management request is refused without the key and accepted with it, that the key requirement of `/metrics` and `/v1/models` matches the settings, that `/v1/models` reports the selected context size, that `/health` reports the selected thinking level, and that a short chat completion is answered

## Known limitations

- Not yet implemented, and not yet run on real hardware (see below).
- NVIDIA GPUs of the RTX 20 series or newer only. AMD GPUs, Intel Arc, older NVIDIA GPUs (V100, GTX 10) and WSL are not supported.
- One GPU only; Maya's multi-GPU operation is not offered.
- The context size 768K is outside Maya's own choices and untested by the Maya project.
- Not meant to run at the same time as qwen-strata-installer-for-resolute's service.
- While Maya runs, other programs get little RAM.
- Requiring the API key for only one of the web page and the agents depends on request headers and can be circumvented on purpose.
- With the default settings anyone on the networks the web server listens on can use the model without a key; only the management functions are protected.
- Maya's model management and its Ollama-style API are turned off, and Maya cannot update itself.
- Claude Code and other Anthropic-compatible clients that call `/v1/messages/count_tokens` get a 404 for that call.
- TLS is out of scope.

## Verification

Nothing has been verified by running it. What is written here about Maya comes from reading the documentation and the source of Maya v1.1.63, and what is written about the apt packages from the package index and the package contents of Ubuntu 26.04.1 (`cuda-toolkit-13` 13.1.1 in `multiverse`; its headers accept GCC up to 15; `nvcc` is installed as `/usr/local/cuda-13.1/bin/nvcc`, where Maya looks for it).

To be done on real hardware (planned machine: Ryzen Threadripper PRO 3995WX, 512 GB DDR4-3200, GeForce RTX 5080 Ti 12 GB):

- The engine builds with `cuda-toolkit-13`, `g++` 15.2 and Python 3.14 (Maya's Python packages install into `.venv`); if the build refuses the compiler, `g++-14` with Maya's `--host-compiler g++-14` is the fallback
- Maya's setup runs to the end without a terminal and without questions with `--yes --plain --no-start --download-model`
- The service starts with each context size, in particular 786432 (768K) and 1048576 (1M), and `/v1/models` reports it
- `MAYA_API_KEY`, `MAYA_MODEL_MANAGEMENT=0` and `MAYA_UPDATE_CHECK=0` from the unit's `EnvironmentFile` are what the server enforces
- Each `--thinking` value is accepted at start (Maya stops the start for a value it does not take), and a number such as `42` works
- A complete installation, a re-run, a re-run with another quantization, and `--uninstall`
- Through nginx: a reply in the web chat (PC and smartphone) without an "API key needed" message when `--web-api-key` is off, replies from `/v1/chat/completions` and `/v1/messages`, 401 for a management request without the key and 200 with it; the list of paths the web page needs (see [API key](#api-key)) is complete
- A web chat and a coding agent taking turns reuse their kept conversations
- `systemctl stop` and `restart` timings, and switching between `deepseek-maya` and `qwen-strata`
- Speed (reading a prompt and writing an answer) with `Maya-S` at 256K, 512K, 768K and 1M, and whether `--drafting measure` keeps the drafter
