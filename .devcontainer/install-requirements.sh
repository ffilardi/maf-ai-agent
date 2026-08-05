#!/usr/bin/env bash
set -euo pipefail

echo "[devcontainer] Restoring .NET projects under src/* (C# backend)"
shopt -s nullglob
csproj_files=( src/*/*.csproj )

if [ ${#csproj_files[@]} -eq 0 ]; then
  echo "[devcontainer] No .csproj files found under src/*"
else
  for proj in "${csproj_files[@]}"; do
    echo "[devcontainer] dotnet restore $proj"
    dotnet restore "$proj"
  done
fi

echo "[devcontainer] Installing npm dependencies under src/* (Vite + React frontend)"
package_files=( src/*/package.json )

if [ ${#package_files[@]} -eq 0 ]; then
  echo "[devcontainer] No package.json files found under src/*"
else
  for pkg in "${package_files[@]}"; do
    dir="$(dirname "$pkg")"
    echo "[devcontainer] npm install ($dir)"
    ( cd "$dir" && npm install )
  done
fi

echo "[devcontainer] Dependency installation complete."
