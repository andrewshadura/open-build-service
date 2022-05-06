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

mkdir -p $REPOS_DIR/$prj_public_prefix/conf
mkdir -p $REPOS_DIR/$prj_internal_prefix/conf

curl -O https://gitlab.apertis.org/infrastructure/apertis-infrastructure/-/raw/main/release-scripts/add-new-repo
sh ./add-new-repo $prj_distro

gpgkey=$(gpg --list-keys --with-colons | grep -e "^fpr" | head -n1 | cut -d':' -f10)
sed -i "s/SignWith:.*/SignWith: $gpgkey/g" $REPOS_DIR/$prj_public_prefix/conf/distributions
sed -i "s/SignWith:.*/SignWith: $gpgkey/g" $REPOS_DIR/$prj_internal_prefix/conf/distributions

reprepro --gnupghome $GNUPGHOME -Vb $REPOS_DIR/$prj_public_prefix export $prj_distro

for c in $prj_components
do
	mkdir -p $BUILD_DIR/$prj_osname:$prj_distro:$c/default $BUILD_DIR/$prj_osname:$prj_distro:$c/rebuild
	chown obsrun:obsrun -R $BUILD_DIR/$prj_osname:$prj_distro:$c
done

for c in $prj_components
do
	echo obs_admin --clone-repository $prj_osname:$prj_distro:$c default $prj_osname:$prj_distro:$c default
done

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
done

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
	done
done

echo "PASSED: all tests successfully passed!" >&2
exit 0
