from dataclasses import dataclass
from http import HTTPStatus
from pathlib import Path
from typing import ClassVar, Iterator, Literal, Protocol
from xml.etree import ElementTree as ET

import argparse
import difflib
import dataclasses
import enum
import hashlib
import itertools
import logging
import os
import posixpath
import stat
import subprocess
import sys
import tempfile
import textwrap
import time
import urllib.error
import urllib.parse

from debian.deb822 import Packages, Sources
from ruamel.yaml import YAML

import pydantic
import requests

try:
    import hvac
except ImportError:
    HAVE_HVAC = False
else:
    HAVE_HVAC = True

try:
    import osc.conf as oscconf
except ImportError:
    HAVE_OSC = False
else:
    HAVE_OSC = True


APTLY_TESTS_DIR = Path(__file__).parent


OBS_REPO = 'default'
OBS_ARCH = os.uname().machine
assert OBS_ARCH in ('x86_64', 'aarch64')

DEBIAN_ARCH = {'x86_64': 'amd64', 'aarch64': 'arm64'}[OBS_ARCH]


APERTIS_URL = 'https://repositories.apertis.org/apertis'
APERTIS_DIST = 'v2024'

APTLY_PREFIX = 'apertis-test'

# We add a .9999 so all versions of the test package are newer than those in
# the upstream repo.
APERTIS_TEST_RELEASE_BASE = f'{APERTIS_DIST}.9999'
# Also add the current timestamp to the release so that no filename conflicts
# will occur if the aptly pool isn't cleaned across test runs. This is in a
# separate variable so that, when we test the packages installed are those we
# built by checking their version, we can exclude the timestamp, which allows
# the tests to accept packages built on a previous test run when running with
# --skip-clean-rebuild.
APERTIS_TEST_RELEASE = f'{APERTIS_TEST_RELEASE_BASE}.{int(time.time())}'

APERTIS_REGISTRY = 'registry.gitlab.apertis.org/infrastructure/apertis-docker-images'


class BilateralUrl(pydantic.BaseModel):
    from_docker: str
    from_host: str

    @staticmethod
    def from_str(s: str) -> 'BilateralUrl':
        return BilateralUrl(from_docker=s, from_host=s)

    class Config:
        extra = pydantic.Extra.forbid


class AptlyVaultTokenConfig(pydantic.BaseModel):
    from_: Literal['vault'] = pydantic.Field(alias='from')
    url: str
    mount: str
    path: str

    class Config:
        extra = pydantic.Extra.forbid


class AptlyApiConfig(pydantic.BaseModel):
    url: str
    token: AptlyVaultTokenConfig | None = None

    class Config:
        extra = pydantic.Extra.forbid


class AptlyContentConfig(pydantic.BaseModel):
    url: BilateralUrl

    @pydantic.validator('url', pre=True)
    def validate_url(cls, v):
        if isinstance(v, str):
            return BilateralUrl.from_str(v)
        return v

    class Config:
        extra = pydantic.Extra.forbid


class AptlyConfig(pydantic.BaseModel):
    api: AptlyApiConfig
    content: AptlyContentConfig
    gpg_key: str

    class Config:
        extra = pydantic.Extra.forbid


class ObsCredentials(enum.Enum):
    DEFAULT = 'default'
    OSCRC = 'oscrc'


class ObsConfig(pydantic.BaseModel):
    url: str
    credentials: ObsCredentials = ObsCredentials.DEFAULT

    class Config:
        extra = pydantic.Extra.forbid


class TestConfig(pydantic.BaseModel):
    instance: ClassVar['TestConfig']

    aptly: AptlyConfig
    obs: ObsConfig

    class Config:
        extra = pydantic.Extra.forbid


@dataclass
class MultiSegment:
    part: str


def build_url(
    base: str,
    *parts: str | MultiSegment,
    query: dict[str, str] | None = None,
) -> str:
    url = posixpath.join(
        base,
        *(
            urllib.parse.quote(p.part)
            if isinstance(p, MultiSegment)
            else urllib.parse.quote(p, safe='')
            for p in parts
        ),
    )

    if query:
        url += '?' + urllib.parse.urlencode(query)

    return url


