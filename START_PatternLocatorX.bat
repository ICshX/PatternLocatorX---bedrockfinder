//------------------------------------
// Original: Copyright (c) 2025 ICshX
//------------------------------------
@echo off 
SETLOCAL ENABLEDELAYEDEXPANSION

REM ================= Default values =================
set "SEED=0"
set "RANGE=10000"
set "CONFIG=config.txt"
set "LASTSEEDFILE=last_seed.txt"
set "PATTERN_LOG_DIR=Pattern-log"

REM ================= Load last seed if exists =================
if exist "%LASTSEEDFILE%" (
    set /p SEED=<"%LASTSEEDFILE%"
)

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

REM ================= Ask for parameters =================
echo Enter Seed [Use SeedcrackerX to find out the seed on servers] (default: %SEED%):
set /p USERSEED=
if not "!USERSEED!"=="" set "SEED=!USERSEED!"

echo Enter Range (leave blank for default %RANGE%):
set /p USERRANGE=
if not "!USERRANGE!"=="" set "RANGE=!USERRANGE!"

REM ================= Pattern input =================
echo.
echo Enter your pattern row by row OR type "load <filename>" to use a previous pattern.
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

REM ================= Direction selection =================
echo.
echo Enter directions to check [N E S W] (leave blank for all):
set /p USERDIRS=
if "!USERDIRS!"=="" set "USERDIRS=all"

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

REM ================= Set search height automatically =================
set "LOWER_Y=0"
set "UPPER_Y=0"
if /i "!USERDIM!"=="overworld" (
    set "LOWER_Y=4"
    set "UPPER_Y=5"
) else if /i "!USERDIM!"=="netherfloor" (
    set "LOWER_Y=4"
    set "UPPER_Y=5"
) else if /i "!USERDIM!"=="netherceiling" (
    set "LOWER_Y=122"
    set "UPPER_Y=127"
)

REM ================= Run program =================
echo Running PatternLocatorX...
echo Seed: %SEED%
echo Range: %RANGE%
echo Dimension: %USERDIM%
echo Directions: %USERDIRS%

if defined PATTERNFILE (
    REM Reihenfolge: Seed, Range, Dimension, Pattern-Datei, Directions
    "%ZIGPATH%" run main.zig -O ReleaseFast -- %SEED% %RANGE% "%PATTERNFILE%" "%USERDIRS%" %USERDIM%
) else (
    REM Reihenfolge: Seed, Range, Dimension, Directions (ohne Pattern-Datei)
    "%ZIGPATH%" run main.zig -O ReleaseFast -- %SEED% %RANGE% "%USERDIRS%" %USERDIM%
)

REM ================= Save last seed =================
<nul set /p =%SEED%>"%LASTSEEDFILE%"

pause
