#!/usr/bin/env bash
#
# 本地 LLM 環境健檢工具 — 偵測腳本
#
# 規格來源：rules-draft.md v3.0-verified（唯一規格來源）
# 每條規則的判定邏輯都標註對應的規則編號，可回溯到規格文件。
#
# 硬性原則：
#   * 只讀不改 —— 除了產出 report.html，不寫入任何系統狀態
#   * 零 sudo、零安裝
#   * 純規則判斷，不呼叫任何 LLM（規格硬性限制 1）
#   * 零相依：只用 bash / coreutils / awk / sed / curl
#
set -uo pipefail

VERSION="0.1.0"
SPEC_VERSION="rules-draft.md v3.0-verified"

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
OUT_HTML="${SCRIPT_DIR}/report.html"
NO_HTML=0
LIVE_MODE=0

while [ $# -gt 0 ]; do
    case "$1" in
        -o|--output) OUT_HTML="$2"; shift 2 ;;
        --no-html)   NO_HTML=1; shift ;;
        --live)      LIVE_MODE=1; shift ;;
        -h|--help)
            cat <<EOF
用法：check.sh [選項]
  -o, --output <路徑>   report.html 的輸出位置（預設：腳本所在資料夾）
      --no-html         只在終端機顯示，不產生 report.html
      --live            實際載入一個模型跑一次，讓核心檢查有真實資料可判定
                        ⚠ 這是唯一會改變系統狀態的選項：它會佔用顯示卡記憶體，
                          由 Ollama 依 keep-alive 設定自動釋放（預設 5 分鐘）
  -h, --help            顯示這段說明
EOF
            exit 0 ;;
        *) echo "未知選項：$1（用 --help 看說明）" >&2; exit 2 ;;
    esac
done

# ---------------------------------------------------------------------------
# 輸出工具
# ---------------------------------------------------------------------------

if [ -t 1 ]; then
    C_RESET=$'\033[0m'; C_BOLD=$'\033[1m'; C_DIM=$'\033[2m'
    C_PASS=$'\033[32m'; C_WARN=$'\033[33m'; C_FAIL=$'\033[31m'; C_INFO=$'\033[36m'
else
    C_RESET=""; C_BOLD=""; C_DIM=""; C_PASS=""; C_WARN=""; C_FAIL=""; C_INFO=""
fi

have() { command -v "$1" >/dev/null 2>&1; }

# ---------------------------------------------------------------------------
# 輸出去識別化
#
# 這份報告的設計用途是「複製起來貼給任何 AI 助手追問」，所以輸出裡
# 絕對不能出現使用者的帳號名稱。
#
# 具體風險（實測過，不是理論）：R4 會輸出 `type -aP nvidia-smi` 與
# `ldconfig -p` 的結果。把 nvidia-smi 裝在 conda / pyenv / uv venv /
# ~/bin 的人，那兩行就會印出 /home/<他的帳號>/...，而且 PASS 分支
# 照樣輸出。使用者按一次「複製診斷資訊」貼進聊天視窗，帳號名就外送了。
#
# 因此所有進入報告的文字都要先過這一層。這是對下游使用者的承諾，
# 不是可選的美化。
# ---------------------------------------------------------------------------
mask_home() {
    sed -E \
        -e 's#/home/[^/[:space:]"]+#/home/使用者#g' \
        -e 's#/mnt/c/Users/[^/[:space:]"]+#/mnt/c/Users/使用者#g' \
        -e 's#/Users/[^/[:space:]"]+#/Users/使用者#g' \
        -e 's#/root/#~/#g'
}

# 規則結果表。索引一致的平行陣列，順序即報告顯示順序。
RULE_ID=(); RULE_TITLE=(); RULE_STATUS=()
RULE_SYMPTOM=(); RULE_CONSEQ=(); RULE_FIX=(); RULE_DETAIL=(); RULE_ACTION=()

# add_rule <id> <標題> <狀態> <症狀> <後果> <修法> <詳細資料> [一句話行動]
# 狀態：PASS / WARN / FAIL / SKIP / INFO
#
# 第 8 個參數是給結論層用的「一句話行動」，可省略。
# 不能直接拿 <修法> 的第一行來當它 —— 修法常常以「兩條路，先試第一條：」
# 這種標題開頭，抓第一行會抓到標題而不是動作。
add_rule() {
    RULE_ID+=("$1"); RULE_TITLE+=("$2"); RULE_STATUS+=("$3")
    RULE_SYMPTOM+=("$4"); RULE_CONSEQ+=("$5"); RULE_FIX+=("$6")
    # 詳細資料是唯一會塞入系統原始輸出的欄位，統一在這裡過去識別化，
    # 集中一處比要求每條規則各自記得處理可靠。
    RULE_DETAIL+=("$(printf '%s' "$7" | mask_home)")
    RULE_ACTION+=("${8:-}")
}

# ---------------------------------------------------------------------------
# 後端抽象（規格 2.2 節）
#
# 偵測層分兩類：
#   後端無關 —— R0 / R4 / R5 / R8   （只碰 nvidia-smi / dpkg / 效能計數器）
#   後端相關 —— R1 / R2 / R3 / R6 / R9（需要向引擎問「載入了什麼、跑在哪」）
#
# 能力清單刻意設計成「可以不支援」。規格 2.2 的關鍵約束：
#   backend_offload_ratio（溢位比例）是一個可缺席的能力。
#   Ollama 從 ollama ps 的 PROCESSOR 欄直接給；LM Studio（未來的第二後端）
#   給不出來，只能退化成「判斷有無溢位但不給比例」。
#   第一版不實作退化路徑，但資料結構先留位置，之後加後端不必動 R1 的核心。
# ---------------------------------------------------------------------------

BACKEND=""          # 後端 id，空字串代表沒有偵測到任何後端
BACKEND_LABEL=""    # 給使用者看的名字
BACKEND_CAPS=""     # 空白分隔的能力清單

backend_use_ollama() {
    BACKEND="ollama"
    BACKEND_LABEL="Ollama"
    # detect       服務在不在
    # loaded       哪些模型已載入
    # model_size   模型檔案多大
    # offload_ratio溢位比例（Ollama 直接給，見 R1）
    # context      context 設定值
    # logs         有可解析的 runtime log（見 R9）
    BACKEND_CAPS="detect loaded model_size offload_ratio context logs"
}

# 未來的第二後端範例，保留簽章供參考，第一版不啟用：
#   backend_use_lmstudio() {
#       BACKEND="lmstudio"; BACKEND_LABEL="LM Studio"
#       # 注意：沒有 offload_ratio。R1 必須走退化路徑。
#       BACKEND_CAPS="detect loaded model_size context"
#   }

backend_has_cap() {
    case " ${BACKEND_CAPS} " in
        *" $1 "*) return 0 ;;
        *)        return 1 ;;
    esac
}

# ---------------------------------------------------------------------------
# 環境探測（各規則共用的原始資料，全部唯讀）
# ---------------------------------------------------------------------------

GPU_PRESENT=0
GPU_NAME=""; GPU_VRAM_TOTAL_MIB=0; GPU_VRAM_USED_MIB=0; GPU_DRIVER=""
GPU_PROBE_ERR=""

probe_gpu() {                                        # 規則 R0
    if ! have nvidia-smi; then
        GPU_PROBE_ERR="找不到 nvidia-smi 指令"
        return
    fi
    local out
    out="$(nvidia-smi --query-gpu=name,memory.total,memory.used,driver_version \
           --format=csv,noheader,nounits 2>&1)"
    if [ $? -ne 0 ] || [ -z "$out" ]; then
        GPU_PROBE_ERR="$(printf '%s' "$out" | head -3)"
        return
    fi
    # 多卡機器只取第 0 張（規格 R0 變體 3）
    IFS=',' read -r GPU_NAME GPU_VRAM_TOTAL_MIB GPU_VRAM_USED_MIB GPU_DRIVER \
        <<<"$(printf '%s' "$out" | head -1)"
    GPU_NAME="$(printf '%s' "$GPU_NAME" | sed 's/^ *//; s/ *$//')"
    GPU_VRAM_TOTAL_MIB="$(printf '%s' "$GPU_VRAM_TOTAL_MIB" | tr -dc '0-9')"
    GPU_VRAM_USED_MIB="$(printf '%s' "$GPU_VRAM_USED_MIB" | tr -dc '0-9')"
    GPU_DRIVER="$(printf '%s' "$GPU_DRIVER" | sed 's/^ *//; s/ *$//')"
    [ -n "$GPU_VRAM_TOTAL_MIB" ] && GPU_PRESENT=1
}

# 背景 VRAM 取樣。規格 R5：同日漂移超過 1.2 GB，單次取樣不可信，
# 必須取樣 3 次取中位數。
VRAM_USED_MEDIAN=0
VRAM_SAMPLES=""
probe_vram_median() {                                # 規則 R5
    [ "$GPU_PRESENT" -eq 1 ] || return
    local s1 s2 s3
    s1="$(nvidia-smi --query-gpu=memory.used --format=csv,noheader,nounits 2>/dev/null | head -1 | tr -dc '0-9')"
    sleep 0.3
    s2="$(nvidia-smi --query-gpu=memory.used --format=csv,noheader,nounits 2>/dev/null | head -1 | tr -dc '0-9')"
    sleep 0.3
    s3="$(nvidia-smi --query-gpu=memory.used --format=csv,noheader,nounits 2>/dev/null | head -1 | tr -dc '0-9')"
    VRAM_SAMPLES="${s1:-0} ${s2:-0} ${s3:-0}"
    VRAM_USED_MEDIAN="$(printf '%s\n' ${VRAM_SAMPLES} | sort -n | sed -n '2p')"
    [ -n "$VRAM_USED_MEDIAN" ] || VRAM_USED_MEDIAN="${GPU_VRAM_USED_MIB}"
}

# Ollama 服務與載入狀態
OLLAMA_BIN=""; OLLAMA_VERSION=""
SVC_WSL_UP=0; SVC_WSL_BODY=""
SVC_WIN_UP=0; SVC_WIN_BODY=""
LMSTUDIO_PORT_UP=0
PORT_11434_FOREIGN=0                                 # 有人監聽但回應不是 Ollama

probe_service() {                                    # 規則 R6
    OLLAMA_BIN="$(command -v ollama 2>/dev/null || true)"
    local body
    body="$(curl -s --max-time 3 http://localhost:11434/ 2>/dev/null)"
    if [ -n "$body" ]; then
        SVC_WSL_BODY="$body"
        case "$body" in
            *"Ollama is running"*) SVC_WSL_UP=1 ;;
            *)                     PORT_11434_FOREIGN=1 ;;   # port 被別的程式佔走
        esac
    fi
    if [ "$SVC_WSL_UP" -eq 1 ]; then
        OLLAMA_VERSION="$(curl -s --max-time 3 http://localhost:11434/api/version 2>/dev/null \
                          | sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')"
    fi
    # Windows 側：WSL 是 NAT 網路模式，localhost 不互通，必須走 interop
    if have powershell.exe; then
        SVC_WIN_BODY="$(powershell.exe -NoProfile -Command \
            "try{(Invoke-WebRequest -UseBasicParsing -TimeoutSec 2 http://localhost:11434/).Content}catch{'DOWN'}" \
            2>/dev/null | tr -d '\r\0')"
        case "$SVC_WIN_BODY" in *"Ollama is running"*) SVC_WIN_UP=1 ;; esac
    fi
    curl -s --max-time 2 http://localhost:1234/v1/models >/dev/null 2>&1 && LMSTUDIO_PORT_UP=1
}