def diff_sets(expected: set | frozenset, actual: set | frozenset) -> str:
    def lineify(x: str) -> str:
        return str(x) + '\n'

    return '\n' + ''.join(
        difflib.unified_diff(
            sorted(map(lineify, expected)),
            sorted(map(lineify, actual)),
            fromfile='expected',
            tofile='actual',
        )
    )


class ProjectKind(enum.Enum):
    DOD = enum.auto()
    TEST = enum.auto()

    def __str__(self) -> str:
        return self.name.lower()


class Component(enum.Enum):
    TARGET = enum.auto()
    DEVELOPMENT = enum.auto()
    SDK = enum.auto()

    def __str__(self) -> str:
        return self.name.lower()

    @property
    def build_depends(self) -> Iterator['Component']:
        yield from (Component.TARGET, Component.DEVELOPMENT)
        if self == Component.SDK:
            yield Component.SDK


@dataclass
class Project:
    kind: ProjectKind
    component: Component

    def __str__(self) -> str:
        return f'apertis:{self.kind}:{APERTIS_DIST}:{self.component}'

    @property
    def aptly_repo(self) -> str:
        assert self.kind == ProjectKind.TEST
        return f'{self}/{OBS_REPO}'


@dataclass(frozen=True)
class TestPackage:
    name: str
    component: Component
    outputs: frozenset[str]

    @property
    def project(self) -> Project:
        return Project(ProjectKind.TEST, self.component)

    def __str__(self) -> str:
        return f'{self.project}/{self.component}/{self.name}'


TEST_PACKAGES = [
    TestPackage(
        'aalib',
        Component.TARGET,
        frozenset(
            {
                'libaa-bin',
                'libaa-bin-dbgsym',
                'libaa1',
                'libaa1-dbgsym',
                'libaa1-dev',
            }
        ),
    ),
    TestPackage(
        'pkgconf',
        Component.DEVELOPMENT,
        frozenset(
            {
                'libpkgconf-dev',
                'libpkgconf3',
                'libpkgconf3-dbgsym',
                'pkg-config',
                'pkgconf',
                'pkgconf-bin',
                'pkgconf-bin-dbgsym',
            }
        ),
    ),
    TestPackage(
        'espeak-ng',
        Component.SDK,
        frozenset(
            {
                'espeak-ng',
                'espeak-ng-data',
                'espeak-ng-dbgsym',
                'espeak-ng-espeak',
                'libespeak-ng-dev',
                'libespeak-ng-libespeak1',
                'libespeak-ng-libespeak-dev',
                'libespeak-ng1',
                'libespeak-ng1-dbgsym',
            }
        ),
    ),
]


@dataclass
class DebianRepoDist:
    base_url: str
    dist: str

    @property
    def full_url(self) -> str:
        return build_url(self.base_url, 'dists', MultiSegment(self.dist))

    def __str__(self) -> str:
        return f'{self.base_url} {self.dist}'


@dataclass
class RemoteFile:
    name: str
    url: str
    md5: str
    sha256: str

    @staticmethod
    def from_source_paragraph(
        paragraph: Sources, *, base_url: str
    ) -> list['RemoteFile']:
        directory = build_url(base_url, MultiSegment(paragraph['directory']))
        files_md5 = {file['name']: file['md5sum'] for file in paragraph['files']}
        files_sha256 = {
            file['name']: file['sha256'] for file in paragraph['checksums-sha256']
        }
        assert set(files_md5.keys()) == set(files_sha256.keys())
        return [
            RemoteFile(
                name=filename,
                url=build_url(directory, filename),
                md5=md5,
                sha256=files_sha256[filename],
            )
            for filename, md5 in files_md5.items()
        ]

    @staticmethod
    def from_package_paragraph(paragraph: Packages, *, base_url: str) -> 'RemoteFile':
        filename = paragraph['filename']
        return RemoteFile(
            name=posixpath.basename(filename),
            url=build_url(base_url, MultiSegment(filename)),
            md5=paragraph['MD5Sum'],
            sha256=paragraph['SHA256'],
        )

    def download(self) -> bytes:
        response = requests.get(self.url)
        response.raise_for_status()

        actual_hash = hashlib.sha256(response.content).hexdigest()
        if actual_hash != self.sha256:
            raise ValueError(
                f'Expected {self.url} sha256 to be {self.sha256}, not {actual_hash}'
            )

        return response.content


