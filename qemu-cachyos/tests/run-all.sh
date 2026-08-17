#!/usr/bin/env bash
# Run every test suite plus static checks. Needs no root, no hardware, no KVM.
set -uo pipefail
cd "$(dirname "$(readlink -f "$0")")/.."

rc=0

printf '\n\e[1m=== Shell syntax ===\e[0m\n'
for f in ./*.sh lib/*.sh hooks/qemu tests/*.sh; do
  [[ -f $f ]] || continue
  if bash -n "$f" 2>/dev/null; then
    printf '  \e[32mOK\e[0m   %s\n' "$f"
  else
    printf '  \e[31mFAIL\e[0m %s\n' "$f"; bash -n "$f"; rc=1
  fi
done

printf '\n\e[1m=== Python syntax ===\e[0m\n'
for f in lib/*.py; do
  [[ -f $f ]] || continue
  if python3 -m py_compile "$f" 2>/dev/null; then
    printf '  \e[32mOK\e[0m   %s\n' "$f"
  else
    printf '  \e[31mFAIL\e[0m %s\n' "$f"; python3 -m py_compile "$f"; rc=1
  fi
done
rm -rf lib/__pycache__

if command -v shellcheck >/dev/null; then
  printf '\n\e[1m=== shellcheck ===\e[0m\n'
  shellcheck -S warning ./*.sh lib/*.sh hooks/qemu || rc=1
fi

for suite in tests/test-topology.sh tests/test-render.sh tests/test-hook.sh; do
  "$suite" || rc=1
done

printf '\n'
if (( rc == 0 )); then
  printf '\e[32m\e[1mEverything passed.\e[0m\n\n'
else
  printf '\e[31m\e[1mSome checks failed.\e[0m\n\n'
fi
exit $rc