# ollama ps 解析。實測欄位（規格 R1 變體 1、F4）：
#   NAME  ID  SIZE  PROCESSOR  CONTEXT  UNTIL
# SIZE 是「5.3 GB」兩個欄位，PROCESSOR 是「100% GPU」或「29%/71% CPU/GPU」兩個欄位。
MODEL_LOADED=0
M_NAME=""; M_SIZE_RAW=""; M_SIZE_MIB=0
M_PROC_RAW=""; M_CPU_PCT=0; M_GPU_PCT=100
M_CONTEXT=""
PS_RAW=""

gb_to_mib() { awk -v v="$1" 'BEGIN{printf "%.0f", v*1000000000/1048576}'; }
mb_to_mib() { awk -v v="$1" 'BEGIN{printf "%.0f", v*1000000/1048576}'; }

probe_loaded_model() {                               # 規則 R1 / R3
    backend_has_cap loaded || return
    [ "$SVC_WSL_UP" -eq 1 ] || return
    [ -n "$OLLAMA_BIN" ] || return
    PS_RAW="$(ollama ps 2>/dev/null)"
    local has_ctx=0 line
    printf '%s' "$PS_RAW" | head -1 | grep -q 'CONTEXT' && has_ctx=1
    line="$(printf '%s\n' "$PS_RAW" | sed -n '2p')"
    [ -n "${line// /}" ] || return                   # 只有表頭 = 沒有模型載入（F7）
    MODEL_LOADED=1
    M_NAME="$(awk '{print $1}' <<<"$line")"
    M_SIZE_RAW="$(awk '{print $3" "$4}' <<<"$line")"
    M_PROC_RAW="$(awk '{print $5" "$6}' <<<"$line")"
    [ "$has_ctx" -eq 1 ] && M_CONTEXT="$(awk '{print $7}' <<<"$line")"

    local n u
    n="$(awk '{print $3}' <<<"$line")"; u="$(awk '{print $4}' <<<"$line")"
    case "$u" in
        GB) M_SIZE_MIB="$(gb_to_mib "$n")" ;;
        MB) M_SIZE_MIB="$(mb_to_mib "$n")" ;;
        *)  M_SIZE_MIB=0 ;;
    esac

    # PROCESSOR 三態（規格 R1 變體 3）
    local pct kind
    pct="$(awk '{print $5}' <<<"$line")"; kind="$(awk '{print $6}' <<<"$line")"
    case "$kind" in
        GPU)     M_CPU_PCT=0;   M_GPU_PCT=100 ;;
        CPU)     M_CPU_PCT=100; M_GPU_PCT=0 ;;
        CPU/GPU) M_CPU_PCT="${pct%%/*}"; M_CPU_PCT="${M_CPU_PCT%\%}"
                 M_GPU_PCT="${pct##*/}"; M_GPU_PCT="${M_GPU_PCT%\%}" ;;
    esac
    M_CPU_PCT="$(printf '%s' "$M_CPU_PCT" | tr -dc '0-9')"; : "${M_CPU_PCT:=0}"
    M_GPU_PCT="$(printf '%s' "$M_GPU_PCT" | tr -dc '0-9')"; : "${M_GPU_PCT:=0}"
}

# 模型檔案大小（用於 R3 歸因：載入後大小 − 檔案大小 = context 的代價）
M_FILE_MIB=0
probe_model_file_size() {                            # 規則 R3
    backend_has_cap model_size || return
    [ "$MODEL_LOADED" -eq 1 ] || return
    local line n u
    line="$(ollama list 2>/dev/null | awk -v m="$M_NAME" '$1==m {print; exit}')"
    [ -n "$line" ] || return
    n="$(awk '{print $3}' <<<"$line")"; u="$(awk '{print $4}' <<<"$line")"
    case "$u" in
        GB) M_FILE_MIB="$(gb_to_mib "$n")" ;;
        MB) M_FILE_MIB="$(mb_to_mib "$n")" ;;
    esac
}

# R9：llama.cpp 的自動調整 log。這是比 ollama ps 更精確的第二來源。
R9_AVAILABLE=0
R9_LAYERS_ON=""; R9_LAYERS_TOTAL=""
R9_PROJECTED=""; R9_FREE=""
R9_RAW=""; R9_AGE=""

# 把秒數講成人話。空載時 R9 顯示的是歷史紀錄，必須讓使用者一眼知道「多久以前」。
humanize_age() {
    local s="$1"
    if   [ "$s" -lt 90 ];    then echo "不到 1 分鐘前"
    elif [ "$s" -lt 5400 ];  then echo "約 $(( (s + 30) / 60 )) 分鐘前"
    elif [ "$s" -lt 172800 ];then echo "約 $(( (s + 1800) / 3600 )) 小時前"
    else                          echo "約 $(( (s + 43200) / 86400 )) 天前"
    fi
}
probe_fit_log() {                                    # 規則 R9
    backend_has_cap logs || return
    have journalctl || return
    # 視窗要夠大：溢位時 llama.cpp 會多印十幾行 fitting 迭代，
    # 把最關鍵的 "projected to use ... vs ..." 擠出視窗外。
    # 用 tail -6 會導致「最需要缺口數字的溢位情境」反而抓不到，實測踩過。
    local log
    log="$(journalctl -u ollama --no-pager 2>/dev/null \
           | grep -E 'common_params_fit_impl|offloaded [0-9]+/[0-9]+ layers' | tail -60)"
    [ -n "$log" ] || return
    # 詳細資料只留有判讀價值的行，避免把十幾行迭代過程塞進報告。
    #
    # 同時抽掉 journalctl 預設格式裡的「主機名 ollama[PID]:」——
    # 主機名（例如 DESKTOP-XXXXXXX）是可識別資訊，而這段 log 會原樣
    # 進入報告的詳細資料區與「複製診斷資訊」文字，也就是使用者被鼓勵
    # 貼給 AI 的那份。時間戳與訊息本體全部保留，R9 的判讀不受影響。
    R9_RAW="$(printf '%s\n' "$log" \
              | grep -E 'projected to use|will leave|offloaded [0-9]+/[0-9]+ layers|layers, .* MiB used' \
              | sed -E 's/ [^ ]+ ollama\[[0-9]+\]:/ ollama:/' \
              | tail -6)"
    [ -n "$R9_RAW" ] || R9_RAW="$(printf '%s\n' "$log" \
              | sed -E 's/ [^ ]+ ollama\[[0-9]+\]:/ ollama:/' | tail -6)"
    local off proj
    off="$(printf '%s\n' "$log" | grep -oE 'offloaded [0-9]+/[0-9]+ layers' | tail -1)"
    if [ -n "$off" ]; then
        R9_LAYERS_ON="$(sed -E 's/offloaded ([0-9]+)\/([0-9]+).*/\1/' <<<"$off")"
        R9_LAYERS_TOTAL="$(sed -E 's/offloaded ([0-9]+)\/([0-9]+).*/\2/' <<<"$off")"
        R9_AVAILABLE=1
    fi
    # 取最後一次載入事件的時間戳，用來標示「這是多久以前的紀錄」
    local ts now
    ts="$(journalctl -u ollama --no-pager -o short-unix 2>/dev/null \
          | grep -E 'offloaded [0-9]+/[0-9]+ layers' | tail -1 | awk '{print $1}' | cut -d. -f1)"
    if [ -n "$ts" ]; then
        now="$(date +%s)"
        [ "$now" -ge "$ts" ] && R9_AGE="$(humanize_age $(( now - ts )))"
    fi
    proj="$(printf '%s\n' "$log" | grep -oE 'projected to use [0-9]+ MiB of device memory vs\. [0-9]+ MiB' | tail -1)"
    if [ -n "$proj" ]; then
        R9_PROJECTED="$(grep -oE 'projected to use [0-9]+' <<<"$proj" | tr -dc '0-9')"
        R9_FREE="$(grep -oE 'vs\. [0-9]+' <<<"$proj" | tr -dc '0-9')"
        R9_AVAILABLE=1
    fi
}

# R5：誰在吃 VRAM。
# 兩個 counter 的可信度完全不同（規格 R5 變體 2 / U6）：
#   GPU Adapter Memory（整張卡）  與 nvidia-smi 吻合 0.1% 以內 → 可信，用於總量
#   GPU Process Memory（單程序）  加總會超過實際總量        → 只能用於排名
ADAPTER_MIB=""
PROC_RANK=""            # 每行：<程序名>\t<MB>\t<可否建議關閉>
probe_vram_consumers() {                             # 規則 R5
    have powershell.exe || return
    ADAPTER_MIB="$(powershell.exe -NoProfile -Command \
        "(Get-Counter '\\GPU Adapter Memory(*)\\Dedicated Usage' -ErrorAction SilentlyContinue | Select-Object -ExpandProperty CounterSamples | Sort-Object CookedValue -Descending | Select-Object -First 1).CookedValue" \
        2>/dev/null | tr -d '\r\0' | awk 'NF{printf "%.0f", $1/1048576; exit}')"
    local raw
    raw="$(powershell.exe -NoProfile -Command \
        "Get-Counter '\\GPU Process Memory(*)\\Dedicated Usage' -ErrorAction SilentlyContinue | Select-Object -ExpandProperty CounterSamples | Where-Object {\$_.CookedValue -gt 200MB} | Sort-Object CookedValue -Descending | Select-Object -First 8 | ForEach-Object { \$p=[int](\$_.InstanceName -replace 'pid_(\d+).*','\$1'); '{0}|{1:N0}' -f (Get-Process -Id \$p -ErrorAction SilentlyContinue).ProcessName, (\$_.CookedValue/1MB) }" \
        2>/dev/null | tr -d '\r\0')"
    [ -n "$raw" ] || return

    # 同一個程序在每個 GPU adapter 上各有一個 instance（獨顯一個、內顯一個），
    # 不去重的話同一個程式會在清單裡出現兩次。已按用量降冪排序，取第一筆即可。
    raw="$(printf '%s\n' "$raw" | awk -F'|' '!seen[$1]++')"

    local line pname pmb closable
    while IFS= read -r line; do
        [ -n "${line// /}" ] || continue
        pname="${line%%|*}"; pmb="${line##*|}"
        [ -n "$pname" ] || pname="(未知程序)"
        closable="$(process_closable "$pname")"
        PROC_RANK+="${pname}	${pmb}	${closable}
"
    done <<<"$raw"
}

# ---------------------------------------------------------------------------
# R5 的排除規則（規格「vmwp 排除規則」，實作必做）
#
# WSL 裡跑的模型，其 VRAM 在 Windows 側全部記在 vmwp（虛擬機工作程序）名下，
# 而且穩居第一名。建議關掉它 = 叫使用者關掉自己的模型，還會連 WSL 一起關掉。
# 這是整份規格裡唯一一條「沒做會主動造成傷害」的規則。
# ---------------------------------------------------------------------------
process_closable() {
    case "$1" in
        vmwp|vmmem|vmmemWSL) echo "no" ;;    # WSL 虛擬機 = 很可能就是使用者的模型
        dwm|System|Registry|csrss|winlogon) echo "no" ;;   # 系統元件，關不掉
        *) echo "yes" ;;
    esac
}

process_friendly() {
    case "$1" in
        vmwp|vmmem|vmmemWSL) echo "WSL 內的程式（很可能就是你的本地模型）" ;;
        dwm)                 echo "Windows 桌面特效" ;;
        "NVIDIA Overlay"|"NVIDIA App") echo "NVIDIA App 的遊戲overlay" ;;
        Roon|roon)           echo "Roon 音樂播放器" ;;
        chrome)              echo "Chrome 瀏覽器" ;;
        msedge)              echo "Edge 瀏覽器" ;;
        firefox)             echo "Firefox 瀏覽器" ;;
        steamwebhelper)      echo "Steam" ;;
        wallpaper64|wallpaper32) echo "Wallpaper Engine 動態桌布" ;;
        Discord)             echo "Discord" ;;
        System|Registry)     echo "Windows 系統元件" ;;
        *)                   echo "$1" ;;
    esac
}