@dataclass
class MissingPackage(Exception):
    package: TestPackage
    url: str

    def __str__(self) -> str:
        return f'Failed to find package {self.package.name} in {self.url}'


def get_remote_source_files(
    package: TestPackage,
    dist: DebianRepoDist,
) -> list[RemoteFile]:
    logging.info(f'finding source files for {package.name} @ {dist}')

    sources_url = build_url(
        dist.full_url,
        str(package.component),
        'source',
        'Sources',
    )
    sources = requests.get(sources_url)
    sources.raise_for_status()

    for paragraph in Sources.iter_paragraphs(sources.content, use_apt_pkg=False):
        if paragraph['package'] == package.name:
            return RemoteFile.from_source_paragraph(paragraph, base_url=dist.base_url)

    raise MissingPackage(package, sources_url)


def get_remote_binary_files_by_package(
    package: TestPackage,
    dist: DebianRepoDist,
) -> dict[str, RemoteFile]:
    logging.info(f'finding binary files for {package.name} @ {dist}')

    packages_url = build_url(
        dist.full_url,
        str(package.component),
        f'binary-{DEBIAN_ARCH}',
        'Packages',
    )
    packages = requests.get(packages_url)
    packages.raise_for_status()

    files: dict[str, RemoteFile] = {}
    for paragraph in Packages.iter_paragraphs(packages.content, use_apt_pkg=False):
        if paragraph.source == package.name:
            files[paragraph['package']] = RemoteFile.from_package_paragraph(
                paragraph, base_url=dist.base_url
            )

    if not files:
        raise MissingPackage(package, packages_url)

    return files


def get_aptly_token(token_config: AptlyVaultTokenConfig) -> str:
    if not HAVE_HVAC:
        raise ValueError('hvac is not installed, cannot access Vault')

    if (vault_token := os.environ.get('VAULT_TOKEN')) is None:
        raise ValueError('VAULT_TOKEN must be set to connect to Vault')

    client = hvac.Client(url=token_config.url, token=vault_token)
    resp = client.secrets.kv.v2.read_secret(
        mount_point=token_config.mount,
        path=token_config.path,
    )

    return resp['data']['data']['token']


class AptlyPublish(pydantic.BaseModel):
    prefix: str
    distribution: str
    source_kind: str

    class Config:
        alias_generator = lambda k: ''.join(w.capitalize() for w in k.split('_'))


class AptlyApi:
    instance: ClassVar['AptlyApi']

    def __init__(self, api_url: str, api_token: str | None) -> None:
        self.api_url = api_url
        self.session = requests.Session()

        if api_token is not None:
            self.session.headers.update({'Authorization': f'Bearer {api_token}'})

    @staticmethod
    def from_config() -> 'AptlyApi':
        aptly_config = TestConfig.instance.aptly.api
        token: str | None = None
        if aptly_config.token is not None:
            token = get_aptly_token(aptly_config.token)

        return AptlyApi(aptly_config.url, token)

    def _get_api_path(self, *parts: str) -> str:
        return build_url(self.api_url, 'api', *parts)

    def check_repo_exists(self, repo: str) -> None:
        response = self.session.get(self._get_api_path('repos', repo))
        response.raise_for_status()

    def list_publishes(self) -> list[AptlyPublish]:
        response = self.session.get(self._get_api_path('publish'))
        response.raise_for_status()
        return pydantic.parse_obj_as(list[AptlyPublish], response.json())

    def delete_publish(self, prefix: str, dist: str) -> None:
        response = self.session.delete(self._get_api_path('publish', prefix, dist))
        response.raise_for_status()


