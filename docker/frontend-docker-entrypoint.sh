#!/bin/sh -e

cd /obs/src/api

# Make sure there are no stale files from previous runs
rm -rfv tmp/pids/*
chown -R frontend log tmp

chmod a+rwxt /tmp

/opt/configure-app.sh
/opt/configure-db.sh
#/opt/configure-sso.py

: ${OBS_FRONTEND_WORKERS:=4}
export OBS_FRONTEND_WORKERS

exec /usr/bin/supervisord -n
