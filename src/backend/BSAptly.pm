#!/usr/bin/perl -w
#
# SPDX-License-Identifier: GPL-2.0+
#
# Copyright 2022 Collabora Ltd.

package BSAptly;

use BSConfiguration;
use BSPublisher::Util;
use BSRevision;
use BSUtil;
use Build::Deb;

use strict;

our %aptly_config_projects;

BEGIN {
  # From the aptly configuration, generate hash mapping project and repositories
  # to the distribution where they live.
  foreach my $prefix (keys %{ $BSConfig::aptly_config }) {
    my $distros = $BSConfig::aptly_config->{$prefix};
    foreach my $distro (keys %{ $distros }) {
      my $distro_config = $distros->{$distro};
      my $distro_components = $distro_config->{'components'};
      foreach my $component (keys %{ $distro_components }) {
        my $component_config = $distro_components->{$component};
        $aptly_config_projects{$component_config->{'project'}}{$component_config->{'repository'}} = $distro_config;
        $distro_config->{'prefix'} = $prefix;
        $distro_config->{'distribution'} = $distro;
        $component_config->{'component'} = $component;
      }
    }
  }
}

# By default, aptly will try to read configuration from ~/.aptly.conf
# OBS runs as `obsrun` user, but HOME is pointing to /root/, so this will
# raise a permission error. Thus, set the default system configuration file.
use constant APTLY_CONFIG_FILE => '/etc/obs/aptly.conf';
use constant APTLY_LOG_FILE => '/srv/obs/log/aptly.log';

sub aptly_exec {
  my @args = ('aptly', "-config=".APTLY_CONFIG_FILE, @_);
  my $pid;

  if (!defined($pid = fork())) {
    die "Failed to fork child: $!";
  } elsif ($pid == 0) {
    BSUtil::lockopen(*STDOUT, '>>', APTLY_LOG_FILE);
    open(STDERR, '>&STDOUT');
    print STDOUT ">>>>> aptly_exec: ".join(' ', @args)."\n";
    exec(@args) || die("Failed to exec $args[0]: $!\n");
  } else {
    waitpid($pid, 0) == $pid || die("Failed on waitpid $pid: $!\n");
    return $?;
  }
}

# Aptly configuration helpers

sub aptly_distro_get_config {
  my ($prefix, $distro) = @_;
  return $BSConfig::aptly_config->{$prefix}{$distro};
}

sub aptly_project_get_config {
  my ($projid) = @_;
  return $aptly_config_projects{$projid};
}

sub aptly_repo_get_config {
  my ($projid, $repoid) = @_;
  return $aptly_config_projects{$projid}{$repoid};
}

sub aptly_repo_get_component {
  my ($projid, $repoid) = @_;
  my $repo_config = aptly_repo_get_config($projid, $repoid);
  my $distro_components = $repo_config->{'components'};
  foreach my $component (keys %$distro_components) {
    my $component_config = $distro_components->{$component};
    if ($component_config->{'project'} eq $projid && $component_config->{'repository'} eq $repoid) {
      return $component;
    }
  }
  return undef;
}

sub aptly_get_config {
  my ($configid) = @_;
  my @args = ('aptly', "-config=".APTLY_CONFIG_FILE,
    'config', 'show');
  my $args = join(' ', @args);
  foreach my $line (`$args`) {
    if ($line =~ /^\s*"$configid":\s*"(\S*)",$/) {
      return $1;
    }
  }
  return undef;
}

# OBS objects helpers

sub obs_get_project {
  my ($projid) = @_;
  return BSRevision::readproj_local($projid, 1);
}

sub obs_get_repo {
  my ($projid, $repoid) = @_;
  my $obs_proj = obs_get_project($projid);
  if (!$obs_proj || !$obs_proj->{'repository'}) {
    return undef;
  }
  foreach my $repo (@{ $obs_proj->{'repository'} }) {
    if ($repo->{'name'} eq $repoid) {
      return $repo;
    }
  }
  return undef;
}