def delete_aptly_publishes(prefix: str = APTLY_PREFIX) -> None:
    logging.info(f'deleting aptly publish points in prefix {prefix}')

    publishes = AptlyApi.instance.list_publishes()
    for publish in publishes:
        if publish.prefix == prefix:
            logging.info(f'deleting {prefix}/{publish.distribution}')
            AptlyApi.instance.delete_publish(prefix, publish.distribution)


class ObsApi:
    instance: ClassVar['ObsApi']

    def __init__(self, api_url: str, *, username: str, password: str) -> None:
        self.api_url = api_url
        self.session = requests.Session()
        self.session.auth = requests.auth.HTTPBasicAuth(username, password)
        self.session.headers['Accept'] = 'application/xml'

    @staticmethod
    def from_config() -> 'ObsApi':
        obs_config = TestConfig.instance.obs
        match obs_config.credentials:
            case ObsCredentials.DEFAULT:
                username = 'Admin'
                password = 'opensuse'
            case ObsCredentials.OSCRC:
                if not HAVE_OSC:
                    raise ValueError('osc is not installed, cannot use oscrc')

                oscconf.get_config()
                host_options = oscconf.get_apiurl_api_host_options(obs_config.url)
                username = host_options.get('user') or oscconf.config['user']
                # This might be an instance of osc.conf.Password which is a UserString
                # instance that lazily retrieves the password. That's all a bit
                # confusing for our use case, so just force the inner value out early.
                password = str(host_options['pass'])

        return ObsApi(obs_config.url, username=username, password=password)

    def get_server_configuration(self) -> bytes:
        response = self.session.get(build_url(self.api_url, 'configuration'))
        response.raise_for_status()
        return response.content

    def delete_project(self, project: str) -> None:
        response = self.session.delete(build_url(self.api_url, 'source', project))
        response.raise_for_status()

    def edit_project_meta(self, project: str, meta: str) -> None:
        response = self.session.put(
            build_url(self.api_url, 'source', project, '_meta'),
            data=meta,
        )
        response.raise_for_status()

    def edit_project_config(self, project: str, config: str) -> None:
        response = self.session.put(
            build_url(self.api_url, 'source', project, '_config'),
            data=config,
        )
        response.raise_for_status()

    def project_build_results(self, project: str, *, package: str) -> str:
        response = self.session.get(
            build_url(
                self.api_url,
                'build',
                project,
                '_result',
                query={'package': package},
            )
        )
        response.raise_for_status()
        return response.text

    def edit_package_meta(self, project: str, package: str, meta: str) -> None:
        response = self.session.put(
            build_url(self.api_url, 'source', project, package, '_meta'),
            data=meta,
        )
        response.raise_for_status()

    def upload_for_commit(
        self,
        project: str,
        package: str,
        *,
        name: str,
        data: bytes,
    ) -> None:
        response = self.session.put(
            build_url(
                self.api_url,
                'source',
                project,
                package,
                name,
                query={'rev': 'repository'},
            ),
            data=data,
        )
        response.raise_for_status()

    def commit_filelist(
        self,
        project: str,
        package: str,
        *,
        filelist: str,
        comment: str,
    ) -> str:
        response = self.session.post(
            build_url(
                self.api_url,
                'source',
                project,
                package,
                query={'cmd': 'commitfilelist', 'comment': comment},
            ),
            data=filelist,
        )
        response.raise_for_status()
        return response.text


# Note that this is, at best, a guess; OBS is filled with race conditions when it comes
# to parsing the configuration sent by the frontend doing setup tasks that depend on
# said configuration.
def check_dod_configuration() -> None:
    logging.info('checking server DoD configuration')

    config_xml = ObsApi.instance.get_server_configuration()
    logging.debug(f'{config_xml=!s}')

    config_el = ET.fromstring(config_xml)
    dod_el = config_el.find('download_on_demand')
    if dod_el is None or dod_el.text != 'on':
        raise ValueError('download_on_demand is not enabled')