# ---------------------------------------------------------------------------
# 規則實作
# ---------------------------------------------------------------------------

rule_r0() {                                          # R0 前置盤點
    if [ "$GPU_PRESENT" -eq 1 ]; then
        add_rule "R0" "顯示卡偵測" "PASS" \
            "找到你的顯示卡了。" \
            "型號是 ${GPU_NAME}，顯示卡記憶體 $(awk -v v="$GPU_VRAM_TOTAL_MIB" 'BEGIN{printf "%.1f", v/1024}') GB。後續的顯示卡相關檢查都會依這張卡計算。" \
            "" \
            "GPU: ${GPU_NAME}
VRAM total: ${GPU_VRAM_TOTAL_MIB} MiB
Driver: ${GPU_DRIVER}"
    else
        add_rule "R0" "顯示卡偵測" "SKIP" \
            "未偵測到支援的顯示卡。" \
            "這個版本只支援 NVIDIA 顯示卡，所以跟顯示卡有關的檢查（模型放不放得下、有沒有別的程式佔用顯存）會全部跳過。其餘檢查照常進行。" \
            "多數情況下不需要做任何事。如果你確定這台電腦裝了 NVIDIA 顯示卡，往下看「WSL 顯示卡支援狀態」那一項列出的三種可能。" \
            "nvidia-smi probe: ${GPU_PROBE_ERR:-無法取得輸出}"
    fi
}

rule_r8() {                                          # R8 安裝中途失敗（缺 zstd）
    if [ -n "$OLLAMA_BIN" ]; then
        return 0                                     # 裝好了，本條不適用
    fi
    # 路徑做成可覆寫，只為了讓這條分支能在不動系統狀態的前提下測試。
    local dir="${OLLAMA_LIBDIR:-/usr/local/lib/ollama}" dir_empty=0 zstd_missing=0
    [ -d "$dir" ] && [ -z "$(ls -A "$dir" 2>/dev/null)" ] && dir_empty=1
    have zstd || zstd_missing=1

    if [ "$dir_empty" -eq 1 ] && [ "$zstd_missing" -eq 1 ]; then
        add_rule "R8" "Ollama 安裝中途失敗" "FAIL" \
            "你照官方教學貼過安裝指令，看起來跑完了，但打 ollama 會說找不到指令。" \
            "Ollama 根本沒裝起來，什麼都不能用。安裝其實中途就停了——它需要一個叫 zstd 的解壓縮小工具，而你的系統沒有。錯誤訊息當時有印出來，但會被前面的輸出蓋過去，很容易漏看。" \
            "補裝那個小工具，再重跑一次安裝：
sudo apt-get install zstd
curl -fsSL https://ollama.com/install.sh | sh" \
            "${dir} 存在且為空
zstd: 未安裝
判定依據：安裝腳本會先建目錄再下載解壓，缺 zstd 時在解壓階段中止" \
            "先補裝 zstd 這個小工具，再重新安裝一次 Ollama"
    elif [ "$dir_empty" -eq 1 ]; then
        add_rule "R8" "Ollama 安裝中途失敗" "FAIL" \
            "你裝過 Ollama，但沒裝完。" \
            "安裝在中途停掉了，留下一個空資料夾。Ollama 目前不能用。" \
            "重跑一次安裝指令，這次注意看有沒有紅色的錯誤訊息：
curl -fsSL https://ollama.com/install.sh | sh" \
            "${dir} 存在且為空；zstd 已安裝（所以不是 zstd 造成的）" \
            "重跑一次官方安裝指令"
    else
        add_rule "R8" "Ollama 是否安裝" "FAIL" \
            "找不到 Ollama。" \
            "這個工具是設計來診斷 Ollama 的，沒有它就沒東西可以檢查。" \
            "先安裝 Ollama（Ubuntu 使用者建議連 zstd 一起裝，否則安裝會中途失敗）：
sudo apt-get install zstd
curl -fsSL https://ollama.com/install.sh | sh" \
            "command -v ollama: 找不到
${dir}: $( [ -d "$dir" ] && echo '存在（非空）' || echo '不存在' )
zstd: $(have zstd && echo '已安裝' || echo '未安裝')" \
            "先安裝 Ollama"
    fi
}

rule_r6() {                                          # R6 服務沒起來 / port 被佔用
    [ -n "$OLLAMA_BIN" ] || return 0                 # 沒安裝的情況由 R8 處理
    if [ "$PORT_11434_FOREIGN" -eq 1 ]; then
        local who
        who="$( (have ss && ss -ltnp "sport = :11434" 2>/dev/null | tail -n +2) || echo "（需要 ss 指令才能查出程式名）")"
        add_rule "R6" "Ollama 服務" "FAIL" \
            "有別的程式佔用了 Ollama 要用的門牌號碼（11434）。" \
            "Ollama 連不上自己的門，聊天介面會一直轉圈圈或顯示連線錯誤。這跟「慢」無關——它根本沒在計算。" \
            "先找出佔用的程式是誰，決定要關掉它還是換 Ollama 的門牌：
ss -ltnp 'sport = :11434'" \
            "port 11434 有回應但內容不是 Ollama。
回應開頭：$(printf '%s' "$SVC_WSL_BODY" | head -c 120)
${who}" \
            "找出佔用 11434 這個門牌的程式並關掉它"
        return
    fi
    if [ "$SVC_WSL_UP" -eq 0 ]; then
        add_rule "R6" "Ollama 服務" "FAIL" \
            "Ollama 的背景服務沒有在跑。" \
            "沒有服務就沒有任何東西在計算，聊天介面會一直轉圈圈或連不上。這要先修好，其他問題才談得下去。" \
            "啟動服務：
sudo systemctl start ollama" \
            "curl http://localhost:11434/ 連線被拒（無回應）
systemctl is-active ollama: $(systemctl is-active ollama 2>/dev/null || echo '查詢失敗')" \
            "執行 sudo systemctl start ollama 把服務打開"
        return
    fi
    if [ "$SVC_WIN_UP" -eq 1 ]; then
        add_rule "R6" "Ollama 服務" "WARN" \
            "你的電腦上同時跑著兩套 Ollama：一套在 WSL 裡，一套在 Windows 上。" \
            "兩套各自存放模型，互相看不到對方的。最常見的症狀是「我明明下載過那個模型，怎麼不見了」——其實是下載到另一套去了。" \
            "決定只留一套。建議留 WSL 這套（這個工具檢查的就是它），然後在 Windows 的工作管理員裡結束 Ollama，並取消它的開機自動啟動。" \
            "WSL 側 11434：Ollama is running
Windows 側 11434：Ollama is running" \
            "在 Windows 那一側關掉 Ollama，只留 WSL 這一套"
        return
    fi
    add_rule "R6" "Ollama 服務" "PASS" \
        "Ollama 服務正常運作中。" \
        "版本 ${OLLAMA_VERSION:-未知}，門牌 11434 回應正常。$( [ "$LMSTUDIO_PORT_UP" -eq 1 ] && echo ' 另外偵測到 LM Studio 也在執行（門牌 1234）——這個版本的深度診斷只支援 Ollama。' )" \
        "" \
        "curl http://localhost:11434/ → Ollama is running
version: ${OLLAMA_VERSION:-未取得}
Windows 側 11434: $( [ "$SVC_WIN_UP" -eq 1 ] && echo '也在跑' || echo '沒有（正常）' )
LM Studio 1234: $( [ "$LMSTUDIO_PORT_UP" -eq 1 ] && echo '有回應' || echo '沒有' )"
}

rule_r1_r2() {                                       # R1 溢位 ＋ R2 全 CPU
    [ -n "$OLLAMA_BIN" ] || return 0
    [ "$SVC_WSL_UP" -eq 1 ] || return 0

    if [ "$MODEL_LOADED" -eq 0 ]; then
        # 這是外部實測暴露的最大缺口：兩台受測機器都空載，
        # 導致 R1/R3/R5 一條都沒跑到。所以這裡要主動把使用者導向 --live。
        add_rule "R1" "模型跑在哪裡" "SKIP" \
            "目前沒有模型在執行，所以沒辦法看它跑在顯示卡還是 CPU 上。" \
            "這不是問題，但也代表這次檢查看不到最關鍵的部分。想看完整診斷，有兩個辦法。" \
            "最簡單：改成雙擊「run-live.bat」，它會自動載入一個小模型實際跑一次再檢查。

或者你自己讓模型回答一句話，然後在 5 分鐘內重跑這個檢查：
ollama run llama3.1:8b" \
            "ollama ps 只有表頭，沒有載入中的模型
（Ollama 預設閒置 5 分鐘後會自動卸載模型）
在 WSL 終端機裡的等效指令：./check.sh --live" \
            "改用 run-live.bat（或 ./check.sh --live）做完整檢查"
        return
    fi

    # 溢位比例：這個能力可以不被後端支援（規格 2.2）。
    # Ollama 支援；若換成不支援的後端，這裡會退化成「只判斷有無溢位」。
    if ! backend_has_cap offload_ratio; then
        add_rule "R1" "模型跑在哪裡" "INFO" \
            "目前這個引擎沒辦法告訴我們模型有多少比例被擠到 CPU。" \
            "只能判斷有沒有溢位，給不出嚴重程度。" \
            "" \
            "backend=${BACKEND} 不具備 offload_ratio 能力（規格 2.2 的退化路徑）"
        return
    fi

    local detail
    detail="ollama ps: ${M_NAME}  ${M_SIZE_RAW}  ${M_PROC_RAW}  context=${M_CONTEXT:-未知}
換算：載入大小 ${M_SIZE_MIB} MiB，CPU ${M_CPU_PCT}% / GPU ${M_GPU_PCT}%"
    if [ "$R9_AVAILABLE" -eq 1 ] && [ -n "$R9_LAYERS_ON" ]; then
        detail="${detail}
R9 佐證：offloaded ${R9_LAYERS_ON}/${R9_LAYERS_TOTAL} layers to GPU"
    fi

    # R2：完全跑在 CPU
    if [ "$M_CPU_PCT" -ge 100 ]; then
        # 偵測不到 NVIDIA 卡時，「跑在 CPU 上」是預期結果而不是故障。
        # 這裡原本一律判 FAIL 並要求「先解決顯示卡驅動的問題」，對一台
        # 本來就沒有 N 卡的機器來說是跟 R4 同一類的自信錯誤建議，
        # 所以在無 GPU 的前提下降為 INFO 並改寫文案。
        if [ "$GPU_PRESENT" -eq 0 ]; then
            add_rule "R2" "模型跑在 CPU 上" "INFO" \
                "模型完全用 CPU 在跑。這台機器上偵測不到 NVIDIA 顯示卡，所以這是預期的結果，不是故障。" \
                "純用 CPU 跑會明顯比有顯示卡慢，這是硬體的差距，不是設定沒調好。如果你確定這台有 NVIDIA 顯示卡，往下看「WSL 顯示卡支援狀態」那一項的三種可能。" \
                "沒有 NVIDIA 顯示卡的話，能做的是換更小的模型讓它跑得動一些：
ollama run llama3.2:1b" \
                "$detail" \
                "換一個更小的模型"
            return
        fi
        add_rule "R2" "完全跑在 CPU 上" "FAIL" \
            "模型完全用 CPU 在跑，顯示卡沒有出力。" \
            "這是最嚴重的一種慢。CPU 讀取資料的速度大約只有顯示卡的十分之一，實際體感通常是慢上好幾倍到十幾倍。顯示卡本身是好的，是 Ollama 沒有認到它。" \
            "先重啟服務試試：
sudo systemctl restart ollama

還是不行就更新 Ollama：
curl -fsSL https://ollama.com/install.sh | sh" \
            "$detail" \
            "執行 sudo systemctl restart ollama"
        return
    fi

    # R1：部分溢位。分級門檻依規格（實測 29% → 3.3 倍、82% → 8.7 倍，中間為內插）
    if [ "$M_CPU_PCT" -eq 0 ]; then
        add_rule "R1" "模型跑在哪裡" "PASS" \
            "模型完整放進顯示卡裡了。" \
            "這是最理想的狀態，速度不會被記憶體拖累。" \
            "" \
            "$detail"
    elif [ "$M_CPU_PCT" -le 15 ]; then
        add_rule "R1" "模型放不進顯示卡" "WARN" \
            "模型有一小部分（約 ${M_CPU_PCT}%）放不進顯示卡，被擠到主記憶體用 CPU 跑。" \
            "會變慢，但還不算嚴重。參考本機實測：約三成被擠出去時會慢 3.3 倍，你目前遠低於這個程度。" \
            "先看下面「其他程式佔用顯示卡記憶體」那一項——通常關掉一兩個程式就能全部放回顯示卡，不需要換模型。" \
            "$detail" \
            "先關掉一兩個佔用顯示卡記憶體的程式"
    elif [ "$M_CPU_PCT" -le 50 ]; then
        add_rule "R1" "模型放不進顯示卡" "FAIL" \
            "模型有大約 ${M_CPU_PCT}% 放不進顯示卡，被擠到主記憶體用 CPU 跑。" \
            "這不是「稍微慢一點」。本機實測：約三成被擠出去時，速度掉到原本的三分之一（慢 3.3 倍）——原本三秒回答完的，要等十秒。" \
            "兩條路，先試第一條：
1. 看下面「其他程式佔用顯示卡記憶體」，關掉佔用的程式
2. 換小一號的模型，例如 7B/8B 換成更低的量化版本" \
            "$detail" \
            "先關掉佔用顯示卡記憶體的程式，不夠再換小一號的模型"
    else
        add_rule "R1" "模型放不進顯示卡" "FAIL" \
            "模型有大約 ${M_CPU_PCT}% 放不進顯示卡，大部分都在用 CPU 跑。" \
            "非常慢。本機實測：約八成被擠出去時，速度掉到原本的九分之一（慢 8.7 倍）——原本三秒的回答要等半分鐘。" \
            "這個程度光靠關程式救不回來，換一個小一號的模型比較實際：
ollama run llama3.2:3b" \
            "$detail" \
            "換一個小一號的模型"
    fi
}

