my @reprepro_releases = ("v2022");
my @aptly_releases = ("v2023");
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

1;
