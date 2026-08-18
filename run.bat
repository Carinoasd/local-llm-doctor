﻿@echo off
chcp 65001 >nul 2>&1
setlocal enabledelayedexpansion
title 本地 LLM 環境健檢

echo.
echo   本地 LLM 環境健檢
echo   ==========================================
echo   正在檢查你的環境，大約需要 10 秒。
echo   這個工具只讀取設定，不會修改任何東西。
echo.
echo   （如果上面出現 "UNC paths are not supported" 的英文提示，
echo     那是 Windows 的正常訊息，可以忽略，不影響檢查。）
echo.

REM cmd.exe 不支援用 UNC 路徑當工作目錄。
REM 這個資料夾放在 WSL 裡的話，%~dp0 會是 \\wsl.localhost\... 開頭，
REM pushd 會自動把它對應成一個暫時的磁碟機代號，popd 再還原。
pushd "%~dp0" 2>nul
if errorlevel 1 (
    echo   [錯誤] 進不去這個資料夾：%~dp0
    goto :theend
)

REM 如果這個 .bat 就放在 WSL 的檔案系統裡，從路徑取出發行版名稱，
REM 避免使用者的預設發行版不是放著這些檔案的那一個。
REM 註 1：刻意用子字串比對而不是 findstr。實測 findstr /B /C:"\\wsl"
REM       比不到反斜線開頭的 UNC 路徑，會靜默走到 fallback。
REM 註 2：後面的 -d 刻意不加引號。實測 wsl.exe -d "Ubuntu" 會回報
REM       WSL_E_DISTRO_NOT_FOUND，它不會剝掉發行版名稱的引號。
REM       代價是含空白的發行版名稱會失敗，那種情況由下面的重試接住。
set "SD=%~dp0"
set "DISTRO="
if "!SD:~0,5!"=="\\wsl" (
    for /f "tokens=1,2 delims=\" %%a in ("!SD!") do set "DISTRO=%%b"
)

set "RC=0"
if defined DISTRO (
    echo   （使用 WSL 發行版：!DISTRO!）
    echo.
    wsl.exe -d !DISTRO! --cd "%~dp0" -- bash ./check.sh
    set "RC=!errorlevel!"
    if not "!RC!"=="0" (
        echo.
        echo   （那個發行版叫不動，改用預設的 WSL 發行版重試）
        echo.
        wsl.exe --cd "%~dp0" -- bash ./check.sh
        set "RC=!errorlevel!"
    )
) else (
    echo.
    wsl.exe --cd "%~dp0" -- bash ./check.sh
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