rule_r3() {                                          # R3 context 開太大
    [ -n "$OLLAMA_BIN" ] || return 0
    [ "$GPU_PRESENT" -eq 1 ] || return 0
    backend_has_cap context || return 0
    if [ "$MODEL_LOADED" -eq 0 ]; then
        add_rule "R3" "對話長度設定" "SKIP" \
            "沒有模型在執行，所以查不到目前的對話長度設定。" \
            "對話長度（能記住多少內容）只有在模型載入時才問得到。" \
            "" \
            "需要有模型在載入狀態才能檢查本項"
        return 0
    fi

    local ctx="${M_CONTEXT:-0}"
    ctx="$(printf '%s' "$ctx" | tr -dc '0-9')"; : "${ctx:=0}"
    local kv_mib=$(( M_SIZE_MIB - M_FILE_MIB ))
    [ "$kv_mib" -lt 0 ] && kv_mib=0
    local kv_share=0
    [ "$M_SIZE_MIB" -gt 0 ] && kv_share=$(( kv_mib * 100 / M_SIZE_MIB ))
    local threshold=$(( GPU_VRAM_TOTAL_MIB * 9 / 10 ))

    local detail="context 設定：${ctx}
載入後大小：${M_SIZE_MIB} MiB；模型檔案：${M_FILE_MIB} MiB
差額（對話記憶的代價）：${kv_mib} MiB，佔載入大小 ${kv_share}%
顯示卡記憶體總量：${GPU_VRAM_TOTAL_MIB} MiB（PASS 門檻 ${threshold} MiB）"

    if [ "$M_SIZE_MIB" -gt "$GPU_VRAM_TOTAL_MIB" ]; then
        if [ "$kv_share" -gt 35 ]; then
            add_rule "R3" "對話長度設定過大" "FAIL" \
                "你把「對話能記多長」設得太大了（目前 ${ctx}），光是存放對話記憶就吃掉 $(awk -v v="$kv_mib" 'BEGIN{printf "%.1f", v/1024}') GB 的顯示卡記憶體。" \
                "整個模型加上對話記憶已經超過顯示卡的容量，所以有一部分被擠到 CPU 上跑（見上面那一項）。調小對話長度比換模型划算——你不會損失模型的能力，只是它記得的對話短一點。" \
                "把對話長度調回 8192。開始對話後輸入：
/set parameter num_ctx 8192

想永久生效的話，改服務設定（需要重啟服務）：
sudo mkdir -p /etc/systemd/system/ollama.service.d && printf '[Service]\nEnvironment=\"OLLAMA_CONTEXT_LENGTH=8192\"\n' | sudo tee /etc/systemd/system/ollama.service.d/ctx.conf && sudo systemctl daemon-reload && sudo systemctl restart ollama" \
                "$detail" \
                "把對話長度調回 8192"
        else
            add_rule "R3" "對話長度設定" "WARN" \
                "模型本身就比顯示卡裝得下的還大，跟對話長度關係不大。" \
                "對話記憶只佔載入大小的 ${kv_share}%，主因是模型本身。調小對話長度幫助有限。" \
                "換一個小一號的模型會比較有效，作法見上面「模型放不進顯示卡」那一項。" \
                "$detail" \
                "換一個小一號的模型"
        fi
    elif [ "$ctx" -gt 8192 ]; then
        add_rule "R3" "對話長度設定" "WARN" \
            "對話長度設得比較大（${ctx}），目前還放得進顯示卡，但已經在付代價。" \
            "本機實測：對話長度從 4096 開到 65536，即使完全沒有溢位，速度仍然掉了 16%。對話記憶越大，每產生一個字要掃過的資料就越多。如果你不需要這麼長的記憶，調小會比較快。" \
            "想換速度的話，調回 8192：
/set parameter num_ctx 8192" \
            "$detail" \
            "把對話長度調回 8192"
    else
        # 若 R1 已判定溢位，這裡不能說「整體放得進顯示卡」——會與 R1 互相矛盾。
        # 這種情形代表擁擠的原因不是對話長度（例如被 num_gpu 之類的設定限制住）。
        local conseq="對話記憶佔用 $(awk -v v="$kv_mib" 'BEGIN{printf "%.1f", v/1024}') GB，模型整體放得進顯示卡。"
        [ "$M_CPU_PCT" -gt 0 ] && \
            conseq="對話記憶只佔 $(awk -v v="$kv_mib" 'BEGIN{printf "%.1f", v/1024}') GB，以這張卡的容量來說綽綽有餘。所以上面那項「模型放不進顯示卡」的原因不是對話長度，調小它不會有幫助。"
        add_rule "R3" "對話長度設定" "PASS" \
            "對話長度設定正常（${ctx}）。" \
            "$conseq" \
            "" \
            "$detail"
    fi
}

rule_r9() {                                          # R9 直接解析溢位判定 log
    [ -n "$OLLAMA_BIN" ] || return 0
    # 雙來源結構：R9 抓不到就退回 ollama ps（硬性要求）
    if [ "$R9_AVAILABLE" -eq 0 ]; then
        local fallback="退回 ollama ps 判定"
        [ "$MODEL_LOADED" -eq 1 ] || fallback="退回 ollama ps 判定（但目前也沒有模型載入）"
        add_rule "R9" "詳細層數資訊" "INFO" \
            "拿不到引擎的詳細載入紀錄，改用另一個來源判斷。" \
            "不影響診斷結果。上面關於「模型跑在哪裡」的判定改用 ollama ps 的資料，只是少了精確到「幾層」的細節。" \
            "" \
            "journalctl -u ollama 沒有 common_params_fit_impl / offloaded 相關行
可能原因：服務剛啟動還沒載入過模型、log 已輪替、或這個版本的字串改了
${fallback}"
        return
    fi
    # log 是歷史紀錄，模型卸載後仍留著。沒有模型在跑時，絕不可把它當成現況呈現。
    #
    # 這裡刻意「保留並標註時態」而不是直接 SKIP：Ollama 預設閒置 5 分鐘就卸載模型，
    # 而使用者的典型流程是「覺得慢 → 去找工具 → 跑起來」，很容易超過 5 分鐘。
    # 那時候這份歷史紀錄是唯一還留著的證據，SKIP 會讓最需要診斷的情境變成一片空白。
    local when="引擎的紀錄顯示：" tense="這就是上面那項判定的來源。"
    if [ "$MODEL_LOADED" -eq 0 ]; then
        when="以下是最近一次模型載入的紀錄（${R9_AGE:-時間不明}），不是目前的狀態——現在沒有模型在跑："
        tense="這是${R9_AGE:-稍早}的紀錄，不代表現在。如果你剛才覺得慢，這筆紀錄很可能就是當時的情況。"
    fi

    local status="PASS" symptom conseq
    if [ -n "$R9_LAYERS_ON" ] && [ -n "$R9_LAYERS_TOTAL" ] \
       && [ "$R9_LAYERS_ON" -lt "$R9_LAYERS_TOTAL" ]; then
        status="INFO"
        symptom="${when}模型有 ${R9_LAYERS_ON} 層放進顯示卡，總共 ${R9_LAYERS_TOTAL} 層。"
        conseq="剩下的 $(( R9_LAYERS_TOTAL - R9_LAYERS_ON )) 層在 CPU 上跑。${tense}"
    else
        status="INFO"
        [ "$MODEL_LOADED" -eq 1 ] && status="PASS"
        symptom="${when}模型 ${R9_LAYERS_TOTAL:-全部} 層全部放進顯示卡。"
        conseq="沒有任何一層被擠到 CPU。${tense}"
    fi
    local gap=""
    if [ -n "$R9_PROJECTED" ] && [ -n "$R9_FREE" ]; then
        if [ "$R9_PROJECTED" -gt "$R9_FREE" ]; then
            gap="上次載入時，需要 ${R9_PROJECTED} MiB 但只有 ${R9_FREE} MiB 可用，差 $(( R9_PROJECTED - R9_FREE )) MiB。"
        else
            gap="上次載入時，需要 ${R9_PROJECTED} MiB，可用 ${R9_FREE} MiB，夠用。"
        fi
    fi
    add_rule "R9" "詳細層數資訊" "$status" "$symptom" "${conseq}${gap:+ $gap}" "" \
        "$R9_RAW"
}

