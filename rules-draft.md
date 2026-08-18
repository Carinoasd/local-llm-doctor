# 本地 LLM 環境健檢工具 — 規則表 v3.0-verified

> **所有數字來自 2026-08-18 本機實測。** 本文件中出現的每一個倍率、容量、
> 欄位格式與字串，都有對應的原始輸出存於 `verify-report.md`。
> 先前版本的推算值（「慢 10-20 倍」「20–40%」「2.1 倍」）已全部移除，未混入任何估計值。

- 版本：**v3.0-verified**（規則內容定案，等待階段二開工）
- 狀態：**階段一完成。`#01`–`#26` 驗證通過，尚未寫任何程式碼**
- 受眾（已定案）：**裝了 Ollama、能跑起來、但不懂底層在幹嘛的人**
- 後端（已定案）：Ollama 為第一個也是唯一實作的後端；LM Studio 列為未來的受限後端
- 驗證機器：Windows 11 (10.0.26200) + WSL2 (Ubuntu 26.04) + RTX 5070 Ti 16GB
- 驗證對象：**Ollama 0.32.14**
- 實測日期：2026-08-18

> ⚠️ **測試環境的重要但書**：三檔位測速與 R3 溢位測試期間，
> 機器上有一個**穩定的背景影片解碼負載（約 2.8 GB VRAM），全程未開關**。
> 這壓縮了可用 VRAM（Ollama 回報 `available="14.7 GiB"` 而非滿額 15.9 GiB）。
> **檔位之間的相對倍率不受影響**（同一組背景條件下的公平比較），
> 但絕對門檻（特別是 R3 的溢位臨界點）在無背景負載的機器上會不同。

## 0. 這份文件怎麼用

每條規則有五欄資訊（規則名稱／偵測指令／判斷條件／怎麼故意觸發／修法）。
你在自己機器上逐條跑，把**原始輸出**貼回來。貼回來的輸出就是階段二解析器的規格書。

信心標記（每條判斷條件都必須有）：

| 標記 | 意義 |
| --- | --- |
| **【驗證】** | **2026-08-18 由 `#01`–`#26` 正式驗證，原始輸出見 `verify-report.md`** |
| 【實測】 | 2026-08-18 在本機跑過，輸出附在第 4 節 |
| 【文件】 | 官方文件有寫，但未在本機驗證 |
| 【社群】 | 大量 GitHub issue／論壇共識，字句可能因版本而異 |
| 【推測】 | 我推的，尚未驗證 |

---

## 1. 修訂摘要

### v2.1 → v3.0-verified（驗證回填）

| # | 項目 | 驗證結果 |
| --- | --- | --- |
| 1 | **R1 後果數字** | 填入實測：29% 溢位 → **3.32 倍慢**；82% 溢位 → **8.71 倍慢**。先前的「20–40%」估計嚴重低估 |
| 2 | **R3 觸發值** | 65536 → **98304**。65536 在 16GB 卡上不會溢位（SIZE 13 GB 但仍 `100% GPU`），是三選一分支之外的**第四種結果** |
| 3 | **R3 新增後果** | context 開大**就算不溢位也會變慢**：65536 在 `100% GPU` 下仍慢 16%（105.8 → 88.5 tok/s） |
| 4 | **R5 `vmwp` 排除規則** | WSL 裡的模型在 Windows 計數器上顯示為 `vmwp` 且排名第一。不排除的話工具會**建議使用者關掉自己的模型** |
| 5 | **R5 資料來源改正** | 總量改用 `GPU Adapter Memory`（與 nvidia-smi 吻合 0.1%）；`GPU Process Memory` 只用於排名 |
| 6 | **R5 取樣方式** | 背景 VRAM 同日漂移超過 1.2 GB → 改為取樣 3 次取中位數 ＋ 500 MiB 容差 |
| 7 | **R8 新規則** | `zstd` 缺失導致 Ollama 安裝失敗的偵測（正式納入） |
| 8 | **R9 新規則** | 直接解析 `common_params_fit_impl` log 的溢位判定（正式納入） |
| 9 | **六項格式修正** | F3–F10，見各規則卡的「輸出格式變體」欄 |

### v1 → v2 的五項修正（已完成，保留紀錄）

| # | 修正 | 怎麼改的 |
| --- | --- | --- |
| 1 | R1 後果描述錯誤（把部分溢位和全 CPU 混用同一套頻寬推算） | 刪掉「1/5～1/20」，改三檔位實測 → **v3.0 已填入數字** |
| 2 | R5 門檻無意義 | R5 降級為 R1 的證據：平常只報資訊，只有 R1 觸發時才升級並串因果 |
| 3 | R3 觸發值 131072 會直接載入失敗 | 改 65536 → **v3.0 再改為 98304** |
| 4 | R4 觸發驗證風險不對稱 | 不做觸發驗證，錯誤字句改引用 GitHub issue |
| 5 | 受眾與技術重心錯開 | 走方案 A，架構上抽象出「後端」概念 |

### 沒有改的

- 三段式輸出（症狀／後果／修法）的要求
- 只診斷不自動修復
- 第一版只支援 NVIDIA
- R2／R4／R6 的判斷條件（R2／R6 的故障態驗證 `#28`–`#35` 尚未執行，小抄見 `verify-report.md` 第 9 節）

---

## 2. 受眾與後端架構（已定案）

### 2.1 決定（2026-08-18）

**採用方案 A。**

- **受眾定義：裝了 Ollama、能跑起來、但不懂底層在幹嘛的人。**
  他看不懂 `torch 2.5.1+cpu`，也不知道 VRAM 和 RAM 差在哪。
  「會用 Ollama」不等於「懂底層」——安裝是一行 curl、使用是 `ollama run`，
  敢開終端機的門檻遠低於懂 VRAM／量化／KV cache。受眾定義沒有變質，只是範圍縮到 Ollama 使用者。
- **所有文案以此為準。** 報告裡不出現「本工具支援多種引擎」這類暗示，
  但也不寫死成「Ollama 專用工具」——見下面的後端抽象。

### 2.2 後端抽象（架構決定）

偵測層分成兩類，階段二的 `check.sh` 要照這條界線切：

| 類別 | 規則 | 說明 |
| --- | --- | --- |
| **後端無關** | R0、R4、R5 | 只碰 nvidia-smi／dpkg／效能計數器，跟哪個引擎無關 |
| **後端相關** | R1、R2、R3、R6 | 需要向引擎問「載入了什麼、跑在哪」 |

後端要提供的能力介面（第一版只有 Ollama 實作）：

| 能力 | Ollama 的實作 | LM Studio（未來）|
| --- | --- | --- |
| `backend_detect` 服務在不在 | `curl :11434` | `curl :1234` ／ `lms server status` |
| `backend_loaded_models` 載入了什麼 | `ollama ps` | `lms ps --json` ／ `/api/v1/models` |
| `backend_model_size` 檔案多大 | `ollama list` | `lms ps` 的 Size 欄 |
| `backend_offload_ratio` **溢位比例** | `ollama ps` 的 PROCESSOR 欄，**直接給** | **給不出來**（見 2.3）|
| `backend_context` context 設定 | 環境變數／SIZE 反推 | `/api/v1/models` 的 `config` |

**關鍵設計約束：`backend_offload_ratio` 是可以「不支援」的能力。**
後端若回報不支援，R1 要能退化成「只判斷有沒有溢位，不給比例」的模式
（走 VRAM 算術推論）。這個退化路徑第一版不實作，但**資料結構要先留位置**，
否則之後加第二後端會需要動到 R1 的核心邏輯。

### 2.3 LM Studio 技術盤點（保留，供未來的受限後端）

> 本節資訊均來自官方文件與搜尋，**本機沒有安裝 LM Studio（已實測確認），因此一條都沒驗過。**
> 第一版不實作，這裡只保存調查結果，避免之後重做一次。

#### 那個決定性的問題

> 「LM Studio 有沒有等價於 `ollama ps` 的東西？」

**有一半。** 拆開來看：

| 診斷能力 | Ollama | LM Studio |
| --- | --- | --- |
| 服務在不在 | `curl :11434`【實測·連線層】 | `curl :1234`【文件】，但 server 預設是**關的** |
| 哪些模型已載入 | `ollama ps`【文件】 | `lms ps`（有 `--json`）【文件】 |
| 模型檔案大小 | `ollama list`【文件】 | `lms ps` 的 Size 欄【文件】 |
| **實際 GPU/CPU 層分配（＝溢位事實）** | `ollama ps` 的 **PROCESSOR 欄，直接給**【文件】 | **沒有直接欄位**（見下） |
| context 設定值 | 由 `ollama ps` SIZE 反推／環境變數 | `/api/v1/models` → `loaded_instances[].config`【文件·待驗】 |
| GPU offload 設定值 | `num_gpu` 參數 | 同上 `config` 內含 "GPU offload"【文件·待驗】 |