def delete_project_if_exists(project: Project) -> None:
    logging.info(f'deleting project: {project}')
    try:
        ObsApi.instance.delete_project(str(project))
    except requests.HTTPError as ex:
        if ex.response.status_code == HTTPStatus.NOT_FOUND:
            logging.debug(f'{project} did not exist')
        else:
            raise


@dataclass
class ProjectDownload:
    url: str
    dist: str
    component: Component


def create_project(
    project: Project,
    *,
    download: ProjectDownload | None = None,
    dep_projects: list[Project] = [],
) -> None:
    logging.info(f'creating project: {project}')

    project_el = ET.Element('project', {'name': str(project)})
    repository_el = ET.SubElement(
        project_el,
        'repository',
        name=OBS_REPO,
        rebuild='local',
        block='never',
    )

    ET.SubElement(repository_el, 'arch').text = OBS_ARCH

    if download is not None:
        ET.SubElement(
            repository_el,
            'download',
            arch=OBS_ARCH,
            url=posixpath.join(download.url, download.dist, str(download.component)),
            repotype='deb',
        )

    for dep in dep_projects:
        ET.SubElement(
            repository_el,
            'path',
            {
                'project': str(dep),
                'repository': OBS_REPO,
            },
        )

    ET.indent(project_el)
    meta = ET.tostring(project_el).decode()

    logging.debug(f'{meta=!s}')
    ObsApi.instance.edit_project_meta(str(project), meta)

    if project.kind == ProjectKind.TEST:
        logging.info(f'checking for aptly repo: {project.aptly_repo}')
        AptlyApi.instance.check_repo_exists(project.aptly_repo)

    match project.kind:
        case ProjectKind.DOD:
            prjconf_filename = 'apertis-dod.conf'
            prjconf_header = ''
        case ProjectKind.TEST:
            prjconf_filename = 'apertis-test.tmpl.conf'
            prjconf_header = f'%define APERTIS_TEST_RELEASE {APERTIS_TEST_RELEASE}'

    with (APTLY_TESTS_DIR / prjconf_filename).open() as fp:
        prjconf = fp.read()

    if prjconf_header:
        prjconf = prjconf_header + '\n' + prjconf

    ObsApi.instance.edit_project_config(str(project), prjconf)


def create_package(package: TestPackage) -> None:
    logging.info(f'creating package: {package}')

    package_el = ET.Element('package', name=package.name, project=str(package.project))

    ET.indent(package_el)
    meta = ET.tostring(package_el).decode()

    logging.debug(f'{meta=}')
    ObsApi.instance.edit_package_meta(str(package.project), package.name, meta)


def copy_package_to_project(package: TestPackage, files: list[RemoteFile]) -> None:
    files_by_name = {file.name: file for file in files}

    filelist_el = ET.Element('directory')
    for file in files_by_name.values():
        ET.SubElement(
            filelist_el,
            'entry',
            name=file.name,
            md5=file.md5,
            hash=f'sha256:{file.sha256}',
        )

    ET.indent(filelist_el)
    filelist = ET.tostring(filelist_el).decode()
    logging.debug(f'{filelist=!s}')

    missing: set[str] = set()
    for i in range(2):
        if missing:
            logging.info(f'uploading {len(missing)} missing file(s)')
            for name in missing:
                file = files_by_name[name]
                content = file.download()

                ObsApi.instance.upload_for_commit(
                    str(package.project),
                    package.name,
                    name=name,
                    data=content,
                )

        logging.info(f'committing {package} (attempt #{i + 1})')
        commit_result = ObsApi.instance.commit_filelist(
            str(package.project),
            package.name,
            filelist=filelist,
            comment='imported package',
        )
        logging.debug(f'{commit_result=!s}')

        commit_result_el = ET.fromstring(commit_result)
        if (error := commit_result_el.attrib.get('error')) is not None:
            assert error == 'missing', commit_result
            missing = {e.attrib['name'] for e in commit_result_el}
        else:
            break
    else:
        raise ValueError(f'Failed to upload file(s) ({len(missing)} still missing)')


