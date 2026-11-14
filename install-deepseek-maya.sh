#!/bin/bash
# DeepSeek-V4.1-Flash-1017 + Project Maya installer for Ubuntu 26.04 LTS (Resolute Raccoon), x86_64,
# Server or Desktop.
#
#   bash install-deepseek-maya.sh [options]     install or update in place
#   bash install-deepseek-maya.sh --uninstall   uninstall
#
# Compiling the engine, downloading the model and writing the engine configuration are left
# to Maya's own setup (maya.sh).  This installer adds the CUDA toolkit and the other apt
# packages, the service user, the systemd unit, the nginx site, ufw rules, GPU and network
# interface selection and uninstall.
#
# See README.md or --help for the options.

set -euo pipefail
umask 022

readonly DSMAYAINS_APP_NAME="deepseek-maya"
readonly DSMAYAINS_CONF_DIR="/etc/$DSMAYAINS_APP_NAME"
readonly DSMAYAINS_CONF_FILE="$DSMAYAINS_CONF_DIR/install.conf"
readonly DSMAYAINS_ENV_FILE="$DSMAYAINS_CONF_DIR/maya.env"
readonly DSMAYAINS_NGINX_KEY_FILE="$DSMAYAINS_CONF_DIR/nginx-key.conf"
readonly DSMAYAINS_UNIT="$DSMAYAINS_APP_NAME.service"
readonly DSMAYAINS_UNIT_DIR="/etc/systemd/system"
readonly DSMAYAINS_NGINX_SITE="/etc/nginx/sites-available/$DSMAYAINS_APP_NAME"
readonly DSMAYAINS_NGINX_LINK="/etc/nginx/sites-enabled/$DSMAYAINS_APP_NAME"
readonly DSMAYAINS_LOGROTATE_FILE="/etc/logrotate.d/$DSMAYAINS_APP_NAME"
readonly DSMAYAINS_MARKER=".$DSMAYAINS_APP_NAME-installation"

# Project Maya release (pinned).  The archive of the tag is downloaded with curl; it is not
# verified with a checksum (GitHub does not guarantee that generated archives stay
# byte-identical).  Everything else is downloaded and verified by Maya's setup.
readonly DSMAYAINS_MAYA_VERSION="1.1.63"
readonly DSMAYAINS_MAYA_URL="https://github.com/mw00/project-maya/archive/refs/tags/v$DSMAYAINS_MAYA_VERSION.tar.gz"
# Name of the model in Maya (--model) and of its folder under models/ (with "-GGUF").
readonly DSMAYAINS_MODEL="DeepSeek-V4.1-Flash-1017"
# Maya requires NVIDIA driver 580 or later when the engine is built with CUDA 13, and
# CUDA 13 cannot compile for a compute capability below 7.5 (RTX 20 series).
readonly DSMAYAINS_NVIDIA_MIN_DRIVER="580"
readonly DSMAYAINS_MIN_COMPUTE_CAP="7.5"
# The unit of the qwen-strata installer: never runs together with this service.
readonly DSMAYAINS_QWEN_UNIT="qwen-strata.service"

readonly DSMAYAINS_BASE_PACKAGES="cuda-toolkit-13 build-essential python3 python3-venv nginx-full curl ca-certificates tar pciutils"

# Quantizations: "<Maya's --ds4-quant> <folder under models/DeepSeek-V4.1-Flash-1017-GGUF/>
# <provider> <download, GB> <GPU memory + RAM for the whole model, GB>".
# Figures from Maya 1.1.63 (tools/ds4/download_gguf.json, docs/MEMORY.md).  Unsloth's files
# are used with Maya's Q6_K Engram tables (161 GB), which is included in the download.
declare -A DSMAYAINS_QUANT=(
  [Maya-XS]="maya-xs Maya-XS Project-Maya 278 121"
  [Maya-S]="maya-s Maya-S Project-Maya 340 186"
  [UD-IQ1_S]="gguf-iq1_s UD-IQ1_S Unsloth 284 123"
  [UD-IQ1_M]="gguf-iq1_m UD-IQ1_M Unsloth 301 140"
  [UD-IQ2_XXS]="gguf-iq2_xxs UD-IQ2_XXS Unsloth 327 166"
  [UD-Q2_K_XL]="gguf-q2_k_xl UD-Q2_K_XL Unsloth 361 200"
  [UD-IQ3_XXS]="gguf-iq3_xxs UD-IQ3_XXS Unsloth 395 234"
  [UD-IQ3_S]="gguf-iq3_s UD-IQ3_S Unsloth 424 263"
  [UD-Q3_K_XL]="gguf-q3_k_xl UD-Q3_K_XL Unsloth 444 283"
  [UD-Q4_K_XL]="gguf-q4 UD-Q4_K_XL Unsloth 459 298"
  [UD-Q8_K_XL]="gguf-q8 UD-Q8_K_XL Unsloth 467 306"
)
readonly DSMAYAINS_QUANTS="Maya-XS Maya-S UD-IQ1_S UD-IQ1_M UD-IQ2_XXS UD-Q2_K_XL UD-IQ3_XXS UD-IQ3_S UD-Q3_K_XL UD-Q4_K_XL UD-Q8_K_XL"
# Disk space needed besides the model files: drafter, vision tower, pack, kept
# conversations, llama.cpp source, build and .venv (bytes).
readonly DSMAYAINS_EXTRA_DISK=$((20 * 1000 * 1000 * 1000))
# RAM (GiB) below which Maya is not expected to work (the minimum Maya names).
readonly DSMAYAINS_MIN_RAM_GB=32
# Context sizes offered (256K, 512K, 768K, 1M).  768K is not one of Maya's own choices.
readonly DSMAYAINS_CTX_SIZES="262144 524288 786432 1048576"
readonly DSMAYAINS_THINKING_LEVELS="none low medium high xhigh max"
readonly DSMAYAINS_DRAFTING_MODES="skip measure on"
# Seconds to wait for the service to load the model.
readonly DSMAYAINS_HEALTH_TIMEOUT=3600

# Settings: KEY -> default.  Values come from options > environment > install.conf > default.
# GPU: empty = choose one GPU automatically (see validate_gpus).
readonly DSMAYAINS_KEYS="DESTDIR USER QUANT GPU CTX_SIZE THINKING DRAFTING WEB_PORT MAYA_PORT INTERFACES WEB_API_KEY AGENT_API_KEY PARALLEL VISION"
declare -A DSMAYAINS_DEFAULT=(
  [DESTDIR]=/opt/deepseek-maya [USER]=dsmaya [QUANT]=Maya-S [GPU]="" [CTX_SIZE]=524288
  [THINKING]=high [DRAFTING]=skip [WEB_PORT]=58080 [MAYA_PORT]=58081 [INTERFACES]=all
  [WEB_API_KEY]=no [AGENT_API_KEY]=no [PARALLEL]=1 [VISION]=yes
)
declare -A DSMAYAINS_ARG=() DSMAYAINS_VAL=() DSMAYAINS_SAVED=() DSMAYAINS_FROM_USER=()
DSMAYAINS_ACTION=install
DSMAYAINS_ASSUME_YES=no
DSMAYAINS_OPEN_PORTS=""   # yes/no: open the port in ufw; empty: ask when ufw is active
DSMAYAINS_INTERACTIVE=no
[[ -t 0 ]] && DSMAYAINS_INTERACTIVE=yes
DSMAYAINS_UFW_RULES=""    # ufw rules added by the installer: PORT (any interface) or PORT@INTERFACE
DSMAYAINS_API_KEY=""
DSMAYAINS_TMP=""
DSMAYAINS_MODEL_ID=""
DSMAYAINS_N_CTX=""

# ---------------------------------------------------------------- utilities

info()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn()  { printf '\033[1;33mWarning:\033[0m %s\n' "$*" >&2; }
die()   { printf '\033[1;31mError:\033[0m %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<EOF
Usage: bash $(basename "$0") [options]

Installs DeepSeek-V4.1-Flash-1017 with the Project Maya $DSMAYAINS_MAYA_VERSION inference engine as a
systemd service behind nginx (web chat page and OpenAI/Anthropic-compatible API).
Values that are not given are asked interactively; when standard input is
not a terminal, defaults are used.  Re-running updates the installation.

Options asked interactively when not given (environment variable in brackets):
  --destdir DIR            install directory and home of the service user
                           [DSMAYA_DESTDIR] (default ${DSMAYAINS_DEFAULT[DESTDIR]})
  --user NAME              service user [DSMAYA_USER] (default ${DSMAYAINS_DEFAULT[USER]})
  --quant TYPE             Maya-XS, Maya-S (Project Maya), UD-IQ1_S, UD-IQ1_M,
                           UD-IQ2_XXS, UD-Q2_K_XL, UD-IQ3_XXS, UD-IQ3_S, UD-Q3_K_XL,
                           UD-Q4_K_XL or UD-Q8_K_XL (Unsloth)
                           [DSMAYA_QUANT] (default ${DSMAYAINS_DEFAULT[QUANT]})
  --gpu PCI                the GPU used by Maya, by PCI address such as 0000:03:00.0
                           [DSMAYA_GPU] (default: the largest memory, then the most
                           free memory, then the lowest PCI address; asked when two
                           or more GPUs are usable)
  --ctx-size N             maximum context in tokens: 262144 (256K), 524288 (512K),
                           786432 (768K; not tested by the Maya project) or
                           1048576 (1M) [DSMAYA_CTX_SIZE] (default ${DSMAYAINS_DEFAULT[CTX_SIZE]})
  --thinking LEVEL         thinking level of requests that name none: none, low,
                           medium, high, xhigh, max, or DeepSeek's effort 1-100
                           [DSMAYA_THINKING] (default ${DSMAYAINS_DEFAULT[THINKING]})
  --drafting skip|measure|on
                           DeepSeek's DSpark drafter: skip = not used, nothing is
                           measured; measure = Maya measures it (5 to 30 minutes)
                           and keeps it only if it is faster; on = used without
                           measuring [DSMAYA_DRAFTING] (default ${DSMAYAINS_DEFAULT[DRAFTING]})
  --web-port PORT          web server (nginx) port [DSMAYA_WEB_PORT] (default ${DSMAYAINS_DEFAULT[WEB_PORT]})
  --interfaces all|IF[,IF...]
                           network interfaces on which the web server accepts
                           connections from other hosts [DSMAYA_INTERFACES] (default
                           all; asked when two or more interfaces have addresses);
                           127.0.0.1 always works
  --web-api-key            require the API key for the web chat page
  --no-web-api-key         do not require it (default) [DSMAYA_WEB_API_KEY=yes|no]
  --agent-api-key          require the API key for the API used by coding agents
  --no-agent-api-key       do not require it (default) [DSMAYA_AGENT_API_KEY=yes|no]
                           The management paths always require the API key.
  --open-ports             open the web server port in ufw when ufw is active
  --no-open-ports          do not open ports in ufw [DSMAYA_OPEN_PORTS=yes|no]
                           (default: ask when ufw is active)

Options that are never asked:
  --parallel N             requests answered at once, 1-8; each keeps a whole
                           context in GPU memory [DSMAYA_PARALLEL] (default ${DSMAYAINS_DEFAULT[PARALLEL]})
  --vision                 download the vision tower so that pictures can be read
  --no-vision              text only [DSMAYA_VISION=yes|no] (default ${DSMAYAINS_DEFAULT[VISION]})
  --maya-port PORT         port of Maya on 127.0.0.1 [DSMAYA_MAYA_PORT] (default ${DSMAYAINS_DEFAULT[MAYA_PORT]})

Actions:
  --yes                    answer yes to warnings, opening ufw ports and uninstalling
  --uninstall              uninstall
  -h, --help               show this help
EOF
}

yesno() {  # normalize yes/no; prints "yes", "no" or nothing
  case "${1,,}" in
    y|yes|true|1|on) echo yes ;;
    n|no|false|0|off) echo no ;;
  esac
}

trim() {  # print $1 without leading and trailing whitespace
  local DSMAYAINS_s=$1
  DSMAYAINS_s="${DSMAYAINS_s#"${DSMAYAINS_s%%[![:space:]]*}"}"
  DSMAYAINS_s="${DSMAYAINS_s%"${DSMAYAINS_s##*[![:space:]]}"}"
  printf '%s' "$DSMAYAINS_s"
}

# ask_yn "question" y|n -> returns 0 for yes.  Invalid input is asked again.
ask_yn() {
  local DSMAYAINS_answer DSMAYAINS_hint="[y/N]"
  [[ $2 != y ]] || DSMAYAINS_hint="[Y/n]"
  while :; do
    read -r -p "$1 $DSMAYAINS_hint " DSMAYAINS_answer || die "no input"
    DSMAYAINS_answer=$(trim "$DSMAYAINS_answer")
    [[ -n $DSMAYAINS_answer ]] || DSMAYAINS_answer=$2
    case $(yesno "$DSMAYAINS_answer") in
      yes) return 0 ;;
      no) return 1 ;;
    esac
    warn "answer yes or no"
  done
}

# confirm "question" -> returns 0 for yes.  --yes answers yes; non-interactive answers no.
confirm() {
  [[ $DSMAYAINS_ASSUME_YES == yes ]] && return 0
  [[ $DSMAYAINS_INTERACTIVE == yes ]] || return 1
  ask_yn "$1" n
}

# Warn about a problem and ask whether to continue.
warn_continue() {
  warn "$1"
  confirm "Continue anyway?" || die "aborted (use --yes to continue despite warnings)"
}

ask() {  # ask KEY "prompt" [extra help]: sets VAL[KEY] unless given by option/env
  local DSMAYAINS_key=$1 DSMAYAINS_prompt=$2 DSMAYAINS_answer
  [[ -n ${DSMAYAINS_FROM_USER[$DSMAYAINS_key]:-} || $DSMAYAINS_INTERACTIVE != yes ]] && return 0
  [[ -n ${3:-} ]] && printf '%s\n' "$3"
  read -r -p "$DSMAYAINS_prompt [${DSMAYAINS_VAL[$DSMAYAINS_key]}]: " DSMAYAINS_answer || die "no input"
  DSMAYAINS_answer=$(trim "$DSMAYAINS_answer")
  [[ -n $DSMAYAINS_answer ]] && DSMAYAINS_VAL[$DSMAYAINS_key]=$DSMAYAINS_answer
  return 0
}