關鍵差異：**`lms ps` 的官方文件列出的欄位是 Identifier／Type／Path／Size／Architecture，
沒有 GPU 層數、VRAM、context**【文件】。有一則搜尋結果宣稱 `lms ps` 會顯示 GPU vs CPU 層數
【社群·低信心，官方文件的範例輸出裡沒有，需實裝驗證】。

LM Studio 0.4.0 的原生 `/api/v1/models` 會回 `loaded_instances[]`，其 `config` 據文件說明
包含「context length, GPU offload, etc.」【文件·中信心，沒看到逐字 JSON 範例】。
但請注意這是**設定值（他要求 offload 多少）**，不是**結果（實際跑起來多少層在 GPU）**——
Ollama 的 PROCESSOR 欄給的是後者。這兩者在「模型剛好塞不下」時會不一致，
而那正是 R1 要抓的狀況。

舊版 LM Studio 的 `/api/v0/models` 只有 `state`（loaded／not-loaded）與 `max_context_length`，
**完全沒有 GPU 資訊**【文件】。

#### 未來若要加 LM Studio 後端：可行性逐條盤點

| 規則 | LM Studio 可行性 | 依據 |
| --- | --- | --- |
| R6 服務／port | **可行** | `curl :1234/api/v0/models`【文件】或 `lms server status`【文件】 |
| R2 全 CPU | **勉強可行** | 靠 VRAM 算術推論（見下），無直接欄位 |
| R1 部分溢位 | **無直接來源** | `lms ps` 無此欄位【文件】；`/api/v1` 的 config 是設定值非結果【文件·待驗】 |
| R3 context | **可能可行** | `/api/v1/models` 的 `config`【文件·待驗】，需 0.4.0+ |
| R4 WSL 驅動 | 不受影響 | 與引擎無關 |
| R5 其他程式佔 VRAM | 不受影響 | 與引擎無關（走 nvidia-smi／效能計數器） |

**R1／R2 的替代路線（若走 B 必須接受這個）：** 用算術推論取代直接讀值——
「模型檔案 8GB，但 nvidia-smi 顯示 GPU 只多用了 3.5GB → 一定沒有全部在 GPU 上」。
這是純規則、可決定性的，符合硬性限制 1。但它**只能判斷「有沒有溢位」，給不出比例**，
且需要「模型載入前後各量一次」或已知的桌面基線，準確度低於 Ollama 的直讀。

**四項額外工程成本（前兩項是實測到的，不是推測）：**

1. **跨 OS 邊界。** LM Studio 是 Windows 側 GUI app，而 WSL 是 **NAT 網路模式**【實測】——
   WSL 裡 `curl localhost:1234` **碰不到** Windows 的 LM Studio。每次查詢都要經 `powershell.exe`
   中轉，單次呼叫約 0.3–1 秒，六條規則跑下來會明顯拖慢。
2. **中文 Windows 的編碼坑。** 實測 `wsl.exe --version` 輸出是中文標籤且夾帶 NUL 字元
   （要 `tr -d '\0'` 才能解析）。透過 interop 拿 LM Studio 的輸出會遇到同類問題，
   而 `lms ps --json`【文件】可以繞過大部分，前提是該版本真的支援。
3. **版本分歧。** v0 API（無 GPU 資訊）與 v1 API（0.4.0+，有 config）要各寫一套並偵測版本。
4. **驗證負擔。** 本機沒裝 LM Studio【實測】，要驗的話每條規則都得先裝 LM Studio、
   下載模型、開 server，驗證工作量約翻倍。

**還有一個體驗層的風險：** LM Studio 的 server 預設是關的，要去 Developer 分頁手動開。
所以「偵測不到 LM Studio」最可能的原因不是故障，而是使用者沒開 server——
對不懂底層的使用者來說，要他先開 server 才能被診斷，本身就是個門檻。
（`lms` CLI 走的是 app 內部通道，可能不需要開 server 就能用【推測·待驗 U13】——
若成立，這個風險就消失。U13 保留在待驗清單，**低優先，本輪不做**。）

#### 未來的最小實作路徑（記錄用，第一版不做）

只做 R6 的 LM Studio 偵測（port 1234 有沒有人在），其餘規則維持 Ollama-only。
偵測到 LM Studio 但拿不到細節時，報告顯示：
「偵測到 LM Studio 正在執行。目前這個工具的深度診斷只支援 Ollama，
以下是你可以自己在 LM Studio 介面裡確認的三件事：……」

成本只多一條 curl，但對 LM Studio 使用者給不出真正的診斷——
所以它是「擴大覆蓋」而不是「擴大能力」，要不要做取決於之後的使用者來源分佈。

---

## 3. 規則卡

### 總覽

| 規則 | 偵測指令（核心） | 判斷條件（核心） | 驗證狀態 | 修法（核心） |
| --- | --- | --- | --- | --- |
| R0 前置盤點 | 兩側 `nvidia-smi` | 都失敗→顯示「未偵測到支援的顯示卡」並跳過 GPU 區塊 | ✅ 驗證 | — |
| R1 VRAM 溢位 | `ollama ps` PROCESSOR 欄 | `100% GPU`=PASS；`n%/m% CPU/GPU`=依比例分級 | ✅ **三檔位完成** | 依溢位程度給不同建議 |
| R2 全 CPU | `ollama ps` ＋ journalctl | `100% CPU`=FAIL，再分流 | ⏭️ 待 `#32`–`#35` | restart／更新／轉 R4 |
| R3 context 吃光 VRAM | `ollama ps` SIZE ＋ CONTEXT 欄 | SIZE 膨脹 >35% 來自 context =FAIL | ✅ **驗證（觸發值改 98304）** | `num_ctx` 調回 8192 |
| R4 WSL 驅動裝錯 | `/dev/dxg`＋`which -a`＋`dpkg -l` | dpkg 有 nvidia 套件 或 which 首位是 `/usr/bin` =FAIL | ✅ 健康態驗證（不做破壞測試） | purge ＋ `wsl --shutdown` |
| R5 其他程式佔 VRAM | `GPU Adapter Memory` 總量＋程序排名 | **平常不判定好壞**；只在 R1 觸發時升級為警告 | ✅ **驗證（含 `vmwp` 排除）** | 關程式／關硬體加速 |
| R6 服務／port | 兩側 `curl 11434`／`1234` | 拒連=沒起；回非 Ollama 內容=被占 | ⚠️ 健康態已驗，故障態待 `#28`–`#31` | `systemctl start ollama` |
| **R8 安裝失敗** | `/usr/local/lib/ollama` 空目錄＋`which zstd` | 目錄存在且空 ＋ 無 zstd → 安裝中途失敗 | ✅ **實例驗證（本機踩過）** | `sudo apt-get install zstd` 後重跑安裝 |
| **R9 溢位 log 直讀** | `journalctl` 的 `common_params_fit_impl` | `projected to use X` > `free device memory Y` → 溢位 | ✅ **驗證** | 同 R1／R3 |

---

### R0 前置盤點（決定後續規則跑不跑）

**偵測指令**【WSL】

```bash
nvidia-smi --query-gpu=name,memory.total,memory.used,driver_version --format=csv,noheader
```

**判斷條件**

- 有輸出 → 記下 VRAM 總量，供 R1／R3／R5 使用【實測：`NVIDIA GeForce RTX 5070 Ti, 16303 MiB, 3016 MiB, 596.49`】
- 指令不存在或失敗 → 轉 R4 的決策樹判斷是「沒有 N 卡」還是「驅動壞了」
- 確定沒有 NVIDIA GPU → 顯示「未偵測到支援的顯示卡」，**跳過 R1／R3／R5**，仍執行 R2／R4／R6

**輸出格式變體**

1. 【實測】CSV 格式穩定，單位固定是 `MiB`，欄位間是 `, `
2. 【實測·重要】WSL 側 banner 的 `NVIDIA-SMI 595.71.05` 與 `Driver Version: 596.49` **數字不同是正常的**
   （前者 Linux 端函式庫版本、後者 Windows 驅動版本）。不要把這個當異常。
   Windows 側 `nvidia-smi.exe` 則兩個都是 596.49【實測】
3. 【推測】多卡機器會有多行，第一版只取第 0 張並註明

---

### R1 模型塞不進 VRAM，部分層溢位到系統 RAM

> **文案已定稿，數字全部來自 2026-08-18 實測（`#09`–`#17`）。**

**文案（定稿）**

- **症狀**：模型有在回答，但一個字一個字慢慢吐，風扇變大聲。
- **後果**：模型太大，顯示卡放不下，有一部分被擠到主記憶體改用 CPU 跑。
  本機實測：約**三成**被擠出去時**慢 3.3 倍**，約**八成**被擠出去時**慢 8.7 倍**。
  這不是「稍微慢一點」，是等待時間變成好幾倍。