rule_r5() {                                          # R5 其他程式佔用 VRAM
    [ "$GPU_PRESENT" -eq 1 ] || return 0

    local others_mib=-1
    # --live 模式下，載入模型「之前」量到的背景 VRAM 是實測值，
    # 比從載入後的總量推算扣除模型準確，優先採用。
    if [ -n "$PRELOAD_OTHERS_MIB" ]; then
        others_mib="$PRELOAD_OTHERS_MIB"
    elif [ "$MODEL_LOADED" -eq 1 ] && [ "$M_SIZE_MIB" -gt 0 ]; then
        # 規格 R5：模型在 GPU 上的部分 ≈ SIZE × GPU% + 250 MiB（U12 驗證，殘差 +223~280）
        local model_on_gpu
        model_on_gpu="$(awk -v s="$M_SIZE_MIB" -v p="$M_GPU_PCT" 'BEGIN{printf "%.0f", s*p/100+250}')"
        others_mib=$(( VRAM_USED_MEDIAN - model_on_gpu ))
        [ "$others_mib" -lt 0 ] && others_mib=0
    else
        others_mib="$VRAM_USED_MEDIAN"
    fi

    # 排除清單（vmwp / dwm / 系統元件）不進入「可以關掉」的建議名單，
    # 否則會叫使用者關掉自己的模型或關不掉的系統元件。
    local top_name="" closable_list="" excluded_list="" top_line=""
    if [ -n "$PROC_RANK" ]; then
        while IFS=$'\t' read -r pname pmb closable; do
            [ -n "$pname" ] || continue
            local friendly; friendly="$(process_friendly "$pname")"
            if [ "$closable" = "no" ]; then
                excluded_list="${excluded_list}${friendly}
"
            else
                closable_list="${closable_list}${friendly}
"
                [ -n "$top_name" ] || top_name="$friendly"
            fi
        done <<<"$PROC_RANK"
        top_line="$(printf '%s' "$closable_list" | head -3 | paste -sd'、' -)"
    fi

    local detail="nvidia-smi 取樣三次（MiB）：${VRAM_SAMPLES} → 中位數 ${VRAM_USED_MEDIAN}
GPU Adapter Memory（可信，用於總量）：${ADAPTER_MIB:-未取得} MiB
估算其他程式佔用：${others_mib} MiB
⚠ 以下清單含你桌面上的程式名稱，貼給他人前請自行確認。
GPU Process Memory 排名（僅供排序，數值會膨脹，不可當絕對值）：
$(printf '%s' "$PROC_RANK" | awk -F'\t' 'NF{printf "  %-24s %8s MB  %s\n", $1, $2, ($3=="no"?"[排除]":"")}')"

    # 第二段：只有 R1 實際觸發溢位時才升級為警告，並串起因果（規格 R5 兩段式）
    if [ "$MODEL_LOADED" -eq 1 ] && [ "$M_CPU_PCT" -gt 0 ] && [ "$others_mib" -gt 0 ]; then
        local avail=$(( GPU_VRAM_TOTAL_MIB - others_mib ))
        local gap=$(( M_SIZE_MIB - avail ))
        if [ "$gap" -gt 0 ]; then
            local hint="關掉一些不用的程式，可能就能把模型完整放進顯示卡。"
            [ -n "$top_name" ] && hint="目前佔用最多、而且可以關掉的是「${top_name}」——關掉它很可能就解決了。"
            add_rule "R5" "其他程式佔用顯示卡記憶體" "WARN" \
                "你的模型需要 $(awk -v v="$M_SIZE_MIB" 'BEGIN{printf "%.1f", v/1024}') GB，這張卡有 $(awk -v v="$GPU_VRAM_TOTAL_MIB" 'BEGIN{printf "%.1f", v/1024}') GB，但現在有 $(awk -v v="$others_mib" 'BEGIN{printf "%.1f", v/1024}') GB 被其他程式佔著，所以差 $(awk -v v="$gap" 'BEGIN{printf "%.1f", v/1024}') GB 塞不下。" \
                "這就是上面「模型放不進顯示卡」的原因。${hint}" \
                "關掉不用的程式；瀏覽器可以只關硬體加速（設定 → 系統 → 關閉「使用硬體加速」），不必整個關掉。
※ 清單裡標示「不建議關閉」的請不要動——那是 WSL 本身或 Windows 系統元件。" \
                "$detail" \
                "${top_name:+關掉「${top_name}」試試}"
            return
        fi
    fi

    # 第一段：平常只顯示資訊，不判定好壞（規格 R5：絕對門檻與比例門檻都是假訊號）
    local excl_note=""
    [ -n "$excluded_list" ] && excl_note=" 另外有 $(printf '%s' "$excluded_list" | paste -sd'、' -) 也佔著顯存，但那些不該關掉。"
    add_rule "R5" "其他程式佔用顯示卡記憶體" "INFO" \
        "目前有 $(awk -v v="$others_mib" 'BEGIN{printf "%.1f", v/1024}') GB 顯示卡記憶體被其他程式使用中。" \
        "${top_line:+可以關掉的當中，佔用較多的是：${top_line}。}這不一定是問題——只有當模型塞不下時才需要處理。${excl_note}" \
        "" \
        "$detail"
}

rule_r4() {                                          # R4 WSL 驅動裝錯（只做偵測）
    local dxg=0 pkgs="" which_first="" ld=""
    [ -e /dev/dxg ] && dxg=1
    pkgs="$(dpkg -l 2>/dev/null | grep -E '^ii +(nvidia-|libnvidia-)' | awk '{print $2}' | paste -sd' ' -)"
    # 注意：bash 的 `command -v` 不支援 -a，必須用 `type -aP` 才能列出 PATH 中的所有同名執行檔。
    # 這一行是 R4 的核心：誤裝 Linux 驅動時 /usr/bin/nvidia-smi 會排在 WSL 版之前。
    which_first="$(type -aP nvidia-smi 2>/dev/null | head -1)"
    local which_all; which_all="$(type -aP nvidia-smi 2>/dev/null | paste -sd' ' -)"
    ld="$(ldconfig -p 2>/dev/null | grep -m1 'libcuda.so.1' | sed 's/^[[:space:]]*//')"

    local detail="/dev/dxg：$( [ "$dxg" -eq 1 ] && echo '存在' || echo '不存在' )
nvidia-smi 全部路徑：${which_all:-找不到}
  → 第一個（實際會執行的）：${which_first:-找不到}
  → 期望值：/usr/lib/wsl/lib/nvidia-smi
dpkg 的 nvidia 套件：${pkgs:-無（正常）}
ldconfig libcuda：${ld:-未找到}"

    if [ -n "$pkgs" ] || { [ -n "$which_first" ] && [ "$which_first" != "/usr/lib/wsl/lib/nvidia-smi" ]; }; then
        add_rule "R4" "WSL 顯示卡驅動" "FAIL" \
            "你在 WSL 裡面裝了 Linux 版的顯示卡驅動，那會蓋掉 Windows 幫你準備好的那一份。" \
            "顯示卡會完全用不到，所有模型都會退回 CPU 跑（最慢的那種情況）。正確做法是：驅動只裝在 Windows 那一側，WSL 裡面什麼都不用裝。" \
            "把 WSL 裡誤裝的驅動套件移除：
sudo apt-get purge -y '^nvidia-.*' '^libnvidia-.*' && sudo apt-get autoremove -y && hash -r

然後在 Windows 的 PowerShell 執行 wsl --shutdown，再重開 WSL。" \
            "$detail" \
            "移除 WSL 裡誤裝的 nvidia 驅動套件"
        return
    fi
    if [ "$dxg" -eq 0 ]; then
        add_rule "R4" "WSL 顯示卡驅動" "FAIL" \
            "WSL 這邊看不到顯示卡的通道，等於顯示卡沒有接進來。" \
            "所有模型都只能用 CPU 跑。常見原因是 WSL 版本太舊，或這台還在用舊版的 WSL1。" \
            "在 Windows 的 PowerShell 執行：
wsl --update

然後 wsl --shutdown 再重開。" \
            "$detail" \
            "在 Windows 的 PowerShell 執行 wsl --update"
        return
    fi
    if [ "$GPU_PRESENT" -eq 0 ]; then
        # 這一段原本判 WARN 並直接說「Windows 驅動太舊或沒裝好，去更新驅動」。
        # 第一批外部實測（n=2）打臉了這個判斷：一台 Intel 內顯 ＋ NVIDIA 獨顯的
        # 雙顯卡筆電（Surface Book），/dev/dxg 存在但 WSL 內問不到 nvidia-smi，
        # 工具卻自信地叫使用者去更新驅動 —— 而使用者的機器根本沒問題。
        #
        # 根本錯誤：/dev/dxg 在任何啟用 GPU 直通的 WSL2 上都存在，Intel 與 AMD
        # 也算。它證明的是「WSL 的顯示卡通道通了」，不是「這台應該要有 NVIDIA」。
        # 拿它當「NVIDIA 應該存在」的證據，就會對沒有 N 卡的機器產生自信的錯誤建議
        # —— 跟 vmwp 那條（叫使用者關掉自己的模型）是同一類問題。
        #
        # 現在改成 INFO 並列出三種可能，讓使用者自己對號入座。
        # 「這台電腦沒有 NVIDIA 顯示卡」不是一個需要警告的狀態。
        add_rule "R4" "WSL 顯示卡支援狀態" "INFO" \
            "WSL 的顯示卡通道是通的，但在裡面問不到 NVIDIA 顯示卡。" \
            "這有三種可能，先看看哪一種符合你的情況：
（一）這台電腦本來就沒有 NVIDIA 顯示卡，只有內建顯示晶片或 AMD 的卡——那這是正常的，不用處理，這個工具目前只支援 NVIDIA。
（二）這是一台雙顯卡筆電（Surface Book、多數電競筆電都是）——WSL 常常問不到獨立顯示卡，這是已知限制，不代表你的機器壞了。
（三）這是桌機，而且你確定裝了 NVIDIA 顯示卡——那才有可能是 Windows 那邊的驅動需要更新。" \
            "只有第（三）種情況才需要動手：到 Windows 更新 NVIDIA 驅動（NVIDIA App 或官網下載頁），更新後在 PowerShell 執行 wsl --shutdown 再重開。
前兩種情況不需要做任何事。" \
            "$detail"
        return
    fi
    add_rule "R4" "WSL 顯示卡驅動" "PASS" \
        "WSL 的顯示卡設定是正確的。" \
        "顯示卡通道正常，而且 WSL 裡面沒有誤裝 Linux 版驅動（這是最常見的踩雷）。" \
        "" \
        "$detail"
}


# ---------------------------------------------------------------------------
# --live 模式：讓核心規則有真實資料可判定
#
# 為什麼需要：R1（溢位）、R3（context）、R5（因果）全部依賴「模型正在
# 記憶體裡」，而 Ollama 預設閒置 5 分鐘就卸載。使用者通常是「覺得慢 →
# 去找工具 → 跑起來」，這中間很容易超過 5 分鐘，結果最有價值的三條規則
# 全部 SKIP。--live 讓工具自己製造出可診斷的狀態。
#
# ⚠ 這是整支工具唯一會改變系統狀態的路徑。預設（無參數）行為不受影響。
# ---------------------------------------------------------------------------

# 速度基準表。鍵是「顯示卡|模型」—— 兩者都必須吻合才有比較意義：
# 同一張卡上 1B 本來就比 8B 快好幾倍，只用顯示卡當鍵會得出荒謬結論。
# 數字來源見 MEASUREMENTS.md 的「基準值對照表」，每一筆都是單一機器單次測量。
declare -A SPEED_BASELINE=(
    ["NVIDIA GeForce RTX 5070 Ti|llama3.1:8b"]="105.812"
    ["NVIDIA GeForce RTX 5070 Ti|llama3.2:1b"]="246.802"
)

LIVE_PROMPT="用三句話解釋什麼是光合作用"
LIVE_TIMEOUT=60

