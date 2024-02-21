# OBS Aptly integration

OBS has integrated [aptly](https://www.aptly.info/) backend support for Debian
repository management.

This can be used to automatically publish repositories, packages and snapshots
built from OBS.

In order to use aptly backend, repositories must be defined in the OBS
configuration files as detailed in the next sections.

## Users/permissions

The OBS backend process runs on `obsrun` user. Do not run aptly using the `root`
user as it will create and access files, which may end up having root access
only.

## OBS configuration

The OBS configuration files (e.g. `BSConfig.pm`) must have the following
configurations defined in order to use the aptly backend.

### aptly repositories hash

The OBS configuration files must provide a hash named `aptly_projects` with the
following structure:

```
our $aptly_projects = {
  "obs_project_id" => {
    "obs_repository_id" => {
      "target"       => "repository_name",
      "distribution" => "distribution_name",
      "component"    => "component_name",
      "gpg-key"      => "optional_gpg_hash",
    },
    [...]
  },
  [...]
};
```

For each `repository_name`, there must be an entry in a hash `aptly_targets`:

```
our $aptly_targets = {
  "repository_name" => {
    "server"  => {
      "url" => "https://...",
      "token" => "...",
    },
    "gpg-key" => "gpg_hash",
    "prefix"  => "prefix_path",
  }
};
```

Instead of specifying `target` and a corresponding entry in `aptly_targets`,
it’s also possible to configure the aptly endpoint directly using
`aptly-server` hash (see example below).

For example, for an Apertis v2025 release:
* publish prefix path set to: `shared/apertis/public`.
* 3 distributions defined: `v2025`, `v2025-security`, `v2025-updates`.
* each distribution has 3 components: `target`, `development`, `sdk`.
* for each component, the OBS project and repository is defined.
* `rebuild` repository for `sdk` is published at a separate aptly instance which
  is specified inline using `aptly-server` setting.
* as an example, `v2025` will be published using the `gpg-key` defined for this
distribution. Otherwise, the default `gpg-key` is used.

```
my $apertis_aptly_server = {
  "url" => "https://...",
  "token" => "...",
};

our $aptly_repos = {
  "apertis" => {
    "server"  => $apertis_aptly_server
    "gpg-key" => $aptly_gpgkey,
    "prefix"  => "shared/apertis/public",
  }
};

our $aptly_projects = {
  "apertis:v2025:target" => {
    "default" => {
      "target"       => "apertis",
      "distribution" => "v2025",
      "component"    => "target",
    }
  },
  "apertis:v2025:development" => {
    "default" => {
      "target"       => "apertis",
      "distribution" => "v2025",
      "component"    => "development",
    }
  },
  "apertis:v2025:sdk" => {
    "default" => {
      "target"       => "apertis",
      "distribution" => "v2025",
      "component"    => "sdk",
    },
    "rebuild" => {
      "distribution" => "v2025",
      "component"    => "sdk",
      "gpg-key"      => "...",
      "prefix"       => "apertis",
      "aptly-server" => {
        "url" => "https://rebuilds.apertis.org",
        "token" => "tokentoken",
      },
    },
  },
  "apertis:v2025:updates:target" => {
    "default" => {
      "target"       => "apertis",
      "distribution" => "v2025-updates",
      "component"    => "target",
    }
  },
  "apertis:v2025:updates:development" => {
    "default" => {
      "target"       => "apertis",
      "distribution" => "v2025-updates",
      "component"    => "development",
    }
  },
  "apertis:v2025:updates:sdk" => {
    "default" => {
      "target"       => "apertis",
      "distribution" => "v2025-updates",
      "component"    => "sdk",
    },
  },
  "apertis:v2025:security:target" => {
    "default" => {
      "target"       => "apertis",
      "distribution" => "v2025-security",
      "component"    => "target",
    }
  },
  "apertis:v2025:security:development" => {
    "default" => {
      "target"       => "apertis",
      "distribution" => "v2025-security",
      "component"    => "development",
    }
  },
  "apertis:v2025:security:sdk" => {
    "default" => {
      "target"       => "apertis",
      "distribution" => "v2025-security",
      "component"    => "sdk",
    },
  },
};
```

### aptly defconfig

Default configurations for aptly can be defined using the `aptly_defconfig`
hash, which right now only support setting the default `gpg-key`.

```
our $aptly_defconfig = {
  "gpg-key" => "8E62938108AE643A217D0511027B2E6C53229B30",
};
```

### aptly publish hook

Each time a package is published on OBS, the `publishedhook` will run. This is
useful for tasks like creating snapshots. The following can be configured in the
`BSConfig.pm` OBS configuration files:

```
our $publishedhook_use_regex = 1;
our $publishedhook = {
  "apertis:v2022:.*" => "/usr/lib/obs/server/bs_published_hook_aptly_snapshot",
};
```

The above published hook source code can be found at
`./src/backend/bs_published_hook_aptly_snapshot` and will be installed by
default to `/usr/lib/obs/server/bs_published_hook_aptly_snapshot`.

### aptly database cleanup

Aptly needs to regularly run a database cleanup to remove unused data,
which can be accomplished by running `aptlyctl db-cleanup` periodically.
