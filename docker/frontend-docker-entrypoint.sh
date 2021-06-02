#!/bin/sh -e

cd /obs/src/api

# Make sure there are no stale files from previous runs
rm -rfv tmp/pids/*
chown -R frontend log tmp

/opt/configure-app.sh
/opt/configure-db.sh
#/opt/configure-sso.py

sed -i -e /web:/d Procfile
echo "web: bundle exec puma -p 3000 -w ${OBS_FRONTEND_WORKERS:-4}" >> Procfile

runuser -u frontend foreman start
