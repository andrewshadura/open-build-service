#!/bin/sh -e

obsrundir=/run/obs
workerdir=/var/cache/build
workerbootdir="$workerdir/boot"
obslogdir=/var/log/obs

mkdir -p "$obsrundir"

: ${OBS_REPO_SERVERS:=obs-server:5252}

repo_param=
for i in $OBS_REPO_SERVERS
do
    repo_param="$REPO_PARAM --reposerver http://$i"
    WORKER_CODE="http://$i"
done

: ${OBS_WORKER_NICE_LEVEL:=18}

OBS_WORKER_OPT="--hardstatus $repo_param ${OBS_WORKER_JOBS:+--jobs $OBS_WORKER_JOBS}\
 ${OBS_WORKER_CLEANUP_CHROOT:+--cleanup-chroot}\
 ${OBS_WORKER_WIPE_AFTER_BUILD:+--wipeafterbuild}\
 ${OBS_SRC_SERVER:+--srcserver $OBS_SRC_SERVER}\
 ${OBS_ARCH:+--arch $OBS_ARCH} ${OBS_WORKER_OPT}"

export OBS_WORKER_OPT

: ${OBS_WORKER_NAME:=$(hostname)}

export OBS_WORKER_NAME

: ${OBS_WORKER_INSTANCES:=$(nproc)}

export OBS_WORKER_INSTANCES

OBS_WORKER_PATH=/usr/lib/obs/server

update_worker() {
    echo "Fetching initial worker code from $WORKER_CODE/getworkercode"
    mkdir -p "$workerbootdir"
    cd "$workerbootdir"
    for retry in $(seq 10)
    do
        if curl --fail --silent --show-error "$WORKER_CODE/getworkercode" | cpio --extract
        then
            ln -sfn . XML
            chmod 755 bs_worker
            echo "Worker code downloaded." >&2
            ls -l
            return 0
        fi
        # we need to wait for rep server maybe
        echo "WARNING: Could not reach rep server $WORKER_CODE. Trying again." >&2
        sleep 10
    done
    echo "ERROR: Unable to reach rep server $WORKER_CODE!" >&2
    return 1
}

if [ -n "$WORKER_CODE" ]
then
    update_worker
    OBS_WORKER_PATH="$workerbootdir"
fi

export OBS_WORKER_PATH

for i in $(seq 1 $OBS_WORKER_INSTANCES)
do
    mkdir -p $workerdir/root_$i $workerdir/state_$i
done

exec nice -n "$OBS_WORKER_NICE_LEVEL" /usr/bin/supervisord -n
