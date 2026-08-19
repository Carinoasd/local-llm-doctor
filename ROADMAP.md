# ROADMAP

> **這份文件記錄的是長期方向，不是當前開發計畫。**
>
> 當前實際優先序見下一節。本文件其餘部分描述的所有項目，
> 在有實測回報支持之前，都維持在願景階段——它們是「如果將來
> 需要，會往這個方向走」，不是待辦清單。
>
> 文末的「為什麼現在不做」記錄了擱置的判斷依據，重啟任何項目前
> 請先讀那一節。

---

## 當前優先序

| 狀態 | 項目 | 說明 |
| --- | --- | --- |
| ✅ 已完成 | R4 誤判修正 | 外部實測（n=2）發現：對非 NVIDIA／雙顯卡筆電誤判為驅動問題 |
| ✅ 已完成 | `--live` 模式 | 解決空載時 R1/R3/R5 全部 SKIP、核心價值展示不出來的問題 |
| ⬜ 待開始 | Windows 原生 Scan | 不依賴 WSL 的偵測路徑。需先決定三個架構問題：啟動入口如何分流、Windows/WSL 兩側 Ollama 並存的處理、規則是否分平台 |
| ⬜ 等待中 | 本文件其餘所有項目 | 等前三項的實測回報再決定是否升級成計畫 |

---

## 長期產品定位

若將來條件成熟，local-llm-doctor 可以從「WSL2 Ollama 一次性健檢腳本」
發展為：

> **本機 AI 環境的一鍵檢測、根因診斷、安全安裝、修復與驗證工具。**

主要服務對象維持不變：不懂 VRAM、GPU offload、context、驅動和 WSL 的
一般使用者。

它不會是聊天 UI、模型排行榜或 benchmark 平台。核心價值仍然是：

- 自動找出問題
- 顯示判斷證據
- 說明影響
- 提供安全修復計畫
- 經使用者確認後自動處理
- 完成後重新驗證並產生可分享的去識別化報告

---

## 支援優先順序（長期）

**第一優先**

- Windows 10/11 原生環境
- Windows 原生 Ollama
- NVIDIA GPU
- 沒有 Ollama 的全新電腦
- 已安裝但故障或很慢的 Ollama

**第二優先**

- 現有 Windows + WSL2 + Ollama 使用者
- Linux 原生 Ollama

**明確不做**

- 聊天 UI
- 常駐 GPU 監控
- 大型模型推薦平台
- 自動訓練模型
- LM Studio 完整支援
- macOS 完整支援
- 雲端 AI 解釋
- 遙測或帳號系統

---

## 長期流程構想

### 1. Scan（唯讀檢測）

涵蓋範圍可能包括：

- Windows 版本／CPU／RAM／磁碟
- GPU 廠牌型號 VRAM 驅動
- NVIDIA 工具與 GPU 可用性
- WSL 安裝狀態與版本
- Ollama 裝在哪一側
- Ollama 版本／服務／11434 port／API
- 已下載與已載入模型
- 模型 CPU/GPU 分配
- context 與 KV cache 與顯存缺口
- 佔用顯存的程序
- Ollama log 中的載入層數與錯誤
- 網路與下載條件
- 是否需要重新啟動

Scan 不得修改系統，也不能因缺少某個工具而崩潰。

### 2. Plan（產生計畫，不執行）

根據檢測結果產生可理解的處理計畫：

- 將安裝什麼、預計下載大小
- 將下載哪個入門模型、預計佔用空間
- 是否需要管理員權限
- 是否需要重新啟動
- 哪些步驟只提供指引不自動執行
- 每個動作的風險和回復方法

使用者確認前不得修改任何設定。

### 3. Apply（使用者確認後才執行）

可能範圍：

- 透過官方來源安裝或修復 Ollama
- 啟動 Ollama
- 必要時啟用 Windows／WSL 元件
- 安裝必要但低風險的依賴
- 下載使用者確認的保守型入門模型
- 修復安全且可逆的服務設定
- 保存進度使重新啟動後可以繼續

