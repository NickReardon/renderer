#!/usr/bin/env bash
# macOS counterpart of build.bat.
# Usage:
#   ./build.sh          build the host (build/engine) and the game library, copy libwgpu_native.dylib
#   ./build.sh game     rebuild only the game library; a running engine hot-reloads it
#   ./build.sh test     build and run the core, UI and game tests
#   ./build.sh run      full build, then start the engine
set -euo pipefail
cd "$(dirname "$0")"

command -v odin >/dev/null || PATH="$HOME/.local/odin:$PATH"
command -v odin >/dev/null || { echo "error: odin not found on PATH" >&2; exit 1; }

# SDL3 comes from Homebrew (Odin ships only the Windows SDL3 library). @executable_path is where
# both the engine and the game library look for libwgpu_native.dylib: the copy next to the engine.
LINKER_FLAGS="-extra-linker-flags:-L$(brew --prefix sdl3)/lib -Wl,-rpath,@executable_path"
COMMON_FLAGS=(-collection:engine=src -vet -debug "$LINKER_FLAGS")
# -define:WGPU_SHARED=true links wgpu as libwgpu_native.dylib, so every loaded copy of the game
# library shares one wgpu instead of each carrying its own static copy.
GAME_FLAGS=("${COMMON_FLAGS[@]}" -define:WGPU_SHARED=true)

mkdir -p build

if [[ "${1:-}" == "test" ]]; then
	odin test src/core "${COMMON_FLAGS[@]}" -out:build/core_tests
	odin test src/ui "${COMMON_FLAGS[@]}" -out:build/ui_tests
	odin test src/game "${COMMON_FLAGS[@]}" -out:build/game_tests
	exit 0
fi

if [[ "${1:-}" != "game" ]]; then
	# Full build. Remove leftover hot-reload copies first.
	rm -rf build/game_*.dylib build/game_*.dylib.dSYM
	case "$(uname -m)" in
		arm64) WGPU_ARCH=aarch64 ;;
		*)     WGPU_ARCH=x86_64 ;;
	esac
	cp "$(odin root)vendor/wgpu/lib/wgpu-macos-$WGPU_ARCH-release/lib/libwgpu_native.dylib" build/
	odin build src/host "${COMMON_FLAGS[@]}" -out:build/engine
fi

# Build to a temporary name and then rename: the host watches game.dylib and must never load a
# half-written file.
odin build src/game "${GAME_FLAGS[@]}" -build-mode:dll -out:build/game_tmp.dylib
mv -f build/game_tmp.dylib build/game.dylib
echo "build ok"

if [[ "${1:-}" == "run" ]]; then
	exec build/engine
fi