class PackageStatusPoller:
    _FINAL_STATUS_CODES = {'broken', 'disabled', 'excluded', 'failed', 'succeeded'}

    def __init__(self, package: TestPackage):
        self._package = package

        self._last_code: str | None = None
        self._last_details: str | None = None

    def update(self) -> bool:
        logging.debug(f'retrieving current status of {self._package}')

        meta = ObsApi.instance.project_build_results(
            str(self._package.project), package=self._package.name
        )
        logging.debug(f'{meta=!s}')
        meta_el = ET.fromstring(meta)
        if (status_el := meta_el.find('.//status')) is None:
            return False
        if (code := status_el.attrib.get('code')) is None:
            raise ValueError(f'meta has missing or invalid status element: {meta}')

        details_el = status_el.find('details')
        details = details_el.text if details_el is not None else None
        if self._last_code != code or self._last_details != details:
            status = self._format_status(code=code, details=details)
            logging.info(f'{self._package}: {status}')

            self._last_code = code
            self._last_details = details

            return True

        return False

    def _format_status(self, *, code: str, details: str | None) -> str:
        return f'{code}: {details}' if details is not None else code

    def format_last_status(self) -> str:
        return self._format_status(
            code=self._last_code or '<unknown>',
            details=self._last_details,
        )

    @property
    def done(self) -> bool:
        return self._last_code in self._FINAL_STATUS_CODES

    @property
    def succeeded(self) -> bool:
        return self._last_code == 'succeeded'

    @property
    def package(self) -> TestPackage:
        return self._package


def wait_for_packages(packages: list[TestPackage]) -> None:
    # 5 seconds * 240 tries = 20 minutes.
    DELAY_SECONDS = 5
    RETRY_COUNT = 240

    retry_counter = itertools.count()

    logging.info(f'watching packages: {", ".join(map(str, packages))}')
    pollers = [PackageStatusPoller(pkg) for pkg in packages]
    while True:
        retry = next(retry_counter)
        if not pollers or retry >= RETRY_COUNT:
            break

        time.sleep(DELAY_SECONDS)

        for poller in pollers[:]:
            if poller.update():
                # Reset the retry counter whenever something actually changed.
                retry_counter = itertools.count()

            if poller.done:
                if not poller.succeeded:
                    raise ValueError(
                        f'Build failed: {poller.package}: {poller.format_last_status()}'
                    )

                pollers.remove(poller)

    if pollers:
        raise ValueError(
            'Package(s) never finished building:\n'
            + '\n'.join(
                f'  - {poller.package}: {poller.format_last_status()}'
                for poller in pollers
            )
        )


def clean_rebuild(package_files: dict[TestPackage, list[RemoteFile]]) -> None:
    components = {package.component for package in package_files}

    delete_aptly_publishes()

    # We intentionally avoid deleting the DoD projects, because recreating those seems
    # to break the DoD's ability to download altogether without a backend restart.
    for component in components:
        delete_project_if_exists(Project(ProjectKind.TEST, component))

    logging.info('creating DoD projects')
    for component in components:
        create_project(
            Project(ProjectKind.DOD, component),
            download=ProjectDownload(
                url=APERTIS_URL,
                dist=APERTIS_DIST,
                component=component,
            ),
        )

    logging.info('creating test projects')
    for i, component in enumerate(components):
        # There's a nasty race condition inside our aptly integration where OBS might
        # create the aptly prefix before all the OBS projects have been created, which
        # results in the prefix missing components. As a workaround, we always start
        # out by deleting the prefix, ensuring it gets recreated every time and that
        # the final one will have the full component list.
        if i > 0:
            logging.info('deleting previous aptly publish prefix')
            AptlyApi.instance.delete_publish(APTLY_PREFIX, APERTIS_DIST)

        create_project(
            Project(ProjectKind.TEST, component),
            dep_projects=[
                Project(ProjectKind.DOD, dep_component)
                for dep_component in component.build_depends
            ],
        )

    for package in TEST_PACKAGES:
        create_package(package)
        copy_package_to_project(package, package_files[package])

    wait_for_packages(TEST_PACKAGES)


