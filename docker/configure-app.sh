#!/bin/sh -e

if [ -z "$OBS_BACKEND_HOST" ]; then
    echo >&2 'error: server backend is unavailable and hostname option is not specified '
    echo >&2 '  You need to specify OBS_BACKEND_HOST'
    exit 1
fi

for d in log tmp db/sphinx
do
    mkdir -p $d
    chown -R frontend $d
done

# Allow overriding the secret key
if [ -f /run/secrets/secretkey ]
then
    ln -sf /run/secrets/secretkey config/secret.key
fi

if [ ! -r config/secret.key ]
then
    bundle exec rake secret > config/secret.key
fi

for d in options.yml thinking_sphinx.yml
do
    [ -r config/$d ] || cp config/$d.example config/$d
done

if [ ! -z "$OBS_BACKEND_HOST" ]; then
    sed -i s/"source_host: localhost"/"source_host: ${OBS_BACKEND_HOST}"/g config/options.yml
fi

if [ ! -z "$OBS_MEMCACHE_HOST" ]
then
    sed -i "s/memcached_host: .*/memcached_host: $OBS_MEMCACHE_HOST/g" config/options.yml
fi

if [ ! -z "$OBS_LOG_LEVEL" ]
then
    sed -i "s/config.log_level = .*/config.log_level = :$OBS_LOG_LEVEL/g" config/environments/production.rb
fi

# Set up msmtp if a configuration is supplied
if [ -f /run/secrets/msmtprc ]
then
    ln -sf /run/secrets/msmtprc /etc/msmtprc
fi

# Set up SSO auth if a configuration is supplied
if [ -f /run/secrets/ssoauth ]
then
    ln -sf /run/secrets/ssoauth config/auth.yml
fi