- **修法**：依溢位程度分級（輕度→先看 R5 有沒有程式佔著顯存；重度→換小一號模型或量化）。

**實測基準（`#09`–`#17`，llama3.1:8b，固定提示詞，每檔位兩次取第二次）**

| 檔位 | num_gpu | PROCESSOR | 層數 | nvidia-smi used | SIZE | 第 1 次（棄） | **第 2 次（採用）** | 相對 A |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| A | 未設定 | `100% GPU` | 33/33 | 8076 MiB | 5.3 GB | 47.71 | **105.812 tok/s** | 1.00× |
| B | 24 | `29%/71% CPU/GPU` | 24/33 | 6822 MiB | 5.6 GB | 30.45 | **31.896 tok/s** | **3.32× 慢** |
| C | 4 | `82%/18% CPU/GPU` | 4/33 | 4040 MiB | 5.6 GB | 12.02 | **12.144 tok/s** | **8.71× 慢** |

測速前背景 VRAM：**2799 MiB**（⚠️ 含穩定的背景影片解碼負載，見檔頭但書）

> **文案裡的數字要不要寫精確值？** 建議寫「約 3 倍」「約 9 倍」而非 3.32／8.71——
> 這組數字是在單一機器、單一模型、含背景影片解碼負載的條件下測得，
> 精確到小數點會給使用者過度的精確感。**精確值留在本文件，文案用約數。**

**先前兩個推算的驗屍（保留紀錄，避免日後有人再推一次）**

| 來源 | 預測 | 實測對照 |
| --- | --- | --- |
| 實務估計 | 4/32 層在 CPU ≈ 慢 20–40% | ❌ **嚴重低估** |
| 純頻寬模型 | VRAM ~900GB/s vs DDR5 ~80GB/s，12% 溢位 ≈ 2.1 倍 | 方向正確：同模型換算 29% 溢位 ≈ 3.6 倍，實測 3.32 倍，**相當接近** |

→ 結論：**頻寬模型可用來估數量級，實務直覺不可靠。** 但文案仍只用實測值。

**偵測指令**【WSL】（前提：模型已載入。Ollama 預設閒置 5 分鐘卸載【文件】）

```bash
ollama ps
```

佐證（第二來源，待驗 U11）：

```bash
journalctl -u ollama --no-pager | grep -iE 'offload|layers' | tail -5
```

**判斷條件**

- PROCESSOR = `100% GPU` → PASS【驗證】
- PROCESSOR = `n%/m% CPU/GPU` → 本條命中，**依 CPU 百分比分級**：
  | CPU 百分比 | 等級 | 說明（依實測內插） |
  | --- | --- | --- |
  | 1–15% | WARN 輕度 | 先看 R5，關掉佔顯存的程式可能就夠 |
  | 16–50% | **FAIL 中度** | 實測 29% → 慢 3.3 倍 |
  | > 50% | **FAIL 重度** | 實測 82% → 慢 8.7 倍 |
  > 分級門檻是**依兩個實測點內插**的設計判斷，不是實測值本身。
  > 只有 29% 與 82% 兩點有數據，中間與兩端是外推【推測】。
- PROCESSOR = `100% CPU` → 轉 R2
- 清單空的（只有表頭）→ 不是故障，是沒有模型在載入狀態【驗證】

**輸出格式變體**

1. 【驗證·F4】欄位是 **`NAME ID SIZE PROCESSOR CONTEXT UNTIL`**——
   **有 `CONTEXT` 欄**（v2.1 標為【推測】，現已證實）。解析器欄位數要照這個寫
2. 【驗證·F7】空清單**只有表頭，沒有任何提示訊息**（不是「no models」之類）
3. 【驗證】PROCESSOR 字串實例：`100% GPU`、`29%/71% CPU/GPU`、`82%/18% CPU/GPU`——
   CPU 在前 GPU 在後，斜線兩側無空格，百分比與 `CPU/GPU` 之間有一個空格
4. 【驗證·F3·重要】**PROCESSOR 的百分比不是層數比例，是記憶體比例**：
   | num_gpu | 層數比例 | PROCESSOR 顯示 |
   | --- | --- | --- |
   | 24 | 24/33 = 72.7% | 71% GPU |
   | 4 | 4/33 = 12.1% | **18% GPU** |
   → **不能用 PROCESSOR 反推層數**，要層數就讀 log 的 `offloaded X/Y layers`（見 R9）
5. 【驗證·F6】本機版本是 **0.32.14**（v2.1 推測的 0.11.x 差距極大，版本假設不可靠）
6. 【社群·待驗 U3】server 沒起時：`Error: could not connect to ollama app, is it running?`

**重現方法（已執行，供日後在別台機器複驗）**

llama3.1:8b 的層數 = **33**（32 個 repeating block ＋ 1 個 output layer）【驗證·`#19`】。

⚠️ **不要用 `ollama run` 互動模式**（會卡住自動化流程），改用 HTTP API：

```bash
curl -s http://localhost:11434/api/generate -d '{"model":"llama3.1:8b","prompt":"用三句話解釋什麼是光合作用","stream":false,"options":{"num_gpu":24}}'
```

速度由回應的 `eval_count` ÷ (`eval_duration` ÷ 1e9) 計算（`eval_duration` 單位是奈秒）。
檔位 A 省略 `options`；檔位 B 用 `num_gpu:24`；檔位 C 用 `num_gpu:4`。

**方法學規則（實測證明必要）**：每檔位呼叫兩次、取第二次。
檔位 A 第一次只有 47.71 tok/s、第二次 105.812——差一倍，因為第一次含模型載入暖機。
**若取第一次當基準，倍率會被系統性放大。**

`num_gpu` 在 0.32.14 上**確實生效**【驗證·`#18`】，三檔位 PROCESSOR 明顯不同，
不需要 `OLLAMA_GPU_OVERHEAD` 備案。

**修法（分級）**

- **輕度溢位**：先看 R5 的清單，關掉佔 VRAM 的程式可能就夠了
  （**這是 R5 降級後的主要用途**，因果句見 R5）
- **中／重度溢位**：換小一號模型或更低量化
  ```bash
  ollama run llama3.1:8b
  ```
- **context 造成的溢位**：轉 R3（先調 `num_ctx` 比換模型划算，因為不損失模型品質）
- 報告會依偵測結果動態算：「你的卡是 X GB，建議選檔案大小 ≤ X×0.7 的模型」
  （0.7 仍是【推測】的經驗係數。本機參考點：16.3 GB 卡、預設 4096 context 時，
  5.3 GB 的載入大小可 100% 上 GPU，比值 0.33；但那是在有 2.8 GB 背景佔用的條件下）

---

### R2 完全跑在 CPU / GPU 沒被偵測到

**文案草稿**

- 症狀：不管換哪個模型都超慢，CPU 風扇狂轉，但顯示卡沒動靜。
- 後果：**這條才是 10 倍以上的量級**（頻寬差距 ~10x【推測】，實測倍率由三檔位測速的 C 檔位
  ＋本條觸發後的數字共同校準）。
- 修法：先重啟服務，不行就更新，再不行看 R4。

**偵測指令**【WSL】

```bash
ollama ps
```

```bash
journalctl -u ollama --no-pager 2>/dev/null | grep -iE 'gpu|cuda|discover' | tail -20
```

**判斷條件**

- PROCESSOR = `100% CPU` → FAIL，再分流：
  - `nvidia-smi` 正常 → runtime 沒抓到 GPU：restart → 更新 → 看 log
  - `nvidia-smi` 失敗 → 轉 R4
- log 出現 `no compatible GPUs were discovered`【社群·中信心，來自 Ollama 原始碼與大量 issue，
  本機未驗】 → 確認是偵測不到 GPU → 待驗 U4

**輸出格式變體**

1. 【文件】`100% CPU`
2. 【社群·待驗】log 字串如上；舊版可能不同
3. 【文件·systemd 常識】若 Ollama 是手動 `ollama serve` 跑的，log 在該終端機 stderr，journalctl 查不到

**怎麼故意觸發**（會暫停服務約 10 分鐘，可完全還原）

1. `sudo systemctl stop ollama`
2. 同終端機：`CUDA_VISIBLE_DEVICES=-1 ollama serve`（無效 GPU ID 強制 CPU【文件·官方 GPU 文件】）
3. ⚠️ 手動 serve 用的是 `~/.ollama`，systemd 服務用的是 `/usr/share/ollama/.ollama`，
   **不是同一個模型目錄** → 另開終端機跑 `ollama run llama3.2:1b --verbose` 會重新下載 1.3GB，屬預期
   （這個「雙模型目錄」坑本身值得列為未來候選規則 R7）
4. `ollama ps` → 預期 `100% CPU`；比對 eval rate 與 R1 的 A 檔位
5. 還原：Ctrl+C，`sudo systemctl start ollama`