ask_bool() {  # ask_bool KEY "question": sets VAL[KEY] to yes/no unless given by option/env
  local DSMAYAINS_key=$1 DSMAYAINS_default=n
  [[ -n ${DSMAYAINS_FROM_USER[$DSMAYAINS_key]:-} || $DSMAYAINS_INTERACTIVE != yes ]] && return 0
  [[ ${DSMAYAINS_VAL[$DSMAYAINS_key]} != yes ]] || DSMAYAINS_default=y
  if ask_yn "$2" "$DSMAYAINS_default"; then
    DSMAYAINS_VAL[$DSMAYAINS_key]=yes
  else
    DSMAYAINS_VAL[$DSMAYAINS_key]=no
  fi
}

human() { numfmt --to=iec --suffix=B "$1"; }

service_exists() { [[ -f $DSMAYAINS_UNIT_DIR/$1 ]]; }

# version_ge A B: is version A >= B (dotted numbers)?
version_ge() { [[ $(printf '%s\n%s\n' "$1" "$2" | sort -V | head -n1) == "$2" ]]; }

# quant_field N [QUANT]: field N (1 Maya's --ds4-quant, 2 folder, 3 provider, 4 download in
# GB, 5 memory for the whole model in GB) of a quantization (default: the selected one).
quant_field() {
  local DSMAYAINS_fields
  read -r -a DSMAYAINS_fields <<<"${DSMAYAINS_QUANT[${2:-${DSMAYAINS_VAL[QUANT]}}]}"
  echo "${DSMAYAINS_fields[$(($1 - 1))]}"
}

# ctx_label N: "512K" for 524288.
ctx_label() {
  if (($1 == 1048576)); then echo "1M"; else echo "$(($1 / 1024))K"; fi
}

# json_get FILE KEY...: print the value at a path of a JSON file ("-": standard input; a
# number is an index into a list); prints nothing when it is not there.  true and false are
# printed in lower case.
json_get() {
  python3 -I -c '
import json, sys
try:
    v = json.load(sys.stdin if sys.argv[1] == "-" else open(sys.argv[1], encoding="utf-8"))
    for k in sys.argv[2:]:
        v = v[int(k)] if isinstance(v, list) else v[k]
except Exception:
    sys.exit(0)
if isinstance(v, bool):
    v = "true" if v else "false"
print(json.dumps(v) if isinstance(v, (dict, list)) else v)
' "$@" 2>/dev/null || true
}

cleanup_tmp() {
  [[ -z $DSMAYAINS_TMP ]] || rm -rf "$DSMAYAINS_TMP"
}

# ------------------------------------------------------------------ options

parse_args() {
  local DSMAYAINS_opt DSMAYAINS_key
  while (($#)); do
    DSMAYAINS_opt=$1
    case $DSMAYAINS_opt in
      --destdir|--user|--quant|--gpu|--ctx-size|--thinking|--drafting|--web-port|--maya-port|--interfaces|--parallel)
        (($# >= 2)) || die "$DSMAYAINS_opt requires a value"
        DSMAYAINS_key=${DSMAYAINS_opt#--}; DSMAYAINS_key=${DSMAYAINS_key//-/_}; DSMAYAINS_key=${DSMAYAINS_key^^}
        DSMAYAINS_ARG[$DSMAYAINS_key]=$2; shift 2 ;;
      --destdir=*|--user=*|--quant=*|--gpu=*|--ctx-size=*|--thinking=*|--drafting=*|--web-port=*|--maya-port=*|--interfaces=*|--parallel=*)
        DSMAYAINS_key=${DSMAYAINS_opt%%=*}; DSMAYAINS_key=${DSMAYAINS_key#--}; DSMAYAINS_key=${DSMAYAINS_key//-/_}; DSMAYAINS_key=${DSMAYAINS_key^^}
        DSMAYAINS_ARG[$DSMAYAINS_key]=${DSMAYAINS_opt#*=}; shift ;;
      --web-api-key) DSMAYAINS_ARG[WEB_API_KEY]=yes; shift ;;
      --no-web-api-key) DSMAYAINS_ARG[WEB_API_KEY]=no; shift ;;
      --agent-api-key) DSMAYAINS_ARG[AGENT_API_KEY]=yes; shift ;;
      --no-agent-api-key) DSMAYAINS_ARG[AGENT_API_KEY]=no; shift ;;
      --vision) DSMAYAINS_ARG[VISION]=yes; shift ;;
      --no-vision) DSMAYAINS_ARG[VISION]=no; shift ;;
      --open-ports) DSMAYAINS_OPEN_PORTS=yes; shift ;;
      --no-open-ports) DSMAYAINS_OPEN_PORTS=no; shift ;;
      --yes|-y) DSMAYAINS_ASSUME_YES=yes; shift ;;
      --uninstall) DSMAYAINS_ACTION=uninstall; shift ;;
      -h|--help) usage; exit 0 ;;
      *) usage >&2; die "unknown option: $DSMAYAINS_opt" ;;
    esac
  done
}