預設優先安裝 Windows 原生 Ollama。只有使用者已經使用 WSL，
或明確選擇 WSL 模式時，才在 WSL 安裝。

「自動安裝 AI」在這裡指安裝 Ollama runtime 和模型，不是訓練新模型。

### 4. Verify（安裝或修復後重新檢測）

- Ollama API 可連線、模型可以載入、可以完成一個短 prompt
- 記錄 TTFT 和 tokens/sec
- 確認 GPU 是否真的使用
- 確認模型是否部分落到 CPU
- 檢查 context 是否合理
- 確認服務重新啟動後仍可用

驗證失敗時，保留原始證據並給出下一步，不得假裝成功。

### 5. Report

- 人話 HTML 報告
- 結構化 JSON
- 可複製給維護者或 AI 助手的去識別化文字
- 已執行動作紀錄
- 尚未解決的問題
- 工具版本／規則版本／Ollama 版本／檢測時間

---

## 安全界線

> 以下為原始規格逐條保留，未經改寫。將來若實作 Apply 相關功能，
> 這一節是硬性護欄，必須逐條遵守。

這些是硬性要求：

- 顯示卡驅動只能偵測與提供官方指引，不能靜默安裝、降級、purge 或移除。
- 不得自動刪除模型、使用者資料、WSL 發行版或系統套件。
- 不得自動執行 destructive cleanup。
- 高風險與需要管理員權限的動作逐項確認。
- 所有安裝來源必須是官方 HTTPS 來源。
- Windows 安裝檔應驗證 Authenticode 簽章；若官方提供 checksum，也要驗證。
- 不使用 eval、Invoke-Expression 或由未受信任輸出拼接的 shell 指令。
- 所有外部程序使用參數陣列或安全 escaping。
- HTML、JSON 和文字報告必須正確 escape。
- 遮蔽帳號、主機名稱、完整路徑、token、環境變數祕密和可識別資訊。
- Scan 模式不得連外。
- 不加入遙測。
- 不把診斷資料上傳。
- 所有 Apply 動作必須支援 dry-run。
- 重複執行必須是 idempotent。
- 不要為了測試而在開發電腦上真的安裝、移除或修改 WSL、驅動、Ollama；
  系統變更測試必須使用 mocks／fixtures，除非另有明確授權。

---

## 架構構想

若將來要動架構，應先評估現有程式，再提出最小風險的遷移方案。

一個候選方向是以 Go 建立可發布成單一 Windows `.exe` 的核心，
但不應在沒有理由的情況下重寫全部 Bash 邏輯。

可能的模組切分：

- `collectors/windows`、`collectors/wsl`、`collectors/linux`
- `backends/ollama`
- evidence schema
- deterministic rule engine
- action planner
- safe action executor
- reboot/resume state
- redaction
- HTML/JSON/text renderer
- command runner abstraction

現有 `check.sh` 應保留為 WSL／Linux adapter 或相容模式，
規則逐步移入可測試的核心，不做一次性切換。

CLI 可能的樣貌：

```
doctor scan | plan | apply | verify | report | setup
--dry-run  --json  --output  --mode windows|wsl|auto
```

GUI 是更後面的事。若真要走到那一步，第一版應先完成可靠的
單一 exe + 自動開啟 HTML 報告。

---

## 模型選擇構想

不做大型排行榜。只維護一份小型、可版本化、可更新的保守入門模型目錄。

依據：

- 可用 VRAM、系統 RAM、磁碟空間
- 是否支援 GPU
- 預留作業系統和 context 空間

推薦 1–3 個入門選項，顯示模型大小和預期執行位置。未經確認不下載。

不捏造精確速度；估計值和實測值必須清楚分開
（現行 `MEASUREMENTS.md` 已遵循此原則）。

---

## 測試策略構想