**修法**

```bash
sudo systemctl restart ollama
```

```bash
curl -fsSL https://ollama.com/install.sh | sh
```

---

### R3 context 開太大，KV cache 吃光 VRAM

**文案（定稿）**

- **症狀**：剛開始很快，對話越長越慢；或一調大 context 就變慢。
- **後果**：對話記憶（KV cache）會佔掉好幾 GB。**兩段式後果，兩段都要講**：
  1. **就算還塞得進顯示卡，也會變慢。** 本機實測：context 從 4096 開到 65536，
     在完全沒有溢位（`100% GPU`）的情況下速度仍從 105.8 掉到 88.5 tok/s（**慢 16%**）
  2. **塞不下時就變成 R1 的溢位**，代價是好幾倍（見 R1）
- **修法**：把 context 調回 8192。

**KV cache 計算式（Ollama 自己的 log 完全證實）**

```
每 token = 2 × 層數 × KV heads × head dim × 2 bytes
llama3.1-8b = 2 × 32 × 8 × 128 × 2 = 131072 bytes = 128 KiB/token
```

【驗證·`#19`／`#20`／`#22`】三個實測點完全線性：

```
llama_kv_cache: size =   512.00 MiB (  4096 cells, 32 layers, 1/1 seqs), K (f16):  256.00 MiB, V (f16):  256.00 MiB
llama_kv_cache: size =  8192.00 MiB ( 65536 cells, 32 layers, 1/1 seqs), K (f16): 4096.00 MiB, V (f16): 4096.00 MiB
llama_kv_cache: size = 12288.00 MiB ( 98304 cells, 32 layers, 1/1 seqs), K (f16): 6144.00 MiB, V (f16): 6144.00 MiB
```

512 MiB ÷ 4096 = **128 KiB/token**，與計算式完全吻合。
換算：32k ≈ 4GB，64k ≈ 8GB，96k ≈ 12GB，128k ≈ 16GB。
各模型不同，GQA 的 KV heads 數是關鍵變因。

**前提條件【驗證·F9／F10】**：本機 `OLLAMA_KV_CACHE_TYPE` 為空（預設 **f16 未量化**）、
`OLLAMA_FLASH_ATTENTION:false`、`OLLAMA_NUM_PARALLEL:1`。
三者任一改變都會讓上面的換算失效——**階段二要先讀這三個值再套公式**。

**偵測指令**【WSL】（核心思路：不硬算 KV，直接量——「載入後大小」減「檔案大小」＝ context 的代價）

```bash
ollama list
```

```bash
ollama ps
```

**判斷條件**（門檻是初值【推測】，驗證時一起調）

- `ollama ps` SIZE ≤ VRAM×0.9 → PASS
- SIZE > VRAM → FAIL，再歸因：
  - (SIZE − `ollama list` 檔案大小) ÷ SIZE > 35% → **主因是 context** → 本條修法
  - 否則 → 主因是模型本身太大 → 給 R1 修法
- 設計理由：R1 從 Ollama 的回報抓「溢位事實」，R3 用算術歸因「是誰造成的」，兩條不打架

**輸出格式變體**

1. 【驗證】`ollama list` 欄位 `NAME ID SIZE MODIFIED`
2. 【驗證】`ollama ps` SIZE 單位 GB（實例：`5.3 GB`、`13 GB`、`18 GB`），小模型可能是 MB
3. 【驗證·F5】`OLLAMA_CONTEXT_LENGTH` 的預設**不是固定值**，官方說明是
   `default: 4k/32k/256k based on VRAM`——**依 VRAM 動態決定**。
   v2.1 推測的「固定 4096 或 2048」機制錯誤；本機 16GB 卡解析為 **4096**（`ollama ps` 的 CONTEXT 欄）
4. 【驗證·F10】`OLLAMA_NUM_PARALLEL` 預設為 **1**（server log 確認），KV 不會被乘倍

**怎麼故意觸發【驗證·觸發值已修正為 98304】**

```bash
curl -s http://localhost:11434/api/generate -d '{"model":"llama3.1:8b","prompt":"用三句話解釋什麼是光合作用","stream":false,"options":{"num_ctx":98304}}'
```

然後 `ollama ps`。

**實測結果（16.3 GB 卡 ＋ 約 2.8 GB 背景佔用）**

| num_ctx | SIZE | PROCESSOR | KV cache | nvidia-smi | tok/s |
| --- | --- | --- | --- | --- | --- |
| 4096（預設） | 5.3 GB | `100% GPU` | 512 MiB | 8076 MiB | 105.812 |
| **65536** | **13 GB** | **`100% GPU`** ← 沒溢位 | 8192 MiB | 15357 MiB | 88.455 |
| **98304** | **18 GB** | **`22%/78% CPU/GPU`** ← 觸發 | 12288 MiB | 15650 MiB | 22.321 |

> ⚠️【驗證·F1】**v2.1 的三選一分支不完整，實際出現第四種結果。**
> 原本預期 65536 會「壓在邊緣產生部分溢位」，實際是 **SIZE 確實膨脹到 13 GB
> 且 KV 完全沒被量化（正好 8192 MiB），但 16 GB 的卡就是塞得下**。
> 三選一裡沒有「數字符合預期但仍然塞得下」這一格。
>
> **在別台機器複驗時，正確的做法是階梯式往上加**：65536 →（不溢位）→ 98304 →（不溢位）→ 131072。
> 觸發值取決於「VRAM 總量 − 背景佔用」，沒有通用值。

**修法**

- 對話內：`/set parameter num_ctx 8192`
- 服務層（永久）：
  ```bash
  sudo mkdir -p /etc/systemd/system/ollama.service.d && printf '[Service]\nEnvironment="OLLAMA_CONTEXT_LENGTH=8192"\n' | sudo tee /etc/systemd/system/ollama.service.d/ctx.conf && sudo systemctl daemon-reload && sudo systemctl restart ollama
  ```
- 進階（KV 減半，需版本支援【文件·待驗 U9】）：加
  `Environment="OLLAMA_FLASH_ATTENTION=1"` 與 `Environment="OLLAMA_KV_CACHE_TYPE=q8_0"`

---

### R4 WSL2 驅動裝錯（在 WSL 裡裝了 Linux 版 NVIDIA 驅動）

> **本條不做觸發驗證。** 理由（採納你的判斷）：判斷條件是自明的布林檢查，
> 而 purge 之後 ldconfig 狀態不保證乾淨還原，最壞要 `wsl --shutdown` 重來——
> 為了驗一個邏輯自明的規則去弄壞 GPU 直通，風險不對稱。
> 改用**健康態基準反證**：本機的 PASS 輸出已完整採樣（第 4 節），FAIL 分支靠邏輯檢閱＋引用來源。

**文案草稿**

- 症狀：在 WSL 打 `nvidia-smi` 會報錯，或裝完某個「CUDA 教學」後 GPU 就消失了。
- 後果：GPU 完全用不到，一切退回 CPU（＝R2 的量級）。
- 修法：把 WSL 裡誤裝的 NVIDIA 套件全部移除。**正確做法是驅動只裝在 Windows 側。**

**權威依據（逐字引用）**

> "The CUDA driver installed on Windows host will be stubbed inside the WSL 2 as libcuda.so,
> therefore users **must not install any NVIDIA GPU Linux driver within WSL 2**."
> — NVIDIA CUDA on WSL User Guide（見附錄 S1，多個 CUDA 版本一致）

**偵測指令**【WSL】（決策樹，按順序）

```bash
ls /dev/dxg && ls /usr/lib/wsl/lib/libcuda.so.1
```

```bash
which -a nvidia-smi
```

```bash
dpkg -l | grep -E '^ii +(nvidia-|libnvidia-)' ; echo "exit=$?"
```

```bash
nvidia-smi
```

**判斷條件**（PASS 對照組見第 4 節，全部實測）

1. `/dev/dxg` 不存在 → WSL 層 GPU 支援沒啟用（WSL1／WSL 太舊／Windows 太舊）→ 修法 `wsl --update`
   【實測本機：存在】
2. dpkg 有任何輸出（exit=0）→ **FAIL：WSL 裡裝了 Linux NVIDIA 套件**【實測本機：乾淨，exit=1】
3. `which -a nvidia-smi` 首位不是 `/usr/lib/wsl/lib/nvidia-smi` 而是 `/usr/bin/nvidia-smi` → 同上 FAIL
   【實測本機：只有 `/usr/lib/wsl/lib/nvidia-smi`】
   - 補充【實測】：本機 PATH 中 `/usr/bin` 排在 `/usr/lib/wsl/lib` **之前**，
     所以一旦誤裝，Linux 版確實會蓋掉 WSL 版——這條規則的前提在本機成立
4. 前三關過但問不到 NVIDIA 顯示卡（`nvidia-smi` 不存在或執行失敗）
   → **INFO，不是 WARN**，並列出三種可能讓使用者對號入座（見下方修正紀錄）
