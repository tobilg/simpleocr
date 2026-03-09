#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

export SWIFTPM_MODULECACHE_OVERRIDE="$repo_root/.build/module-cache"
export CLANG_MODULE_CACHE_PATH="$repo_root/.build/clang-module-cache"

swift build "$@"