LIVE_STATUS=""          # ok / no-model / service-down / timeout / too-big / api-error
LIVE_MODEL=""
LIVE_TOKS=""            # 第二次（採用值）
LIVE_TOKS_FIRST=""      # 第一次（暖機，僅供對照）
LIVE_USED_EXISTING=0    # 1 = 用使用者原本就載入的模型，沒有載入新的
LIVE_NOTE=""
PRELOAD_OTHERS_MIB=""   # 載入模型前量到的背景 VRAM，R5 用它算「其他程式佔用」

# 從 ollama list 挑出檔案最小的模型。回傳「名稱 大小MiB」。
pick_smallest_model() {
    ollama list 2>/dev/null | awk 'NR>1 && NF>=4 {
        n=$3; u=$4;
        if (u=="GB") mib=n*1000000000/1048576;
        else if (u=="MB") mib=n*1000000/1048576;
        else if (u=="TB") mib=n*1000000000000/1048576;
        else next;
        if (best=="" || mib<bestmib) { best=$1; bestmib=mib }
    } END { if (best!="") printf "%s %.0f\n", best, bestmib }'
}

# 這台機器總共有多少記憶體可以裝模型（顯存 + 系統可用記憶體）
total_capacity_mib() {
    local ram_kb ram_mib
    ram_kb="$(awk '/^MemAvailable:/{print $2}' /proc/meminfo 2>/dev/null)"
    ram_mib=$(( ${ram_kb:-0} / 1024 ))
    echo $(( GPU_VRAM_TOTAL_MIB + ram_mib ))
}

# 對指定模型跑一次固定 prompt，印出 tok/s。失敗時印空字串並回傳非 0。
live_one_run() {
    local model="$1" tmp rc
    tmp="$(mktemp)"
    curl -s --max-time "$LIVE_TIMEOUT" http://localhost:11434/api/generate \
        -d "{\"model\":\"${model}\",\"prompt\":\"${LIVE_PROMPT}\",\"stream\":false}" \
        -o "$tmp" 2>/dev/null
    rc=$?
    if [ "$rc" -ne 0 ]; then rm -f "$tmp"; return "$rc"; fi
    awk 'BEGIN{RS=","} /"eval_count"/{gsub(/[^0-9]/,"",$0); c=$0} /"eval_duration"/{gsub(/[^0-9]/,"",$0); d=$0}
         END{ if (c>0 && d>0) printf "%.3f\n", c/(d/1000000000) }' "$tmp"
    rm -f "$tmp"
    return 0
}

do_live_test() {
    # 前提：服務要在跑
    if [ "$SVC_WSL_UP" -ne 1 ] || [ -z "$OLLAMA_BIN" ]; then
        LIVE_STATUS="service-down"; return
    fi

    # 決定 3：使用者已經有模型載入時，用「他的」模型測，不載入新的。
    # 去載入另一個模型可能把他正在用的擠掉，或讓兩個同時佔著顯存。
    if [ "$MODEL_LOADED" -eq 1 ]; then
        LIVE_MODEL="$M_NAME"; LIVE_USED_EXISTING=1
    else
        local pick name mib cap
        pick="$(pick_smallest_model)"
        if [ -z "$pick" ]; then LIVE_STATUS="no-model"; return; fi
        name="${pick%% *}"; mib="${pick##* }"
        cap="$(total_capacity_mib)"
        # 風險一：最小的模型也可能一點都不小。裝不下就別載，
        # 逾時之後才說「載入超時」對使用者沒有幫助，機器還會卡上一分鐘。
        if [ "$mib" -gt "$cap" ]; then
            LIVE_STATUS="too-big"; LIVE_MODEL="$name"
            LIVE_NOTE="模型約 $(awk -v v="$mib" 'BEGIN{printf "%.1f", v/1024}') GB，這台可用的記憶體約 $(awk -v v="$cap" 'BEGIN{printf "%.1f", v/1024}') GB"
            return
        fi
        LIVE_MODEL="$name"
    fi

    # 決定 4：跑兩次取第二次。基準是這樣量的，只跑一次會系統性地
    # 把使用者判定成「偏慢」—— 實測第一次因暖機可能慢 37%～100%。
    local t1 t2 rc
    t1="$(live_one_run "$LIVE_MODEL")"; rc=$?
    if [ "$rc" -eq 28 ]; then LIVE_STATUS="timeout"; return; fi
    if [ "$rc" -ne 0 ]; then LIVE_STATUS="api-error"; return; fi
    LIVE_TOKS_FIRST="$t1"

    t2="$(live_one_run "$LIVE_MODEL")"; rc=$?
    if [ "$rc" -eq 28 ]; then LIVE_STATUS="timeout"; return; fi
    if [ "$rc" -ne 0 ]; then LIVE_STATUS="api-error"; return; fi
    [ -n "$t2" ] || { LIVE_STATUS="api-error"; return; }

    LIVE_TOKS="$t2"; LIVE_STATUS="ok"
}

# 速度評價。決定 5：顯示卡與模型都吻合才給評價；決定 6：措辭必須反映
# 基準只是單次測量，不能講成「正常範圍」。
live_speed_verdict() {
    local key base ratio
    key="${GPU_NAME}|${LIVE_MODEL}"
    base="${SPEED_BASELINE[$key]:-}"
    if [ -z "$base" ]; then
        echo "目前沒有這張顯示卡搭配這個模型的基準值，所以只報數字不做評價——沒有基準就不裝懂。"
        return
    fi
    ratio="$(awk -v a="$LIVE_TOKS" -v b="$base" 'BEGIN{printf "%.2f", a/b}')"
    local head
    head="本專案在同一款顯示卡、同一個模型上實測到 ${base} tok/s（單次測量），你的是 $(awk -v v="$LIVE_TOKS" 'BEGIN{printf "%.1f", v}') tok/s。"
    if   awk -v r="$ratio" 'BEGIN{exit !(r<0.5)}'; then
        echo "${head}明顯偏慢（約基準的 $(awk -v r="$ratio" 'BEGIN{printf "%d", r*100}')%），往下看有沒有溢位或其他程式佔用顯示卡。"
    elif awk -v r="$ratio" 'BEGIN{exit !(r<0.7)}'; then
        echo "${head}比基準慢一些（約 $(awk -v r="$ratio" 'BEGIN{printf "%d", r*100}')%），可以往下看看有沒有可以改善的地方。"
    elif awk -v r="$ratio" 'BEGIN{exit !(r>1.3)}'; then
        echo "${head}比基準快，代表你的環境條件比測量當時更好（例如背景程式較少）。"
    else
        echo "${head}兩者在同一個量級，看起來正常。"
    fi
}

rule_live() {                                        # --live 的結果卡片
    [ -n "$LIVE_STATUS" ] || return 0
    case "$LIVE_STATUS" in
        ok)
            local until_txt src
            # 用時間片語比對而不是固定欄位位置：欄位數會因 Ollama 版本
            # 有無 CONTEXT 欄而不同，寫死位置會抓到隔壁的欄位。
            until_txt="$(ollama ps 2>/dev/null | sed -n '2p' \
                         | grep -oE '[0-9]+ (second|minute|hour)s? from now' | head -1)"
            if [ -n "$until_txt" ]; then
                until_txt="約 $(printf '%s' "${until_txt% from now}" \
                    | sed -e 's/ seconds\?$/ 秒/' -e 's/ minutes\?$/ 分鐘/' -e 's/ hours\?$/ 小時/' \
                    | sed 's/^ *//; s/ *$//')後"
            else
                until_txt="幾分鐘後"
            fi
            local LIVE_TOKS_R
            LIVE_TOKS_R="$(awk -v v="$LIVE_TOKS" 'BEGIN{printf "%.1f", v}')"
            if [ "$LIVE_USED_EXISTING" -eq 1 ]; then
                src="用的是你原本就載入的模型（${LIVE_MODEL}），沒有另外載入任何東西。"
            else
                src="載入了你電腦裡最小的模型（${LIVE_MODEL}）來測。"
            fi
            add_rule "LIVE" "實際跑一次的速度" "INFO" \
                "實際跑了一次，速度是每秒 ${LIVE_TOKS_R} 個 token。" \
                "（token 是模型輸出的基本單位，數字越大越快。）$(live_speed_verdict) ${src}測試用的模型還在記憶體裡，${until_txt}會自動釋放，不需要你動手。" \
                "" \
                "模型：${LIVE_MODEL}
第 1 次 ${LIVE_TOKS_FIRST:-未取得} tok/s（暖機，不採用）
第 2 次 ${LIVE_TOKS} tok/s（採用值，與基準相同的量法）
提示詞：${LIVE_PROMPT}
顯示卡：${GPU_NAME}
基準查詢鍵：${GPU_NAME}|${LIVE_MODEL}"
            ;;
        no-model)
            add_rule "LIVE" "實際跑一次的速度" "SKIP" \
                "你的電腦裡還沒有任何模型，所以沒辦法實際跑一次。" \
                "沒有模型就沒有東西可以測。這個工具不會自動幫你下載——模型動輒好幾 GB，那應該由你決定。" \
                "先下載一個小模型（約 1.3 GB），再重跑一次：
ollama pull llama3.2:1b" \
                "ollama list 沒有任何項目" \
                "先執行 ollama pull llama3.2:1b 下載一個小模型"
            ;;
        service-down)
            add_rule "LIVE" "實際跑一次的速度" "SKIP" \
                "Ollama 服務沒有在跑，所以跳過實測。" \
                "上面的「Ollama 服務」那一項說明了原因。修好之後再跑一次就會有實測結果。" \
                "" \
                "SVC_WSL_UP=${SVC_WSL_UP}"
            ;;
        too-big)
            add_rule "LIVE" "實際跑一次的速度" "SKIP" \
                "你電腦裡最小的模型（${LIVE_MODEL}）對這台機器來說還是太大，所以沒有實際去跑。" \
                "硬跑下去會讓機器卡住好一段時間，而且結果只會告訴你「跑不動」——那個你已經知道了。${LIVE_NOTE}。" \
                "下載一個小一點的模型再試：
ollama pull llama3.2:1b" \
                "${LIVE_NOTE}
判定：模型大小 > 顯示卡記憶體 + 系統可用記憶體" \
                "下載一個小一點的模型（ollama pull llama3.2:1b）"
            ;;
        timeout)
            add_rule "LIVE" "實際跑一次的速度" "WARN" \
                "模型載入超過 ${LIVE_TIMEOUT} 秒還沒有回應，所以停止等待。" \
                "這本身就是有用的診斷結果：通常代表模型太大、需要從硬碟大量搬資料，或是被擠到 CPU 上跑。往下看「模型放不進顯示卡」那一項會更清楚。⚠ 注意：我們只是不再等待，Ollama 那邊可能還在繼續載入，所以顯示卡記憶體可能會再被佔用一段時間。" \
                "如果這台電腦跑不動這個模型，換一個小一點的：
ollama pull llama3.2:1b" \
                "模型：${LIVE_MODEL}
逾時設定：${LIVE_TIMEOUT} 秒（curl exit 28）" \
                "換一個小一點的模型試試"
            ;;
        api-error)
            add_rule "LIVE" "實際跑一次的速度" "WARN" \
                "實測的過程中發生錯誤，沒有拿到速度數字。" \
                "服務有回應，但這次請求沒有正常完成。標準檢查的結果不受影響，仍然可以參考。" \
                "" \
                "模型：${LIVE_MODEL:-未選定}
狀態：API 呼叫未回傳可解析的結果"
            ;;
    esac
}

# ---------------------------------------------------------------------------
# 執行
# ---------------------------------------------------------------------------

