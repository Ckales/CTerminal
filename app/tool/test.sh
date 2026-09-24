#!/bin/sh
# 全部测试：Rust 核心 + Dart 逻辑 + 真实内核驱动的界面测试。
# 界面测试用临时配置目录，不会读写你的真实 CTerminal 配置。
set -e
cd "$(dirname "$0")/.."
(cd ../crates/cterm-core && cargo test -q)
(cd rust && cargo build --release -q)
CONFIG_DIR=$(mktemp -d)
trap 'rm -r "$CONFIG_DIR"' EXIT
CTERMINAL_CONFIG_DIR="$CONFIG_DIR" flutter test