# install.conf is parsed, never sourced.
load_saved_config() {
  local DSMAYAINS_line DSMAYAINS_key DSMAYAINS_value
  [[ -f $DSMAYAINS_CONF_FILE ]] || return 0
  while IFS= read -r DSMAYAINS_line || [[ -n $DSMAYAINS_line ]]; do
    [[ $DSMAYAINS_line =~ ^([A-Z_]+)=(.*)$ ]] || continue
    DSMAYAINS_key=${BASH_REMATCH[1]}; DSMAYAINS_value=${BASH_REMATCH[2]}
    DSMAYAINS_value=${DSMAYAINS_value#\'}; DSMAYAINS_value=${DSMAYAINS_value%\'}
    DSMAYAINS_SAVED[$DSMAYAINS_key]=$DSMAYAINS_value
  done < "$DSMAYAINS_CONF_FILE"
}

# Merge options > environment > install.conf > default into VAL.
resolve_values() {
  local DSMAYAINS_key DSMAYAINS_env DSMAYAINS_b
  for DSMAYAINS_key in $DSMAYAINS_KEYS; do
    DSMAYAINS_env="DSMAYA_$DSMAYAINS_key"
    if [[ -n ${DSMAYAINS_ARG[$DSMAYAINS_key]:-} ]]; then
      DSMAYAINS_VAL[$DSMAYAINS_key]=${DSMAYAINS_ARG[$DSMAYAINS_key]}; DSMAYAINS_FROM_USER[$DSMAYAINS_key]=1
    elif [[ -n ${!DSMAYAINS_env:-} ]]; then
      DSMAYAINS_VAL[$DSMAYAINS_key]=${!DSMAYAINS_env}; DSMAYAINS_FROM_USER[$DSMAYAINS_key]=1
    elif [[ -n ${DSMAYAINS_SAVED[$DSMAYAINS_key]:-} ]]; then
      DSMAYAINS_VAL[$DSMAYAINS_key]=${DSMAYAINS_SAVED[$DSMAYAINS_key]}
    else
      DSMAYAINS_VAL[$DSMAYAINS_key]=${DSMAYAINS_DEFAULT[$DSMAYAINS_key]}
    fi
  done
  if [[ -z $DSMAYAINS_OPEN_PORTS && -n ${DSMAYA_OPEN_PORTS:-} ]]; then
    DSMAYAINS_OPEN_PORTS=$(yesno "$DSMAYA_OPEN_PORTS")
    [[ -n $DSMAYAINS_OPEN_PORTS ]] || die "invalid value for DSMAYA_OPEN_PORTS: $DSMAYA_OPEN_PORTS (use yes or no)"
  fi
  for DSMAYAINS_key in WEB_API_KEY AGENT_API_KEY VISION; do
    DSMAYAINS_b=$(yesno "${DSMAYAINS_VAL[$DSMAYAINS_key]}")
    [[ -n $DSMAYAINS_b ]] || die "invalid value for DSMAYA_$DSMAYAINS_key: ${DSMAYAINS_VAL[$DSMAYAINS_key]} (use yes or no)"
    DSMAYAINS_VAL[$DSMAYAINS_key]=$DSMAYAINS_b
  done
  return 0
}

# ------------------------------------------------------------- GPU selection
#
# The model runs on one NVIDIA GPU.  It is selected by PCI address (stable across reboots)
# and converted to the nvidia-smi index, which is what Maya's --gpu takes, when Maya's
# setup is run.

# Print the makers of display controllers (nvidia, amd, intel) found on PCI.
gpu_vendors() {
  local DSMAYAINS_dev DSMAYAINS_class DSMAYAINS_vendor
  for DSMAYAINS_dev in /sys/bus/pci/devices/*; do
    [[ -r $DSMAYAINS_dev/class && -r $DSMAYAINS_dev/vendor ]] || continue
    DSMAYAINS_class=$(<"$DSMAYAINS_dev/class"); DSMAYAINS_vendor=$(<"$DSMAYAINS_dev/vendor")
    [[ $DSMAYAINS_class == 0x03* ]] || continue
    case $DSMAYAINS_vendor in
      0x10de) echo nvidia ;;
      0x1002) echo amd ;;
      0x8086) echo intel ;;
    esac
  done | sort -u
}

# normalize_pci ADDRESS: print a PCI address as dddd:bb:dd.f (lower case), or nothing if invalid.
normalize_pci() {
  local DSMAYAINS_a=${1,,}
  [[ $DSMAYAINS_a =~ ^[0-9a-f]{2}:[0-9a-f]{2}\.[0-7]$ ]] && DSMAYAINS_a="0000:$DSMAYAINS_a"
  [[ $DSMAYAINS_a =~ ^([0-9a-f]{4,8}):([0-9a-f]{2}:[0-9a-f]{2}\.[0-7])$ ]] || return 0
  printf '%04x:%s\n' "$((16#${BASH_REMATCH[1]}))" "${BASH_REMATCH[2]}"
}

# Print "index<TAB>PCI address" for each NVIDIA GPU that answers to nvidia-smi.
nvidia_devices() {
  local DSMAYAINS_out DSMAYAINS_idx DSMAYAINS_bus
  command -v nvidia-smi >/dev/null 2>&1 || return 0
  DSMAYAINS_out=$(nvidia-smi --query-gpu=index,pci.bus_id --format=csv,noheader 2>/dev/null) || return 0
  while IFS=, read -r DSMAYAINS_idx DSMAYAINS_bus; do
    DSMAYAINS_idx=$(trim "$DSMAYAINS_idx"); DSMAYAINS_bus=$(normalize_pci "$(trim "$DSMAYAINS_bus")")
    [[ $DSMAYAINS_idx =~ ^[0-9]+$ && -n $DSMAYAINS_bus ]] && printf '%s\t%s\n' "$DSMAYAINS_idx" "$DSMAYAINS_bus"
  done <<<"$DSMAYAINS_out"
  return 0
}

# Print "nvidia<TAB>PCI address<TAB>total MiB<TAB>used MiB<TAB>name" for each GPU Maya can
# use (NVIDIA GPUs that answer to nvidia-smi).
gpu_candidates() {
  local DSMAYAINS_out DSMAYAINS_pci DSMAYAINS_total DSMAYAINS_used DSMAYAINS_name
  command -v nvidia-smi >/dev/null 2>&1 || return 0
  DSMAYAINS_out=$(nvidia-smi --query-gpu=pci.bus_id,memory.total,memory.used,name --format=csv,noheader,nounits 2>/dev/null) || DSMAYAINS_out=""
  while IFS=, read -r DSMAYAINS_pci DSMAYAINS_total DSMAYAINS_used DSMAYAINS_name; do
    DSMAYAINS_pci=$(normalize_pci "$(trim "$DSMAYAINS_pci")")
    DSMAYAINS_total=$(trim "$DSMAYAINS_total"); DSMAYAINS_used=$(trim "$DSMAYAINS_used")
    [[ -n $DSMAYAINS_pci && $DSMAYAINS_total =~ ^[0-9]+$ ]] || continue
    [[ $DSMAYAINS_used =~ ^[0-9]+$ ]] || DSMAYAINS_used=0
    printf 'nvidia\t%s\t%s\t%s\t%s\n' "$DSMAYAINS_pci" "$DSMAYAINS_total" "$DSMAYAINS_used" "$(trim "$DSMAYAINS_name")"
  done <<<"$DSMAYAINS_out"
  return 0
}

# gpu_ranked CANDIDATES: sort the candidates by preference: the largest memory, then the
# most free memory, then the PCI address.
gpu_ranked() {
  [[ -n $1 ]] || return 0
  awk -F '\t' -v OFS='\t' '{print $0, $3 - $4}' <<<"$1" \
    | LC_ALL=C sort -t $'\t' -k1,1r -k3,3nr -k6,6nr -k2,2 | cut -f1-5
}

# gpu_selected CANDIDATES: print the candidate line of the GPU in VAL[GPU].
gpu_selected() {
  awk -F '\t' -v p="${DSMAYAINS_VAL[GPU]}" '$2 == p' <<<"$1"
}

# Stop early when Maya has nothing to run on: it has no CPU-only engine.
require_gpu() {
  local DSMAYAINS_vendors
  [[ -z $(gpu_candidates) ]] || return 0
  DSMAYAINS_vendors=$(gpu_vendors | paste -sd, -)
  if [[ $DSMAYAINS_vendors == *nvidia* ]]; then
    die "an NVIDIA GPU was found but nvidia-smi does not work; install the NVIDIA driver $DSMAYAINS_NVIDIA_MIN_DRIVER or later first (e.g. sudo ubuntu-drivers install), reboot and re-run"
  fi
  die "no NVIDIA GPU was found (detected: ${DSMAYAINS_vendors:-none}); this installer needs an NVIDIA GPU of the RTX 20 series or newer"
}

# Check VAL[GPU] (one PCI address) or choose the default GPU.
validate_gpus() {
  local DSMAYAINS_v=${DSMAYAINS_VAL[GPU],,} DSMAYAINS_cands DSMAYAINS_list DSMAYAINS_a=""
  DSMAYAINS_cands=$(gpu_candidates)
  [[ -n $DSMAYAINS_cands ]] || die "no GPU that Maya can use was found"
  DSMAYAINS_list=$(cut -f2 <<<"$DSMAYAINS_cands")
  if [[ -n $DSMAYAINS_v ]]; then
    [[ $DSMAYAINS_v != all && $DSMAYAINS_v != *,* && $DSMAYAINS_v != *[[:space:]]* ]] \
      || die "--gpu takes one GPU: this installer runs the model on a single GPU (given: ${DSMAYAINS_VAL[GPU]})"
    DSMAYAINS_a=$(normalize_pci "$DSMAYAINS_v")
    [[ -n $DSMAYAINS_a ]] || die "invalid PCI address in --gpu: ${DSMAYAINS_VAL[GPU]} (use e.g. 0000:03:00.0)"
    if ! grep -qx "$DSMAYAINS_a" <<<"$DSMAYAINS_list"; then
      if [[ -n ${DSMAYAINS_FROM_USER[GPU]:-} ]]; then
        die "GPU $DSMAYAINS_a is not an NVIDIA GPU that answers to nvidia-smi (usable: $(paste -sd' ' <<<"$DSMAYAINS_list"))"
      fi
      warn "the saved GPU selection ($DSMAYAINS_v) does not match this machine; choosing a GPU again"
      DSMAYAINS_a=""
    fi
  fi
  [[ -n $DSMAYAINS_a ]] || DSMAYAINS_a=$(gpu_ranked "$DSMAYAINS_cands" | sed -n '1p' | cut -f2)
  DSMAYAINS_VAL[GPU]=$DSMAYAINS_a
}

# Ask which GPU to use when two or more are usable.
prompt_gpus() {
  local DSMAYAINS_cands DSMAYAINS_pcis=() DSMAYAINS_pci DSMAYAINS_total DSMAYAINS_used DSMAYAINS_name DSMAYAINS_i DSMAYAINS_default="" DSMAYAINS_answer
  [[ -z ${DSMAYAINS_FROM_USER[GPU]:-} && $DSMAYAINS_INTERACTIVE == yes ]] || return 0
  DSMAYAINS_cands=$(gpu_candidates)
  while IFS=$'\t' read -r _ DSMAYAINS_pci _; do
    [[ -n $DSMAYAINS_pci ]] || continue
    DSMAYAINS_pcis+=("$DSMAYAINS_pci")
  done <<<"$DSMAYAINS_cands"
  ((${#DSMAYAINS_pcis[@]} >= 2)) || return 0
  echo "GPUs that Maya can use (the model runs on one of them):"
  DSMAYAINS_i=0
  while IFS=$'\t' read -r _ DSMAYAINS_pci DSMAYAINS_total DSMAYAINS_used DSMAYAINS_name; do
    [[ -n $DSMAYAINS_pci ]] || continue
    DSMAYAINS_i=$((DSMAYAINS_i + 1))
    printf '  %d) %s  %s (%s MiB, %s MiB in use)\n' "$DSMAYAINS_i" "$DSMAYAINS_pci" "$DSMAYAINS_name" "$DSMAYAINS_total" "$DSMAYAINS_used"
  done <<<"$DSMAYAINS_cands"
  for DSMAYAINS_i in "${!DSMAYAINS_pcis[@]}"; do
    [[ ${DSMAYAINS_VAL[GPU]} != "${DSMAYAINS_pcis[$DSMAYAINS_i]}" ]] || DSMAYAINS_default=$((DSMAYAINS_i + 1))
  done
  while :; do
    read -r -p "GPU to use (one number) [$DSMAYAINS_default]: " DSMAYAINS_answer || die "no input"
    DSMAYAINS_answer=$(trim "$DSMAYAINS_answer")
    DSMAYAINS_answer=${DSMAYAINS_answer:-$DSMAYAINS_default}
    if [[ $DSMAYAINS_answer =~ ^[0-9]+$ ]] && ((DSMAYAINS_answer >= 1 && DSMAYAINS_answer <= ${#DSMAYAINS_pcis[@]})); then
      DSMAYAINS_VAL[GPU]=${DSMAYAINS_pcis[$((DSMAYAINS_answer - 1))]}
      break
    fi
    warn "answer one number between 1 and ${#DSMAYAINS_pcis[@]}"
  done
  validate_gpus
}

gpu_label() {
  gpu_selected "$(gpu_candidates)" | awk -F '\t' '{printf "%s (%s, %s MiB)\n", $2, $5, $3}'
}

# Print the nvidia-smi index of the selected GPU, as Maya's --gpu takes it.
gpu_index() {
  local DSMAYAINS_id
  DSMAYAINS_id=$(awk -F '\t' -v p="${DSMAYAINS_VAL[GPU]}" '$2 == p {print $1; exit}' <<<"$(nvidia_devices)")
  [[ -n $DSMAYAINS_id ]] || die "GPU ${DSMAYAINS_VAL[GPU]} was not found among the NVIDIA GPUs; re-run the installer and select the GPU again"
  echo "$DSMAYAINS_id"
}

# Print the CUDA compute capability (e.g. 8.6) of the selected GPU, or nothing when
# nvidia-smi does not report it.
gpu_compute_cap() {
  local DSMAYAINS_out DSMAYAINS_pci DSMAYAINS_cap
  DSMAYAINS_out=$(nvidia-smi --query-gpu=pci.bus_id,compute_cap --format=csv,noheader 2>/dev/null) || return 0
  while IFS=, read -r DSMAYAINS_pci DSMAYAINS_cap; do
    DSMAYAINS_pci=$(normalize_pci "$(trim "$DSMAYAINS_pci")"); DSMAYAINS_cap=$(trim "$DSMAYAINS_cap")
    if [[ $DSMAYAINS_pci == "${DSMAYAINS_VAL[GPU]}" && $DSMAYAINS_cap =~ ^[0-9]+\.[0-9]+$ ]]; then
      echo "$DSMAYAINS_cap"
      return 0
    fi
  done <<<"$DSMAYAINS_out"
  return 0
}

# Print the NVIDIA driver version (the oldest if the GPUs disagree), or nothing.
nvidia_driver_version() {
  local DSMAYAINS_v
  command -v nvidia-smi >/dev/null 2>&1 || return 0
  DSMAYAINS_v=$(nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null) || return 0
  DSMAYAINS_v=$(grep -E '^[0-9]+(\.[0-9]+)*$' <<<"$DSMAYAINS_v" | sort -V | head -n1 || true)
  echo "$DSMAYAINS_v"
}

# ------------------------------------------------------- network interfaces
#
# nginx cannot bind to an interface, so the selected interfaces are turned into their
# current addresses when the configuration is written (re-run the installer if an address
# changes).  127.0.0.1 (and ::1) are always included so that local clients and the test at
# the end keep working.  ufw rules are limited with "in on IF".

# Print "interface<TAB>address address ..." for each interface with a global address
# (container and VM bridges excluded; temporary/deprecated IPv6 addresses skipped).
net_interfaces() {
  local DSMAYAINS_out DSMAYAINS_ifc DSMAYAINS_fam DSMAYAINS_addr DSMAYAINS_rest DSMAYAINS_order=()
  local -A DSMAYAINS_addrs=()
  DSMAYAINS_out=$(ip -o addr show scope global 2>/dev/null || true)
  while read -r _ DSMAYAINS_ifc DSMAYAINS_fam DSMAYAINS_addr DSMAYAINS_rest; do
    [[ -n $DSMAYAINS_ifc && ( $DSMAYAINS_fam == inet || $DSMAYAINS_fam == inet6 ) ]] || continue
    [[ $DSMAYAINS_rest == *temporary* || $DSMAYAINS_rest == *deprecated* || $DSMAYAINS_rest == *tentative* ]] && continue
    DSMAYAINS_ifc=${DSMAYAINS_ifc%%@*}
    case $DSMAYAINS_ifc in lo|docker*|br-*|veth*|virbr*|lxdbr*|cni*) continue ;; esac
    [[ -n ${DSMAYAINS_addrs[$DSMAYAINS_ifc]+x} ]] || DSMAYAINS_order+=("$DSMAYAINS_ifc")
    DSMAYAINS_addrs[$DSMAYAINS_ifc]+="${DSMAYAINS_addrs[$DSMAYAINS_ifc]:+ }${DSMAYAINS_addr%/*}"
  done <<<"$DSMAYAINS_out"
  for DSMAYAINS_ifc in "${DSMAYAINS_order[@]}"; do
    printf '%s\t%s\n' "$DSMAYAINS_ifc" "${DSMAYAINS_addrs[$DSMAYAINS_ifc]}"
  done
}

# Print the addresses of the selected interfaces, one per line (nothing for "all").
listen_addresses() {
  local DSMAYAINS_list DSMAYAINS_ifc DSMAYAINS_addr_list=()
  [[ ${DSMAYAINS_VAL[INTERFACES]} != all ]] || return 0
  DSMAYAINS_list=$(net_interfaces)
  for DSMAYAINS_ifc in ${DSMAYAINS_VAL[INTERFACES]//,/ }; do
    read -r -a DSMAYAINS_addr_list <<<"$(awk -F '\t' -v i="$DSMAYAINS_ifc" '$1 == i {print $2}' <<<"$DSMAYAINS_list")"
    ((${#DSMAYAINS_addr_list[@]} == 0)) || printf '%s\n' "${DSMAYAINS_addr_list[@]}"
  done
}

interfaces_label() {
  local DSMAYAINS_list DSMAYAINS_ifc DSMAYAINS_out=""
  if [[ ${DSMAYAINS_VAL[INTERFACES]} == all ]]; then echo "all"; return 0; fi
  DSMAYAINS_list=$(net_interfaces)
  for DSMAYAINS_ifc in ${DSMAYAINS_VAL[INTERFACES]//,/ }; do
    DSMAYAINS_out+="${DSMAYAINS_out:+, }$DSMAYAINS_ifc ($(awk -F '\t' -v i="$DSMAYAINS_ifc" '$1 == i {gsub(/ /, ", ", $2); print $2}' <<<"$DSMAYAINS_list"))"
  done
  echo "$DSMAYAINS_out (and 127.0.0.1)"
}

validate_interfaces() {
  local DSMAYAINS_v=${DSMAYAINS_VAL[INTERFACES]} DSMAYAINS_list DSMAYAINS_ifc DSMAYAINS_out=()
  if [[ -z $DSMAYAINS_v || ${DSMAYAINS_v,,} == all ]]; then DSMAYAINS_VAL[INTERFACES]=all; return 0; fi
  DSMAYAINS_list=$(net_interfaces | cut -f1)
  for DSMAYAINS_ifc in ${DSMAYAINS_v//,/ }; do
    [[ $DSMAYAINS_ifc =~ ^[A-Za-z0-9_.:-]{1,15}$ ]] || die "invalid interface name: $DSMAYAINS_ifc"
    if ! grep -qxF "$DSMAYAINS_ifc" <<<"$DSMAYAINS_list"; then
      if [[ -n ${DSMAYAINS_FROM_USER[INTERFACES]:-} ]]; then
        die "interface $DSMAYAINS_ifc has no global address (available: $(paste -sd' ' <<<"$DSMAYAINS_list"))"
      fi
      warn "the saved interface selection ($DSMAYAINS_v) does not match this machine; listening on all interfaces"
      DSMAYAINS_VAL[INTERFACES]=all; return 0
    fi
    [[ " ${DSMAYAINS_out[*]} " == *" $DSMAYAINS_ifc "* ]] || DSMAYAINS_out+=("$DSMAYAINS_ifc")
  done
  DSMAYAINS_VAL[INTERFACES]=$(IFS=,; echo "${DSMAYAINS_out[*]}")
}

# Ask on which interfaces to accept connections when two or more have addresses.
prompt_interfaces() {
  local DSMAYAINS_list DSMAYAINS_names=() DSMAYAINS_ifc DSMAYAINS_addrs DSMAYAINS_i DSMAYAINS_default="" DSMAYAINS_answer DSMAYAINS_tok DSMAYAINS_sel=() DSMAYAINS_ok
  [[ -z ${DSMAYAINS_FROM_USER[INTERFACES]:-} && $DSMAYAINS_INTERACTIVE == yes ]] || return 0
  DSMAYAINS_list=$(net_interfaces)
  [[ -n $DSMAYAINS_list ]] || return 0
  while IFS=$'\t' read -r DSMAYAINS_ifc DSMAYAINS_addrs; do DSMAYAINS_names+=("$DSMAYAINS_ifc"); done <<<"$DSMAYAINS_list"
  ((${#DSMAYAINS_names[@]} >= 2)) || return 0
  echo "Network interfaces on which the web server accepts connections from other hosts"
  echo "(127.0.0.1 is always available on this machine):"
  DSMAYAINS_i=0
  while IFS=$'\t' read -r DSMAYAINS_ifc DSMAYAINS_addrs; do
    DSMAYAINS_i=$((DSMAYAINS_i + 1))
    printf '  %d) %-12s %s\n' "$DSMAYAINS_i" "$DSMAYAINS_ifc" "${DSMAYAINS_addrs// /, }"
  done <<<"$DSMAYAINS_list"
  if [[ ${DSMAYAINS_VAL[INTERFACES]} == all ]]; then
    DSMAYAINS_default=all
  else
    for DSMAYAINS_i in "${!DSMAYAINS_names[@]}"; do
      [[ ",${DSMAYAINS_VAL[INTERFACES]}," == *",${DSMAYAINS_names[$DSMAYAINS_i]},"* ]] && DSMAYAINS_default+="${DSMAYAINS_default:+,}$((DSMAYAINS_i + 1))"
    done
  fi
  while :; do
    read -r -p "Interfaces (all, or numbers such as 1,2) [$DSMAYAINS_default]: " DSMAYAINS_answer || die "no input"
    DSMAYAINS_answer=$(trim "$DSMAYAINS_answer")
    DSMAYAINS_answer=${DSMAYAINS_answer:-$DSMAYAINS_default}
    if [[ ${DSMAYAINS_answer,,} == all ]]; then DSMAYAINS_VAL[INTERFACES]=all; return 0; fi
    DSMAYAINS_sel=(); DSMAYAINS_ok=yes
    for DSMAYAINS_tok in ${DSMAYAINS_answer//,/ }; do
      if [[ $DSMAYAINS_tok =~ ^[0-9]+$ ]] && ((DSMAYAINS_tok >= 1 && DSMAYAINS_tok <= ${#DSMAYAINS_names[@]})); then
        DSMAYAINS_ifc=${DSMAYAINS_names[$((DSMAYAINS_tok - 1))]}
        [[ " ${DSMAYAINS_sel[*]} " == *" $DSMAYAINS_ifc "* ]] || DSMAYAINS_sel+=("$DSMAYAINS_ifc")
      else
        DSMAYAINS_ok=no
      fi
    done
    if [[ $DSMAYAINS_ok == yes && ${#DSMAYAINS_sel[@]} -gt 0 ]]; then
      DSMAYAINS_VAL[INTERFACES]=$(IFS=,; echo "${DSMAYAINS_sel[*]}")
      return 0
    fi
    warn "answer all, or numbers between 1 and ${#DSMAYAINS_names[@]} separated by commas"
  done
}

# ------------------------------------------------------------------ prompts

prompt_values() {
  local DSMAYAINS_q DSMAYAINS_list="" DSMAYAINS_f
  [[ $DSMAYAINS_INTERACTIVE == yes ]] || return 0
  ask DESTDIR "Install directory (becomes the home directory of the service user)"
  ask USER "Service user"
  for DSMAYAINS_q in $DSMAYAINS_QUANTS; do
    read -r -a DSMAYAINS_f <<<"${DSMAYAINS_QUANT[$DSMAYAINS_q]}"
    DSMAYAINS_list+=$(printf '  %-11s %-12s download %3s GB, GPU memory + RAM for the whole model about %3s GB' "$DSMAYAINS_q" "${DSMAYAINS_f[2]}" "${DSMAYAINS_f[3]}" "${DSMAYAINS_f[4]}")$'\n'
  done
  ask QUANT "Quantization" "Quantizations of DeepSeek-V4.1-Flash-1017 (larger is closer to the original and needs more memory):"$'\n'"${DSMAYAINS_list%$'\n'}"
  ask CTX_SIZE "Maximum context in tokens" "Context sizes: 262144 (256K), 524288 (512K), 786432 (768K; not tested by the Maya project), 1048576 (1M)"
  ask THINKING "Thinking level (none, low, medium, high, xhigh, max, or 1-100)"
  ask DRAFTING "Drafting (skip: no drafter; measure: Maya measures it, 5 to 30 minutes; on: use the drafter)"
  ask WEB_PORT "Web server port"
  ask_bool WEB_API_KEY "Require the API key for the web chat page?"
  ask_bool AGENT_API_KEY "Require the API key for the API used by coding agents?"
}

validate() {
  local DSMAYAINS_d=${DSMAYAINS_VAL[DESTDIR]} DSMAYAINS_p DSMAYAINS_q DSMAYAINS_found="" DSMAYAINS_t
  [[ $DSMAYAINS_d == /* ]] || die "destdir must be an absolute path: $DSMAYAINS_d"
  [[ $DSMAYAINS_d =~ ^/[A-Za-z0-9._/-]+$ && $DSMAYAINS_d != *//* && $DSMAYAINS_d != */./* && $DSMAYAINS_d != */../* && $DSMAYAINS_d != */. && $DSMAYAINS_d != */.. ]] \
    || die "destdir may contain only letters, digits and . _ - / : $DSMAYAINS_d"
  DSMAYAINS_d=${DSMAYAINS_d%/}; DSMAYAINS_VAL[DESTDIR]=$DSMAYAINS_d
  case $DSMAYAINS_d in
    ""|/bin|/boot|/dev|/etc|/home|/lib|/lib64|/media|/mnt|/opt|/proc|/root|/run|/sbin|/srv|/sys|/tmp|/usr|/usr/*|/var|/var/lib|/etc/*|/proc/*|/sys/*|/dev/*|/run/*|/boot/*|/root/*)
      die "destdir must not be a system directory: $DSMAYAINS_d" ;;
  esac
  [[ ${DSMAYAINS_VAL[USER]} =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] || die "invalid user name: ${DSMAYAINS_VAL[USER]}"
  [[ ${DSMAYAINS_VAL[USER]} != root ]] || die "the service user must not be root"
  for DSMAYAINS_q in $DSMAYAINS_QUANTS; do
    [[ ${DSMAYAINS_q,,} != "${DSMAYAINS_VAL[QUANT],,}" ]] || DSMAYAINS_found=$DSMAYAINS_q
  done
  [[ -n $DSMAYAINS_found ]] || die "quantization must be one of: $DSMAYAINS_QUANTS"
  DSMAYAINS_VAL[QUANT]=$DSMAYAINS_found
  [[ ${DSMAYAINS_VAL[CTX_SIZE]} =~ ^[0-9]{1,7}$ ]] || die "context size must be one of: $DSMAYAINS_CTX_SIZES (given: ${DSMAYAINS_VAL[CTX_SIZE]})"
  DSMAYAINS_VAL[CTX_SIZE]=$((10#${DSMAYAINS_VAL[CTX_SIZE]}))
  [[ " $DSMAYAINS_CTX_SIZES " == *" ${DSMAYAINS_VAL[CTX_SIZE]} "* ]] || die "context size must be one of: $DSMAYAINS_CTX_SIZES (given: ${DSMAYAINS_VAL[CTX_SIZE]})"
  DSMAYAINS_t=${DSMAYAINS_VAL[THINKING],,}
  if [[ $DSMAYAINS_t =~ ^[0-9]{1,3}$ ]]; then
    DSMAYAINS_t=$((10#$DSMAYAINS_t))
    ((DSMAYAINS_t >= 1 && DSMAYAINS_t <= 100)) || die "thinking level must be one of: $DSMAYAINS_THINKING_LEVELS, or a number from 1 to 100 (given: ${DSMAYAINS_VAL[THINKING]})"
  else
    [[ " $DSMAYAINS_THINKING_LEVELS " == *" $DSMAYAINS_t "* ]] || die "thinking level must be one of: $DSMAYAINS_THINKING_LEVELS, or a number from 1 to 100 (given: ${DSMAYAINS_VAL[THINKING]})"
  fi
  DSMAYAINS_VAL[THINKING]=$DSMAYAINS_t
  DSMAYAINS_VAL[DRAFTING]=${DSMAYAINS_VAL[DRAFTING],,}
  [[ " $DSMAYAINS_DRAFTING_MODES " == *" ${DSMAYAINS_VAL[DRAFTING]} "* ]] || die "drafting must be one of: $DSMAYAINS_DRAFTING_MODES"
  [[ ${DSMAYAINS_VAL[PARALLEL]} =~ ^[1-8]$ ]] || die "parallel must be a number from 1 to 8: ${DSMAYAINS_VAL[PARALLEL]}"
  for DSMAYAINS_p in WEB_PORT MAYA_PORT; do
    [[ ${DSMAYAINS_VAL[$DSMAYAINS_p]} =~ ^[0-9]{1,5}$ ]] || die "invalid port number: ${DSMAYAINS_VAL[$DSMAYAINS_p]}"
    DSMAYAINS_VAL[$DSMAYAINS_p]=$((10#${DSMAYAINS_VAL[$DSMAYAINS_p]}))
    ((DSMAYAINS_VAL[$DSMAYAINS_p] >= 1 && DSMAYAINS_VAL[$DSMAYAINS_p] <= 65535)) || die "invalid port number: ${DSMAYAINS_VAL[$DSMAYAINS_p]}"
  done
  ((DSMAYAINS_VAL[WEB_PORT] != DSMAYAINS_VAL[MAYA_PORT])) || die "the web server port and the Maya port must differ"
  validate_gpus
  validate_interfaces
}

key_label() { if [[ $1 == yes ]]; then echo "required"; else echo "not required"; fi; }

thinking_label() {
  if [[ ${DSMAYAINS_VAL[THINKING]} =~ ^[0-9]+$ ]]; then echo "${DSMAYAINS_VAL[THINKING]} of 100"; else echo "${DSMAYAINS_VAL[THINKING]}"; fi
}

show_summary() {
  local DSMAYAINS_ctx=${DSMAYAINS_VAL[CTX_SIZE]} DSMAYAINS_note="" DSMAYAINS_vision="yes"
  [[ $DSMAYAINS_ctx != 786432 ]] || DSMAYAINS_note="; not tested by the Maya project"
  [[ ${DSMAYAINS_VAL[VISION]} == yes ]] || DSMAYAINS_vision="no (text only)"
  cat <<EOF

Installation settings:
  Install directory    : ${DSMAYAINS_VAL[DESTDIR]}
  Service user         : ${DSMAYAINS_VAL[USER]}
  Model                : $DSMAYAINS_MODEL ${DSMAYAINS_VAL[QUANT]} ($(quant_field 3); download $(quant_field 4) GB)
  Engine               : Project Maya $DSMAYAINS_MAYA_VERSION (compiled on this machine with CUDA 13)
  GPU                  : $(gpu_label)
  Context size         : $DSMAYAINS_ctx tokens ($(ctx_label "$DSMAYAINS_ctx")$DSMAYAINS_note)
  Thinking             : $(thinking_label)
  Drafting             : ${DSMAYAINS_VAL[DRAFTING]}
  Parallel requests    : ${DSMAYAINS_VAL[PARALLEL]}
  Pictures             : $DSMAYAINS_vision
  Web server           : port ${DSMAYAINS_VAL[WEB_PORT]} (nginx)
  Listen on            : $(interfaces_label)
  Open ports in ufw    : $(ufw_label)
  Maya                 : 127.0.0.1:${DSMAYAINS_VAL[MAYA_PORT]}
  API key, web page    : $(key_label "${DSMAYAINS_VAL[WEB_API_KEY]}")
  API key, agents      : $(key_label "${DSMAYAINS_VAL[AGENT_API_KEY]}")
  API key, management  : required (always)

EOF
  if [[ $DSMAYAINS_INTERACTIVE == yes && $DSMAYAINS_ASSUME_YES != yes ]]; then
    confirm "Proceed with the installation?" || die "aborted"
  fi
}

# -------------------------------------------------------------- preflight

check_platform() {
  [[ $EUID -eq 0 ]] || die "run as root (e.g. sudo bash $0)"
  [[ $(uname -m) == x86_64 ]] || die "only x86_64 is supported (found $(uname -m))"
  [[ -r /etc/os-release ]] || die "cannot read /etc/os-release"
  local DSMAYAINS_id DSMAYAINS_version
  # Parse instead of sourcing, so that os-release cannot clash with our variables.
  DSMAYAINS_id=$(sed -n 's/^ID=//p' /etc/os-release | tr -d '"')
  DSMAYAINS_version=$(sed -n 's/^VERSION_ID=//p' /etc/os-release | tr -d '"')
  [[ $DSMAYAINS_id == ubuntu && $DSMAYAINS_version == 26.04 ]] || die "only Ubuntu 26.04 is supported (found ${DSMAYAINS_id:-?} ${DSMAYAINS_version:-?})"
  if [[ -e /proc/sys/fs/binfmt_misc/WSLInterop || -n ${WSL_DISTRO_NAME:-} ]] || grep -qi microsoft /proc/version 2>/dev/null; then
    die "Ubuntu on WSL is not supported"
  fi
  command -v systemctl >/dev/null || die "systemd is required"
}

# port_in_use_by_others PORT [UNIT]: is TCP port PORT used by a process that does not
# belong to the systemd unit UNIT?
port_in_use_by_others() {
  local DSMAYAINS_port=$1 DSMAYAINS_unit=${2:-} DSMAYAINS_listeners DSMAYAINS_pids DSMAYAINS_pid
  DSMAYAINS_listeners=$(ss -Hltnp "sport = :$DSMAYAINS_port" 2>/dev/null) || DSMAYAINS_listeners=""
  [[ -n $DSMAYAINS_listeners ]] || return 1
  [[ -n $DSMAYAINS_unit ]] || return 0
  DSMAYAINS_pids=$(grep -o 'pid=[0-9]*' <<<"$DSMAYAINS_listeners" | cut -d= -f2 | sort -u || true)
  [[ -n $DSMAYAINS_pids ]] || return 0
  for DSMAYAINS_pid in $DSMAYAINS_pids; do
    grep -qsF "/$DSMAYAINS_unit" "/proc/$DSMAYAINS_pid/cgroup" || return 0
  done
  return 1
}

port_free() { [[ -z $(ss -Hltn "sport = :$1" 2>/dev/null || true) ]]; }

existing_dir() {  # nearest existing ancestor of $1
  local DSMAYAINS_d=$1
  while [[ ! -d $DSMAYAINS_d ]]; do DSMAYAINS_d=$(dirname "$DSMAYAINS_d"); done
  echo "$DSMAYAINS_d"
}

preflight() {
  local DSMAYAINS_d=${DSMAYAINS_VAL[DESTDIR]} DSMAYAINS_u=${DSMAYAINS_VAL[USER]} DSMAYAINS_unit="" DSMAYAINS_home DSMAYAINS_need DSMAYAINS_have DSMAYAINS_avail DSMAYAINS_mem DSMAYAINS_vram DSMAYAINS_driver DSMAYAINS_cap
  info "Checking prerequisites"

  # Ports.  The web port may be held by nginx only if it was ours before; the Maya port
  # only by our own service.
  [[ -f $DSMAYAINS_NGINX_LINK && ${DSMAYAINS_SAVED[WEB_PORT]:-} == "${DSMAYAINS_VAL[WEB_PORT]}" ]] && DSMAYAINS_unit=nginx.service
  if port_in_use_by_others "${DSMAYAINS_VAL[WEB_PORT]}" "$DSMAYAINS_unit"; then
    die "TCP port ${DSMAYAINS_VAL[WEB_PORT]} is already in use: $(ss -Hltnp "sport = :${DSMAYAINS_VAL[WEB_PORT]}" | head -n1)"
  fi
  if port_in_use_by_others "${DSMAYAINS_VAL[MAYA_PORT]}" "$DSMAYAINS_UNIT"; then
    die "TCP port ${DSMAYAINS_VAL[MAYA_PORT]} is already in use: $(ss -Hltnp "sport = :${DSMAYAINS_VAL[MAYA_PORT]}" | head -n1)"
  fi

  # Existing destdir must be empty or a previous installation (uninstall removes it).
  if [[ -d $DSMAYAINS_d && ! -e $DSMAYAINS_d/$DSMAYAINS_MARKER ]] && [[ -n $(ls -A "$DSMAYAINS_d") ]]; then
    die "$DSMAYAINS_d exists and is not empty; choose another directory"
  fi

  # Maya's setup and maya.sh run as the service user with destdir as its home directory.
  if id -u "$DSMAYAINS_u" >/dev/null 2>&1; then
    DSMAYAINS_home=$(getent passwd "$DSMAYAINS_u" | cut -d: -f6)
    [[ ${DSMAYAINS_home%/} == "$DSMAYAINS_d" ]] \
      || die "user $DSMAYAINS_u exists and its home directory is ${DSMAYAINS_home:-unset}, not $DSMAYAINS_d; choose another user name or destdir (or change it with: usermod -d $DSMAYAINS_d $DSMAYAINS_u)"
  fi

  grep -qw avx2 /proc/cpuinfo || warn_continue "this CPU does not report AVX2, which Maya needs"

  # GPU driver and GPU.  Drivers are never installed here.
  DSMAYAINS_driver=$(nvidia_driver_version)
  [[ -n $DSMAYAINS_driver ]] || die "nvidia-smi does not work; install the NVIDIA driver first (e.g. sudo ubuntu-drivers install), reboot and re-run"
  version_ge "$DSMAYAINS_driver" "$DSMAYAINS_NVIDIA_MIN_DRIVER" \
    || die "NVIDIA driver $DSMAYAINS_driver is too old: the engine is compiled with CUDA 13, which needs driver $DSMAYAINS_NVIDIA_MIN_DRIVER or later; update the driver (e.g. sudo ubuntu-drivers install), reboot and re-run"
  DSMAYAINS_cap=$(gpu_compute_cap)
  if [[ -z $DSMAYAINS_cap ]]; then
    warn "nvidia-smi does not report the compute capability of GPU ${DSMAYAINS_VAL[GPU]}; CUDA 13 needs $DSMAYAINS_MIN_COMPUTE_CAP or higher (RTX 20 series or newer)"
  else
    version_ge "$DSMAYAINS_cap" "$DSMAYAINS_MIN_COMPUTE_CAP" \
      || die "GPU ${DSMAYAINS_VAL[GPU]} has compute capability $DSMAYAINS_cap: CUDA 13 cannot compile for less than $DSMAYAINS_MIN_COMPUTE_CAP (an RTX 20 series GPU or newer is needed)"
  fi
  info "NVIDIA driver $DSMAYAINS_driver, GPU $(gpu_label)${DSMAYAINS_cap:+, compute capability $DSMAYAINS_cap}"

  # Disk space: model files and the rest, minus what destdir already holds.
  DSMAYAINS_need=$(($(quant_field 4) * 1000 * 1000 * 1000 + DSMAYAINS_EXTRA_DISK))
  DSMAYAINS_have=0
  [[ ! -d $DSMAYAINS_d ]] || DSMAYAINS_have=$(($(du -sk "$DSMAYAINS_d" 2>/dev/null | cut -f1) * 1024))
  DSMAYAINS_need=$((DSMAYAINS_need - DSMAYAINS_have))
  DSMAYAINS_avail=$(($(df --output=avail -k "$(existing_dir "$DSMAYAINS_d")" | tail -n1) * 1024))
  if ((DSMAYAINS_avail < DSMAYAINS_need)); then
    warn_continue "not enough free disk space in $(existing_dir "$DSMAYAINS_d"): $(human "$DSMAYAINS_avail") available, about $(human "$DSMAYAINS_need") more needed for ${DSMAYAINS_VAL[QUANT]}"
  fi

  # Memory (MiB): RAM, and RAM plus the memory of the selected GPU against what holds the
  # whole model.
  DSMAYAINS_mem=$(($(awk '/^MemTotal:/ {print $2}' /proc/meminfo) / 1024))
  DSMAYAINS_vram=$(gpu_selected "$(gpu_candidates)" | cut -f3)
  [[ $DSMAYAINS_vram =~ ^[0-9]+$ ]] || DSMAYAINS_vram=0
  if ((DSMAYAINS_mem < DSMAYAINS_MIN_RAM_GB * 1024)); then
    warn_continue "this machine has $((DSMAYAINS_mem / 1024)) GB of RAM; Maya names $DSMAYAINS_MIN_RAM_GB GB as the minimum"
  elif ((DSMAYAINS_mem + DSMAYAINS_vram < $(quant_field 5) * 1024)); then
    warn "this machine has $((DSMAYAINS_mem / 1024)) GB of RAM and $((DSMAYAINS_vram / 1024)) GB of GPU memory; ${DSMAYAINS_VAL[QUANT]} is held whole from about $(quant_field 5) GB. Maya will keep as many experts as fit and read the rest from the SSD, which is much slower."
  fi
}

# ---------------------------------------------------------------- install

install_packages() {
  local DSMAYAINS_missing=() DSMAYAINS_p
  for DSMAYAINS_p in $DSMAYAINS_BASE_PACKAGES; do
    [[ $(dpkg-query -W -f='${Status}' "$DSMAYAINS_p" 2>/dev/null || true) == "install ok installed" ]] || DSMAYAINS_missing+=("$DSMAYAINS_p")
  done
  if ((${#DSMAYAINS_missing[@]} == 0)); then
    info "Required packages are already installed"
  else
    info "Installing packages: ${DSMAYAINS_missing[*]}"
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get install -y --no-install-recommends "${DSMAYAINS_missing[@]}" \
      || die "apt-get install failed (cuda-toolkit-13 is in the multiverse component, the others in main and universe; are they enabled?)"
  fi
  # Maya looks for nvcc in PATH and in /usr/local/cuda*/bin.
  if ! command -v nvcc >/dev/null 2>&1 && [[ -z $(compgen -G '/usr/local/cuda*/bin/nvcc' || true) ]]; then
    die "nvcc was not found after installing cuda-toolkit-13 (expected /usr/local/cuda-13.*/bin/nvcc); Maya cannot compile its engine without it"
  fi
}