CHECK_PUBLISHED_RETRIES = 5
CHECK_PUBLISHED_DELAY_SECONDS = 1


def check_published_package_sources(
    package: TestPackage,
    original_files: list[RemoteFile],
    *,
    result_dist: DebianRepoDist,
) -> None:
    for i in itertools.count():
        try:
            result_files = get_remote_source_files(package, result_dist)
        except MissingPackage:
            if i >= CHECK_PUBLISHED_RETRIES:
                raise

            logging.info(
                f'package missing, retrying in {CHECK_PUBLISHED_DELAY_SECONDS}s...'
            )
            time.sleep(CHECK_PUBLISHED_DELAY_SECONDS)
        else:
            break

    logging.info(f'checking sources: {package}')
    original_info = {(file.name, file.md5, file.sha256) for file in original_files}
    result_info = {(file.name, file.md5, file.sha256) for file in result_files}
    assert original_info == result_info, diff_sets(original_info, result_info)

    for file in result_files:
        logging.info(f'- {file.name}')
        file.download()


def check_published_package_outputs(
    package: TestPackage,
    *,
    result_dist: DebianRepoDist,
) -> None:
    for i in itertools.count():
        try:
            result_files = get_remote_binary_files_by_package(package, result_dist)
        except MissingPackage:
            if i >= CHECK_PUBLISHED_RETRIES:
                raise

            logging.info(
                f'package missing, retrying in {CHECK_PUBLISHED_DELAY_SECONDS}s...'
            )
            time.sleep(CHECK_PUBLISHED_DELAY_SECONDS)
        else:
            break

    logging.info(f'checking outputs: {package}')
    result_outputs = set(result_files)
    assert package.outputs == result_outputs, diff_sets(package.outputs, result_outputs)

    for file in result_files.values():
        logging.info(f'- {file.name}')
        file.download()


def check_published_package(
    package: TestPackage,
    *,
    original_source_files: list[RemoteFile],
    result_dist: DebianRepoDist,
) -> None:
    check_published_package_sources(
        package,
        original_source_files,
        result_dist=result_dist,
    )
    check_published_package_outputs(package, result_dist=result_dist)


def install_packages_into_container(
    packages: list[TestPackage],
    dist: DebianRepoDist,
    *,
    gpg_key: str,
) -> None:
    LIST_MOUNT = '/etc/apt/sources.list.d/test.list'
    KEY_MOUNT = '/run/host/test.gpg'

    SCRIPT = textwrap.dedent(
        """
        set -ex
        (
            # Handy info for debugging.
            cat /etc/apt/sources.list.d/test.list
            apt-get update
            apt-get install -y $PACKAGES
        ) >&2
        dpkg -s $PACKAGES
        """.lstrip('\n')
    )

    components = {package.component for package in packages}
    all_outputs = {out for p in packages for out in p.outputs}

    with tempfile.NamedTemporaryFile(
        'w'
    ) as apt_list, tempfile.NamedTemporaryFile() as key:
        # These needs to be readable from within the container as the non-root
        # user. (The contents aren't exactly sensitive, so being world-readable
        # doesn't matter.)
        for fd in apt_list.fileno(), key.fileno():
            os.fchmod(
                fd,
                # r--r--r--
                stat.S_IRUSR | stat.S_IRGRP | stat.S_IROTH,
            )

        for component in sorted(components, key=lambda c: c.name):
            for source_type in 'deb', 'deb-src':
                print(
                    ' '.join(
                        (
                            source_type,
                            f'[signed-by={KEY_MOUNT}]',
                            dist.base_url,
                            dist.dist,
                            component.name.lower(),
                        )
                    ),
                    file=apt_list,
                )

        apt_list.flush()

        subprocess.run(
            ['gpg', '--dearmor'],
            check=True,
            stdout=key,
            input=gpg_key.encode(),
        )

        result = subprocess.run(
            [
                'docker',
                'run',
                '--rm',
                '-i',
                '--net=host',
                f'--volume={apt_list.name}:{LIST_MOUNT}:ro,z',
                f'--volume={key.name}:{KEY_MOUNT}:ro,z',
                f'--env=PACKAGES={" ".join(all_outputs)}',
                f'{APERTIS_REGISTRY}/{APERTIS_DIST}-base',
                'sh',
                '-c',
                SCRIPT,
            ],
            check=True,
            stdout=subprocess.PIPE,
            stderr=sys.stderr,
            text=True,
        )

    logging.debug(result.stdout)

    missing_packages = all_outputs.copy()
    for paragraph in Packages.iter_paragraphs(result.stdout, use_apt_pkg=False):
        assert APERTIS_TEST_RELEASE_BASE in paragraph['version'], paragraph.dump()
        missing_packages.remove(paragraph['package'])

    assert not missing_packages, missing_packages


