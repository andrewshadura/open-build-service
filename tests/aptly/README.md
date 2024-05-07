# OBS Aptly integration tests

Aptly integration is tested via the `run.py` script in this directory.

## Dependencies

The following Python packages are required:

- pydantic
- python-debian
- requests
- ruamel.yaml

The following Python packages are optional:

- hvac
  - Required if you need [Vault integration](#vault-integration).
- osc
  - Required if using a test configuration with `obs:credentials:` set to `oscrc`.
- keyring
  - Required by osc if your `~/.config/osc/oscrc` stores credentials in the system
    keyring, which is **highly recommended for accessing external OBS instances**.

You can install these from the Debian repositories via:

```
apt install \
  osc \
  python3-debian \
  python3-hvac \
  python3-keyring \
  python3-pydantic \
  python3-requests \
  python3-ruamel.yaml \
```

## Usage

To run the tests against a local OBS started via `docker-compose`, run:

```
$ python3 tests/aptly/run.py
```

This will:

- Destroy and recreate the test projects and aptly prefix.
- Copy a few different packages (one per component) from the Apertis repositories onto
  the target OBS and monitor the build.
- Once built, check that all the packages are published properly.
- Try installing the packages into a fresh docker container.
- Repeat the above two steps but on the latest snapshot created.

If you already built the packages but want to run the remainder of the steps again, run
the tests with `--skip-clean-rebuild`.

## OBS configuration

The tests expect these OBS projects to be configured to publish to aptly, under the
prefix `apertis-test`:

- `apertis:test:v2024:target`
- `apertis:test:v2024:development`
- `apertis:test:v2024:sdk`

Additionally, it will create these projects in order to pull the needed build
dependencies:

- `apertis:dod:v2024:target`
- `apertis:dod:v2024:development`
- `apertis:dod:v2024:sdk`

**You should avoid deleting these.** Due to unknown OBS bugs, if these projects get
deleted, when the script re-creates them, they will be entirely non-functional without
a backend restart.

See `BSConfig.local.pm` for an example configuration.

## Test configuration

The tests are configured via the files inside the `configs/` subdirectory,
which can be passed to `run.py` via `--config`:

```
$ python3 tests/aptly/run.py --config configs/local.yaml
```

The following are currently included by default:

- `local.yaml` (the default) - Targets a docker-compose cluster running on localhost.
- `local-ci.yaml` - Identical to the above but with the hostname and ports adjusted for
  use on GitLab CI.
- `staging.yaml` **TODO: doesn't exist yet** - Targets the staging OBS;
  [requires `VAULT_TOKEN` to be set in the environment](#vault-integration).

### Format

Configuration files are written in YAML as laid out as such:

```yaml
aptly:
  api:
    # Aptly API URL.
    url: http://localhost:8088/
    # Authentication token to pass to the API (optional).
    # (See the "Aptly authentication" section below for details.)
    token:
      # Source for the token; currently only 'vault' is supported.
      from: vault
      # Vault URL.
      url: https://VAULT-URL/
      # Mount point for a v2 kv secrets engine that contains the below path.
      mount: apertis
      # Path to the token.
      path: /my-aptly/api
  content:
    # URL that the repositories are published to, *excluding* the aptly prefix
    # `apertis-test`.
    # TODO: describe from_host/from_docker
    url: http://localhost:9000/
  # Public (*not* private!) GPG key that the debian repositories are signed with.
  gpg_key: |
    -----BEGIN PGP PUBLIC KEY BLOCK-----

    mDMEZi/EFxYJKwYBBAHaRw8BAQdAoi7LGyU9eo73lmJGi8Tb4E/9XXIPpzXXk4iX
    pMRL1ea0BHRlc3SImQQTFgoAQRYhBCxjBD6eHxYUYFzRkEfioIEWl31tBQJmL8QX
    AhsDBQkFo5qABQsJCAcCAiICBhUKCQgLAgQWAgMBAh4HAheAAAoJEEfioIEWl31t
    dw8BAI/s8RoFVuIik3ZwL0ZVJyAuCnUeJ1if9PLW/mRoJGuzAQD+gKFeR3vDYO0m
    O2MNKxeblV36xrBZcrcXMW70/5/uDrg4BGYvxBcSCisGAQQBl1UBBQEBB0DNW2PG
    q7d37xU3Nc2rdmqcw2XxQ7BvNn4fxOKuhMlFCQMBCAeIeAQYFgoAIBYhBCxjBD6e
    HxYUYFzRkEfioIEWl31tBQJmL8QXAhsMAAoJEEfioIEWl31t+/UA/0LmJR7L5CtI
    X55eEPrpcegR/AOL9HpMt+TeZQSZxYmiAP0fZBHz4RvnB8ryOBcRDyFZ+h6Xco6s
    gtdC8C3BnzcJDg==
    =fzGT
    -----END PGP PUBLIC KEY BLOCK-----

## Vault integration
obs:
  # OBS API URL.
  url: http://localhost:3000/
  # Credentials to use for OBS, one of two values:
  # - `default`: Use the default out-of-the-box credentials `Admin:opensuse`.
  # - `oscrc`: Retrieve the credentials for the API URL from your .oscrc.
  credentials: default
```

### Vault integration

When `aptly:api:token:from:` is set `vault`, the Aptly token will be retrieved from the
configured Hashicorp Vault installation. In order for this to work, **you must set
`VAULT_TOKEN` in your shell to be your Vault auth token**.

## Troubleshooting

### Packages stay stuck forever as unresolved

These tests use OBS's Download-on-Demand support, which tends to be rather
temperamental. In particular, deleting and re-creating the DoD repositories will
completely break the ability to download from them. In most cases, fully restarting the
backend will resolve the issue.
