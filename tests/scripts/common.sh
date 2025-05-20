. $(dirname $0)/scripts/tap.sh

debian_release=bullseye

OBSDIR=$PWD

dir="$(mktemp -d)"

set -x

cd "$dir"
