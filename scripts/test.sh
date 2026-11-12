#!/bin/zsh
# Xcode 없이 Command Line Tools 만으로 swift-testing 실행
# 통합 테스트: scripts/test-dbs.sh up 으로 컨테이너를 띄운 뒤 scripts/test-dbs.sh test
set -e
cd "$(dirname "$0")/.."
F=/Library/Developer/CommandLineTools/Library/Developer/Frameworks
L=/Library/Developer/CommandLineTools/Library/Developer/usr/lib
if xcode-select -p | grep -q "Xcode.app"; then
  swift test
else
  swift test -Xswiftc -F -Xswiftc $F -Xlinker -F -Xlinker $F -Xlinker -rpath -Xlinker $F -Xlinker -rpath -Xlinker $L
fi
