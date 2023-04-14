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
use POSIX qw(strftime);

use strict;

our %aptly_config_projects;

BEGIN {
  # From the aptly configuration, generate hash mapping project and repositories
  # to the distribution where they live.
  foreach my $prefix (keys %{ $BSConfig::aptly_config }) {
    my $distros = $BSConfig::aptly_config->{$prefix};
    foreach my $distro (keys %{ $distros }) {
      my $distro_config = $distros->{$distro};
      die "$prefix -> $distro does not have aptly_server defined" if !defined $distro_config->{'aptly_server'};

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

sub api_tool_exec {
  my $aptly_server = shift;
  my @args = @_;
  my $pid;

  if (!defined($pid = fork())) {
    die "Failed to fork child: $!";
  } elsif ($pid == 0) {
    open(STDERR, '>&STDOUT');
    $ENV{'APTLY_API_URL'} = $aptly_server->{'url'};
    $ENV{'APTLY_API_TOKEN'} = $aptly_server->{'token'} if defined $aptly_server->{'token'};
    my $timestamp = strftime "%Y-%m-%d %H:%M:%S", gmtime;
    print STDOUT "$timestamp: ".join(' ', @args)."\n";
    exec(@args) || die("Failed to exec $args[0]: $!\n");
  } else {
    waitpid($pid, 0) == $pid || die("Failed on waitpid $pid: $!\n");
    return $?;
  }
}

sub aptlyctl_exec {
  my $aptly_server = shift;
  api_tool_exec($aptly_server, 'aptlyctl', @_);
}

sub obs2aptly_exec {
  my $aptly_server = shift;
  api_tool_exec($aptly_server, 'obs2aptly', @_);
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
  my @to_publish;

  my $distro_config = aptly_distro_get_config($prefix, $distribution);
  my $distro_components = $distro_config->{'components'};

  foreach my $component (keys %$distro_components) {
    my $component_config = $distro_components->{$component};
    my $projid = $component_config->{'project'};
    my $repoid = $component_config->{'repository'};
    my $obs_proj = obs_get_project($projid);
    my $obs_repo = obs_get_repo($projid, $repoid);

    next unless $obs_repo;

    push @to_publish, "$projid/$repoid//$component";
    foreach my $arch (@{ $obs_repo->{'arch'} }) {
      if (BSUtil::enabled($repoid, $obs_proj->{'publish'}, 1, $arch)) {
        $archs{$arch} = 1;
      }
    }
  }

  if (!%archs) {
    return 0;
  }

  my $gpgkey = $distro_config->{'gpg-key'} || $BSConfig::aptly_defconfig->{'gpg-key'};

  my @args = ('publish', 'create', 'repo',
    "--architectures=".join(',', map { Build::Deb::basearch($_) } (('source'), keys %archs)),
    "--distribution=$distribution",
    '--skip-contents',
    '--skip-bz2',
    $prefix, @to_publish);
  push @args, "--gpg-key=$gpgkey" if $gpgkey;
  return aptlyctl_exec($distro_config->{'aptly_server'}, @args);
}

# Aptly publish command wrappers

sub aptly_publish_drop_check {
  my ($prefix, $distribution) = @_;
  my $distro_config = aptly_distro_get_config($prefix, $distribution);
  my @args = ('publish', 'drop', '--ignore-if-missing', $prefix, $distribution);
  return aptlyctl_exec($distro_config->{'aptly_server'}, @args);
}

sub aptly_publish_update {
  my ($prefix, $distribution) = @_;
  # Update an already published repository distribution
  my $distro_config = aptly_distro_get_config($prefix, $distribution);
  my $gpgkey = $distro_config->{'gpg-key'} || $BSConfig::aptly_defconfig->{'gpg-key'};
  my @args = ('publish', 'update',
    '--skip-contents',
    '--skip-bz2',
    $prefix, $distribution);
  push @args, "--gpg-key=$gpgkey" if $gpgkey;
  return aptlyctl_exec($distro_config->{'aptly_server'}, @args);
}

# Aptly snapshot command wrappers

sub aptly_snapshot_create {
  my ($projid, $repoid, $timestamp) = @_;
  my $repo_config = aptly_repo_get_config($projid, $repoid);
  my @args = ('repo', 'snapshot',
    "$projid/$repoid",
    "$projid/$repoid/$timestamp");
  return aptlyctl_exec($repo_config->{'aptly_server'}, @args);
}

sub aptly_snapshot_exists {
  # Check if aptly snapshot exists
  my ($projid, $repoid, $timestamp) = @_;
  my $repo_config = aptly_repo_get_config($projid, $repoid);
  my @args = ('snapshot', 'test-exists', "$projid/$repoid/$timestamp");
  return aptlyctl_exec($repo_config->{'aptly_server'}, @args) == 0;
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

sub aptly_publish_snapshot {
  # Publish snapshots for the repositories in an aptly prefix/distribution.
  my ($prefix, $distribution, $timestamp) = @_;
  my %archs;
  my @to_publish;

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

    push @to_publish, "$projid/$repoid/$timestamp//$component";
    foreach my $arch (@{ $obs_repo->{'arch'} }) {
      if (BSUtil::enabled($repoid, $obs_proj->{'publish'}, 1, $arch)) {
        $archs{$arch} = 1;
      }
    }
  }

  if (!%archs) {
    return 0;
  }

  my $gpgkey = $distro_config->{'gpg-key'} || $BSConfig::aptly_defconfig->{'gpg-key'};
  my @args = ('publish', 'create', 'snapshot',
    "--architectures=".join(',', map { Build::Deb::basearch($_) } (('source'), keys %archs)),
    "--distribution=$distribution/snapshots/$timestamp",
    '--skip-contents',
    '--skip-bz2',
    $prefix, @to_publish);
  push @args, "--gpg-key=$gpgkey" if $gpgkey;

  return aptlyctl_exec($distro_config->{'aptly_server'}, @args);
}

# Aptly repo command wrappers

sub aptly_repo_create {
  my ($projid, $repoid, $distribution, $component) = @_;
  my $repo_config = aptly_repo_get_config($projid, $repoid);
  my @args = ('repo', 'create',
    "--distribution=$distribution",
    "--component=$component",
    "$projid/$repoid");
  return aptlyctl_exec($repo_config->{'aptly_server'}, @args);
}

sub aptly_repo_drop {
  # Remove aptly repository. Use -force flag to remove even if there's
  # a related snapshot based on this repo.
  my ($projid, $repoid) = @_;
  my $repo_config = aptly_repo_get_config($projid, $repoid);
  my @args = ('repo', 'drop', '--force',
    "$projid/$repoid");
  return aptlyctl_exec($repo_config->{'aptly_server'}, @args);
}

# Hook functions for OBS

sub aptly_putproject {
  my ($proj, $oldproj, $proj_config) = @_;

  my $oldrepos = obs_project_repos($oldproj);
  my $newrepos = obs_project_repos($proj);

  foreach my $repoid (keys %{ $oldrepos }) {
    my $repo_config = $proj_config->{$repoid};
    if (!$newrepos->{$repoid}) {
      #aptly_publish_drop_check($repo_config->{'prefix'}, $repo_config->{'distribution'});
      aptly_repo_drop($proj->{'name'}, $repoid);
      aptly_publish_repo($repo_config->{'prefix'}, $repo_config->{'distribution'});
    }
  }

  foreach my $repoid (keys %{ $newrepos }) {
    my $repo_config = $proj_config->{$repoid};
    #aptly_publish_drop_check($repo_config->{'prefix'}, $repo_config->{'distribution'});
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
  my ($projid, $repoid, $config, $extrep) = @_;
  my $repo_config = aptly_repo_get_config($projid, $repoid);
  return obs2aptly_exec($repo_config->{'aptly_server'}, "$projid/$repoid", $extrep)
    || aptly_publish_update($config->{'prefix'}, $config->{'distribution'});
}

1;