def check_published_repository(
    package_files: dict[TestPackage, list[RemoteFile]],
    *,
    snapshot: bool,
) -> None:
    result_dist = DebianRepoDist(
        base_url=build_url(
            TestConfig.instance.aptly.content.url.from_host,
            APTLY_PREFIX,
        ),
        dist=APERTIS_DIST,
    )
    if snapshot:
        snapshot_publishes = [
            p for p in AptlyApi.instance.list_publishes() if p.source_kind == 'snapshot'
        ]
        assert snapshot_publishes, 'No published snapshots'

        latest_snapshot = max(snapshot_publishes, key=lambda p: p.distribution)
        result_dist = dataclasses.replace(
            result_dist,
            dist=latest_snapshot.distribution,
        )

    for package, files in package_files.items():
        check_published_package(
            package,
            original_source_files=files,
            result_dist=result_dist,
        )

    install_packages_into_container(
        TEST_PACKAGES,
        dataclasses.replace(
            result_dist,
            base_url=build_url(
                TestConfig.instance.aptly.content.url.from_docker,
                APTLY_PREFIX,
            ),
        ),
        gpg_key=TestConfig.instance.aptly.gpg_key,
    )


class Args(Protocol):
    config: Path
    verbose: bool
    skip_clean_rebuild: bool
    only_components: list[str]


def main() -> None:
    parser = argparse.ArgumentParser()

    parser.add_argument(
        '--config',
        help='Path to the testing configuration file',
        type=Path,
        default=APTLY_TESTS_DIR / 'configs' / 'local.yaml',
    )
    parser.add_argument(
        '--verbose',
        '-v',
        help='Enable verbose logging',
        action='store_true',
        default=False,
    )
    parser.add_argument(
        '--skip-clean-rebuild',
        help='Skip deleting the projects and rebuilding the packages',
        action='store_true',
        default=False,
    )
    parser.add_argument(
        '--only-component',
        help='Only test the given components',
        dest='only_components',
        action='append',
        default=[],
    )

    args: Args = parser.parse_args()

    if args.verbose:
        logging.basicConfig(
            format='%(asctime)s %(levelname)s %(name)s: %(message)s',
            level=logging.DEBUG,
        )
    else:
        logging.basicConfig(
            format='%(asctime)s %(levelname)s: %(message)s',
            level=logging.INFO,
        )

    components = (
        {Component[c] for c in args.only_components}
        if args.only_components
        else set(Component)
    )

    with args.config.open() as fp:
        config_data = YAML(typ='safe').load(fp)
        TestConfig.instance = TestConfig(**config_data)

    AptlyApi.instance = AptlyApi.from_config()
    ObsApi.instance = ObsApi.from_config()

    check_dod_configuration()

    package_files: dict[TestPackage, list[RemoteFile]] = {}
    dod_dist = DebianRepoDist(base_url=APERTIS_URL, dist=APERTIS_DIST)
    for package in TEST_PACKAGES:
        if package.component in components:
            package_files[package] = get_remote_source_files(package, dod_dist)

    if not args.skip_clean_rebuild:
        clean_rebuild(package_files)

    for check_snapshot in False, True:
        check_published_repository(package_files, snapshot=check_snapshot)


if __name__ == '__main__':
    main()
