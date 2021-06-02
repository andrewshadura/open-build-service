#!/bin/sh -e

if [ -z "$OBS_FRONTEND_HOST" ] || [ -z "$OBS_BACKEND_HOST" ]
then
    echo >&2 'You need to specify OBS_FRONTEND_HOST and OBS_BACKEND_HOST'
    exit 1
fi

if [ -d /srv/obs/run ] && [ "$(stat -c %U /srv/obs/run)" != obsrun ]
then
    echo "OBS files are owned by a wrong user $(stat -c %U /srv/obs/run), NOT re-owning!" >&2
    echo "Please fix and restart." >&2
    exit 1
fi

mkdir -p /srv/obs/log /srv/obs/run
chmod ug=rwxt /srv/obs/run
chown obsrun:obsrun /srv/obs/*

if [ ! -f /etc/obs/BSConfig.pm ]
then
    echo "OBS backend configuration not found, starting from scratch"
    cp /usr/lib/obs/server/BSConfig.pm.template /etc/obs/BSConfig.pm
fi

echo "Configure OBS backend host: $OBS_BACKEND_HOST"
sed -i "s/hostname = .*/hostname = '$OBS_BACKEND_HOST';/g" /etc/obs/BSConfig.pm

echo "Configure OBS frontend host: $OBS_FRONTEND_HOST"
sed -i "s/frontend = .*/frontend = '$OBS_FRONTEND_HOST';/g" /etc/obs/BSConfig.pm

for arch in ${OBS_ARCHES:-x86_64 i586 armv7hl aarch64}
do
    for template in /opt/services/backend/*@.conf.in
    do
        conf=$(echo $(basename $template) | sed -e "s|@|@$arch|" -e 's|.in$||')
        sed -e "s|@ARCH@|$arch|g" $template > /etc/supervisor/conf.d/$conf
    done
done

exec /usr/bin/supervisord -n