sub obs_project_repos {
  # From an OBS project, get all its repositories names in a hash. Only those
  # repositories configured in aptly are included.
  my ($proj) = @_;
  my %ret;
  if ($proj && $proj->{'repository'}) {
    foreach my $repo (@{ $proj->{'repository'} }) {
      my $reponame = $repo->{'name'};
      next if (!aptly_repo_get_config($proj->{'name'}, $reponame));
      $ret{$reponame} = 1;
    }
  }
  return \%ret;
}

sub aptly_publish_repo {
  # Given a prefix and distribution, publish a set of multi-component
  # repositories. A repository is included only if:
  # * it's defined in the aptly config for this prefix/distribution.
  # * the publish flag is enabled on OBS for the related project/repository.
  # Note that, as this included multiple OBS repositories, the archs defined
  # for each one might differ. So the union of all the enabled archs is used
  # when publishing.
  my ($prefix, $distribution) = @_;
  my %archs;
  my @components;
  my @repos;

  my $distro_config = aptly_distro_get_config($prefix, $distribution);
  my $distro_components = $distro_config->{'components'};

  foreach my $component (keys %$distro_components) {
    my $component_config = $distro_components->{$component};
    my $projid = $component_config->{'project'};
    my $repoid = $component_config->{'repository'};
    my $obs_proj = obs_get_project($projid);
    my $obs_repo = obs_get_repo($projid, $repoid);

    next unless $obs_repo;

    push @components, $component;
    push @repos, "$projid/$repoid";
    foreach my $arch (@{ $obs_repo->{'arch'} }) {
      if (BSUtil::enabled($repoid, $obs_proj->{'publish'}, 1, $arch)) {
        $archs{$arch} = 1;
      }
    }
  }

  if (!%archs) {
    return 0;
  }

  my $gpgkey = $distro_config->{'gpg-key'} || $BSConfig::aptly_defconfig->{'gpg-key'} || "";

  my @args = ('publish', 'repo',
    "-architectures=".join(',', map { Build::Deb::basearch($_) } (('source'), keys %archs)),
    "-distribution=$distribution",
    "-component=".join(',', @components),
    "-gpg-key=$gpgkey",
    '-skip-contents',
    @repos, $prefix);
  return aptly_exec(@args);
}

# Aptly publish command wrappers

sub aptly_publish_drop {
  my ($prefix, $distribution) = @_;
  my @args = ('publish', 'drop', $distribution, $prefix);
  return aptly_exec(@args);
}

sub aptly_publish_drop_check {
  my ($prefix, $distribution) = @_;
  if (!aptly_is_published($prefix, $distribution)) {
    return 0;
  }
  return aptly_publish_drop($prefix, $distribution);
}

sub aptly_publish_update {
  my ($prefix, $distribution) = @_;
  # Update an already published repository distribution
  my $distro_config = aptly_distro_get_config($prefix, $distribution);
  my $gpgkey = $distro_config->{'gpg-key'} || $BSConfig::aptly_defconfig->{'gpg-key'} || "";
  my @args = ('publish', 'update',
    "-gpg-key=$gpgkey",
    '-skip-contents',
    $distribution, $prefix);
  return aptly_exec(@args);
}

sub aptly_is_published {
  my ($prefix, $distribution) = @_;
  my @args = ('publish', 'show', $distribution, $prefix);
  return aptly_exec(@args) == 0;
}

# Aptly snapshot command wrappers

sub aptly_snapshot_create {
  my ($projid, $repoid, $timestamp) = @_;
  my @args = ('snapshot', 'create',
    "$projid/$repoid/$timestamp",
    'from', 'repo', "$projid/$repoid");
  return aptly_exec(@args);
}

sub aptly_snapshot_drop {
  my ($projid, $repoid, $timestamp) = @_;
  my @args = ('snapshot', 'drop',
    "$projid/$repoid/$timestamp");
  return aptly_exec(@args);
}

sub aptly_snapshot_exists {
  # Check if aptly snapshot exists
  my ($projid, $repoid, $timestamp) = @_;
  my @args = ('snapshot', 'show', "$projid/$repoid/$timestamp");
  return aptly_exec(@args) == 0;
}