5. 全過 → PASS

### ⚠️ 修正紀錄：第 4 關原本是錯的（第一批外部實測 n=2 發現）

**原本的判斷：** 第 4 關判 WARN，文案直接斷定「可能是 Windows 那邊的驅動太舊或沒裝好」，
並要求使用者去更新 NVIDIA 驅動。

**外部實測打臉：** 一台 Surface Book（Intel 內顯 ＋ NVIDIA 獨顯的混合機制）上，
`/dev/dxg` 存在但 WSL 內找不到 `nvidia-smi`。R0 已正確判定「未偵測到支援的顯示卡」並 SKIP，
但 R4 仍給出驅動警告，而且**結論層把它標成「最主要的問題」**。
使用者回報這個診斷不適用於他的機器。

**根本錯誤：** `/dev/dxg` 在**任何**啟用 GPU 直通的 WSL2 上都存在，Intel 與 AMD 也算。
它證明的是「WSL 的顯示卡通道通了」，**不是「這台應該要有 NVIDIA」**。
拿它當「NVIDIA 應該存在」的證據，就會對沒有 N 卡的機器產生自信的錯誤建議——
**跟 R5 的 `vmwp` 陷阱（叫使用者關掉自己的模型）是同一類問題**：
規則本身邏輯自洽，但把「我偵測不到」誤讀成「它壞了」。

**修正後的判斷條件（第 4 關）：**

- 等級 **WARN → INFO**。「這台電腦沒有 NVIDIA 顯示卡」不是一個需要警告的狀態
- 文案改成條件式，涵蓋三種可能而非斷定：
  1. 本來就沒有 NVIDIA 卡（只有內顯或 AMD）→ 正常，不用處理
  2. 雙顯卡筆電（Surface Book、多數電競筆電）→ WSL 常問不到獨顯，已知限制，不是故障
  3. 桌機且確定有 NVIDIA 卡 → 才建議更新 Windows 驅動
- 規則標題在這個分支改為「WSL 顯示卡支援狀態」，避免用「驅動」二字暗示有驅動問題
- 結論層加防護：`GPU_PRESENT=0` 時 R4 一律不得被選為「最主要的問題」
  （R4 現在是 INFO 本來就選不到，這層是防止日後改回 WARN 時復發）

**連帶修正 R2：** 同一個錯誤也存在於 R2。它原本在偵測不到 GPU 時仍判 FAIL 並說
「先解決顯示卡驅動的問題」。對一台本來就沒有 N 卡的機器，「跑在 CPU 上」是**預期結果**
而不是故障。已改為：`GPU_PRESENT=0` 時降為 INFO，文案說明這是硬體差距不是設定錯誤，
建議改用更小的模型。結論層也加了對應的說法。

**這件事的教訓（值得寫進未來的規則設計原則）：**
每一條規則都要能區分「我偵測到 X 是壞的」與「我偵測不到 X」。
第二種情況下，工具能給的最好答案往往是「列出幾種可能讓你自己判斷」，
而不是挑一個最可能的原因斷定。**自信的錯誤建議比誠實的不確定更傷害使用者。**

**錯誤字句變體（引用來源，不再靠推測）**

| 字句 | 來源 | 信心 |
| --- | --- | --- |
| `Failed to initialize NVML: GPU access blocked by the operating system` | microsoft/WSL issues #9938／#10289／#12859／#14339（見附錄 S2） | 【社群·高】字串本身確定；**但成因多為權限／Server 版 Windows，未必是誤裝驅動** |
| `Failed to properly shut down NVML: GPU access blocked by the operating system` | microsoft/WSL #9166 | 【社群·高】 |
| `NVIDIA-SMI has failed because it couldn't communicate with the NVIDIA driver` | 經典訊息，常見於裝了 Linux 驅動但無核心模組 | 【社群·中】與「誤裝」的對應關係是【推測】 |
| `command not found` | — | 【確定】 |

> ⚠️ 誠實標註：上表**字串**有來源，但「哪個字串 ↔ 哪個成因」的對應關係我沒有可靠依據。
> 階段二的做法應該是：**用 dpkg／which 判定成因（那是確定的），錯誤字句只用來輔助說明**，
> 不要反過來用字串猜成因。

**修法**

```bash
sudo apt-get purge -y '^nvidia-.*' '^libnvidia-.*' && sudo apt-get autoremove -y && hash -r
```

- 工具**只在 dpkg 確認有誤裝套件時**才顯示這條，避免使用者在乾淨機器上亂跑
- 加上：Windows 側更新驅動的點擊步驟 ＋ 在 PowerShell 跑 `wsl --shutdown` 後重開

---

### R5 其他程式佔用 VRAM（已降級為 R1 的證據）

> **設計變更：本條不再是獨立的好壞判定。**
> 理由：同樣 3GB，對 8B 模型無感、對 30B 模型致命，而工具不知道使用者想跑什麼。
> 絕對門檻（1.5GB）與比例門檻（VRAM 25%）都是假訊號。

**兩段式行為**

> ⚠️⚠️ **最高優先的實作注意事項：必須排除 `vmwp`，否則工具會建議使用者關掉自己的模型。**
> 詳見下方「`vmwp` 排除規則」。這條沒做對，R5 就是一個會造成傷害的功能。

**第一段——資訊區塊（永遠顯示，不判定好壞，無 PASS/WARN/FAIL 標籤）**

> 目前有 **3.0 GB** 顯示卡記憶體被其他程式使用中。
> 佔用最多的是：Windows 桌面特效、NVIDIA Overlay、Steam。
> 這不一定是問題——只有當模型塞不下時才需要處理。

**第二段——條件式升級（只有 R1 實際觸發溢位時才出現，等級 WARN）**

因果句模板：

> 你的模型需要 **{需求} GB**，這張卡有 **{總量} GB**，
> 但現在有 **{其他程式佔用} GB** 被其他程式佔著，所以差 **{缺口} GB** 塞不下。
> 目前佔用最多的是 **{程式名}**——關掉它很可能就能全部放進顯示卡。

#### ⚠️ `vmwp` 排除規則（實作必做）【驗證·F2·`#24`】

溢位狀態下的程序排名實測：

```
vmwp                           13,935 MB   ← 這就是使用者自己的模型
NVIDIA Overlay                  6,589 MB
dwm                             3,928 MB
```

`vmwp` = Virtual Machine Worker Process，**就是 WSL 那台虛擬機**。
**在 WSL 裡跑的 Ollama，它的 VRAM 在 Windows 側全部記在 `vmwp` 名下，而且穩居第一名。**

實作要求：

1. **`vmwp` 一律從「建議關閉」的候選名單中排除**——建議關掉它等於叫使用者關掉自己的模型
   （而且會連 WSL 整個環境一起關掉）
2. 顯示時把它標成人話：**「WSL 內的程式（很可能就是你的本地模型）」**
3. 同理排除：`dwm`（Windows 桌面合成器，關不掉）、`System`、`Registry`

> 這條是整份文件裡**唯一一條「沒做會主動造成傷害」的規則**，不是效能問題。

**因果判定的算術**

```
需求        = ollama ps 的 SIZE
其他程式佔用 = nvidia-smi used − 模型在 GPU 上的部分
             模型在 GPU 上的部分 ≈ SIZE × PROCESSOR 的 GPU 百分比 + 250 MiB  【驗證·U12】
缺口        = 需求 − (總量 − 其他程式佔用)
升級條件    = 缺口 > 0 且 存在單一程式佔用 ≥ 缺口（排除 vmwp / dwm / System）
```

**U12 驗證結果【`#26`】**：推算成立，且有一個穩定的常數偏差。

| 檔位 | nvidia-smi 增量（減 2799 基線） | `SIZE × GPU%` | 殘差 |
| --- | --- | --- | --- |
| A | 5277 MiB | ≈ 5054 MiB | +223 MiB |
| B | 4023 MiB | ≈ 3792 MiB | +231 MiB |
| C | 1241 MiB | ≈ 961 MiB | +280 MiB |

殘差穩定在 **+223 ~ +280 MiB**（CUDA context 與非層權重的固定開銷）→ 公式加上 **+250 MiB** 修正。

> 但實務上**先解決取樣漂移比修正這個常數重要**：背景 VRAM 本身的漂移量（1.2 GB）
> 是這個修正值（250 MiB）的五倍。

**取樣規則【驗證·必做】**：背景 VRAM 同日取樣為
`3016 / 2735 / 2725 / 2690 / 2659 / 2638 / 2799 / 1763` MiB，**最大差距超過 1.2 GB**
（測試後卸載模型反而低於測試前基線）。
→ **必須取樣 3 次取中位數，並保留至少 500 MiB 容差。單次取樣的數字不可信。**

**偵測指令**

