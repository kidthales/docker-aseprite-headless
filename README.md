# Docker Aseprite Headless

[![Batch](https://github.com/kidthales/docker-aseprite-headless/actions/workflows/batch.yml/badge.svg)](https://github.com/kidthales/docker-aseprite-headless/actions/workflows/batch.yml)
[![Lint](https://github.com/kidthales/docker-aseprite-headless/actions/workflows/lint.yml/badge.svg)](https://github.com/kidthales/docker-aseprite-headless/actions/workflows/lint.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](./LICENSE)
[![Platform](https://img.shields.io/badge/platform-linux%2Famd64%20%7C%20linux%2Farm64-lightgrey.svg)](https://github.com/kidthales/docker-aseprite-headless)
[![Base](https://img.shields.io/badge/base-Ubuntu%2024.04%20LTS-E95420.svg)](https://ubuntu.com/)
[![Taskfile](https://img.shields.io/badge/task-go--task%20v3-00ADD8.svg)](https://taskfile.dev/)

Build your own multi-platform Docker container images featuring a headless [Aseprite](https://www.aseprite.org/) binary suitable for [CLI](https://www.aseprite.org/docs/cli/) automation, build scripts, and headless CI pipelines (such as GitHub Actions).

> [!TIP]
> If you need to compile Aseprite with its desktop GUI, refer to the [official Aseprite INSTALL guide](https://github.com/aseprite/aseprite/blob/main/INSTALL.md). For use-cases requiring Docker-based GUI compilation targeting a Linux host, see [nilsve/docker-aseprite-linux](https://github.com/nilsve/docker-aseprite-linux).

> [!NOTE]
> This container builds on **Ubuntu 24.04 LTS (Noble Numbat)** with zero critical vulnerabilities and provides native multi-architecture builds for **`linux/amd64`** (x86_64) and **`linux/arm64`** (Apple Silicon / ARM64).

---

## Downstream Dockerfile Integration Recipe

The primary purpose of this repository is to build an immutable OCI artifact that downstream development containers (such as [`docker-game-development-toolkit`](https://github.com/kidthales/docker-game-development-toolkit)) can consume without recompiling Aseprite from source:

```dockerfile
# syntax=docker/dockerfile:1
FROM ubuntu:24.04

# 1. Copy the pre-compiled Aseprite CLI binary
COPY --from=ghcr.io/kidthales/aseprite:v1.3.18.6-headless /opt/aseprite/bin/aseprite /usr/local/bin/aseprite

# 2. Install minimal runtime dependencies (including libfontconfig1 for brotli/font rendering)
RUN apt-get update && apt-get install -y --no-install-recommends \
    libc++1-18 \
    libfontconfig1 \
    libx11-6 \
    libxcursor1 \
    libxext6 \
    libxrandr2 \
    && rm -rf /var/lib/apt/lists/*

# 3. Verify execution
RUN aseprite --batch --version
```

---

## Local Development with `go-task`

This repository uses [`go-task`](https://taskfile.dev/) for cross-platform automation across Windows, macOS, and Linux:

```shell
# Display available tasks
task

# Build local image
task build

# Run container smoke test
task test

# Run static analysis suite (BuildKit check, Hadolint, ShellCheck, Actionlint, EditorConfig)
task lint

# Print resolved bake configuration
task print
```

### Configuration via `.env`

You can customize build variables by creating a `.env` file in the root directory:

```dotenv
IMAGES_PREFIX="kidthales/"
ASEPRITE_GIT_REF="v1.3.18.6"
ASEPRITE_BUILD_TYPE="Release"
PLATFORMS=["linux/amd64", "linux/arm64"]
```

> [!WARNING]
> Values assigned in `.env` must be wrapped in double quotes. This is a syntax requirement of the underlying `docker buildx bake -f .env` invocation.

---

## Direct Docker Buildx CLI Usage

To build without `go-task` using native Docker Buildx:

```shell
# Build default main-headless image
touch .env && docker buildx bake -f .env -f docker-bake.hcl --pull --no-cache

# Run container interactively
docker run --rm -it aseprite:main-headless --help

# Run CLI batch export on a local sprite
docker run --rm -it -v "${PWD}:/workspace" aseprite:main-headless --batch --layer "Layer 1" sprite.aseprite --save-as sprite.png

# Build a specific Aseprite release tag
ASEPRITE_GIT_REF=v1.3.18.6 docker buildx bake -f .env -f docker-bake.hcl --pull --no-cache
```

---

## GitHub Actions CI

Automated workflows are included under `.github/workflows/`:
- **`lint.yml`**: Runs zero-install containerized static analysis on every pull request.
- **`batch.yml`**: Scheduled daily build testing the `main` branch.
- **`base.yml`**: Multi-platform matrix build across native `ubuntu-latest` (amd64) and `ubuntu-24.04-arm` (arm64) runners with BuildKit GitHub Actions caching.
