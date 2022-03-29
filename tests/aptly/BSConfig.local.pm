our $publishedhook_use_regex = 1;
our $publishedhook = {
  "apertis:v2022:.*" => "/usr/lib/obs/server/bs_published_hook_aptly_snapshot",
};

our $aptly_config = {
  "shared/apertis/public" => {
    "v2022" => {
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