總量【WSL】（**取樣 3 次取中位數**）：

```bash
nvidia-smi --query-gpu=memory.used,memory.total --format=csv,noheader
```

總量的第二來源【Windows PowerShell，適配器層級，與 nvidia-smi 吻合 0.1% 以內】：

```powershell
Get-Counter '\GPU Adapter Memory(*)\Dedicated Usage' | Select-Object -ExpandProperty CounterSamples | ForEach-Object { '{0,-45} {1,8:N0} MB' -f $_.InstanceName, ($_.CookedValue/1MB) }
```

抓出「是誰」【必須在 Windows PowerShell 跑；**僅用於排名，不可當絕對值**】：

```powershell
Get-Counter '\GPU Process Memory(*)\Dedicated Usage' | Select-Object -ExpandProperty CounterSamples | Where-Object {$_.CookedValue -gt 200MB} | Sort-Object CookedValue -Descending | ForEach-Object { $p=[int]($_.InstanceName -replace 'pid_(\d+).*','$1'); '{0,-25} {1,8:N0} MB' -f (Get-Process -Id $p -ErrorAction SilentlyContinue).ProcessName, ($_.CookedValue/1MB) }
```

**為什麼只能走效能計數器（兩條路都實測堵死了）**

- WSL 的 `nvidia-smi` **看不到 Windows 程式**（本機只列出 `/Xwayland`）【實測】
- Windows 的 `nvidia-smi.exe` 在 WDDM 驅動模式下，每程序記憶體欄**全部是 `N/A`**
  （本機 31 個 C+G 程序，無一例外）【實測】

**輸出格式變體**

1. 【驗證】counter 名稱 `GPU Process Memory` / `Dedicated Usage` 在**中文版 Windows 上仍是英文**；
   Instance 格式 `pid_14004_luid_0x00000000_0x0001674a_phys_0`
2. ✅【驗證·U6 已解決】**兩個 counter 的可信度完全不同：**

   | 來源 | 實測值 | 判定 |
   | --- | --- | --- |
   | `nvidia-smi` 總量 | 15,689 MiB | 基準 |
   | **`GPU Adapter Memory\Dedicated Usage`（整張卡）** | **15,709 MB** | ✅ **吻合 0.1% 以內，可信** |
   | `GPU Process Memory\Dedicated Usage` 前三名加總 | 24,452 MB | ❌ **膨脹，超過實際總量** |

   - **設計定案：總量用 `GPU Adapter Memory` 或 `nvidia-smi`；`GPU Process Memory` 只用來排名。**
   - **因果句裡不引用單一程式的絕對數字**，只說「佔用最多的是 X」。
     v2.1 的推測（「counter 是配置額度」）方向正確，現在有量化證據。
3. 【驗證】pid → 程式名的對映**可用**，實測輸出：`vmwp` / `NVIDIA Overlay` / `dwm`
4. 【驗證·必做】程式名要做「人話對映」給不懂底層的使用者看。已知需要處理的：
   | 程序名 | 顯示成 | 可否建議關閉 |
   | --- | --- | --- |
   | `vmwp` | WSL 內的程式（很可能就是你的本地模型） | ❌ **絕對不可** |
   | `dwm` | Windows 桌面特效 | ❌ 關不掉 |
   | `NVIDIA Overlay` | NVIDIA 遊戲overlay | ✅ 可 |
   | `chrome` / `msedge` | Chrome／Edge 瀏覽器 | ✅ 可（或關硬體加速） |
   | `steamwebhelper` | Steam | ✅ 可 |
   | `wallpaper64` | Wallpaper Engine 動態桌布 | ✅ 可 |

**怎麼故意觸發**（零風險）

1. 記基準：跑 WSL 總量指令 3 次取中位數
2. 開瀏覽器 ＋ 十幾個分頁 ＋ 兩個 YouTube 影片，再量一次 → 預期成長數百 MB～2GB
3. 跑 PowerShell 那條 → 瀏覽器程序應出現在前幾名
4. **驗因果升級**：在溢位狀態下同時跑本條，確認「缺口」與「大戶」兩個數字都能算出來
   → ✅ 已於 `#26` 驗證通過
5. 還原：關掉分頁

> 📌 步驟 2「開關瀏覽器」的驗證（`#27`）**未執行**：驗證當天機器上有穩定的背景影片解碼負載，
> 開關瀏覽器會干擾該負載並破壞「背景條件穩定」的前提。這一格沒有填入任何估計值，
> 日後可在無背景負載時補做。

**修法（點擊步驟，無指令）**

- Chrome／Edge：設定 → 系統 → 關閉「使用硬體加速」
- Discord：設定 → 進階 → 關硬體加速
- Wallpaper Engine：暫停或關閉（本機實測有在跑，文案可直接點名常見兇手）

---

### R6 服務沒起來 / port 被佔用

**文案草稿**

- 症狀：聊天介面轉圈圈、連線錯誤、或「明明裝了卻找不到模型」。
- 後果：根本沒在計算，等再久都不會有結果——先修這個才有得談。
- 修法：啟動服務，或找出佔走 port 的程式。

**偵測指令**（NAT 模式實測確認：**兩側要分開查**）

【WSL】查 WSL 側：

```bash
curl -s --max-time 2 http://localhost:11434/ ; echo " <= 11434" ; curl -s --max-time 2 http://localhost:1234/v1/models ; echo " <= 1234"
```

【WSL】透過 interop 查 Windows 側（interop 已實測可用）：

```bash
powershell.exe -NoProfile -Command "try{(Invoke-WebRequest -UseBasicParsing -TimeoutSec 2 http://localhost:11434/).Content}catch{'WIN-11434-DOWN'}"
```

**判斷條件**

- 回 `Ollama is running` → 該側 Ollama 正常【社群·待驗 U3】；`/api/version` 回 `{"version":"..."}`【文件】
- 連線被拒（無輸出，exit 7）→ 該側沒有服務【確定·curl 語義】
- **有回應但內容不是 Ollama** → port 被佔 → `ss -ltnp 'sport = :11434'`（WSL）／
  `Get-NetTCPConnection`（Windows，實測可用）找 PID
- 兩側都在跑 → WARN：兩套 Ollama 並存，模型目錄不同步，常造成「模型不見了」的錯覺
- LM Studio 看 1234；**注意 server 要在 app 裡手動開（Developer 分頁），沒開不算故障**【文件】

**假陽性警告（實測案例）**

本機 port 8080 有人監聽，查明是 **Steam 的 steamwebhelper**（PID 40812），不是 llama.cpp【實測】。
→ **只看 port 有沒有人聽是不夠的，必須驗證回應內容或程序名。**

**輸出格式變體**

1. 【社群·高信心】`Ollama is running`；【文件】`{"version":"0.11.x"}`
2. 【推測】LM Studio `/v1/models` 回 OpenAI 相容格式 `{"data":[...],"object":"list"}` → U8
3. 【確定】被 python 假服務佔走時 curl 拿到 HTML 目錄列表
4. 【文件】mirrored 網路模式下兩側 localhost 互通、兩套服務會搶 port——
   本機是 **NAT**【實測】，此變體僅記錄

**怎麼故意觸發**（接在 R2 的服務停止狀態後做最順）

1. 「沒起來」態：`sudo systemctl stop ollama` → 跑偵測 → 預期 WSL 側拒連
2. 「被佔用」態：服務停著，跑 `python3 -m http.server 11434`（本機有 python3【實測】）
   → 跑偵測 → 預期「有回應但不是 Ollama」
3. 還原：Ctrl+C，`sudo systemctl start ollama`

**修法**

```bash
sudo systemctl start ollama
```

被佔用時：`ss -ltnp 'sport = :11434'` 找出 PID 與程式名，顯示給使用者決定關誰。

---

### R8 Ollama 安裝中途失敗（缺 `zstd`）

> **正式納入。本機在 2026-08-18 實際踩到這個坑**，從現象到根因到修法全程有紀錄。

**文案（定稿）**

- **症狀**：照官方教學貼了那行安裝指令，看起來跑完了，但打 `ollama` 說找不到指令。
- **後果**：Ollama 根本沒裝起來，什麼都不能用。錯誤訊息其實有印出來，
  但會被前面的輸出蓋過去，很容易漏看。
- **修法**：補裝一個小工具再重跑一次安裝。

**偵測指令**【WSL】

```bash
which ollama || (ls -d /usr/local/lib/ollama 2>/dev/null && ls -A /usr/local/lib/ollama)
```

```bash
which zstd
```

**判斷條件**【驗證·實例】

- `ollama` 指令存在 → 不適用本條，跳過
- `ollama` 不存在 **且** `/usr/local/lib/ollama` 存在 **且為空** **且** `zstd` 不存在
  → **FAIL：安裝在解壓縮階段中止**
- `ollama` 不存在且上述目錄也不存在 → 使用者根本沒裝過，給安裝指引（不是本條）

