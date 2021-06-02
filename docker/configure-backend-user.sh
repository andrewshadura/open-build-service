#!/bin/sh -e

if ! getent group obsrun > /dev/null
then
    addgroup --system --gid 999 obsrun
fi

if ! getent passwd obsrun > /dev/null
then
    adduser --system --uid 999 \
        --ingroup obsrun --shell /bin/false \
        --home /usr/lib/obs --no-create-home obsrun
    usermod -c "User for build service backend" obsrun
fi

if ! getent passwd obsservicerun > /dev/null
then
    adduser --system --uid 998 \
        --ingroup obsrun --shell /bin/false \
        --home /usr/lib/obs/server --no-create-home obsservicerun
    usermod -c "User for obs source service server" obsservicerun
fi

mkdir -p /srv/obs/repos
chown obsrun:obsrun /srv/obs/repos