echo "${C_BOLD}本地 LLM 環境健檢${C_RESET} ${C_DIM}v${VERSION} · 規格 ${SPEC_VERSION}${C_RESET}"
if [ "$LIVE_MODE" -eq 1 ]; then
    echo "${C_DIM}完整檢查模式：稍後會實際載入一個模型跑一次，其餘檢查只讀取不修改…${C_RESET}"
else
    echo "${C_DIM}只讀取不修改任何設定，正在檢查…${C_RESET}"
fi
echo

# 包成函式，是為了 --live 能在載入模型之後乾淨地重跑一次。
# 全部都是唯讀檢查，跑兩次沒有副作用。
run_all_probes() {
    probe_gpu
    [ -n "$(command -v ollama 2>/dev/null)" ] && backend_use_ollama
    probe_service
    probe_loaded_model
    probe_model_file_size
    probe_fit_log
    probe_vram_median
    probe_vram_consumers
}

run_all_rules() {
    rule_r0
    rule_live          # LIVE_STATUS 為空時（＝標準模式）自動略過
    rule_r8
    rule_r6
    rule_r1_r2
    rule_r3
    rule_r9
    rule_r5
    rule_r4
}

reset_rules() {
    RULE_ID=(); RULE_TITLE=(); RULE_STATUS=()
    RULE_SYMPTOM=(); RULE_CONSEQ=(); RULE_FIX=(); RULE_DETAIL=(); RULE_ACTION=()
}

run_all_probes
run_all_rules

if [ "$LIVE_MODE" -eq 1 ]; then
    # 載入模型之前量到的背景 VRAM 是「其他程式佔用」的實測值。
    # 載入之後只能靠推算扣除模型，準確度較差，所以先存起來給 R5 用。
    PRELOAD_OTHERS_MIB="$VRAM_USED_MEDIAN"

    echo "${C_DIM}正在實際載入模型測試（這會佔用顯示卡記憶體，稍後由 Ollama 自動釋放）…${C_RESET}"
    do_live_test

    # 不論成功與否都重跑一次：規則的判定條件可能已經改變
    # （例如原本沒有模型載入、現在有了），而且要讓 rule_live 的卡片進入報告。
    reset_rules
    run_all_probes
    run_all_rules
    echo
fi

# ---------------------------------------------------------------------------
# 結論層：報告最上面的 2–3 行人話總結
#
# 使用者第一眼只會看這幾行。它必須回答三件事：
#   1. 有沒有問題　2. 最重要的是哪一個　3. 先做什麼
# 終端機與 report.html 共用同一份文字，避免兩邊講不一樣的話。
# ---------------------------------------------------------------------------

VERDICT=()

build_verdict() {
    # 嚴重度排序：先修不能用的，再修慢的。這個順序決定「最需要處理的是哪一個」。
    local pri=(R8 R6 R2 R4 R1 R3 R5 R0 R9)
    local want top_i=-1 top_kind="" p i

    for want in FAIL WARN; do
        for p in "${pri[@]}"; do
            for i in "${!RULE_ID[@]}"; do
                [ "${RULE_ID[$i]}" = "$p" ] || continue
                # 偵測不到 NVIDIA 卡時，R4 講的是「這台可能本來就沒有 N 卡」，
                # 那不是問題，更不該被推上結論層當成「最主要的問題」。
                # 外部實測踩過：Surface Book 上 R0 已 SKIP，結論層卻把 R4 的
                # 驅動警告當頭條，等於叫一台沒壞的機器去修驅動。
                # R4 現在是 INFO 本來就選不到，這裡再擋一層避免日後改回 WARN 時復發。
                [ "$p" = "R4" ] && [ "$GPU_PRESENT" -eq 0 ] && continue
                if [ "${RULE_STATUS[$i]}" = "$want" ]; then
                    top_i=$i; top_kind="$want"; break 3
                fi
            done
        done
    done

    local act
    if [ "$top_kind" = "FAIL" ] || [ "$top_kind" = "WARN" ]; then
        act="${RULE_ACTION[$top_i]}"
        if [ -n "$act" ]; then
            act="先做這件事：${act}。完整步驟在下面「${RULE_TITLE[$top_i]}」那一段。"
        else
            act="做法看下面「${RULE_TITLE[$top_i]}」那一段，裡面有可以直接複製的指令。"
        fi
    fi

    if [ "$top_kind" = "FAIL" ]; then
        VERDICT+=("檢查完畢，發現 ${n_fail} 個需要處理的問題。最重要的是：${RULE_TITLE[$top_i]}。")
        VERDICT+=("${RULE_SYMPTOM[$top_i]}")
        VERDICT+=("$act")
        return
    fi

    if [ "$top_kind" = "WARN" ]; then
        VERDICT+=("檢查完畢，沒有嚴重問題，但有 ${n_warn} 項值得注意。最主要的是：${RULE_TITLE[$top_i]}。")
        VERDICT+=("${RULE_SYMPTOM[$top_i]}")
        VERDICT+=("$act")
        return
    fi

    # 沒有 NVIDIA 卡而模型跑在 CPU 上：技術上「沒有設定問題」是對的，
    # 但使用者此刻正在經歷慢，只講「沒問題」等於答非所問。
    # 要說出他真正想知道的那件事：慢的原因是硬體，不是他設定錯了。
    if [ "$GPU_PRESENT" -eq 0 ] && [ "$MODEL_LOADED" -eq 1 ] && [ "$M_CPU_PCT" -ge 100 ]; then
        VERDICT+=("檢查完畢，設定沒有問題——但這台機器上偵測不到 NVIDIA 顯示卡，所以模型是用 CPU 在跑。")
        VERDICT+=("這就是它慢的原因。純用 CPU 跑比有顯示卡慢很多，那是硬體的差距，不是你哪裡設定錯了。")
        VERDICT+=("能做的是換更小的模型讓它跑得順一些，例如 llama3.2:1b。詳細說明在下面「模型跑在 CPU 上」那一段。")
        return
    fi

    VERDICT+=("檢查完畢，沒有發現會拖慢速度的設定問題。")
    if [ "$MODEL_LOADED" -eq 1 ] && [ "$M_CPU_PCT" -eq 0 ]; then
        VERDICT+=("你的模型完整跑在顯示卡上，這是最理想的狀態。")
        VERDICT+=("如果還是覺得慢，通常是模型本身偏大或機器規格的限制，而不是設定沒調好。")
    elif [ "$MODEL_LOADED" -eq 0 ]; then
        VERDICT+=("不過目前沒有模型在執行，所以看不到它實際跑在哪裡。")
        VERDICT+=("在你覺得「怎麼這麼慢」的當下再跑一次這個檢查，結果會準確得多。")
    else
        VERDICT+=("環境設定看起來沒有問題。")
    fi
}

# ---------------------------------------------------------------------------
# 終端機輸出（人話為主，技術值只在 report.html 的詳細資料區）
# ---------------------------------------------------------------------------

n_fail=0; n_warn=0; n_pass=0
for i in "${!RULE_ID[@]}"; do
    case "${RULE_STATUS[$i]}" in
        PASS) n_pass=$((n_pass+1)) ;;
        WARN) n_warn=$((n_warn+1)) ;;
        FAIL) n_fail=$((n_fail+1)) ;;
    esac
done

build_verdict

# 結論層 —— 使用者第一眼看到的東西
echo "${C_BOLD}══════════════════════════════════════════════════════${C_RESET}"
for line in "${VERDICT[@]}"; do
    printf '  %s\n' "$line"
done
echo "${C_BOLD}══════════════════════════════════════════════════════${C_RESET}"
echo
echo "${C_DIM}以下是每一項的細節：${C_RESET}"
echo

for i in "${!RULE_ID[@]}"; do
    st="${RULE_STATUS[$i]}"
    case "$st" in
        PASS) col="$C_PASS"; label="正常" ;;
        WARN) col="$C_WARN"; label="注意" ;;
        FAIL) col="$C_FAIL"; label="問題" ;;
        SKIP) col="$C_DIM";  label="略過" ;;
        *)    col="$C_INFO"; label="資訊" ;;
    esac
    printf '%s[%s]%s %s\n' "$col" "$label" "$C_RESET" "${C_BOLD}${RULE_TITLE[$i]}${C_RESET}"
    printf '       %s\n' "${RULE_SYMPTOM[$i]}"
    [ -n "${RULE_CONSEQ[$i]}" ] && printf '       %s%s%s\n' "$C_DIM" "${RULE_CONSEQ[$i]}" "$C_RESET"
    if [ -n "${RULE_FIX[$i]}" ]; then
        echo "       ── 怎麼修 ──"
        printf '%s\n' "${RULE_FIX[$i]}" | sed 's/^/       /'
    fi
    echo
done

echo "${C_BOLD}結果：${C_RESET}${C_FAIL}${n_fail} 個問題${C_RESET}、${C_WARN}${n_warn} 個注意${C_RESET}、${C_PASS}${n_pass} 個正常${C_RESET}"

# ---------------------------------------------------------------------------
# 產生 report.html
#
# 設計約束（改動這一段之前請先看完，這些都是有原因的）：
#
# 1. 零外部資源。CSS 全部內嵌，不引用任何 CDN、字型、圖片。
#    使用者是雙擊開啟本機檔案，不能假設有網路，也不該讓一份診斷報告
#    對外連線。改動時請確認 grep 不到任何 http 引用。
#
# 2. 複製功能有三層退路，缺一不可：
#      navigator.clipboard → document.execCommand → 展開隱藏的 textarea 手動選取
#    原因是這份報告是用 file:// 開啟的，而 file:// 不是安全內容脈絡，
#    瀏覽器可能直接擋掉 clipboard API。只寫第一層在很多環境會靜默失敗，
#    而「複製診斷資訊」正是這份報告最主要的出口，不能讓它沒有備案。
#
# 3. 技術數值一律收進「詳細資料」摺疊區，不當作結論輸出。
#    受眾是不懂底層的人，把 PROCESSOR 欄位或 MiB 數字直接當結論
#    就是這個專案一開始要解決的問題本身。
#
# 4. 五種狀態（PASS/WARN/FAIL/INFO/SKIP），只有前三種給綠黃紅。
#    INFO 與 SKIP 刻意不著色成好壞 —— 例如 R5 平常只報告資訊，
#    把它染成綠色或黃色都會誤導。
#
# 5. 所有動態內容都要經過 esc() 跳脫。內容來自系統指令輸出，
#    不能假設它不含 < > & 這些字元。
#
# 6. 深色模式用 prefers-color-scheme，不做手動切換開關 ——
#    一份看完就關掉的報告不值得為此增加狀態管理。
# ---------------------------------------------------------------------------

