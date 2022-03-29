#!/bin/bash

set -eu

ROOT_DIR="$(dirname -- "${BASH_SOURCE}")"
ABS_ROOT_DIR="$(realpath $ROOT_DIR)"

prj_arch="x86_64"
prj_components="target development sdk"
prj_distro="v2022"
prj_osname="apertis"
prj_prefix="shared/apertis/public"
prj_repo="default"

apertis_pool_url="https://repositories.apertis.org/apertis/pool"

debian_prj_name="Debian:Bullseye:main"
debian_repo="main"
debian_url="http://deb.debian.org/debian/bullseye/main"

aptly="aptly -config=/etc/obs/aptly.conf"
bs_published_hook="/usr/lib/obs/server/bs_published_hook_aptly_snapshot"
oscrc_file="$ABS_ROOT_DIR/oscrc"
osc="osc -c $oscrc_file"

get_oscrc () {
	cat << EOF
[general]
apiurl = http://$OBS_FRONTEND_HOST:3000

[http://$OBS_FRONTEND_HOST:3000]
user=Admin
pass=opensuse
credentials_mgr_class=osc.credentials.PlaintextConfigFileCredentialsManager
EOF
}

get_debianmeta () {
	cat << EOF
<project name="$debian_prj_name">
  <repository name="$debian_repo">
    <download arch="$prj_arch" url="$debian_url" repotype="deb"/>
    <arch>$prj_arch</arch>
  </repository>
</project>
EOF
}

get_debianconf () {
	cat << EOF
Repotype: debian
type: dsc
buildengine: debootstrap

Order: base-passwd:base-files

Preinstall: dash bash sed grep coreutils debianutils
Preinstall: libc6 libncurses5 libacl1 libattr1 libpcre3
Preinstall: libpcre2-8-0 libcrypt1
Preinstall: diffutils tar dpkg libc-bin
Preinstall: gzip base-files base-passwd
Preinstall: libselinux1 libsepol1
Preinstall: libgcc-s1 util-linux debconf tzdata findutils libdbus-1-3
Preinstall: liblzma5 xz-utils libstdc++6 passwd
Preinstall: login zlib1g libbz2-1.0 libtinfo5 libsigsegv2
Preinstall: dash insserv libgmp10 libdebconfclient0
Preinstall: perl-base perl libperl-dev mawk init-system-helpers

Required: build-essential apt mount fakeroot dpkg-dev ncurses-base hostname
Required: libtool

# Work around packge looking up variations of localhost .e.g glibc tries to look up localhost.
Support: libnss-myhostname

Prefer: mawk
Prefer: cvs libesd0 libfam0 libfam-dev expect
Prefer: locales default-jdk
Prefer: xorg-x11-libs libpng fam mozilla mozilla-nss xorg-x11-Mesa
Prefer: unixODBC libsoup glitz java-1_4_2-sun gnome-panel
Prefer: desktop-data-SuSE gnome2-SuSE mono-nunit gecko-sharp2
Prefer: apache2-prefork openmotif-libs ghostscript-mini gtk-sharp
Prefer: glib-sharp libzypp-zmd-backend
Prefer: sysv-rc make
Prefer: libjack-jackd2-dev libsndio-dev
Prefer: pkg-config
Prefer: texlive-htmlxml libncurses-dev
Prefer: libavcodec58
Prefer: libsystemd0
Prefer: libtinfo-dev
Prefer: libavfilter7
Prefer: libfontconfig-dev
EOF
}

get_prjmeta () {
	prj_component="$1"
	project="$prj_osname:$prj_distro:$prj_component"
	cat << EOF
<project name="$project">
  <repository name="$prj_repo">
    <path project="$debian_prj_name" repository="$debian_repo"/>
    <arch>$prj_arch</arch>
  </repository>
</project>
EOF
}

get_prjconf () {
	cat << EOF
Repotype: debian
type: dsc
release: b$prj_distro.0b<B_CNT>
buildengine: debootstrap
EOF
}

get_pkgmeta () {
	prj_component="$1"
	pkg_name="$2"
	project="$prj_osname:$prj_distro:$prj_component"
	cat << EOF
<package name="$pkg_name" project="$project">
</package>
EOF
}

if [ $(id -nu) != obsrun ]; then
	echo "ERROR: needs to be run as obsrun" >&2
	exit 1
fi

echo "Creating OBS config: $oscrc_file"
get_oscrc > $oscrc_file

echo "Creating OBS project: $debian_prj_name"
get_debianmeta | $osc meta prj "$debian_prj_name" -F -
get_debianconf | $osc meta prjconf "$debian_prj_name" -F -

for prj_component in $prj_components; do
	project="$prj_osname:$prj_distro:$prj_component"
	echo "Creating OBS Project: $project"
	get_prjmeta $prj_component | $osc meta prj "$project" -F -
	get_prjconf | $osc meta prjconf "$project" -F -
	repo="$project/$prj_repo"
	echo "Checking aptly repository: $repo"
	if ! $aptly repo show "$repo"; then
		echo "ERROR: aptly repository not created" >&2
		exit 1
	fi
done

echo "Checking aptly distribution publish: $prj_distro $prj_prefix"
if ! $aptly publish show $prj_distro $prj_prefix; then
	echo "ERROR: aptly distribution not published" >&2
	exit 1
fi

target_pkgs=(aalib)
development_pkgs=(advancecomp)
sdk_pkgs=(alembic)

aalib_dsc=(aalib_1.4p5-48+apertis1.dsc)
advancecomp_dsc=(advancecomp_2.1-2.1co1.dsc)
alembic_dsc=(alembic_1.4.3-1apertis0.dsc)

target_bins=(aalib_1.4p5-48+apertis1_source libaa-bin_1.4p5-48+apertis1_amd64 libaa-bin-dbgsym_1.4p5-48+apertis1_amd64 \
	libaa1_1.4p5-48+apertis1_amd64 libaa1-dbgsym_1.4p5-48+apertis1_amd64 libaa1-dev_1.4p5-48+apertis1_amd64)
development_bins=(advancecomp_2.1-2.1co1_amd64 advancecomp_2.1-2.1co1_source advancecomp-dbgsym_2.1-2.1co1_amd64)
sdk_bins=(alembic_1.4.3-1apertis0_all alembic_1.4.3-1apertis0_source python3-alembic_1.4.3-1apertis0_all)

add_pkgs () {
	prj_component="$1"
	eval pkgs=(\${${prj_component}_pkgs[*]})
	tempdir=$(mktemp -d)
	pushd $tempdir
	for pkg in "${pkgs[@]}"; do
		get_pkgmeta $prj_component $pkg | $osc meta pkg "$prj_osname:$prj_distro:$prj_component" $pkg -F -
		project="$prj_osname:$prj_distro:$prj_component"
		$osc co $project $pkg
		pushd $project/$pkg
		pkg_initial=$(echo $pkg | head -c 1)
		eval dsc=(\${${pkg}_dsc[*]})
		url="$apertis_pool_url/$prj_component/$pkg_initial/$pkg"
		echo "Copying file: $dsc from $url"
		dget -u -d "$url/$dsc"
		$osc add ./*
		$osc commit -m "test: $dsc"
		popd
	done
	popd
	rm -rf $tempdir
}

wait_pkgs () {
	prj_component="$1"
	iterations=15
	eval pkgs=(\${${prj_component}_pkgs[*]})
	for pkg in "${pkgs[@]}"; do
		project="$prj_osname:$prj_distro:$prj_component"
		echo "Checking build result: $project $prj_repo $pkg $prj_arch"
		for i in $(seq $iterations); do
			result=$($osc results "$project" "$pkg" -a "$prj_arch" -r "$prj_repo")
			if [ "$(echo $result | cut -d' ' -f 3)" == "succeeded" ]; then
				break
			fi
			if [ $i -eq $iterations ]; then
				echo "ERROR: package not built" >&2
				exit 1
			fi
			echo "Sleeping 60s (iteration $i/$iterations)"
			sleep 60
		done
	done
}

check_bins () {
	prj_component="$1"
	eval bins=(\${${prj_component}_bins[*]})
	repo="$prj_osname:$prj_distro:$prj_component/$prj_repo"
	aptly_pkgs=$($aptly repo search "$repo")
	index=0
	for pkg in $aptly_pkgs; do
		echo "Checking aptly package: $repo $pkg"
		if [ "$pkg" != "${bins[$index]}" ]; then
			echo "ERROR: aptly package not found" >&2
			exit 1
		fi
		index=$((index+1))
	done
}

for prj_component in $prj_components; do
	add_pkgs "$prj_component"
done

for prj_component in $prj_components; do
	wait_pkgs "$prj_component"
	check_bins "$prj_component"
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
	if ! $aptly snapshot show $snapshot; then
		echo "ERROR: aptly snapshot not created" >&2
		exit 1
	fi
done

prefix="$prj_prefix/snapshots/$timestamp"
echo "Checking aptly snapshot publish: $prj_distro $prefix"
if ! $aptly publish show $prj_distro $prefix; then
	echo "ERROR: aptly snapshot not published" >&2
	exit 1
fi

echo "PASSED: all tests successfully passed!" >&2
exit 0
