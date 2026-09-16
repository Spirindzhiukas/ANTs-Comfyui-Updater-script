@echo off
:: by OreX
:: Homepage: https://stabledif.ru
:: Telegram: https://t.me/stable_dif
:: Modified by Antanas - added eng translation and symlinked output folder restoration
:: Modified further - added input folder, consistent paths, pre-flight checks
cls
setlocal enabledelayedexpansion
color 0F

set "COMFY=%~dp0ComfyUI"
set "UPDATE_DIR=%~dp0update"

echo ==============================================================
echo  ComfyUI Updater - Symbolic Link Safe
echo ==============================================================
echo.

:: Pre-flight checks

if not exist "%COMFY%" (
    echo ERROR: ComfyUI folder not found: %COMFY%
    pause
    exit /b 1
)

if not exist "%UPDATE_DIR%\update_comfyui.bat" (
    echo ERROR: Update script not found: %UPDATE_DIR%\update_comfyui.bat
    pause
    exit /b 1
)

for %%F in (models output input) do (
    if not exist "%COMFY%\%%F" (
        echo ERROR: "%COMFY%\%%F" does not exist. Aborting to avoid data loss.
        pause
        exit /b 1
    )
)

:: Step 1 - Rename symlinks out of the way

echo [1/4] Backing up symbolic links...

for %%F in (models output input) do (
    echo   Renaming %%F to %%F_backup
    rename "%COMFY%\%%F" "%%F_backup"
    if errorlevel 1 (
        echo ERROR: Could not rename "%COMFY%\%%F". Check it exists and is not in use.
        pause
        exit /b 1
    )
)

:: Step 2 - Run the updater

echo.
echo [2/4] Running ComfyUI update...
echo ==============================================================
cd /d "%UPDATE_DIR%"
call update_comfyui.bat
if errorlevel 1 (
    echo.
    echo ERROR: update_comfyui.bat reported a failure.
    echo Attempting to restore symbolic links before exiting...
    goto :restore
)
echo ==============================================================
echo.

:: Step 3 - Delete folders created by the updater

echo [3/4] Removing updater-created folders...

for %%F in (models output input) do (
    if exist "%COMFY%\%%F" (
        echo   Deleting %COMFY%\%%F
        rmdir /s /q "%COMFY%\%%F"
        if errorlevel 1 (
            echo ERROR: Could not delete "%COMFY%\%%F".
            pause
            exit /b 1
        )
    ) else (
        echo   Skipping %%F - updater did not create it.
    )
)

:: Step 4 - Restore symlinks

:restore
echo.
echo [4/4] Restoring symbolic links...

for %%F in (models output input) do (
    if exist "%COMFY%\%%F_backup" (
        echo   Restoring %%F_backup to %%F
        rename "%COMFY%\%%F_backup" "%%F"
        if errorlevel 1 (
            echo ERROR: Could not restore "%COMFY%\%%F_backup" to "%%F".
            echo Please rename it manually!
            pause
            exit /b 1
        )
    ) else (
        echo   WARNING: "%COMFY%\%%F_backup" not found - skipping restore for %%F.
    )
)

echo.
echo ==============================================================
echo  Update completed successfully.
echo  Symbolic links for models, output, and input restored.
echo ==============================================================
echo.
echo  Made by OreX  stabledif.ru
echo  Modified by Antanas and improved for robustness
echo.
pause
