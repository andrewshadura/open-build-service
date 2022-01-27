#!/bin/sh -e

UID="${1:-999}"

if ! getent group frontend > /dev/null
then
    addgroup --system --gid $UID frontend
fi

if ! getent passwd frontend > /dev/null
then
    adduser --system --uid $UID \
        --ingroup frontend --shell /bin/false \
        --home /obs --no-create-home frontend
    usermod -c "User for build service frontend" frontend
fi
