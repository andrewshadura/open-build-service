my @reprepro_releases = ("v2022");
my @aptly_releases = ("v2300");
my @apertis_components = ("target", "development", "sdk");
my $apertis_prefix = "shared/apertis/public/apertis";
my $aptly_server = {
  'url' => 'http://aptly:8080',
};

our $publishedhook_use_regex = 1;
our $publishedhook = {};

foreach $release (@reprepro_releases) {
  $publishedhook->{"apertis:".$release.":.*"} = "/usr/lib/obs/server/reprepro-snapshot";
};

foreach $release (@aptly_releases) {
  $publishedhook->{"apertis:".$release.":.*"} = "/usr/lib/obs/server/bs_published_hook_aptly_snapshot";
};

our $reprepository = {};

foreach $release (@reprepro_releases) {
  foreach $component (@apertis_components) {
    $reprepository->{"apertis:".$release.":".$component."/default"} = {
      "repository" => $apertis_prefix,
      "codename" => $release,
      "component" => $component
    };
    $reprepository->{"apertis:".$release.":updates:".$component."/default"} = {
      "repository" => $apertis_prefix,
      "codename" => $release."-updates",
      "component" => $component
    };
    $reprepository->{"apertis:".$release.":security:".$component."/default"} = {
      "repository" => $apertis_prefix,
      "codename" => $release."-security",
      "component" => $component
    };
  };
};

our $aptly_targets = {
  'apertis' => {
    'server' => {
      'url' => 'http://aptly:8080',
    },
    'prefix' => $apertis_prefix,
  },

  'apertis-test' => {
    'server' => {
      'url' => 'http://aptly:8080',
    },
    'prefix' => "apertis-test",
    'gpg-key' => '47E2A08116977D6D',
  },
};

our $aptly_projects = {};

foreach $release (@aptly_releases) {
  foreach $component (@apertis_components) {
    foreach my $suffix ('', '-updates', '-security') {
      $aptly_projects->{"apertis:$release$suffix:$component"} = {
        'default' => {
          'target' => 'apertis',
          'distribution' => $release . $suffix,
          'component' => $component,
        },
      };
    }
  };
};

my @apertis_releases = ("v2024");

foreach $release (@apertis_releases) {
  foreach $component (@apertis_components) {
    $aptly_projects->{"apertis:test:$release:$component"} = {
      'default' => {
        'target' => 'apertis-test',
        'distribution' => $release,
        'component' => $component,
      },
    };
  };
  $publishedhook->{"apertis:test:".$release.":.*"} = "/usr/lib/obs/server/bs_published_hook_aptly_snapshot";
};

1;