# The home directory of the service user is destdir.
ensure_user() {
  local DSMAYAINS_u=${DSMAYAINS_VAL[USER]}
  if id -u "$DSMAYAINS_u" >/dev/null 2>&1; then
    info "Using existing user $DSMAYAINS_u"
  else
    info "Creating system user $DSMAYAINS_u"
    useradd --system --user-group --no-create-home --home-dir "${DSMAYAINS_VAL[DESTDIR]}" --shell /usr/sbin/nologin "$DSMAYAINS_u"
  fi
}

# Everything in destdir belongs to the service user: Maya writes its configuration, its
# logs, .venv and the build inside its own tree, and the packs inside the model folders.
prepare_destdir() {
  local DSMAYAINS_d=${DSMAYAINS_VAL[DESTDIR]} DSMAYAINS_u=${DSMAYAINS_VAL[USER]}
  install -d -m 0755 "$DSMAYAINS_d" "$DSMAYAINS_d/models"
  touch "$DSMAYAINS_d/$DSMAYAINS_MARKER"
  chown -R "$DSMAYAINS_u:$DSMAYAINS_u" "$DSMAYAINS_d"
}

# run_as USER HOME COMMAND [ARGS...]: run a command as the service user with a clean
# environment, HOME set to destdir and Maya's update check off.  The API key is never
# passed here: the service reads it from maya.env.
run_as() {
  local DSMAYAINS_user=$1 DSMAYAINS_home=$2
  shift 2
  (
    cd "$DSMAYAINS_home" || exit 1
    # PYTHONUNBUFFERED: the progress of Maya's setup is shown as it happens (its output is a pipe).
    exec env -i "HOME=$DSMAYAINS_home" "USER=$DSMAYAINS_user" "LOGNAME=$DSMAYAINS_user" \
      PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
      LANG=C.UTF-8 "TERM=${TERM:-dumb}" MAYA_UPDATE_CHECK=0 PYTHONUNBUFFERED=1 \
      runuser -u "$DSMAYAINS_user" -- "$@"
  )
}