html_escape() { sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' -e 's/"/\&quot;/g'; }
esc() { printf '%s' "$1" | html_escape; }

build_copy_text() {
    printf '=== 本地 LLM 環境健檢報告 ===\n'
    printf '產生時間: %s\n' "$(date '+%Y-%m-%d %H:%M:%S')"
    printf '工具版本: check.sh v%s (規格 %s)\n' "$VERSION" "$SPEC_VERSION"
    printf '\n[系統]\n'
    printf '作業系統: %s\n' "$(sed -n 's/^PRETTY_NAME="\(.*\)"/\1/p' /etc/os-release 2>/dev/null)"
    printf '核心: %s\n' "$(uname -r)"
    printf '記憶體: %s\n' "$(free -h 2>/dev/null | awk '/^Mem:/{print $2" 總計, "$7" 可用"}')"
    printf '\n[顯示卡]\n'
    if [ "$GPU_PRESENT" -eq 1 ]; then
        printf '型號: %s\n' "$GPU_NAME"
        printf '顯示卡記憶體: %s MiB 總計\n' "$GPU_VRAM_TOTAL_MIB"
        printf '已使用: %s MiB (三次取樣中位數; 樣本 %s)\n' "$VRAM_USED_MEDIAN" "$VRAM_SAMPLES"
        printf '驅動版本: %s\n' "$GPU_DRIVER"
    else
        printf '未偵測到支援的顯示卡 (%s)\n' "${GPU_PROBE_ERR:-無輸出}"
    fi
    printf '\n[引擎]\n'
    printf '後端: %s\n' "${BACKEND_LABEL:-未偵測到}"
    printf '版本: %s\n' "${OLLAMA_VERSION:-未取得}"
    printf '服務狀態: %s\n' "$( [ "$SVC_WSL_UP" -eq 1 ] && echo '執行中' || echo '未執行' )"
    if [ "$MODEL_LOADED" -eq 1 ]; then
        printf '載入的模型: %s\n' "$M_NAME"
        printf '載入後大小: %s (%s MiB)\n' "$M_SIZE_RAW" "$M_SIZE_MIB"
        printf '模型檔案大小: %s MiB\n' "$M_FILE_MIB"
        printf '執行位置: %s (CPU %s%% / GPU %s%%)\n' "$M_PROC_RAW" "$M_CPU_PCT" "$M_GPU_PCT"
        printf 'context: %s\n' "${M_CONTEXT:-未知}"
        [ -n "$R9_LAYERS_ON" ] && printf '層數: %s/%s 在 GPU\n' "$R9_LAYERS_ON" "$R9_LAYERS_TOTAL"
    else
        printf '載入的模型: 無\n'
    fi
    printf '\n[各項判定]\n'
    for i in "${!RULE_ID[@]}"; do
        printf '%s %s: %s\n' "${RULE_ID[$i]}" "${RULE_TITLE[$i]}" "${RULE_STATUS[$i]}"
    done
    printf '\n[原始關鍵值]\n'
    for i in "${!RULE_ID[@]}"; do
        [ -n "${RULE_DETAIL[$i]}" ] || continue
        printf -- '--- %s ---\n%s\n' "${RULE_ID[$i]}" "${RULE_DETAIL[$i]}"
    done
    printf '\n[說明] 以上由 check.sh 以純規則判斷產生，未使用任何 AI 推論。\n'
    printf '可以把這整段貼給任何 AI 助手追問細節。\n'
}

if [ "$NO_HTML" -eq 0 ]; then
    # 再過一次去識別化當保險：build_copy_text 除了規則詳細資料之外
    # 還會印系統資訊，萬一日後有人加了會帶路徑的欄位也能接住。
    COPY_TEXT="$(build_copy_text | mask_home)"
    {
        cat <<'HTMLHEAD'
<!doctype html>
<html lang="zh-Hant">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>本地 LLM 環境健檢報告</title>
<style>
:root{
  --bg:#f6f7f9; --card:#fff; --fg:#1a1d21; --muted:#5b6472; --line:#e2e5ea;
  --pass:#1a7f47; --pass-bg:#e6f4ec; --warn:#8a6100; --warn-bg:#fdf3e0;
  --fail:#b3261e; --fail-bg:#fdeceb; --info:#0b5f9e; --info-bg:#e8f2fb;
  --code:#f2f3f5;
}
@media (prefers-color-scheme: dark){
  :root{
    --bg:#15181c; --card:#1c2026; --fg:#e6e8eb; --muted:#9aa3b0; --line:#2c323a;
    --pass:#5cc98d; --pass-bg:#16301f; --warn:#e0b25c; --warn-bg:#33280f;
    --fail:#f08a82; --fail-bg:#3a1a18; --info:#6db3ec; --info-bg:#132938;
    --code:#252a31;
  }
}
*{box-sizing:border-box}
body{margin:0;padding:24px 16px 64px;background:var(--bg);color:var(--fg);
  font-family:-apple-system,"Segoe UI","Noto Sans TC","Microsoft JhengHei",sans-serif;
  line-height:1.75;font-size:16px}
.wrap{max-width:820px;margin:0 auto}
h1{font-size:1.6rem;margin:0 0 4px}
.sub{color:var(--muted);font-size:.9rem;margin-bottom:24px}
.summary{display:flex;gap:12px;flex-wrap:wrap;margin-bottom:24px}
.chip{padding:8px 16px;border-radius:999px;font-weight:600;font-size:.95rem}
.chip.f{background:var(--fail-bg);color:var(--fail)}
.chip.w{background:var(--warn-bg);color:var(--warn)}
.chip.p{background:var(--pass-bg);color:var(--pass)}
.card{background:var(--card);border:1px solid var(--line);border-radius:12px;
  padding:20px;margin-bottom:16px}
.card.f{border-left:5px solid var(--fail)}
.card.w{border-left:5px solid var(--warn)}
.card.p{border-left:5px solid var(--pass)}
.card.i,.card.s{border-left:5px solid var(--info)}
.badge{display:inline-block;padding:2px 10px;border-radius:6px;font-size:.8rem;
  font-weight:700;margin-right:8px;vertical-align:2px}
.badge.f{background:var(--fail-bg);color:var(--fail)}
.badge.w{background:var(--warn-bg);color:var(--warn)}
.badge.p{background:var(--pass-bg);color:var(--pass)}
.badge.i,.badge.s{background:var(--info-bg);color:var(--info)}
h2{font-size:1.1rem;margin:0 0 12px;display:flex;align-items:baseline;flex-wrap:wrap}
.sym{font-weight:600;margin:0 0 8px}
.con{color:var(--muted);margin:0 0 12px}
.fix{background:var(--code);border-radius:8px;padding:12px 14px;margin-top:12px}
.fix .t{font-size:.82rem;font-weight:700;color:var(--muted);
  letter-spacing:.05em;margin-bottom:6px}
pre{margin:0;font-family:ui-monospace,"Cascadia Mono",Consolas,monospace;
  font-size:.86rem;white-space:pre-wrap;word-break:break-word}
details{margin-top:12px;border-top:1px solid var(--line);padding-top:10px}
summary{cursor:pointer;color:var(--muted);font-size:.88rem;user-select:none}
details pre{margin-top:10px;background:var(--code);padding:12px;border-radius:8px;
  overflow-x:auto;color:var(--muted)}
.verdict{border-radius:12px;padding:20px 24px;margin-bottom:24px;
  border:1px solid var(--line)}
.verdict.p{background:var(--pass-bg);border-color:var(--pass)}
.verdict.w{background:var(--warn-bg);border-color:var(--warn)}
.verdict.f{background:var(--fail-bg);border-color:var(--fail)}
.verdict p{margin:0 0 8px}
.verdict p:first-child{font-size:1.15rem;font-weight:700}
.verdict p:last-child{margin-bottom:0}
.copybar{background:var(--card);border:1px solid var(--line);border-radius:12px;
  padding:20px;margin-bottom:24px}
button{font:inherit;font-weight:600;padding:10px 20px;border-radius:8px;
  border:1px solid var(--line);background:var(--info-bg);color:var(--info);cursor:pointer}
button:hover{filter:brightness(.97)}
#hidden{position:absolute;left:-9999px;top:0;opacity:0}
.foot{color:var(--muted);font-size:.82rem;margin-top:32px;text-align:center}
</style>
</head>
<body><div class="wrap">
HTMLHEAD

        printf '<h1>本地 LLM 環境健檢報告</h1>\n'
        printf '<div class="sub">%s · 純規則判斷，未使用任何 AI 推論 · 只讀取不修改任何設定</div>\n' \
            "$(date '+%Y-%m-%d %H:%M')"

        printf '<div class="summary">'
        printf '<span class="chip f">%d 個問題</span>' "$n_fail"
        printf '<span class="chip w">%d 個注意</span>' "$n_warn"
        printf '<span class="chip p">%d 個正常</span>' "$n_pass"
        printf '</div>\n'

        # 結論層：與終端機共用同一份 VERDICT 文字
        vk="p"; [ "$n_warn" -gt 0 ] && vk="w"; [ "$n_fail" -gt 0 ] && vk="f"
        printf '<div class="verdict %s">\n' "$vk"
        for line in "${VERDICT[@]}"; do
            printf '<p>%s</p>\n' "$(esc "$line")"
        done
        printf '</div>\n'

        cat <<'COPYBAR'
<div class="copybar">
  <div style="margin-bottom:12px">看不懂下面的結果？按這個按鈕複製一份診斷資訊，貼給任何 AI 助手追問。</div>
  <button id="copybtn" type="button">複製診斷資訊</button>
  <span id="copymsg" style="margin-left:12px;color:var(--muted);font-size:.9rem"></span>
</div>
COPYBAR

        for i in "${!RULE_ID[@]}"; do
            case "${RULE_STATUS[$i]}" in
                PASS) k="p"; lb="正常" ;;
                WARN) k="w"; lb="注意" ;;
                FAIL) k="f"; lb="問題" ;;
                SKIP) k="s"; lb="略過" ;;
                *)    k="i"; lb="資訊" ;;
            esac
            printf '<div class="card %s">\n' "$k"
            printf '<h2><span class="badge %s">%s</span>%s</h2>\n' \
                "$k" "$lb" "$(esc "${RULE_TITLE[$i]}")"
            printf '<p class="sym">%s</p>\n' "$(esc "${RULE_SYMPTOM[$i]}")"
            [ -n "${RULE_CONSEQ[$i]}" ] && \
                printf '<p class="con">%s</p>\n' "$(esc "${RULE_CONSEQ[$i]}")"
            if [ -n "${RULE_FIX[$i]}" ]; then
                printf '<div class="fix"><div class="t">怎麼修</div><pre>%s</pre></div>\n' \
                    "$(esc "${RULE_FIX[$i]}")"
            fi
            if [ -n "${RULE_DETAIL[$i]}" ]; then
                printf '<details><summary>詳細資料（技術值）</summary><pre>%s</pre></details>\n' \
                    "$(esc "${RULE_DETAIL[$i]}")"
            fi
            printf '</div>\n'
        done

        printf '<textarea id="hidden" readonly>%s</textarea>\n' "$(esc "$COPY_TEXT")"
        printf '<div class="foot">check.sh v%s · 規格 %s</div>\n' "$VERSION" "$(esc "$SPEC_VERSION")"

        cat <<'HTMLFOOT'
</div>
<script>
(function(){
  var btn=document.getElementById('copybtn'),
      msg=document.getElementById('copymsg'),
      ta=document.getElementById('hidden');
  function ok(){ msg.textContent='已複製，可以直接貼上了'; setTimeout(function(){msg.textContent='';},4000); }
  function fail(){ msg.textContent='複製失敗，請手動選取下方文字框'; ta.style.position='static'; ta.style.opacity='1';
                   ta.style.width='100%'; ta.style.height='260px'; ta.select(); }
  btn.addEventListener('click',function(){
    var text=ta.value;
    if(navigator.clipboard&&navigator.clipboard.writeText){
      navigator.clipboard.writeText(text).then(ok,legacy);
    }else{ legacy(); }
    function legacy(){
      try{ ta.select(); ta.setSelectionRange(0,text.length);
           document.execCommand('copy')?ok():fail(); }catch(e){ fail(); }
    }
  });
})();
</script>
</body></html>
HTMLFOOT
    } > "$OUT_HTML"

    echo
    # 顯示路徑也要遮罩：使用者常直接把終端機輸出整段貼出來。
    echo "${C_BOLD}報告已產生：${C_RESET}$(printf '%s' "$OUT_HTML" | mask_home)"
    echo "${C_DIM}用瀏覽器打開它，裡面有「複製診斷資訊」按鈕。${C_RESET}"
fi

exit 0
