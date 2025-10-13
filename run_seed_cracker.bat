:: -----------------------------------------------
::  Copyright (c) 2025 ICshX - Seed Cracker Edition
::  Licensed under the MIT License – see LICENSE
:: -----------------------------------------------
@echo off 
SETLOCAL ENABLEDELAYEDEXPANSION

echo -------------------------------------------------
echo  Seed Cracker by ICshX
echo -------------------------------------------------
echo  If you modify and redistribute this script,
echo  please credit/tag ICshX as the original author.
echo -------------------------------------------------
echo  Licensed under the MIT License - see LICENSE
echo -------------------------------------------------

REM ================= Default values =================
set "CONFIG=config.txt"
set "PATTERN_LOG_DIR=Pattern-log"

REM ================= First run check =================
if not exist "%CONFIG%" (
    echo First run detected. Please enter the full path to zig.exe [if not installed, download version [0.10.1] from https://ziglang.org/].
    set /p ZIGPATH=
    if "!ZIGPATH:~-1!"=="\" set "ZIGPATH=!ZIGPATH:~0,-1!"
    if not exist "!ZIGPATH!" (
        echo ERROR: zig.exe path not found.
        pause
        exit /b
    )
    echo !ZIGPATH!> "%CONFIG%"
    echo Config saved.
)

REM ================= Load zig.exe path =================
set /p ZIGPATH=<"%CONFIG%"
set ZIGPATH=%ZIGPATH:"=%

if not exist "%ZIGPATH%" (
    echo ERROR: zig.exe path in config.txt is invalid. Delete config.txt and try again.
    pause
    exit /b
)

REM ================= Clean old builds =================
if exist "zig-cache" (
    echo Cleaning old build files...
    rd /s /q "zig-cache" 2>nul
    timeout /t 1 /nobreak >nul
)

REM ================= Coordinates input =================
echo.
echo Enter the coordinates where you found the pattern:
echo X coordinate:
set /p COORD_X=

echo Z coordinate:
set /p COORD_Z=

REM ================= Pattern input =================
echo.
echo Enter your pattern row by row OR type "load filename.txt" to use a saved pattern.
echo Use 0=non-bedrock, 1=bedrock, space or . = ignore
echo Type "end" when finished entering new rows.

if not exist "%PATTERN_LOG_DIR%" mkdir "%PATTERN_LOG_DIR%"

set "PATTERNFILE="
set /a ROWCOUNT=0

:pattern_input
set /p ROWINPUT=Row !ROWCOUNT!:
if /i "!ROWINPUT!"=="end" goto pattern_done

REM Check if user wants to load a previous pattern
if /i "!ROWINPUT:~0,5!"=="load " (
    set "LOADNAME=!ROWINPUT:~5!"
    set "PATTERNFILE=%PATTERN_LOG_DIR%\!LOADNAME!"
    if exist "!PATTERNFILE!" (
        echo Loading pattern from !PATTERNFILE!
        goto pattern_done
    ) else (
        echo ERROR: File "!PATTERNFILE!" not found.
        goto pattern_input
    )
)

REM Otherwise append input to a new timestamped file
if "!PATTERNFILE!"=="" (
    for /f "tokens=1-6 delims=:. " %%a in ("%date% %time%") do (
        set "YYYY=%%c"
        set "MM=%%a"
        set "DD=%%b"
        set "HH=%%d"
        set "MN=%%e"
        set "SS=%%f"
    )
    set "PATTERNFILE=%PATTERN_LOG_DIR%\pattern_!YYYY!!MM!!DD!_!HH!!MN!!SS!.txt"
    if exist "!PATTERNFILE!" del "!PATTERNFILE!"
)

echo !ROWINPUT!>> "!PATTERNFILE!"
set /a ROWCOUNT+=1
goto pattern_input

:pattern_done

REM ================= Dimension selection =================
echo.
echo Enter dimension [overworld / netherfloor / netherceiling] (default: overworld):
set /p USERDIM=
if "!USERDIM!"=="" set "USERDIM=overworld"

REM ================= Validate dimension =================
if /i not "!USERDIM!"=="overworld" if /i not "!USERDIM!"=="netherfloor" if /i not "!USERDIM!"=="netherceiling" (
    echo ERROR: Unknown dimension "!USERDIM!".
    pause
    exit /b
)

REM ================= Confirmation =================
echo.
echo ------------------------------
echo Configuration:
echo ------------------------------
echo Coordinates: X=%COORD_X%, Z=%COORD_Z%
echo Dimension: %USERDIM%
echo Pattern file: %PATTERNFILE%
echo Seed range: ALL (32-bit)
echo ------------------------------
echo.
echo WARNING: Full scan will take HOURS depending on your CPU!
echo Scanning 4,294,967,296 seeds...
echo.
echo Press any key to start cracking, or Ctrl+C to abort...
pause > nul

REM ================= Run program =================
echo.
echo ------------------------------
echo   Running Seed Cracker...
echo ------------------------------

REM Generate unique executable name to avoid file locks
for /f "tokens=1-4 delims=:.," %%a in ("%time%") do (
    set "HH=%%a"
    set "MM=%%b"
    set "SS=%%c"
    set "MS=%%d"
)
set "HH=%HH: =0%"
set "EXENAME=cracker_%HH%%MM%%SS%%MS%"

if defined PATTERNFILE (
    "%ZIGPATH%" build-exe seed_cracker.zig -O ReleaseFast --name "%EXENAME%" 2>nul && "%EXENAME%.exe" %COORD_X% %COORD_Z% "%PATTERNFILE%" %USERDIM%
) else (
    "%ZIGPATH%" build-exe seed_cracker.zig -O ReleaseFast --name "%EXENAME%" 2>nul && "%EXENAME%.exe" %COORD_X% %COORD_Z% %USERDIM%
)

REM Cleanup
timeout /t 1 /nobreak >nul 2>&1
if exist "%EXENAME%.exe" del /f /q "%EXENAME%.exe" 2>nul
if exist "%EXENAME%.obj" del /f /q "%EXENAME%.obj" 2>nul
if exist "%EXENAME%.pdb" del /f /q "%EXENAME%.pdb" 2>nul
if exist "seed_cracker.obj" del /f /q "seed_cracker.obj" 2>nul
if exist "seed_cracker.pdb" del /f /q "seed_cracker.pdb" 2>nul
if exist "bedrock.obj" del /f /q "bedrock.obj" 2>nul

REM Clean zig cache
if exist "zig-cache" (
    rd /s /q "zig-cache" 2>nul
)

pause