sub aptly_snapshot_gen_distro {
  my ($distribution, $timestamp) = @_;
  return "$distribution/snapshots/$timestamp",
}

sub aptly_distro_snapshot {
  # Create snapshots for all the repositories in an aptly prefix/distribution.
  my ($prefix, $distribution, $timestamp) = @_;
  my $distro_config = aptly_distro_get_config($prefix, $distribution);
  my $distro_components = $distro_config->{'components'};

  foreach my $component (keys %$distro_components) {
    my $component_config = $distro_components->{$component};
    my $projid = $component_config->{'project'};
    my $repoid = $component_config->{'repository'};
    my $obs_proj = obs_get_project($projid);
    my $obs_repo = obs_get_repo($projid, $repoid);

    next unless $obs_repo;

    aptly_snapshot_create($component_config->{'project'}, $component_config->{'repository'}, $timestamp);
  }
}

sub aptly_distro_snapshot_drop {
  # Drop snapshots for all the repositories in an aptly prefix/distribution.
  my ($prefix, $distribution, $timestamp) = @_;
  my $distro_config = aptly_distro_get_config($prefix, $distribution);
  my $distro_components = $distro_config->{'components'};

  foreach my $component (keys %$distro_components) {
    my $component_config = $distro_components->{$component};
    my $projid = $component_config->{'project'};
    my $repoid = $component_config->{'repository'};

    next unless aptly_snapshot_exists($projid, $repoid, $timestamp);

    aptly_snapshot_drop($component_config->{'project'}, $component_config->{'repository'}, $timestamp);
  }
}

sub aptly_publish_snapshot {
  # Publish snapshots for the repositories in an aptly prefix/distribution.
  my ($prefix, $distribution, $timestamp) = @_;
  my %archs;
  my @components;
  my @snapshots;

  my $distro_config = aptly_distro_get_config($prefix, $distribution);
  my $distro_components = $distro_config->{'components'};

  foreach my $component (keys %$distro_components) {
    my $component_config = $distro_components->{$component};
    my $projid = $component_config->{'project'};
    my $repoid = $component_config->{'repository'};
    my $obs_proj = obs_get_project($projid);
    my $obs_repo = obs_get_repo($projid, $repoid);

    next unless $obs_repo;
    next unless aptly_snapshot_exists($projid, $repoid, $timestamp);

    push @components, $component;
    push @snapshots, "$projid/$repoid/$timestamp";
    foreach my $arch (@{ $obs_repo->{'arch'} }) {
      if (BSUtil::enabled($repoid, $obs_proj->{'publish'}, 1, $arch)) {
        $archs{$arch} = 1;
      }
    }
  }

  if (!%archs) {
    return 0;
  }

  my $gpgkey = $distro_config->{'gpg-key'} || $BSConfig::aptly_defconfig->{'gpg-key'} || "";

  my @args = ('publish', 'snapshot',
    "-architectures=".join(',', map { Build::Deb::basearch($_) } (('source'), keys %archs)),
    "-distribution=".aptly_snapshot_gen_distro($distribution, $timestamp),
    "-component=".join(',', @components),
    "-gpg-key=$gpgkey",
    '-skip-contents',
    @snapshots, $prefix);
  return aptly_exec(@args);
}

sub aptly_unpublish_snapshot {
  # Unpublish snapshots for the repositories in an aptly prefix/distribution.
  my ($prefix, $distribution, $timestamp) = @_;
  return aptly_publish_drop($prefix, aptly_snapshot_gen_distro($distribution, $timestamp));
}

# Aptly db command wrappers

sub aptly_db_cleanup {
  # Cleanup aptly database
  my @args = ('db', 'cleanup');
  return aptly_exec(@args);
}


# Aptly repo command wrappers

sub aptly_repo_exists {
  # Check if aptly repository exists
  my ($projid, $repoid) = @_;
  my @args = ('repo', 'show', "$projid/$repoid");
  return aptly_exec(@args) == 0;
}

