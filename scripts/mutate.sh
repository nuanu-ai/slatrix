#!/bin/bash
# Mutation testing for one source file: scripts/mutate.sh <file> [swift test args, e.g. --filter ReadStatePolicyTests]
# Applies one mutation at a time, builds, runs the tests, and lists the mutants no test caught.
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/swift-env.sh

file=${1:?usage: scripts/mutate.sh <file> [swift test args]}
shift

# The native build system recompiles only the mutated file; the default one rebuilds the whole module per mutant.
args=(--build-system native)
previous=
for arg in "${swift_test_args[@]}"; do
    if [[ $previous == --scratch-path ]]; then arg=.build/mutate; fi
    args+=("$arg")
    previous=$arg
done
clt=/Library/Developer/CommandLineTools
if [[ $(xcode-select -p) == "$clt" ]]; then
    frameworks=$clt/Library/Developer/Frameworks
    args+=(-Xswiftc -F -Xswiftc "$frameworks" -Xlinker -F -Xlinker "$frameworks" -Xlinker -rpath -Xlinker "$frameworks")
fi

backup=$(mktemp)
cp "$file" "$backup"
trap 'cmp -s "$backup" "$file" || cp "$backup" "$file"; rm -f "$backup"' EXIT

python3 -I - "$file" "${args[@]}" -- "$@" <<'PY'
import re, signal, subprocess, sys

path = sys.argv[1]
split = sys.argv.index("--")
build_args, test_args = sys.argv[2:split], sys.argv[split + 1:]
source = open(path, encoding="utf-8").read()
signal.signal(signal.SIGTERM, lambda *_: sys.exit(143))
signal.signal(signal.SIGHUP, lambda *_: sys.exit(129))

operators = [
    (r"&&", "||"), (r"\|\|", "&&"), (r"(?<=[\s(,\[])!(?=[\w(.$])", ""),
    (r"(?<= )==(?= )", "!="), (r"(?<= )!=(?= )", "=="),
    (r"(?<= )<(?= )", "<="), (r"(?<= )<=(?= )", "<"), (r"(?<= )>(?= )", ">="), (r"(?<= )>=(?= )", ">"),
    (r"\breturn true\b", "return false"), (r"\breturn false\b", "return true"),
    (r"\btry (?:await )?(?:self\.)?validate\w*\([^()\n]*\)(?=\s*(?:$|\}|;))", ""),
    (r"\bthrow [^\n}]*[^\s}]", ""),
]

def in_code(start):
    line_start = source.rfind("\n", 0, start) + 1
    before = source[line_start:start]
    if "//" in before or before.lstrip().startswith("*"):
        return False
    return before.replace('\\"', "").count('"') % 2 == 0

mutants = sorted(
    (m.start(), m.end(), replacement)
    for pattern, replacement in operators
    for m in re.finditer(pattern, source, re.M)
    if in_code(m.start()))

def run(command, timeout=None):
    try:
        return subprocess.run(command, capture_output=True, text=True, timeout=timeout).returncode
    except subprocess.TimeoutExpired:
        return "timeout"

def build_and_test():
    if run(["swift", "build", "--build-tests", *build_args]) != 0:
        return "uncompilable"
    result = run(["swift", "test", "--skip-build", *build_args, *test_args], timeout=600)
    return "killed (timeout)" if result == "timeout" else ("killed" if result else "SURVIVED")

try:
    if build_and_test() != "SURVIVED":
        sys.exit(f"{path}: the unmutated tests must build and pass first")
    survivors, killed = [], 0
    for index, (start, end, replacement) in enumerate(mutants, 1):
        line = source.count("\n", 0, start) + 1
        open(path, "w", encoding="utf-8").write(source[:start] + replacement + source[end:])
        outcome = build_and_test()
        label = f"{path}:{line}: {source[start:end]!r} -> {replacement!r}"
        print(f"[{index}/{len(mutants)}] {label}: {outcome}", flush=True)
        if outcome == "SURVIVED":
            survivors.append(label + "  | " + source.splitlines()[line - 1].strip())
        elif outcome.startswith("killed"):
            killed += 1
finally:
    open(path, "w", encoding="utf-8").write(source)

total = killed + len(survivors)
print(f"\n{killed}/{total} compiled mutants killed" + (f" ({100 * killed // total}%)" if total else ""))
for label in survivors:
    print("survivor:", label)
PY
