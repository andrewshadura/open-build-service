#!/bin/bash

set -eu

ROOT_DIR="$(dirname -- "${BASH_SOURCE}")"
ABS_ROOT_DIR="$(realpath $ROOT_DIR)"

APERTIS_POOL_URL="https://repositories.apertis.org/apertis/pool"

prj_arch="x86_64"
prj_components="target development sdk"
prj_distro="v2023"
prj_osname="apertis"
prj_prefix="shared/apertis/public/apertis"
prj_repo="default"

debian_prj_name="Debian:Bullseye:main"
debian_repo="main"
debian_url="http://deb.debian.org/debian/bullseye/main"

bs_published_hook="/usr/lib/obs/server/bs_published_hook_aptly_snapshot"
oscrc_file="$ABS_ROOT_DIR/oscrc"
osc="osc -c $oscrc_file"

target_pkgs="aalib"
development_pkgs="advancecomp"
sdk_pkgs="alembic"

aalib_dsc="aalib_1.4p5-48+apertis1.dsc"
advancecomp_dsc="advancecomp_2.1-2.1co1.dsc"
alembic_dsc="alembic_1.4.3-1apertis0.dsc"

target_bins="libaa-bin-dbgsym_1.4p5-48+apertis1bv2023.0b1_amd64
	libaa-bin_1.4p5-48+apertis1bv2023.0b1_amd64
	libaa1-dbgsym_1.4p5-48+apertis1bv2023.0b1_amd64
	libaa1-dev_1.4p5-48+apertis1bv2023.0b1_amd64
	libaa1_1.4p5-48+apertis1bv2023.0b1_amd64"
development_bins="advancecomp-dbgsym_2.1-2.1co1bv2023.0b1_amd64
	advancecomp_2.1-2.1co1bv2023.0b1_amd64"
sdk_bins="alembic_1.4.3-1apertis0bv2023.0b1_all
	python3-alembic_1.4.3-1apertis0bv2023.0b1_all"

get_oscrc () {
	obs_frontend_host="$1"
	cat << EOF
[general]
apiurl = http://$obs_frontend_host:3000

[http://$obs_frontend_host:3000]
user=Admin
pass=opensuse
credentials_mgr_class=osc.credentials.PlaintextConfigFileCredentialsManager
EOF
}

get_debianmeta () {
	debian_prj_name="$1"
	debian_repo="$2"
	prj_arch="$3"
	debian_url="$4"
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
	prj_osname="$1"
	prj_distro="$2"
	prj_component="$3"
	prj_repo="$4"
	debian_prj_name="$5"
	debian_repo="$6"
	prj_arch="$7"
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
	prj_distro="$1"
	cat << EOF
Repotype: debian
type: dsc
release: b$prj_distro.0b<B_CNT>
buildengine: debootstrap
EOF
}

get_pkgmeta () {
	prj_osname="$1"
	prj_distro="$2"
	prj_component="$3"
	pkg_name="$4"
	project="$prj_osname:$prj_distro:$prj_component"
	cat << EOF
<package name="$pkg_name" project="$project">
</package>
EOF
}

copy_pkg () {
	prj_osname="$1"
	prj_distro="$2"
	prj_component="$3"
	pkg_name="$4"
	dsc_file="$5"
	project="$prj_osname:$prj_distro:$prj_component"
	url="$APERTIS_POOL_URL/$prj_component/$(echo $pkg_name | head -c 1)/$pkg_name"

	tempdir=$(mktemp -d)
	pushd $tempdir

	get_pkgmeta $prj_osname $prj_distro $prj_component $pkg_name | $osc meta pkg "$project" $pkg_name -F -
	$osc co $project $pkg_name

	pushd $project/$pkg_name
	echo "Copying file: $dsc_file from $url"
	dget -u -d "$url/$dsc_file"
	$osc add ./*
	$osc commit -m "test: $dsc_file"
	popd

	popd
	rm -rf $tempdir
}

wait_pkgs () {
	prj_osname="$1"
	prj_distro="$2"
	prj_component="$3"
	prj_repo="$4"
	prj_arch="$5"
	pkg_name="$6"
	project="$prj_osname:$prj_distro:$prj_component"
	iterations=15

	echo "Checking build result: $project $prj_repo $pkg_name $prj_arch"
	for i in $(seq $iterations); do
		result=$($osc results "$project" "$pkg_name" -a "$prj_arch" -r "$prj_repo")
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
}

check_bins () {
	prj_osname="$1"
	prj_distro="$2"
	prj_component="$3"
	prj_repo="$4"
	bin_files="$5"
	repo="$prj_osname:$prj_distro:$prj_component/$prj_repo"

	for bin_file in $bin_files; do
		echo "Checking package binary: $bin_file"
		if ! aptlyctl repo search --exit-code "$repo" "$bin_file"; then
			echo "ERROR: aptly binary not found" >&2
			exit 1
		fi
	done
}