sub aptly_repo_create {
  my ($projid, $repoid, $distribution, $component) = @_;
  my @args = ('repo', 'create',
    "-distribution=$distribution",
    "-component=$component",
    "$projid/$repoid");
  return aptly_exec(@args);
}

sub aptly_repo_drop {
  # Remove aptly repository. Use -force flag to remove even if there's
  # a related snapshot based on this repo.
  my ($projid, $repoid) = @_;
  my @args = ('repo', 'drop', '-force',
    "$projid/$repoid");
  return aptly_exec(@args);
}

sub aptly_repo_clean {
  # Remove all packages in aptly repository.
  my ($projid, $repoid) = @_;
  my @args = ('repo', 'remove', "$projid/$repoid", 'Name');
  return aptly_exec(@args);
}

# Hook functions for OBS

sub aptly_putproject {
  my ($proj, $oldproj, $proj_config) = @_;

  my $oldrepos = obs_project_repos($oldproj);
  my $newrepos = obs_project_repos($proj);

  foreach my $repoid (keys %{ $oldrepos }) {
    my $repo_config = $proj_config->{$repoid};
    if (!$newrepos->{$repoid}) {
      aptly_publish_drop_check($repo_config->{'prefix'}, $repo_config->{'distribution'});
      aptly_repo_drop($proj->{'name'}, $repoid);
      aptly_publish_repo($repo_config->{'prefix'}, $repo_config->{'distribution'});
    }
  }

  foreach my $repoid (keys %{ $newrepos }) {
    my $repo_config = $proj_config->{$repoid};
    aptly_publish_drop_check($repo_config->{'prefix'}, $repo_config->{'distribution'});
    if (!$oldrepos->{$repoid}) {
      my $component = aptly_repo_get_component($proj->{'name'}, $repoid);
      aptly_repo_create($proj->{'name'}, $repoid, $repo_config->{'distribution'}, $component);
    }
    aptly_publish_repo($repo_config->{'prefix'}, $repo_config->{'distribution'});
  }
}

sub aptly_delproject {
  my ($proj, $proj_config) = @_;

  my $repos = obs_project_repos($proj);

  foreach my $repoid (keys %{ $repos }) {
    my $repo_config = $proj_config->{$repoid};
    aptly_publish_drop_check($repo_config->{'prefix'}, $repo_config->{'distribution'});
    aptly_repo_drop($proj->{'name'}, $repoid);
    aptly_publish_repo($repo_config->{'prefix'}, $repo_config->{'distribution'});
  }
}

sub aptly_update_repo {
  # Add new packages to an existent aptly repository.
  # All the previous versions are removed.
  my ($projid, $repoid, $config, $extrep, $added_ref, $removed_ref) = @_;
  my @added = @{ $added_ref };
  my @removed = @{ $removed_ref };
  my ($pkg, $version, $arch, $pkgtype);
  my @args;

  # Remove previous versions
  for my $f (@removed) {
    if ($f =~ /^.*\/(.*)_(.*)_(.*)\.([u]?deb)$/) {
      ($pkg, $version, $arch, $pkgtype) = ($1, $2, $3, $4);
    } elsif ($f =~ /^(.*)_(.*)\.dsc$/) {
      ($pkg, $version, $arch, $pkgtype) = ($1, $2, "source", "source");
    } else {
      next;
    }
    @args = ('repo', 'remove', "$projid/$repoid",
      "Name (=\"$pkg\"), Version (<=\"$version\"), \$Architecture (=\"$arch\"), \$PackageType (=\"$pkgtype\")");
    aptly_exec(@args);
  }

  # Add new packages
  for my $f (@added) {
    if (($f =~ /^.*\/(.*)_(.*)_(.*)\.([u]?deb)$/) or ($f =~ /^(.*)_(.*)\.dsc$/)) {
      my $file = "$extrep/$f";
      @args = ('repo', 'add', "$projid/$repoid", $file);
      aptly_exec(@args);
    }
  }

  return aptly_publish_update($config->{'prefix'}, $config->{'distribution'});
}

1;
