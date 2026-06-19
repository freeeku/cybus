#!/usr/bin/env bash
# Regenerate the SwiftProtobuf code for the GTFS-realtime schema.
#
# Requires: protoc + protoc-gen-swift (brew install protobuf swift-protobuf).
# The vendored gtfs-realtime.proto is the canonical proto2 schema from
# google/transit. The generated file is committed so the app builds without
# protoc on hand; re-run this only when bumping the proto or the generator.
set -euo pipefail
cd "$(dirname "$0")"

protoc \
  --proto_path=. \
  --swift_out=../Cybus/Generated \
  gtfs-realtime.proto

echo "Generated ../Cybus/Generated/gtfs-realtime.pb.swift"
echo "protoc:           $(protoc --version)"
echo "protoc-gen-swift: $(protoc-gen-swift --version)"
