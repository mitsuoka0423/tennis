#!/bin/bash
#
# 利用可能なシミュレータから UDID を1つ選んで出力する
#
# Why not 機種名を直接 -destination へ書く: runner イメージが更新されると
# 用意される機種と OS が変わり、「iPhone 16」のような固定名は将来必ず落ちる。
# 実在するものから選べば、イメージの更新に追随する必要がなくなる。
#
# 使い方: pick-simulator.sh <platform> <name-prefix>
#   例) pick-simulator.sh iOS iPhone
#       pick-simulator.sh watchOS 'Apple Watch'

set -euo pipefail

platform="$1"
prefix="$2"

xcrun simctl list devices available --json | python3 -c '
import json, re, sys

platform, prefix = sys.argv[1], sys.argv[2]
devices = json.load(sys.stdin)["devices"]


def version(runtime: str) -> tuple:
    """com.apple.CoreSimulator.SimRuntime.iOS-18-2 → (18, 2)"""
    digits = re.findall(r"\d+", runtime.rsplit(".", 1)[-1])
    return tuple(int(d) for d in digits)


candidates = []
for runtime, entries in devices.items():
    if f".{platform}-" not in runtime:
        continue
    for device in entries:
        if device["name"].startswith(prefix):
            candidates.append((version(runtime), device["name"], device["udid"]))

if not candidates:
    sys.exit(f"利用可能なシミュレータが見つかりません: platform={platform} prefix={prefix}")

# 最新の OS の、名前順で最後のもの（= おおむね新しい機種）を選ぶ
chosen = sorted(candidates)[-1]
os_version = ".".join(str(v) for v in chosen[0])
# f-string の式に \ を書くと Python 3.11 以前で構文エラーになるため % で組む
print("選択: %s (%s %s)" % (chosen[1], platform, os_version), file=sys.stderr)
print(chosen[2])
' "$platform" "$prefix"
