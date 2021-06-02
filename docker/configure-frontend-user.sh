#!/bin/sh -e

if ! getent group frontend > /dev/null
then
    addgroup --system --gid 999 frontend
fi

if ! getent passwd frontend > /dev/null
then
    adduser --system --uid 999 \
        --ingroup frontend --shell /bin/false \
        --home /obs --no-create-home frontend
    usermod -c "User for build service frontend" frontend
fi