**原理**（安裝腳本第 134–143 行，唯讀檢視確認）

```sh
if curl --fail --silent --head --location ".../${filename}.tar.zst..." >/dev/null 2>&1; then
    if ! available zstd; then
        error "This version requires zstd for extraction. Please install zstd and try again:
  - Debian/Ubuntu: sudo apt-get install zstd"
    fi
```

Ollama 已改用 `.tar.zst` 發佈。腳本會先建立目錄（第 169–170 行）再下載解壓（第 171 行），
所以缺 `zstd` 時會留下**空目錄 ＋ 磁碟用量零變化**這個特徵組合。

**本機實測證據**

```
$ ollama --version         → command not found
$ ls -la /usr/local/lib/ollama/  → 空目錄，timestamp 15:29:12
$ which zstd               → exit=1
$ dpkg -l | grep zstd      → ii libzstd1（只有函式庫，沒有 CLI）
$ df -h /                  → 與安裝前完全相同，未下載任何東西
```

**命中率評估**：**Ubuntu 26.04（最新 LTS）預設不含 `zstd` CLI**，
所以任何在乾淨 Ubuntu 26.04 上照官方一行指令安裝的人都會踩到。

**上游狀態**（2026-08-18 檢索）：`repo:ollama/ollama zstd` 共 20 筆，
但全部是**別的情況**——六筆是手動安裝文件缺 `--zstd` 旗標（#15693、#15694、#15896、
#15710、#14036、#14159），一筆（#15291）是 zstd 存在但格式錯誤。
**「install.sh 在缺 zstd 的乾淨系統上直接失敗」查無專屬 issue。**
最接近的是第三方 repo 的 ai-action/setup-ollama #423。
→ 官方短期內不太可能修，**R8 的價值因此更高**。

**修法**

```bash
sudo apt-get install zstd
```

```bash
curl -fsSL https://ollama.com/install.sh | sh
```

> 空的 `/usr/local/lib/ollama` 不需要清除，重跑安裝會直接沿用（本機實測：安裝腳本自己清掉了殘留）。

---

### R9 直接解析溢位判定 log

> **正式納入。** 這是驗證過程中意外發現的資料來源，比從 `ollama ps` 反推更精確。

**原理**：`LLAMA_ARG_FIT`（預設 `on`）會在載入時自動計算能放幾層進 GPU，
**並把「需要多少 vs 有多少」的決策過程寫進 log**。

**偵測指令**【WSL】

```bash
journalctl -u ollama --no-pager | grep -E 'common_params_fit_impl|offloaded [0-9]+/[0-9]+ layers' | tail -6
```

**判斷條件**【驗證·`#19`／`#22`】

- 出現 `offloaded X/Y layers to GPU` 且 **X < Y** → **確定溢位**，且直接得到精確層數比例
- `projected to use A MiB of device memory vs. B MiB of free device memory` 且 **A > B**
  → 溢位的**量化原因**：差 `A − B` MiB
- `will leave N >= 1024 MiB of free device memory, no changes needed` → 沒有溢位

**實測樣本**

溢位時（num_ctx 98304）：

```
common_params_fit_impl: projected to use 16895 MiB of device memory vs. 15011 MiB of free device memory
load_tensors: offloaded 26/33 layers to GPU
```

未溢位時：

```
common_params_fit_impl: projected to use 987 MiB of device memory vs. 15011 MiB of free device memory
common_params_fit_impl: will leave 14023 >= 1024 MiB of free device memory, no changes needed
load_tensors: offloaded 33/33 layers to GPU
```

強制 num_gpu=4 時：

```
load_tensors: offloading output layer to GPU
load_tensors: offloading 3 repeating layers to GPU
load_tensors: offloaded 4/33 layers to GPU
```

**為什麼比 `ollama ps` 好**

| | `ollama ps` PROCESSOR | R9 的 log |
| --- | --- | --- |
| 精度 | 記憶體百分比，**不等於層數比例**（F3） | **精確層數** `X/Y` |
| 缺口 | 要自己用 SIZE 反推 | **直接給** `A − B` MiB |
| 時效 | 只在模型載入中（5 分鐘）有效 | log 保留，模型卸載後仍可查 |

**風險**【推測】：log 字串來自 llama.cpp 上游，**跨版本可能改變**。
階段二應該**兩個來源都讀**：`ollama ps` 當主、R9 log 當佐證與精算，
任一不可用時仍能給出診斷。

**權限備註**【驗證】：讀 `journalctl -u ollama` **不需要 sudo**，
使用者屬於 `adm` 群組即可（本機實測通過）。

---

## 4. 基準樣本（本機正常狀態原始輸出，2026-08-18）

### 機器規格

| 項目 | 值 |
| --- | --- |
| GPU / VRAM | NVIDIA GeForce RTX 5070 Ti / 16303 MiB |
| 驅動 | Windows 596.49（WSL 側 NVIDIA-SMI 顯示 595.71.05，正常）|
| CUDA | 13.2 |
| Windows | Build 10.0.26200 |
| WSL | 2.7.11.0，kernel 6.18.33.2，WSLg 1.0.73.2 |
| 發行版 | Ubuntu 26.04 LTS，systemd 已啟用 |
| RAM | Windows 30.6 GB；WSL 14 GB ＋ 4 GB swap |
| CPU | 16 執行緒（WSL 可見）|
| 磁碟 | WSL `/` 可用 950G；C: 可用 731G |
| 網路模式 | **NAT** |
| 閒置 VRAM 基線 | **1.7–3.0 GB，會漂移**（桌面＋Wallpaper Engine＋NVIDIA Overlay＋QQ＋Discord＋Steam）<br>同日取樣：`3016 / 2735 / 2725 / 2690 / 2659 / 2638 / 2799 / 1763` MiB → **必須取中位數** |

### WSL 側 nvidia-smi（R0／R4 的 PASS 對照）

```
| NVIDIA-SMI 595.71.05    Driver Version: 596.49    CUDA Version: 13.2 |
|   0  NVIDIA GeForce RTX 5070 Ti   On  | 00000000:01:00.0  On | N/A |
|  0%   44C    P8    48W / 300W |  3016MiB / 16303MiB | 18%  Default |
| Processes:  0  N/A  N/A  400  G  /Xwayland  N/A |
```

```
$ nvidia-smi --query-gpu=name,memory.total,memory.used,driver_version --format=csv,noheader
NVIDIA GeForce RTX 5070 Ti, 16303 MiB, 3016 MiB, 596.49
```

### Windows 側 nvidia-smi.exe（注意每程序記憶體全 N/A）

```
| NVIDIA-SMI 596.49    Driver Version: 596.49    CUDA Version: 13.2 |
|   0  NVIDIA GeForce RTX 5070 Ti  WDDM | ... | 3076MiB / 16303MiB |
|  0  N/A  N/A  19752  C+G  ...Discord.exe        N/A |
|  0  N/A  N/A  34992  C+G  ...wallpaper64.exe    N/A |
|  0  N/A  N/A  37384  C+G  ...steamwebhelper.exe N/A |
（共 31 個 C+G 程序，記憶體欄全部 N/A）
```

### PowerShell GPU 計數器（中文版 Windows，counter 名仍是英文）

```
InstanceName                                  MB
pid_14004_..._phys_0（NVIDIA Overlay）      6636
pid_2112_..._phys_0（dwm 桌面合成器）        4313
pid_37384_..._phys_0（steamwebhelper）        325
```

> 加總遠超 nvidia-smi 的 3.0GB → 見 R5 變體 2 與 U6。

### R4 健康態三連（FAIL 分支的對照組）

```
$ which -a nvidia-smi          → /usr/lib/wsl/lib/nvidia-smi（僅此一個）
$ dpkg -l | grep nvidia        → （無輸出，exit=1）
$ ldconfig -p | grep libcuda   → libcuda.so.1 => /usr/lib/wsl/lib/libcuda.so.1
$ ls /dev/dxg                  → crw-rw-rw- 1 root root 10, 258 /dev/dxg
```

### free -h / df -h（節錄）

```
Mem: 14Gi total / 1.7Gi used / 13Gi available    Swap: 4.0Gi
/dev/sdd   1007G  6.4G  950G  1% /
drivers     931G  200G  731G 22% /usr/lib/wsl/drivers   ← 這就是 C:，階段二可從這裡讀 C: 剩餘空間
```

### wsl.exe --version（中文標籤 ＋ NUL 字元）

```
WSL 版本： 2.7.11.0
核心版本： 6.18.33.2-2
Windows 版本： 10.0.26200.9168
```

> **階段二不要解析這個指令**（在地化 ＋ 需要 `tr -d '\0'`）。改用 `/proc/version`。

### 引擎痕跡掃描結果