maya_tree() { echo "${DSMAYAINS_VAL[DESTDIR]}/project-maya"; }

# Maya's setup and the engine need the GPU and the RAM, so the service is stopped first.
stop_service() {
  service_exists "$DSMAYAINS_UNIT" || return 0
  # Always: a unit waiting for its automatic restart is neither active nor failed.
  info "Stopping $DSMAYAINS_UNIT"
  systemctl stop "$DSMAYAINS_UNIT" || die "cannot stop $DSMAYAINS_UNIT"
}

# qwen-strata (qwen-strata-installer-for-resolute) is not meant to run at the same time.
# It is stopped and disabled; --uninstall prints how to enable it again.
disable_qwen_strata() {
  service_exists "$DSMAYAINS_QWEN_UNIT" || return 0
  if systemctl is-active --quiet "$DSMAYAINS_QWEN_UNIT" || systemctl is-enabled --quiet "$DSMAYAINS_QWEN_UNIT" 2>/dev/null; then
    info "Stopping and disabling $DSMAYAINS_QWEN_UNIT (it does not run together with $DSMAYAINS_UNIT)"
    systemctl disable --now "$DSMAYAINS_QWEN_UNIT" || die "cannot stop $DSMAYAINS_QWEN_UNIT"
  fi
}

wait_port_free() {  # wait_port_free PORT SECONDS
  local DSMAYAINS_start=$SECONDS
  until port_free "$1"; do
    ((SECONDS - DSMAYAINS_start < $2)) || return 1
    sleep 1
  done
}

# Download the archive of the pinned tag and extract it into <destdir>/project-maya.  A
# tree of the pinned version is reused (with its .venv, build and configuration).
install_maya() {
  local DSMAYAINS_d=${DSMAYAINS_VAL[DESTDIR]} DSMAYAINS_u=${DSMAYAINS_VAL[USER]} DSMAYAINS_tree DSMAYAINS_new DSMAYAINS_old DSMAYAINS_tar DSMAYAINS_have=""
  DSMAYAINS_tree=$(maya_tree)
  [[ ! -f $DSMAYAINS_tree/VERSION ]] || DSMAYAINS_have=$(tr -d '[:space:]' < "$DSMAYAINS_tree/VERSION")
  if [[ $DSMAYAINS_have == "$DSMAYAINS_MAYA_VERSION" && -f $DSMAYAINS_tree/maya.sh && -f $DSMAYAINS_tree/maya.py ]]; then
    info "Project Maya $DSMAYAINS_MAYA_VERSION is already in $DSMAYAINS_tree"
    return 0
  fi
  info "Downloading Project Maya $DSMAYAINS_MAYA_VERSION ($DSMAYAINS_MAYA_URL)"
  DSMAYAINS_TMP=$(mktemp -d /tmp/deepseek-maya-install.XXXXXX)
  chmod 0755 "$DSMAYAINS_TMP"
  DSMAYAINS_tar="$DSMAYAINS_TMP/project-maya.tar.gz"
  curl --fail --silent --show-error --location --retry 5 --retry-delay 5 --output "$DSMAYAINS_tar" "$DSMAYAINS_MAYA_URL" \
    || die "download failed: $DSMAYAINS_MAYA_URL"
  chmod 0644 "$DSMAYAINS_tar"
  # Extracted beside the final place and moved, so that an interrupted extraction is never
  # taken for an installed tree.
  DSMAYAINS_new="$DSMAYAINS_tree.new"; DSMAYAINS_old="$DSMAYAINS_tree.old"
  rm -rf --one-file-system "${DSMAYAINS_new:?}" "${DSMAYAINS_old:?}"
  run_as "$DSMAYAINS_u" "$DSMAYAINS_d" mkdir "$DSMAYAINS_new" || die "cannot create $DSMAYAINS_new"
  run_as "$DSMAYAINS_u" "$DSMAYAINS_d" tar -xzf "$DSMAYAINS_tar" -C "$DSMAYAINS_new" --strip-components=1 --no-same-owner </dev/null \
    || die "cannot extract Maya's archive into $DSMAYAINS_new"
  cleanup_tmp; DSMAYAINS_TMP=""
  [[ -f $DSMAYAINS_new/VERSION && $(tr -d '[:space:]' < "$DSMAYAINS_new/VERSION") == "$DSMAYAINS_MAYA_VERSION" && -f $DSMAYAINS_new/maya.sh && -f $DSMAYAINS_new/maya.py ]] \
    || die "the downloaded archive is not Project Maya $DSMAYAINS_MAYA_VERSION (see $DSMAYAINS_new)"
  [[ -x $DSMAYAINS_new/maya.sh ]] || run_as "$DSMAYAINS_u" "$DSMAYAINS_d" chmod 0755 "$DSMAYAINS_new/maya.sh"
  if [[ -e $DSMAYAINS_tree ]]; then
    # Another version, or an incomplete tree: replaced.  Its configuration is carried over
    # so that Maya's setup keeps what it keeps from "the config before".
    warn "replacing $DSMAYAINS_tree (version ${DSMAYAINS_have:-unknown}) with Project Maya $DSMAYAINS_MAYA_VERSION; the engine is compiled again"
    mv "$DSMAYAINS_tree" "$DSMAYAINS_old"
    [[ ! -f $DSMAYAINS_old/maya-ds4.json || -L $DSMAYAINS_old/maya-ds4.json ]] \
      || run_as "$DSMAYAINS_u" "$DSMAYAINS_d" cp -p "$DSMAYAINS_old/maya-ds4.json" "$DSMAYAINS_new/maya-ds4.json"
  fi
  mv "$DSMAYAINS_new" "$DSMAYAINS_tree"
  rm -rf --one-file-system "${DSMAYAINS_old:?}"
}

# Keep the API key across re-runs so that clients keep working.  maya.env is read by
# systemd (EnvironmentFile) and may be read by the service user; it also carries Maya's
# switches.  nginx-key.conf is included by the nginx site and defines $dsmaya_bearer.
# shellcheck disable=SC2016
write_key_files() {
  local DSMAYAINS_key=""
  install -d -m 0755 "$DSMAYAINS_CONF_DIR"
  [[ ! -f $DSMAYAINS_ENV_FILE ]] || DSMAYAINS_key=$(sed -n 's/^MAYA_API_KEY=//p;T;q' "$DSMAYAINS_ENV_FILE")
  if [[ $DSMAYAINS_key =~ ^[A-Za-z0-9_-]{24,128}$ ]]; then
    info "Keeping the existing API key"
  else
    info "Generating an API key"
    DSMAYAINS_key="sk-dsmaya-$(od -An -tx1 -N24 /dev/urandom | tr -d ' \n')"
  fi
  DSMAYAINS_API_KEY=$DSMAYAINS_key
  ( umask 077
    printf '# Generated by install-deepseek-maya.sh; changes are overwritten on re-run.\nMAYA_API_KEY=%s\nMAYA_UPDATE_CHECK=0\nMAYA_MODEL_MANAGEMENT=0\n' "$DSMAYAINS_key" > "$DSMAYAINS_ENV_FILE.tmp"
    printf '# Generated by install-deepseek-maya.sh; changes are overwritten on re-run.\nset $dsmaya_bearer "Bearer %s";\n' "$DSMAYAINS_key" > "$DSMAYAINS_NGINX_KEY_FILE.tmp" )
  chown "root:${DSMAYAINS_VAL[USER]}" "$DSMAYAINS_ENV_FILE.tmp"
  chmod 0640 "$DSMAYAINS_ENV_FILE.tmp"
  chown root:root "$DSMAYAINS_NGINX_KEY_FILE.tmp"
  chmod 0600 "$DSMAYAINS_NGINX_KEY_FILE.tmp"
  mv -f "$DSMAYAINS_ENV_FILE.tmp" "$DSMAYAINS_ENV_FILE"
  mv -f "$DSMAYAINS_NGINX_KEY_FILE.tmp" "$DSMAYAINS_NGINX_KEY_FILE"
}

