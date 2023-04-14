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

our $aptly_config = {};

foreach $release (@aptly_releases) {
  foreach $component (@apertis_components) {
    $aptly_config->{$apertis_prefix}{$release}{"aptly_server"} = $aptly_server;
    $aptly_config->{$apertis_prefix}{$release."-updates"}{"aptly_server"} = $aptly_server;
    $aptly_config->{$apertis_prefix}{$release."-security"}{"aptly_server"} = $aptly_server;

    $aptly_config->{$apertis_prefix}{$release}{"components"}{$component} = {
      "project" => "apertis:".$release.":".$component,
      "repository" => "default",
    };
    $aptly_config->{$apertis_prefix}{$release."-updates"}{"components"}{$component} = {
      "project" => "apertis:".$release.":updates:".$component,
      "repository" => "default",
    };
    $aptly_config->{$apertis_prefix}{$release."-security"}{"components"}{$component} = {
      "project" => "apertis:".$release.":security:".$component,
      "repository" => "default",
    };
  };
};

1;
