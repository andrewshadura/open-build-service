#!/bin/bash

set -eu

ROOT_DIR="$(dirname -- "${BASH_SOURCE}")"
ABS_ROOT_DIR="$(realpath $ROOT_DIR)"

. $ABS_ROOT_DIR/common.sh

BUILD_DIR=/srv/obs/build
REPOS_DIR=/srv/obs/repos

prj_arch="x86_64"
prj_components="target development sdk"
prj_distro="v2022"
prj_osname="apertis"
prj_public_prefix="shared/apertis/public/apertis"
prj_internal_prefix="shared/apertis/internal/apertis"
prj_repo="default"

debian_prj_name="Debian:Bullseye:main"
debian_repo="main"
debian_url="http://deb.debian.org/debian/bullseye/main"

aptly="aptly -config=/etc/obs/aptly.conf"
bs_aptly_migration="/usr/lib/obs/server/bs_aptly_migration"
oscrc_file="$ABS_ROOT_DIR/oscrc"
osc="osc -c $oscrc_file"

if [ $(id -nu) != obsrun ]; then
	echo "ERROR: needs to be run as obsrun" >&2
	exit 1
fi

echo "Migrating reprepro $prj_public_prefix/$prj_distro to aptly $prj_public_prefix/$prj_distro"
$bs_aptly_migration $prj_public_prefix $prj_distro

for prj_component in $prj_components; do
	project="$prj_osname:$prj_distro:$prj_component"
	repo="$project/$prj_repo"
	echo "Checking aptly repository: $repo"
	if ! $aptly repo show "$repo"; then
		echo "ERROR: aptly repository not created" >&2
		exit 1
	fi
done

echo "Checking aptly distribution publish: $prj_distro $prj_public_prefix"
if ! $aptly publish show $prj_distro $prj_public_prefix; then
	echo "ERROR: aptly distribution not published" >&2
	exit 1
fi

for prj_component in $prj_components; do
	eval pkgs=(\${${prj_component}_pkgs})
	for pkg_name in $pkgs; do
		eval bin_files=(\${${prj_component}_bins})
		check_bins $prj_osname $prj_distro $prj_component $prj_repo $bin_files
	done
done

pushd /srv/obs/repos/shared/apertis/public/apertis/dists/$prj_distro/snapshots
for d in *; do
	if [ ! -d "$d" ] || [ -L "$d" ]; then
		continue
	fi
	timestamp=$d
	for prj_component in $prj_components; do
		project="$prj_osname:$prj_distro:$prj_component"
		snapshot="$project/$prj_repo/$timestamp"
		echo "Checking aptly snapshot: $snapshot"
		if ! $aptly snapshot show $snapshot; then
			echo "ERROR: aptly snapshot not created" >&2
			exit 1
		fi
	done
	echo "Checking aptly snapshot publish: $prj_distro/snapshots/$timestamp $prj_public_prefix"
	if ! $aptly publish show $prj_distro/snapshots/$timestamp $prj_public_prefix; then
		echo "ERROR: aptly snapshot not published" >&2
		exit 1
	fi
done
popd

echo "PASSED: all tests successfully passed!" >&2
exit 0