# Run Maya's setup once as the service user, without questions and without starting the
# model: it creates .venv, fetches the llama.cpp source, compiles the engine, downloads and
# checks the model, builds the pack and writes maya-ds4.json.  Every option below is needed:
#   --setup           without it a re-run with a configuration starts the server instead
#   --port            without it the setup writes port 8080 into the configuration
#   --drafting        without it the speed calibration runs (--yes measures)
#   --download-model  without it nothing is downloaded and the setup still exits with 0
# The exit code is therefore not trusted: the files the service needs are checked afterwards.
# The API key is not passed: the service reads MAYA_API_KEY from maya.env.
# shellcheck disable=SC2016
setup_maya() {
  local DSMAYAINS_d=${DSMAYAINS_VAL[DESTDIR]} DSMAYAINS_u=${DSMAYAINS_VAL[USER]} DSMAYAINS_tree DSMAYAINS_cfg DSMAYAINS_log DSMAYAINS_pack DSMAYAINS_gpu DSMAYAINS_drafting DSMAYAINS_args DSMAYAINS_got DSMAYAINS_start DSMAYAINS_rc=0
  DSMAYAINS_tree=$(maya_tree)
  DSMAYAINS_cfg="$DSMAYAINS_tree/maya-ds4.json"
  DSMAYAINS_log="$DSMAYAINS_tree/maya-setup.log"
  DSMAYAINS_pack="$DSMAYAINS_d/models/$DSMAYAINS_MODEL-GGUF/$(quant_field 2)/maya-ds4"
  DSMAYAINS_gpu=$(gpu_index)
  wait_port_free "${DSMAYAINS_VAL[MAYA_PORT]}" 60 || die "TCP port ${DSMAYAINS_VAL[MAYA_PORT]} is still in use: $(ss -Hltnp "sport = :${DSMAYAINS_VAL[MAYA_PORT]}" | head -n1)"
  DSMAYAINS_drafting=${DSMAYAINS_VAL[DRAFTING]}
  [[ $DSMAYAINS_drafting != skip ]] || DSMAYAINS_drafting=off
  DSMAYAINS_args=(--setup --yes --plain --no-start --download-model
    --model "$DSMAYAINS_MODEL" --ds4-quant "$(quant_field 1)"
    --gpu "$DSMAYAINS_gpu" --context "${DSMAYAINS_VAL[CTX_SIZE]}" --port "${DSMAYAINS_VAL[MAYA_PORT]}"
    --models-dir "$DSMAYAINS_d/models" --parallel "${DSMAYAINS_VAL[PARALLEL]}"
    --drafting "$DSMAYAINS_drafting")
  [[ ${DSMAYAINS_VAL[VISION]} == yes ]] || DSMAYAINS_args+=(--no-vision)
  DSMAYAINS_args+=(--env MAYA_DS4_SLOT_KEEP=1)
  DSMAYAINS_start=$(date +%s)
  info "Running maya.sh ${DSMAYAINS_args[*]}"
  info "This compiles the engine (10 to 30 minutes at the first installation) and downloads the model ($(quant_field 4) GB for ${DSMAYAINS_VAL[QUANT]}); it can take hours. Log: $DSMAYAINS_log"
  # The log is written by the service user (tee), never by root inside a folder of that user.
  run_as "$DSMAYAINS_u" "$DSMAYAINS_d" bash -o pipefail -c '"$@" 2>&1 | tee "$0"' "$DSMAYAINS_log" "$DSMAYAINS_tree/maya.sh" "${DSMAYAINS_args[@]}" </dev/null || DSMAYAINS_rc=$?
  ((DSMAYAINS_rc == 0)) || die "Maya's setup failed (exit code $DSMAYAINS_rc; see $DSMAYAINS_log); fix the problem reported above and re-run the installer (downloads are resumed)"
  # Written in this run: a configuration left by an earlier run proves nothing.
  [[ -f $DSMAYAINS_cfg && $(stat -c %Y "$DSMAYAINS_cfg") -ge $DSMAYAINS_start ]] \
    || die "Maya's setup did not write $DSMAYAINS_cfg (see $DSMAYAINS_log); it stops like this when it has not downloaded the model"
  DSMAYAINS_got=$(json_get "$DSMAYAINS_cfg" installer ds4_quant)
  [[ $DSMAYAINS_got == "$(quant_field 1)" ]] \
    || die "$DSMAYAINS_cfg is for the quantization '${DSMAYAINS_got:-unknown}', not '$(quant_field 1)': Maya's setup did not finish (see $DSMAYAINS_log)"
  [[ -x $DSMAYAINS_tree/build/maya-ds4 ]] || die "Maya's setup did not build $DSMAYAINS_tree/build/maya-ds4 (see $DSMAYAINS_log)"
  [[ -f $DSMAYAINS_pack/ds4.txt ]] || die "Maya's setup did not build the pack $DSMAYAINS_pack (see $DSMAYAINS_log)"
}

# Maya's setup has no option for the thinking level and writes "reasoning_effort": "high"
# on every run, so it is set here after each setup run (a number as a JSON number).  A key
# left in the configuration ("api_key") would take the place of the one in maya.env when
# maya.py starts the server, so it is removed.  Done as the service user, with the service
# stopped, through a temporary file.
set_thinking() {
  local DSMAYAINS_cfg DSMAYAINS_out
  DSMAYAINS_cfg="$(maya_tree)/maya-ds4.json"
  DSMAYAINS_out=$(run_as "${DSMAYAINS_VAL[USER]}" "${DSMAYAINS_VAL[DESTDIR]}" python3 -I -c '
import json, os, sys
path, effort = sys.argv[1], sys.argv[2]
with open(path, encoding="utf-8") as f:
    cfg = json.load(f)
if not isinstance(cfg, dict):
    sys.exit("not a JSON object: " + path)
cfg["reasoning_effort"] = int(effort) if effort.isdigit() else effort
had_key = cfg.pop("api_key", None) is not None
tmp = path + ".tmp"
with open(tmp, "w", encoding="utf-8") as f:
    json.dump(cfg, f, indent=1)
os.replace(tmp, path)
print("key-removed" if had_key else "ok")
' "$DSMAYAINS_cfg" "${DSMAYAINS_VAL[THINKING]}" </dev/null) || die "cannot set the thinking level in $DSMAYAINS_cfg"
  [[ $DSMAYAINS_out != key-removed ]] || warn "an API key in $DSMAYAINS_cfg was removed; the key in $DSMAYAINS_ENV_FILE is the one in use"
  info "Thinking level: $(thinking_label) (reasoning_effort in $DSMAYAINS_cfg)"
}

write_unit() {
  local DSMAYAINS_u=${DSMAYAINS_VAL[USER]} DSMAYAINS_d=${DSMAYAINS_VAL[DESTDIR]} DSMAYAINS_tree DSMAYAINS_groups="" DSMAYAINS_g
  DSMAYAINS_tree=$(maya_tree)
  for DSMAYAINS_g in video render; do
    if getent group "$DSMAYAINS_g" >/dev/null; then DSMAYAINS_groups+=" $DSMAYAINS_g"; fi
  done
  info "Writing the systemd unit"
  # KillMode=mixed: only maya.py gets SIGTERM; it stops its server and its engine in turn
  # (up to about 150 s; the engine saves its conversations and frees the GPU).
  # After= the plamo-3-translate services: Maya pins nearly all RAM that is free at its start.
  # Sandboxing is light on purpose until tested on real hardware.
  cat > "$DSMAYAINS_UNIT_DIR/$DSMAYAINS_UNIT" <<EOF
# Generated by install-deepseek-maya.sh; changes are overwritten on re-run.
[Unit]
Description=DeepSeek-V4.1-Flash-1017 on Project Maya (maya.sh)
After=network-online.target plamo-3-translate-llama.service plamo-3-translate-uwsgi.service
Wants=network-online.target
Conflicts=$DSMAYAINS_QWEN_UNIT

[Service]
Type=simple
User=$DSMAYAINS_u
Group=$DSMAYAINS_u
${DSMAYAINS_groups:+SupplementaryGroups=${DSMAYAINS_groups# }
}WorkingDirectory=$DSMAYAINS_tree
Environment=HOME=$DSMAYAINS_d
Environment=PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
Environment=LANG=C.UTF-8
EnvironmentFile=$DSMAYAINS_ENV_FILE
ExecStart=$DSMAYAINS_tree/maya.sh --config $DSMAYAINS_tree/maya-ds4.json --port ${DSMAYAINS_VAL[MAYA_PORT]} --plain
Restart=on-failure
RestartSec=30
TimeoutStartSec=infinity
TimeoutStopSec=600
KillMode=mixed
LimitMEMLOCK=infinity
NoNewPrivileges=yes
ProtectSystem=full

[Install]
WantedBy=multi-user.target
EOF
  chmod 0644 "$DSMAYAINS_UNIT_DIR/$DSMAYAINS_UNIT"
}

# Maya appends to the engine log for ever; rotate it in place.
write_logrotate() {
  cat > "$DSMAYAINS_LOGROTATE_FILE" <<EOF
# Generated by install-deepseek-maya.sh; changes are overwritten on re-run.
$(maya_tree)/maya-ds4.log {
    su ${DSMAYAINS_VAL[USER]} ${DSMAYAINS_VAL[USER]}
    weekly
    rotate 4
    missingok
    notifempty
    compress
    delaycompress
    copytruncate
}
EOF
  chmod 0644 "$DSMAYAINS_LOGROTATE_FILE"
}

# nginx_location PATH MODE [prefix]: print a location for an exact path, or with "prefix"
# for everything below PATH (which then ends with a slash).  MODE: add (nginx adds the API
# key), get (nginx adds it to GET requests only), chat (per request, see nginx_site) or
# pass (the client's own headers).  The URI in proxy_pass makes Maya see exactly the
# (normalized) path nginx matched.
# shellcheck disable=SC2016
nginx_location() {
  local DSMAYAINS_auth="" DSMAYAINS_up="http://127.0.0.1:${DSMAYAINS_VAL[MAYA_PORT]}" DSMAYAINS_match="= "
  [[ ${3:-} != prefix ]] || DSMAYAINS_match=""
  case $2 in
    add) DSMAYAINS_auth='        proxy_set_header Authorization $dsmaya_bearer;
        proxy_set_header X-Api-Key "";' ;;
    get) DSMAYAINS_auth='        proxy_set_header Authorization $dsmaya_get_auth;
        proxy_set_header X-Api-Key $dsmaya_get_xkey;' ;;
    chat) DSMAYAINS_auth='        proxy_set_header Authorization $dsmaya_chat_auth;
        proxy_set_header X-Api-Key $dsmaya_chat_xkey;' ;;
  esac
  if [[ -z $DSMAYAINS_auth ]]; then
    printf '    location %s%s {\n        proxy_pass %s%s;\n    }\n' "$DSMAYAINS_match" "$1" "$DSMAYAINS_up" "$1"
  else
    # proxy_set_header is inherited only as a whole, so the server-level ones are repeated.
    printf '    location %s%s {\n        proxy_pass %s%s;\n        proxy_set_header Host $http_host;\n        proxy_set_header X-Forwarded-Proto $scheme;\n%s\n    }\n' \
      "$DSMAYAINS_match" "$1" "$DSMAYAINS_up" "$1" "$DSMAYAINS_auth"
  fi
}

