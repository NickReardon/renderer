@echo off
rem Usage:
rem   build.bat          build the host (engine.exe) and the game DLL, copy runtime DLLs
rem   build.bat game     rebuild only the game DLL; a running engine.exe hot-reloads it
rem   build.bat test     build and run the core and UI tests
rem   build.bat run      full build, then start the engine
setlocal EnableDelayedExpansion
cd /d "%~dp0"

where odin >nul 2>nul || set "PATH=%LOCALAPPDATA%\Programs\odin;%PATH%"
where odin >nul 2>nul || (echo error: odin not found on PATH & exit /b 1)

set "COMMON_FLAGS=-collection:engine=src -vet -debug"
rem -define:WGPU_SHARED=true links wgpu as wgpu_native.dll, so every loaded copy of the game
rem DLL shares one wgpu instead of each carrying its own static copy.
set "GAME_FLAGS=%COMMON_FLAGS% -define:WGPU_SHARED=true"

if not exist build mkdir build

if /i "%~1"=="test" (
	odin test src/core %COMMON_FLAGS% -out:build\core_tests.exe || exit /b 1
	odin test src/ui %COMMON_FLAGS% -out:build\ui_tests.exe || exit /b 1
	exit /b 0
)
if /i "%~1"=="game" goto build_game

rem Full build. Remove leftover hot-reload copies and per-build PDBs first (files in use by a
rem running engine are skipped).
del /q build\game_*.dll build\game_*.pdb 2>nul

rem Not named ODIN_ROOT: Odin reads that variable itself.
for /f "delims=" %%i in ('odin root') do set "ODIN_DIRECTORY=%%i"
copy /y "%ODIN_DIRECTORY%vendor\sdl3\SDL3.dll" build\ >nul || exit /b 1
copy /y "%ODIN_DIRECTORY%vendor\wgpu\lib\wgpu-windows-x86_64-msvc-release\lib\wgpu_native.dll" build\ >nul || exit /b 1

odin build src/host %COMMON_FLAGS% -out:build\engine.exe || exit /b 1

:build_game
rem Build to a temporary name and then rename: the host watches game.dll and must never load
rem a half-written file. A new PDB name per build avoids "PDB in use" link errors while an
rem earlier build is still loaded.
odin build src/game %GAME_FLAGS% -build-mode:dll -out:build\game_tmp.dll -pdb-name:build\game_!RANDOM!.pdb || exit /b 1
move /y build\game_tmp.dll build\game.dll >nul || exit /b 1
echo build ok

if /i "%~1"=="run" start "" build\engine.exe
exit /b 0