| 對象 | 檢查了什麼 | 結果 |
| --- | --- | --- |
| Ollama (WSL) | PATH、`~/.ollama`、systemd unit、port 11434 | 無 |
| Ollama (Windows) | `Get-Command`、`%LOCALAPPDATA%\Programs\Ollama`、`%USERPROFILE%\.ollama`、port 11434 | 無 |
| LM Studio | 安裝目錄、`.lmstudio`、`.cache\lm-studio`、`lms` 指令、port 1234 | 無 |
| llama.cpp | WSL 二進位／原始碼、port 8080 | WSL 無；Windows 8080 ＝ Steam（假陽性）|
| vLLM | `pip show vllm`、conda、HF cache、port 8000 | 無 |

### Ollama 健康態基準（2026-08-18 補採，Ollama 0.32.14）

```
$ ollama --version          → ollama version is 0.32.14
$ which -a ollama           → /usr/local/bin/ollama
$ systemctl is-active ollama→ active（is-enabled → enabled）
$ curl localhost:11434/     → Ollama is running
$ curl .../api/version      → {"version":"0.32.14"}

$ ollama list
NAME           ID              SIZE      MODIFIED
llama3.2:1b    baf6a787fdff    1.3 GB    2 seconds ago
llama3.1:8b    46e0c10c039e    4.9 GB    32 seconds ago

$ ollama ps                 （空載，只有表頭，無提示訊息）
NAME    ID    SIZE    PROCESSOR    CONTEXT    UNTIL

$ ollama ps                 （載入中，100% GPU）
NAME           ID              SIZE      PROCESSOR    CONTEXT    UNTIL
llama3.1:8b    46e0c10c039e    5.3 GB    100% GPU     4096       4 minutes from now
```

Server 啟動時的 GPU 偵測行（R2 的 PASS 對照組）：

```
msg="inference compute" id=0 library=CUDA compute=12.0 name=CUDA0
  description="NVIDIA GeForce RTX 5070 Ti" driver=13.2 total="15.9 GiB" available="14.7 GiB"
```

> 💡 `available="14.7 GiB"` 是 **Ollama 自己算出來的可用 VRAM**，
> 已扣除背景程式佔用。這比 R5 的手工算術更直接，階段二可考慮優先採用此來源。

---

## 5. 待驗證清單（結案狀態）

| # | 是什麼 | 結果 | 影響哪條 |
| --- | --- | --- | --- |
| U1 | `ollama ps` 是否有 CONTEXT 欄 | ✅ **有**：`NAME ID SIZE PROCESSOR CONTEXT UNTIL` | R1 R2 R3 |
| U2 | 環境變數清單與預設值 | ✅ 全文已採（`#02`）。`CONTEXT_LENGTH` 動態、`KV_CACHE_TYPE` f16、`NUM_PARALLEL` 1 | R3 |
| U3 | server 沒起時的錯誤字句 | ⏭️ **未驗**（`#28`／`#29`，故障態未執行） | R6 |
| U4 | log 是否出現 `no compatible GPUs were discovered` | ⏭️ **未驗**（`#35`，故障態未執行） | R2 |
| U5 | `num_gpu` 是否真的強制生效 | ✅ **生效**，三檔位 PROCESSOR 明顯不同 | R1 |
| U6 | GPU 計數器 vs nvidia-smi 的矛盾 | ✅ **解決**：適配器層級可信、程序層級膨脹 | R5 |
| U7 | `OLLAMA_GPU_OVERHEAD` 備援觸發法 | ⏭️ 不需要（U5 生效，備案未動用） | R1 |
| U8 | LM Studio 回應格式 | ⏭️ 低優先（僅未來第二後端需要） | — |
| U9 | KV cache 預設型別／flash attention | ✅ **f16 未量化、flash attention off** | R3 |
| U10 | R4 錯誤字句 | ✅ 改為引用 GitHub issue（附錄 S2／S3） | R4 |
| U11 | `offloaded X/Y layers`，Y 是多少 | ✅ **Y = 33**，且升格為獨立規則 **R9** | R1 |
| U12 | `SIZE × GPU%` 推算準不準 | ✅ **成立**，殘差穩定 +223~280 MiB → 公式加 +250 MiB | R5 |
| U13 | `lms` CLI 是否不需要開 server | ⏭️ 低優先（保留供未來第二後端） | — |

**結案統計：9 項已解決、4 項未驗（U3／U4 待故障態；U8／U13 屬未來後端）。**

### 驗證後新增的未知數

| # | 是什麼 | 為什麼重要 |
| --- | --- | --- |
| **U14** | R1 的三檔位倍率在**無背景負載**的機器上是多少 | 目前數字含背景影片解碼負載。相對倍率應該成立，但沒有第二台機器佐證【推測】 |
| **U15** | R1 分級門檻（1–15% / 16–50% / >50%）是否合理 | 只有 29% 與 82% 兩個實測點，中間與兩端是內插外推 |
| **U16** | R9 的 log 字串跨版本穩定性 | 字串來自 llama.cpp 上游，可能隨版本改變 |
| **U17** | `#27` 開關瀏覽器的 VRAM 變化 | 驗證當天有背景影片解碼負載無法執行，日後補做 |

> 逐步驗證清單見同資料夾的 `verify-checklist.md`，完整原始輸出見 `verify-report.md`。

---

## 6. 驗證執行狀態

**前置（已完成 2026-08-18）**

```bash
sudo apt-get install zstd    # ⚠️ Ubuntu 26.04 必要，否則安裝會中止（見 R8）
curl -fsSL https://ollama.com/install.sh | sh
ollama pull llama3.1:8b    # 4.9GB，R1/R3 主力
ollama pull llama3.2:1b    # 1.3GB，R2 手動 serve 時會用到
```

| 階段 | 內容 | 空格編號 | 狀態 |
| --- | --- | --- | --- |
| 1 | R0 ＋ R6 健康態 ＋ U1／U2 格式採樣 | #01–#08 | ✅ **完成** |
| 2 | R1 三檔位測速 ＋ U5／U11 | #09–#19 | ✅ **完成** |
| 3 | R3（觸發值修正為 98304）＋ U9 | #20–#23 | ✅ **完成**（`#23` 不需執行） |
| 4 | R5 ＋ 溢位狀態驗因果 ＋ U6／U12 | #24–#27 | ✅ **完成**（`#27` 未執行，見 R5 註記） |
| 5 | R2 ＋ R6 兩個故障態 ＋ U3／U4 | #28–#35 | ⏭️ **未執行**，小抄見 `verify-report.md` 第 9 節 |
| 6 | ~~R4 觸發驗證~~ | — | **取消**（風險不對稱，健康態已驗） |

> 完整原始輸出見 `verify-report.md`。
> ⚠️ 階段 5 執行時記得：手動 `ollama serve` 用 `~/.ollama`，
> 服務用 `/usr/share/ollama/.ollama`（**已實測確認**），1b 模型會重新下載 1.3GB。

---

## 附錄：來源清單

| 代號 | 內容 | 來源 |
| --- | --- | --- |
| S1 | "users must not install any NVIDIA GPU Linux driver within WSL 2" | NVIDIA CUDA on WSL User Guide — https://docs.nvidia.com/cuda/wsl-user-guide/index.html |
| S2 | `Failed to initialize NVML: GPU access blocked by the operating system` | microsoft/WSL issues #9938、#10289、#12859、#14339 |
| S3 | `Failed to properly shut down NVML: ...` | microsoft/WSL issue #9166 |
| S4 | `lms ps` 欄位（Identifier／Type／Path／Size／Architecture，含 `--json`） | https://github.com/lmstudio-ai/docs/blob/main/3_cli/0_local-models/ps.md |
| S5 | `lms` 安裝路徑（Windows：`%USERPROFILE%/.lmstudio/bin/lms.exe`）、`lms bootstrap` | https://lmstudio.ai/blog/lms |
| S6 | `/api/v0/models` 欄位（state／max_context_length，無 GPU 資訊）、port 1234 | https://lmstudio.ai/docs/developer/rest/endpoints |
| S7 | `/api/v1/models` 的 `loaded_instances[].config` 含 context length、GPU offload | https://deepwiki.com/lmstudio-ai/docs/2.4-native-rest-api |
| S8 | LM Studio 0.4.0 推出原生 v1 API，v0 轉為 legacy | https://lmstudio.ai/blog/0.4.0 |
| **S9** | Ollama 安裝腳本（R8 的第 134–143 行 zstd 判斷、第 169–215 行 root 需求） | https://ollama.com/install.sh |
| **S10** | ollama/ollama 的 zstd issues（皆非 R8 情況）：#15693、#15694、#15896、#15710、#14036、#14159、#15291 | https://github.com/ollama/ollama/issues |
| **S11** | 第三方 repo 中最接近 R8 的回報：「Action should install zstd if it's not present」 | https://github.com/ai-action/setup-ollama/issues/423 |

---