# Print the nginx site.  Maya always has an API key; nginx adds it to the requests that
# may be made without one:
#   web page (/metrics, /attach, ...; GET of /settings, /mcp, ...)   unless --web-api-key
#   agents (/v1/messages, /v1/responses, /v1/models, ...)            unless --agent-api-key
#   /v1/chat/completions (used by both)      by both settings; when they differ, a request
#       counts as the web page's if the browser says so: Sec-Fetch-Site: same-origin, or
#       (browsers send Sec-Fetch-* only to HTTPS and localhost) an Origin equal to the Host.
#       Other clients can forge these headers.
# Everything else, including all management requests (POST of /settings, /api/context,
# ...), is passed on with the client's own headers, so Maya demands the key there.  Unknown
# paths therefore fail safe.
nginx_site() {
  local DSMAYAINS_port=${DSMAYAINS_VAL[WEB_PORT]} DSMAYAINS_web=${DSMAYAINS_VAL[WEB_API_KEY]} DSMAYAINS_agent=${DSMAYAINS_VAL[AGENT_API_KEY]}
  local DSMAYAINS_listen DSMAYAINS_a DSMAYAINS_web_mode=add DSMAYAINS_get_mode=get DSMAYAINS_agent_mode=add DSMAYAINS_chat_mode DSMAYAINS_page DSMAYAINS_p
  if [[ ${DSMAYAINS_VAL[INTERFACES]} == all ]]; then
    DSMAYAINS_listen="    listen $DSMAYAINS_port;"
    [[ ! -e /proc/net/if_inet6 ]] || DSMAYAINS_listen+=$'\n'"    listen [::]:$DSMAYAINS_port;"
  else
    DSMAYAINS_listen="    listen 127.0.0.1:$DSMAYAINS_port;"
    [[ ! -e /proc/net/if_inet6 ]] || DSMAYAINS_listen+=$'\n'"    listen [::1]:$DSMAYAINS_port;"
    while read -r DSMAYAINS_a; do
      [[ -n $DSMAYAINS_a ]] || continue
      if [[ $DSMAYAINS_a == *:* ]]; then DSMAYAINS_listen+=$'\n'"    listen [$DSMAYAINS_a]:$DSMAYAINS_port;"
      else DSMAYAINS_listen+=$'\n'"    listen $DSMAYAINS_a:$DSMAYAINS_port;"; fi
    done <<<"$(listen_addresses)"
  fi
  if [[ $DSMAYAINS_web == yes ]]; then DSMAYAINS_web_mode=pass; DSMAYAINS_get_mode=pass; fi
  [[ $DSMAYAINS_agent != yes ]] || DSMAYAINS_agent_mode=pass
  if [[ $DSMAYAINS_web == "$DSMAYAINS_agent" ]]; then DSMAYAINS_chat_mode=$DSMAYAINS_web_mode; else DSMAYAINS_chat_mode=chat; fi

  echo "# Generated by install-deepseek-maya.sh; changes are overwritten on re-run."
  echo "# API key: web page $(key_label "$DSMAYAINS_web"), agents $(key_label "$DSMAYAINS_agent"), management always required."
  if [[ $DSMAYAINS_get_mode == get ]]; then
    # The paths the web page only reads: the key is added to GET, any other method keeps
    # the client's own headers (changing a setting is a management request).
    cat <<EOF

map \$request_method \$dsmaya_get_auth {
    default \$http_authorization;
    GET \$dsmaya_bearer;
}
map \$request_method \$dsmaya_get_xkey {
    default \$http_x_api_key;
    GET "";
}
EOF
  fi
  if [[ $DSMAYAINS_chat_mode == chat ]]; then
    # 1 = the request comes from the web page; the key is added for that side only.
    DSMAYAINS_page=1
    [[ $DSMAYAINS_web != yes ]] || DSMAYAINS_page=0
    cat <<EOF

map "\$http_sec_fetch_site|\$http_origin|\$http_host" \$dsmaya_from_page {
    default 0;
    "~^same-origin\\|" 1;
    "~^\\|https?://([^|]+)\\|\\1\$" 1;
}
map \$dsmaya_from_page \$dsmaya_chat_auth {
    default \$http_authorization;
    $DSMAYAINS_page \$dsmaya_bearer;
}
map \$dsmaya_from_page \$dsmaya_chat_xkey {
    default \$http_x_api_key;
    $DSMAYAINS_page "";
}
EOF
  fi
  cat <<EOF

server {
$DSMAYAINS_listen
    server_name _;

    # Pictures and files are sent inline.
    client_max_body_size 256m;
    # Streamed answers; long generations and long waits for a free slot.
    proxy_buffering off;
    proxy_read_timeout 3660s;
    proxy_send_timeout 3660s;
    # Maya refuses a POST whose Origin does not equal the Host header, port included.
    proxy_set_header Host \$http_host;
    proxy_set_header X-Forwarded-Proto \$scheme;

    # Defines \$dsmaya_bearer ("Bearer <API key>"); readable by root only.
    include $DSMAYAINS_NGINX_KEY_FILE;

    # The web page (/, /web/, /fonts/), /health and everything not listed below, with the
    # client's own headers: Maya demands the key for all of it but the page and /health.
    location / {
        proxy_pass http://127.0.0.1:${DSMAYAINS_VAL[MAYA_PORT]};
    }

    # What the web page needs for chatting.
EOF
  for DSMAYAINS_p in /metrics /attach /pdf /api/tokens /v1/strata/stream /v1/strata/cancel; do
    nginx_location "$DSMAYAINS_p" "$DSMAYAINS_web_mode"
  done
  printf '\n    # Read by the web page (GET); changing them (POST) is a management request.\n'
  for DSMAYAINS_p in /settings /mcp /api/context /api/thinking-budget /api/turbo /api/savings /api/update; do
    nginx_location "$DSMAYAINS_p" "$DSMAYAINS_get_mode"
  done
  printf '\n    # Used by the web page and by agents.\n'
  nginx_location /v1/chat/completions "$DSMAYAINS_chat_mode"
  printf '\n    # Used by agents.\n'
  for DSMAYAINS_p in /v1/messages /v1/responses /v1/models /models /props /tokenize /detokenize; do
    nginx_location "$DSMAYAINS_p" "$DSMAYAINS_agent_mode"
  done
  nginx_location /v1/responses/ "$DSMAYAINS_agent_mode" prefix
  echo "}"
}

write_nginx() {
  info "Writing nginx site configuration"
  nginx_site > "$DSMAYAINS_NGINX_SITE"
  chmod 0644 "$DSMAYAINS_NGINX_SITE"
  ln -sfn "$DSMAYAINS_NGINX_SITE" "$DSMAYAINS_NGINX_LINK"
  if ! nginx -t 2>&1; then
    # Do not leave a broken site enabled: it would stop other sites from being reloaded.
    rm -f "$DSMAYAINS_NGINX_LINK"
    die "nginx configuration test failed; the site $DSMAYAINS_APP_NAME was disabled again (see $DSMAYAINS_NGINX_SITE)"
  fi
}

start_services() {
  info "Starting services"
  systemctl daemon-reload
  systemctl enable "$DSMAYAINS_UNIT" nginx.service
  systemctl reset-failed "$DSMAYAINS_UNIT" 2>/dev/null || true
  systemctl restart "$DSMAYAINS_UNIT" || {
    journalctl -u "$DSMAYAINS_UNIT" -n 30 --no-pager >&2 || true
    die "failed to start $DSMAYAINS_UNIT"
  }
  if systemctl is-active --quiet nginx.service; then
    systemctl reload nginx.service
  else
    systemctl start nginx.service
  fi
}

# --------------------------------------------------------------------- ufw

ufw_active() {
  local DSMAYAINS_status
  command -v ufw >/dev/null 2>&1 || return 1
  DSMAYAINS_status=$(ufw status 2>/dev/null) || return 1
  grep -q '^Status: active$' <<<"$DSMAYAINS_status"
}

# Print the ufw rules needed for the web server: PORT, or PORT@INTERFACE when the
# interfaces are restricted.  Maya itself listens on 127.0.0.1 only.
ufw_wanted_rules() {
  local DSMAYAINS_ifc DSMAYAINS_p=${DSMAYAINS_VAL[WEB_PORT]}
  if [[ ${DSMAYAINS_VAL[INTERFACES]} == all ]]; then
    echo "$DSMAYAINS_p"
  else
    for DSMAYAINS_ifc in ${DSMAYAINS_VAL[INTERFACES]//,/ }; do echo "$DSMAYAINS_p@$DSMAYAINS_ifc"; done
  fi
}

# Print the wanted rules that ufw does not allow yet (a rule for all interfaces covers
# every interface).
ufw_closed_ports() {
  local DSMAYAINS_status DSMAYAINS_r DSMAYAINS_p DSMAYAINS_ifc
  DSMAYAINS_status=$(ufw status 2>/dev/null || true)
  while read -r DSMAYAINS_r; do
    [[ -n $DSMAYAINS_r ]] || continue
    DSMAYAINS_p=${DSMAYAINS_r%%@*}
    grep -Eq "^$DSMAYAINS_p(/tcp)?[[:space:]]+ALLOW" <<<"$DSMAYAINS_status" && continue
    if [[ $DSMAYAINS_r == *@* ]]; then
      DSMAYAINS_ifc=${DSMAYAINS_r#*@}
      grep -Eq "^$DSMAYAINS_p(/tcp)? on ${DSMAYAINS_ifc//./\\.}[[:space:]]+ALLOW" <<<"$DSMAYAINS_status" && continue
    fi
    echo "$DSMAYAINS_r"
  done <<<"$(ufw_wanted_rules)"
}

# Human-readable form of rules: "58080/tcp, 58080/tcp on bond0".
ufw_rules_text() {
  local DSMAYAINS_r DSMAYAINS_text=""
  for DSMAYAINS_r in "$@"; do
    if [[ $DSMAYAINS_r == *@* ]]; then DSMAYAINS_text+="${DSMAYAINS_text:+, }${DSMAYAINS_r%%@*}/tcp on ${DSMAYAINS_r#*@}"
    else DSMAYAINS_text+="${DSMAYAINS_text:+, }$DSMAYAINS_r/tcp"; fi
  done
  echo "$DSMAYAINS_text"
}

# ufw arguments for a rule (used with "ufw" and "ufw delete").
ufw_rule_args() {
  if [[ $1 == *@* ]]; then
    echo "allow in on ${1#*@} to any port ${1%%@*} proto tcp"
  else
    echo "allow ${1}/tcp"
  fi
}

# Ask about ufw together with the other questions.  configure_ufw asks again only if
# this was not answered (e.g. ufw was enabled after the questions).
prompt_ufw() {
  local DSMAYAINS_ports
  [[ -z $DSMAYAINS_OPEN_PORTS && $DSMAYAINS_INTERACTIVE == yes && $DSMAYAINS_ASSUME_YES != yes ]] || return 0
  ufw_active || return 0
  DSMAYAINS_ports=$(ufw_closed_ports | paste -sd' ' -)
  [[ -n $DSMAYAINS_ports ]] || return 0
  # shellcheck disable=SC2086
  if confirm "ufw is active. Allow incoming $(ufw_rules_text $DSMAYAINS_ports)?"; then
    DSMAYAINS_OPEN_PORTS=yes
  else
    DSMAYAINS_OPEN_PORTS=no
  fi
}

ufw_label() {
  local DSMAYAINS_ports
  if ! ufw_active; then echo "no (ufw is not active)"; return 0; fi
  DSMAYAINS_ports=$(ufw_closed_ports | paste -sd' ' -)
  # shellcheck disable=SC2086
  DSMAYAINS_ports=$(ufw_rules_text $DSMAYAINS_ports)
  if [[ -z $DSMAYAINS_ports ]]; then echo "no (already allowed)"
  elif [[ $DSMAYAINS_OPEN_PORTS == yes || ( -z $DSMAYAINS_OPEN_PORTS && $DSMAYAINS_ASSUME_YES == yes ) ]]; then echo "yes ($DSMAYAINS_ports)"
  elif [[ $DSMAYAINS_OPEN_PORTS == no ]]; then echo "no ($DSMAYAINS_ports stay closed)"
  else echo "ask later ($DSMAYAINS_ports)"
  fi
}

configure_ufw() {
  local DSMAYAINS_ports DSMAYAINS_p DSMAYAINS_wanted DSMAYAINS_kept=""
  DSMAYAINS_UFW_RULES=${DSMAYAINS_SAVED[UFW_RULES]:-}
  ufw_active || return 0
  # Remove rules this installer added earlier that are no longer wanted (another port,
  # or a rule for all interfaces after restricting the interfaces).
  DSMAYAINS_wanted=" $(ufw_wanted_rules | paste -sd' ' -) "
  for DSMAYAINS_p in $DSMAYAINS_UFW_RULES; do
    if [[ $DSMAYAINS_wanted == *" $DSMAYAINS_p "* ]]; then
      DSMAYAINS_kept+="${DSMAYAINS_kept:+ }$DSMAYAINS_p"
    else
      # shellcheck disable=SC2046
      ufw delete $(ufw_rule_args "$DSMAYAINS_p") >/dev/null 2>&1 || true
      info "Removed the ufw rule for $(ufw_rules_text "$DSMAYAINS_p") added by a previous installation"
    fi
  done
  DSMAYAINS_UFW_RULES=$DSMAYAINS_kept
  DSMAYAINS_ports=$(ufw_closed_ports | paste -sd' ' -)
  if [[ -z $DSMAYAINS_ports ]]; then
    info "ufw already allows the required port(s)"
    return 0
  fi
  # shellcheck disable=SC2086
  if [[ $DSMAYAINS_OPEN_PORTS == yes ]] ||
     { [[ -z $DSMAYAINS_OPEN_PORTS ]] && confirm "ufw is active. Allow incoming $(ufw_rules_text $DSMAYAINS_ports)?"; }; then
    for DSMAYAINS_p in $DSMAYAINS_ports; do
      # shellcheck disable=SC2046
      ufw $(ufw_rule_args "$DSMAYAINS_p") comment "$DSMAYAINS_APP_NAME" >/dev/null
      [[ " $DSMAYAINS_UFW_RULES " == *" $DSMAYAINS_p "* ]] || DSMAYAINS_UFW_RULES=${DSMAYAINS_UFW_RULES:+$DSMAYAINS_UFW_RULES }$DSMAYAINS_p
    done
    # shellcheck disable=SC2086
    info "Allowed $(ufw_rules_text $DSMAYAINS_ports) in ufw"
  else
    # shellcheck disable=SC2086
    warn "ufw is active and $(ufw_rules_text $DSMAYAINS_ports) were not allowed; other hosts cannot connect"
  fi
}

save_config() {
  local DSMAYAINS_key
  install -d -m 0755 "$DSMAYAINS_CONF_DIR"
  {
    echo "# Written by install-deepseek-maya.sh; used as defaults on re-run and by --uninstall."
    for DSMAYAINS_key in $DSMAYAINS_KEYS; do printf "%s='%s'\n" "$DSMAYAINS_key" "${DSMAYAINS_VAL[$DSMAYAINS_key]}"; done
    printf "UFW_RULES='%s'\n" "$DSMAYAINS_UFW_RULES"
  } > "$DSMAYAINS_CONF_FILE.tmp"
  chmod 0644 "$DSMAYAINS_CONF_FILE.tmp"
  mv -f "$DSMAYAINS_CONF_FILE.tmp" "$DSMAYAINS_CONF_FILE"
}

# -------------------------------------------------------------------- tests

# http_code URL [curl options...]: print the HTTP status of a GET.
http_code() {
  local DSMAYAINS_url=$1
  shift
  curl -s -o /dev/null -w '%{http_code}' --max-time 20 "$@" "$DSMAYAINS_url" || true
}

# Maya's server opens its port only after the engine is ready; /health then says
# "status": "ok" and "unloaded": false.
wait_health() {
  local DSMAYAINS_url="http://127.0.0.1:${DSMAYAINS_VAL[MAYA_PORT]}/health" DSMAYAINS_start DSMAYAINS_body="" DSMAYAINS_effort
  info "Waiting for Maya to load the model (up to ${DSMAYAINS_HEALTH_TIMEOUT}s; a start takes minutes)"
  DSMAYAINS_start=$SECONDS
  while :; do
    DSMAYAINS_body=$(curl -s --fail --max-time 5 "$DSMAYAINS_url" 2>/dev/null || true)
    if [[ -n $DSMAYAINS_body && $(json_get - status <<<"$DSMAYAINS_body") == ok && $(json_get - unloaded <<<"$DSMAYAINS_body") == false ]]; then
      break
    fi
    # Restart=on-failure would hide a crash; any restart or inactive state is a failure.
    if [[ $(systemctl show -p ActiveState --value "$DSMAYAINS_UNIT") != active ||
          $(systemctl show -p NRestarts --value "$DSMAYAINS_UNIT") != 0 ]]; then
      journalctl -u "$DSMAYAINS_UNIT" -n 40 --no-pager >&2 || true
      die "Maya is not running (see journalctl -u $DSMAYAINS_UNIT and $(maya_tree)/maya-ds4.log)"
    fi
    if ((SECONDS - DSMAYAINS_start > DSMAYAINS_HEALTH_TIMEOUT)); then
      journalctl -u "$DSMAYAINS_UNIT" -n 40 --no-pager >&2 || true
      die "Maya did not become ready within ${DSMAYAINS_HEALTH_TIMEOUT}s"
    fi
    sleep 5
  done
  DSMAYAINS_MODEL_ID=$(json_get - model <<<"$DSMAYAINS_body")
  DSMAYAINS_N_CTX=$(json_get - max_context <<<"$DSMAYAINS_body")
  DSMAYAINS_effort=$(json_get - defaults reasoning_effort <<<"$DSMAYAINS_body")
  info "Maya is ready ($((SECONDS - DSMAYAINS_start))s): model ${DSMAYAINS_MODEL_ID:-unknown}, context ${DSMAYAINS_N_CTX:-unknown}, thinking ${DSMAYAINS_effort:-unknown} (set: $(thinking_label))"
}

# expect_code DESCRIPTION EXPECTED URL [curl options...]
expect_code() {
  local DSMAYAINS_what=$1 DSMAYAINS_want=$2 DSMAYAINS_got
  shift 2
  DSMAYAINS_got=$(http_code "$@")
  [[ $DSMAYAINS_got == "$DSMAYAINS_want" ]] || die "test failed: $DSMAYAINS_what: HTTP ${DSMAYAINS_got:-none}, expected $DSMAYAINS_want"
  info "Test passed: $DSMAYAINS_what (HTTP $DSMAYAINS_got)"
}

smoke_test() {
  local DSMAYAINS_base="http://127.0.0.1:${DSMAYAINS_VAL[WEB_PORT]}" DSMAYAINS_auth DSMAYAINS_want DSMAYAINS_out DSMAYAINS_code DSMAYAINS_ctx
  wait_health
  DSMAYAINS_auth="Authorization: Bearer $DSMAYAINS_API_KEY"
  info "Testing through the web server (port ${DSMAYAINS_VAL[WEB_PORT]})"
  expect_code "/health" 200 "$DSMAYAINS_base/health"
  expect_code "web page" 200 "$DSMAYAINS_base/"
  expect_code "management path /status without the API key is refused" 401 "$DSMAYAINS_base/status"
  expect_code "management path /status with the API key" 200 "$DSMAYAINS_base/status" -H "$DSMAYAINS_auth"
  DSMAYAINS_want=200; [[ ${DSMAYAINS_VAL[WEB_API_KEY]} != yes ]] || DSMAYAINS_want=401
  expect_code "/metrics without the API key (web page: $(key_label "${DSMAYAINS_VAL[WEB_API_KEY]}"))" "$DSMAYAINS_want" "$DSMAYAINS_base/metrics"
  DSMAYAINS_want=200; [[ ${DSMAYAINS_VAL[AGENT_API_KEY]} != yes ]] || DSMAYAINS_want=401
  expect_code "/v1/models without the API key (agents: $(key_label "${DSMAYAINS_VAL[AGENT_API_KEY]}"))" "$DSMAYAINS_want" "$DSMAYAINS_base/v1/models"
  DSMAYAINS_out=$(curl -s --fail --max-time 20 -H "$DSMAYAINS_auth" "$DSMAYAINS_base/v1/models") || die "test failed: /v1/models with the API key"
  DSMAYAINS_ctx=$(json_get - data 0 context_length <<<"$DSMAYAINS_out")
  [[ $DSMAYAINS_ctx == "${DSMAYAINS_VAL[CTX_SIZE]}" ]] \
    || die "test failed: /v1/models reports the context size ${DSMAYAINS_ctx:-none}, expected ${DSMAYAINS_VAL[CTX_SIZE]}"
  info "Test passed: /v1/models reports the context size $DSMAYAINS_ctx"
  info "Requesting a short chat completion"
  DSMAYAINS_out=$(curl -s -w '\n%{http_code}' --max-time 900 -H 'Content-Type: application/json' -H "$DSMAYAINS_auth" \
    -d "{\"model\": \"${DSMAYAINS_MODEL_ID:-$DSMAYAINS_MODEL}\", \"messages\": [{\"role\": \"user\", \"content\": \"Say hello.\"}], \"max_tokens\": 32}" \
    "$DSMAYAINS_base/v1/chat/completions") || die "cannot connect to the web server on port ${DSMAYAINS_VAL[WEB_PORT]}"
  DSMAYAINS_code=${DSMAYAINS_out##*$'\n'}; DSMAYAINS_out=${DSMAYAINS_out%$'\n'*}
  [[ $DSMAYAINS_code == 200 ]] || die "chat completion test failed (HTTP $DSMAYAINS_code): ${DSMAYAINS_out:0:500}"
  info "Test passed: chat completion (HTTP 200)"
}

# Offer to delete the model files of other quantizations: only their own folders under
# models/DeepSeek-V4.1-Flash-1017-GGUF/.  What the quantizations share (dspark/, vision/,
# Engram-*/) is kept; shared files are hard links, so deleting one folder does not break
# another.  A folder that a symbolic link elsewhere points into is kept.  Asked only
# interactively: --yes does not delete downloads.
cleanup_old_models() {
  local DSMAYAINS_base="${DSMAYAINS_VAL[DESTDIR]}/models/$DSMAYAINS_MODEL-GGUF" DSMAYAINS_q DSMAYAINS_dir
  [[ $DSMAYAINS_INTERACTIVE == yes ]] || return 0
  for DSMAYAINS_q in $DSMAYAINS_QUANTS; do
    [[ $DSMAYAINS_q != "${DSMAYAINS_VAL[QUANT]}" ]] || continue
    DSMAYAINS_dir="$DSMAYAINS_base/$(quant_field 2 "$DSMAYAINS_q")"
    [[ -d $DSMAYAINS_dir && ! -L $DSMAYAINS_dir ]] || continue
    if [[ -n $(find "$DSMAYAINS_base" -path "$DSMAYAINS_dir" -prune -o -type l -lname "$DSMAYAINS_dir/*" -print -quit 2>/dev/null) ]]; then
      warn "the model files of $DSMAYAINS_q in $DSMAYAINS_dir are used by another folder through symbolic links; not offered for deletion"
      continue
    fi
    if ask_yn "Delete the unused model files of $DSMAYAINS_q ($(du -sh "$DSMAYAINS_dir" 2>/dev/null | cut -f1))?" n; then
      rm -rf --one-file-system "${DSMAYAINS_dir:?}"
      info "Deleted the model files of $DSMAYAINS_q"
    fi
  done
}

finish() {
  local DSMAYAINS_ip DSMAYAINS_host
  DSMAYAINS_ip=$(listen_addresses | sed -n '1p')
  [[ -n $DSMAYAINS_ip ]] || DSMAYAINS_ip=$(hostname -I 2>/dev/null | awk '{print $1}')
  [[ $DSMAYAINS_ip != *:* ]] || DSMAYAINS_ip="[$DSMAYAINS_ip]"
  DSMAYAINS_host="${DSMAYAINS_ip:-<this host>}:${DSMAYAINS_VAL[WEB_PORT]}"
  cat <<EOF

$DSMAYAINS_MODEL (${DSMAYAINS_VAL[QUANT]}) with Project Maya $DSMAYAINS_MAYA_VERSION is installed.
  Web chat        : http://$DSMAYAINS_host/
  OpenAI API      : http://$DSMAYAINS_host/v1     (/v1/chat/completions, /v1/responses, /v1/models)
  Anthropic API   : http://$DSMAYAINS_host        (/v1/messages)
  Model name      : ${DSMAYAINS_MODEL_ID:-see /v1/models}
  Context         : ${DSMAYAINS_N_CTX:-${DSMAYAINS_VAL[CTX_SIZE]}} tokens
  Thinking        : $(thinking_label) (when a request names no level)
  Services        : $DSMAYAINS_UNIT, nginx.service
  Logs            : journalctl -u $DSMAYAINS_UNIT
                    $(maya_tree)/maya-ds4.log
  Settings        : $DSMAYAINS_CONF_FILE
  API key         : web page $(key_label "${DSMAYAINS_VAL[WEB_API_KEY]}"), agents $(key_label "${DSMAYAINS_VAL[AGENT_API_KEY]}"), management always required
                    sudo sed -n 's/^MAYA_API_KEY=//p' $DSMAYAINS_ENV_FILE
EOF
  if [[ ${DSMAYAINS_VAL[AGENT_API_KEY]} != yes ]]; then
    echo "                    (agents that insist on an API key can be given any non-empty string)"
  fi
  if [[ ${DSMAYAINS_VAL[WEB_API_KEY]} == yes ]]; then
    echo "                    (enter the key in the settings of the web page)"
  fi
  echo
}

do_install() {
  load_saved_config
  resolve_values
  require_gpu
  prompt_values
  validate
  prompt_gpus
  prompt_interfaces
  prompt_ufw
  show_summary
  preflight
  install_packages
  ensure_user
  prepare_destdir
  stop_service
  disable_qwen_strata
  install_maya
  write_key_files
  setup_maya
  set_thinking
  write_unit
  write_logrotate
  write_nginx
  [[ -n ${DSMAYAINS_SAVED[DESTDIR]:-} && ${DSMAYAINS_SAVED[DESTDIR]} != "${DSMAYAINS_VAL[DESTDIR]}" ]] \
    && warn "the previous installation directory ${DSMAYAINS_SAVED[DESTDIR]} is no longer used; remove it manually if not needed"
  start_services
  configure_ufw
  save_config
  smoke_test
  cleanup_old_models
  finish
}

# -------------------------------------------------------------- uninstall

do_uninstall() {
  local DSMAYAINS_destdir DSMAYAINS_user DSMAYAINS_p DSMAYAINS_rules
  load_saved_config
  DSMAYAINS_destdir=${DSMAYAINS_ARG[DESTDIR]:-${DSMAYA_DESTDIR:-${DSMAYAINS_SAVED[DESTDIR]:-${DSMAYAINS_DEFAULT[DESTDIR]}}}}
  DSMAYAINS_destdir=${DSMAYAINS_destdir%/}
  DSMAYAINS_user=${DSMAYAINS_ARG[USER]:-${DSMAYA_USER:-${DSMAYAINS_SAVED[USER]:-${DSMAYAINS_DEFAULT[USER]}}}}
  cat <<EOF
This will stop and remove the $DSMAYAINS_MODEL / Project Maya service and delete:
  $DSMAYAINS_UNIT_DIR/$DSMAYAINS_UNIT
  $DSMAYAINS_NGINX_SITE (and the link in sites-enabled)
  $DSMAYAINS_LOGROTATE_FILE
  $DSMAYAINS_CONF_DIR (including the API key)
  $DSMAYAINS_destdir (Maya, its engine and all downloaded model files)
EOF
  confirm "Uninstall $DSMAYAINS_MODEL / Project Maya?" || die "aborted (use --yes to uninstall non-interactively)"

  info "Stopping the service"
  if service_exists "$DSMAYAINS_UNIT"; then
    systemctl disable --now "$DSMAYAINS_UNIT" 2>/dev/null || true
    rm -f "${DSMAYAINS_UNIT_DIR:?}/$DSMAYAINS_UNIT"
  fi
  systemctl daemon-reload
  systemctl reset-failed "$DSMAYAINS_UNIT" 2>/dev/null || true

  info "Removing nginx site"
  rm -f "$DSMAYAINS_NGINX_LINK" "$DSMAYAINS_NGINX_SITE"
  if command -v nginx >/dev/null && systemctl is-active --quiet nginx.service; then
    if nginx -t >/dev/null 2>&1; then
      systemctl reload nginx.service
    else
      warn "nginx configuration test failed; nginx was not reloaded"
    fi
  fi
  rm -f "$DSMAYAINS_LOGROTATE_FILE"

  DSMAYAINS_rules=${DSMAYAINS_SAVED[UFW_RULES]:-}
  if [[ -n $DSMAYAINS_rules ]] && command -v ufw >/dev/null; then
    for DSMAYAINS_p in $DSMAYAINS_rules; do
      # shellcheck disable=SC2046
      if ufw delete $(ufw_rule_args "$DSMAYAINS_p") >/dev/null 2>&1; then
        info "Removed the ufw rule for $(ufw_rules_text "$DSMAYAINS_p")"
      fi
    done
  fi

  if [[ -d $DSMAYAINS_destdir ]]; then
    if [[ -e $DSMAYAINS_destdir/$DSMAYAINS_MARKER ]]; then
      info "Removing $DSMAYAINS_destdir"
      rm -rf --one-file-system "${DSMAYAINS_destdir:?}"
    else
      warn "$DSMAYAINS_destdir does not look like a $DSMAYAINS_APP_NAME installation; not removed"
    fi
  fi
  rm -rf "${DSMAYAINS_CONF_DIR:?}"

  cat <<EOF

$DSMAYAINS_MODEL / Project Maya was uninstalled.
The apt packages (cuda-toolkit-13, nginx-full, ...) and the service user $DSMAYAINS_user were kept.
Remove them manually if they are no longer needed, e.g.:
  sudo userdel $DSMAYAINS_user
EOF
  if service_exists "$DSMAYAINS_QWEN_UNIT"; then
    cat <<EOF
$DSMAYAINS_QWEN_UNIT was stopped and disabled when $DSMAYAINS_APP_NAME was installed.  To use it again:
  sudo systemctl enable --now ${DSMAYAINS_QWEN_UNIT%.service}
EOF
  fi
}

main() {
  parse_args "$@"
  check_platform
  trap cleanup_tmp EXIT
  if [[ $DSMAYAINS_ACTION == uninstall ]]; then
    do_uninstall
  else
    do_install
  fi
}

# Not run when the file is sourced (for tests).
if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
  main "$@"
fi