若將來規模擴大，應建立 fixture-based regression tests，涵蓋：

- Windows 中文與英文輸出、WSL 輸出
- 不同 Ollama 版本
- 100% GPU／CPU-GPU 混合／完全 CPU
- context 過大
- 11434 port 衝突
- Ollama 未安裝、Ollama 服務停止
- Ollama log 格式改變
- 多張 GPU、沒有 NVIDIA GPU
- 重新啟動後續跑、重複 Apply
- 使用者拒絕某個動作
- 網路下載失敗
- 簽章或 checksum 驗證失敗
- HTML injection、command injection
- 主機名稱／帳號／路徑遮蔽

使用 fake command runner 和 fake Ollama HTTP server，CI 不得真的改系統。

---

## OSS 完整度（逐步補齊）

GitHub Actions CI、正式 Releases 流程、Windows 預編譯 binary、checksum、
README 截圖與 quick start、`CONTRIBUTING.md`、`SECURITY.md`、issue templates、
支援矩陣、隱私與威脅模型、診斷 fixture 貢獻指南。

---

## 長期驗收標準

全新 Windows 11 電腦在沒有 Ollama 時，應能：

1. 執行 scan
2. 看懂硬體與缺少項目
3. 查看完整安裝計畫
4. 明確確認
5. 從官方來源安裝 Ollama
6. 選擇並下載保守入門模型
7. 完成真實生成測試
8. 確認 GPU／CPU 分配
9. 產生去識別化報告

已有但故障的環境應能找出根因，安全修復可逆問題並重新驗證。

---

## 未來實作時應遵循的原則

- 先檢查 repo 現況、目前行為、未提交變更和現有測試
- 說明目前架構與主要風險
- 提出 2–3 種實作方案與取捨，不要只給一種
- 選擇最小可行方案，寫 design spec 和分階段 implementation plan
- 不要一次無差別重寫整個專案
- 先替現有規則建立 fixtures 和測試保護，再動新功能
- 每階段執行測試、檢查 diff
- 保留既有的手動修改
- 沒有阻塞性歧義時自行作出保守決定並繼續，不為小事反覆確認
- 每階段結束列出完成內容、測試證據、尚未完成項目和下一階段

---

## 為什麼現在不做

這一節記錄擱置的判斷依據。重啟本文件中的任何項目前，
請先確認以下三點是否已經改變。

**一、零外部使用者驗證時，先做規模最大的改造風險過高。**

本專案發布時 star 為 0、issue 為 0。在沒有任何外部需求訊號的情況下
投入數月做 Go 重寫與五階段流程，等於用最大的成本去賭一個未經驗證的
假設。相對地，三塊小改（R4 修正、`--live`、Windows 原生 Scan）
每一塊都能在數天內交付並取得回報。

**二、規則庫目前僅 n=2 驗證，且已發現一次誤判。**

首批外部測試 2 台機器，其中一台（Surface Book 雙顯卡）觸發了 R4 的
錯誤診斷——工具對一台沒有可用 NVIDIA 卡的機器建議「去更新 NVIDIA
驅動」。

這件事的意義超出單一 bug：Apply 的正確性完全建立在規則的正確性上。
安全界線那一節防得住「危險操作」，防不住「判斷本身是錯的」。
R4 那條誤判完全合法、完全可逆，只是建議是錯的——如果它不是「顯示
建議」而是「自動執行修復」，後果會嚴重得多。

因此建議：在 Apply 上線之前，規則庫應在至少 5 台不同機器上驗證過。

**三、三塊小改的實測回報會決定哪些項目值得升級成計畫。**

例如：

- 若回報顯示使用者卡在「必須先有 WSL」→ Windows 原生優先被驗證
- 若回報顯示使用者卡在「安裝太難」→ Plan/Apply 的價值被驗證
- 若回報顯示問題都在「看不懂輸出」→ 該投入的是文案不是架構

在拿到這些訊號之前，任何優先序的排定都是猜測。
