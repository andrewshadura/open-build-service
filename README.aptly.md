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

The OBS configuration files must provide a hash named `aptly_config` with the
following structure:

```
our $aptly_config = {
  "prefix_path" => {
    "distribution_name" => {
      "gpg-key" => "optional_gpg_hash",
      "components" => {
        "component_name" => {
          "project" => "obs_project_id",
          "repository" => "obs_repository_id",
        },
        [...]
      },
    },
    [...]
  },
};
```

NOTE: a pair `(obs_project_id, obs_repository_id)` can only be appear once in
the hash, i.e. it can't be a component of more than one distribution.

For example, for an Apertis v2022 release:
* publish prefix path set to: `shared/apertis/public`.
* 3 distributions defined: `v2022`, `v2022-security`, `v2022-updates`.
* each distribution has 3 components: `target`, `development`, `sdk`.
* for each component, the OBS project and repository is defined.
* as an example, `v2022` will be published using the `gpg-key` defined for this
distribution. Otherwise, the default `gpg-key` is used.

```
our $aptly_config = {
  "shared/apertis/public" => {
    "v2022" => {
      "gpg-key" => "8E62938108AE643A217D0511027B2E6C53229B30",
      "components" => {
        "target" => {
          "project" => "apertis:v2022:target",
          "repository" => "default",
        },
        "development" => {
          "project" => "apertis:v2022:development",
          "repository" => "default",
        },
        "sdk" => {
          "project" => "apertis:v2022:sdk",
          "repository" => "default",
        },
      },
    },
    "v2022-security" => {
      "components" => {
        "target" => {
          "project" => "apertis:v2022:security:target",
          "repository" => "default",
        },
        "development" => {
          "project" => "apertis:v2022:security:development",
          "repository" => "default",
        },
        "sdk" => {
          "project" => "apertis:v2022:security:sdk",
          "repository" => "default",
        },
      },
    },
    "v2022-updates" => {
      "components" => {
        "target" => {
          "project" => "apertis:v2022:updates:target",
          "repository" => "default",
        },
        "development" => {
          "project" => "apertis:v2022:updates:development",
          "repository" => "default",
        },
        "sdk" => {
          "project" => "apertis:v2022:updates:sdk",
          "repository" => "default",
        },
      },
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
