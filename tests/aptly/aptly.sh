#!/bin/bash

set -eu

ROOT_DIR="$(dirname -- "${BASH_SOURCE}")"
ABS_ROOT_DIR="$(realpath $ROOT_DIR)"

. $ABS_ROOT_DIR/common.sh

export APTLY_API_URL=http://aptly:8080

prj_arch="x86_64"
prj_components="target development sdk"
prj_distro="v2023"
prj_osname="apertis"
prj_public_prefix="shared/apertis/public/apertis"
prj_repo="default"

debian_prj_name="Debian:Bullseye:main"
debian_repo="main"
debian_url="http://deb.debian.org/debian/bullseye/main"

bs_published_hook="/usr/lib/obs/server/bs_published_hook_aptly_snapshot"
oscrc_file="$ABS_ROOT_DIR/oscrc"
osc="osc -c $oscrc_file"

if [ $(id -nu) != obsrun ]; then
	echo "ERROR: needs to be run as obsrun" >&2
	exit 1
fi

echo "Creating OBS config: $oscrc_file"
get_oscrc $OBS_FRONTEND_HOST > $oscrc_file

echo "Creating OBS project: $debian_prj_name"
get_debianmeta $debian_prj_name $debian_repo $prj_arch $debian_url | $osc meta prj "$debian_prj_name" -F -
get_debianconf | $osc meta prjconf "$debian_prj_name" -F -

for prj_component in $prj_components; do
	project="$prj_osname:$prj_distro:$prj_component"
	echo "Creating OBS Project: $project"
	get_prjmeta $prj_osname $prj_distro $prj_component $prj_repo $debian_prj_name $debian_repo $prj_arch | $osc meta prj "$project" -F -
	get_prjconf $prj_distro | $osc meta prjconf "$project" -F -
	repo="$project/$prj_repo"
	echo "Checking aptly repository: $repo"
	if ! aptlyctl repo test-exists "$repo"; then
		echo "ERROR: aptly repository not created" >&2
		exit 1
	fi
done

echo "Checking aptly distribution publish: $prj_public_prefix $prj_distro"
if ! aptlyctl publish test-exists $prj_public_prefix $prj_distro; then
	echo "ERROR: aptly distribution not published" >&2
	exit 1
fi

for prj_component in $prj_components; do
	eval pkgs=(\${${prj_component}_pkgs})
	for pkg_name in $pkgs; do
		eval dsc_file=(\${${pkg_name}_dsc})
		copy_pkg $prj_osname $prj_distro $prj_component $pkg_name $dsc_file
	done
done

for prj_component in $prj_components; do
	eval pkgs=(\${${prj_component}_pkgs})
	for pkg_name in $pkgs; do
		eval bin_files=(\${${prj_component}_bins})
		wait_pkgs $prj_osname $prj_distro $prj_component $prj_repo $prj_arch $pkg_name
		check_bins $prj_osname $prj_distro $prj_component $prj_repo $bin_files
	done
done

timestamp=$(date --utc +%Y%m%dT%H%M%SZ)
component=$(echo $prj_components | cut -d' ' -f 1)
project="$prj_osname:$prj_distro:$component"
echo "Triggering snapshot: $project/$prj_repo $timestamp"
$bs_published_hook -t "$timestamp" "$project/$prj_repo"

for prj_component in $prj_components; do
	project="$prj_osname:$prj_distro:$prj_component"
	snapshot="$project/$prj_repo/$timestamp"
	echo "Checking aptly snapshot: $snapshot"
	if ! aptlyctl snapshot test-exists $snapshot; then
		echo "ERROR: aptly snapshot not created" >&2
		exit 1
	fi
done

echo "Checking aptly snapshot publish: $prj_public_prefix $prj_distro"
if ! aptlyctl publish test-exists $prj_public_prefix "$prj_distro/snapshots/$timestamp"; then
	echo "ERROR: aptly snapshot not published" >&2
	exit 1
fi

echo "PASSED: all tests successfully passed!" >&2
exit 0
