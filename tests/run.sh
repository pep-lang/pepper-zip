#!/usr/bin/env bash
# Runs the package's tests: tests/zip_test.pep over the archives in
# tests/data, the unzip example, and, when Python and Info-ZIP's unzip are
# installed, a check that both read an archive this package writes.
#
# Usage: tests/run.sh [path/to/pepper]   (default: pepper on PATH)
set -euxo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
pepper="${1:-pepper}"
build="$(mktemp -d)"
trap 'rm -rf "$build"' EXIT

cd "$build"
# The package is the module `zip`: a folder of that name on the import path.
mkdir packages
ln -s "$root" packages/zip
"$pepper" build -I packages "$root/tests/zip_test.pep" -o zip_test
./zip_test "$root/tests/data"

"$pepper" build -I packages "$root/examples/unzip/main.pep" -o unzip_example
./unzip_example
./unzip_example "$root/tests/data/zip64.zip" extracted
test -f extracted/forced.txt

if command -v python3 > /dev/null && command -v unzip > /dev/null; then
    "$pepper" build -I packages "$root/tests/interop.pep" -o interop
    ./interop interop.zip
    python3 -c 'import sys, zipfile; z = zipfile.ZipFile(sys.argv[1]); assert z.testzip() is None; print(len(z.infolist()), "entries read by Python")' interop.zip
    unzip -tq interop.zip
fi
echo "all tests passed"
