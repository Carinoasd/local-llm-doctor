@echo off
chcp 65001 >nul 2>&1
setlocal enabledelayedexpansion
title 本地 LLM 環境健檢（完整檢查）

echo.
echo   本地 LLM 環境健檢 —— 完整檢查
echo   ==========================================
echo.
echo   一般的檢查只能看到「現在」的狀況。如果你的模型
echo   已經閒置超過五分鐘，最重要的幾項就查不到了。
echo.
echo   完整檢查會自動載入一個小模型、實際跑一句話，
echo   然後在模型還在記憶體裡的時候做檢查。
echo.
echo   這代表：
echo     * 會佔用顯示卡記憶體，幾分鐘後由 Ollama 自動釋放
echo     * 這是這個工具唯一會動到你電腦狀態的動作
echo     * 過程大約 30 秒到 1 分鐘
echo.
echo   ------------------------------------------
echo   要繼續請按任意鍵；不想跑就直接關掉這個視窗。
echo   ------------------------------------------
pause >nul
echo.
echo   開始檢查…
echo.
echo   （如果上面出現 "UNC paths are not supported" 的英文提示，
echo     那是 Windows 的正常訊息，可以忽略，不影響檢查。）
echo.

pushd "%~dp0" 2>nul
if errorlevel 1 (
    echo   [錯誤] 進不去這個資料夾：%~dp0
    goto :theend
)

set "SD=%~dp0"
set "DISTRO="
if "!SD:~0,5!"=="\\wsl" (
    for /f "tokens=1,2 delims=\" %%a in ("!SD!") do set "DISTRO=%%b"
)

set "RC=0"
if defined DISTRO (
    wsl.exe -d !DISTRO! --cd "%~dp0" -- bash ./check.sh --live
    set "RC=!errorlevel!"
    if not "!RC!"=="0" (
        echo.
        echo   （那個發行版叫不動，改用預設的 WSL 發行版重試）
        echo.
        wsl.exe --cd "%~dp0" -- bash ./check.sh --live
        set "RC=!errorlevel!"
    )
) else (
    wsl.exe --cd "%~dp0" -- bash ./check.sh --live
    set "RC=!errorlevel!"
)

if not "!RC!"=="0" (
    echo.
    echo   [錯誤] 檢查沒有正常跑完。
    echo.
    echo   可能的原因：
    echo     1. 這台電腦沒有安裝 WSL
    echo        在 PowerShell 執行 wsl --install 就會裝好
    echo     2. 這個資料夾裡沒有 check.sh
    echo     3. WSL 沒有啟動
    echo        在 PowerShell 執行 wsl --shutdown 之後再試一次
    popd
    goto :theend
)

if not exist "report.html" (
    echo.
    echo   [錯誤] 檢查跑完了，但沒有找到 report.html。
    popd
    goto :theend
)

echo.
echo   完成，正在開啟報告…
start "" "report.html"
popd

:theend
echo.
echo   按任意鍵關閉這個視窗。
pause >nul
endlocal
