#!/bin/bash

# TODO: test docker images before push

function die {
    echo "$0: die - $*" >&2
    exit 1
}

function check_build {
    SRC_GO=$1; shift

    [ ! -f $SRC_GO ] && die "No such src file <$SRC_GO>"

    echo; echo "---- Building binary ----------"
    [ -f demo-binary ] && rm -f demo-binary ]
    CGO_ENABLED=0 go build -a -o demo-binary $SRC_GO
    [ ! -x demo-binary ] && die "Failed to build binary"
    ls -alh demo-binary

    echo; echo "---- Testing  binary ----------"
    LISTEN=127.0.0.1:8080
    ./demo-binary --listen $LISTEN &
    [ $? -ne 0 ] && die "Failed to launch binary"
    PID=$!
    [ -z "$PID" ] && die "Failed to get PID"
    ps -fade | grep $PID

    curl -sL $LISTEN/1 || {
        kill -9 $PID
        die "Failed to contact demo-binary on <$LISTEN>"
    }
    kill -9 $PID
    echo "---- binary OK ----------------"
}

# Properly cached 2stage_build:
#   See https://pythonspeed.com/articles/faster-multi-stage-builds/
function build {
    IMAGE_TAG=$1; shift
    FROM_IMAGE=$1; shift
    EXPOSE_PORT=$1; shift
    TEMPLATE_CMD="$*"; set --

    [ "$TEMPLATE_CMD" = "CMD" ] && die "build: Missing command in <$TEMPLATE_CMD>"
    write_dockerfile $IMAGE_TAG $FROM_IMAGE $EXPOSE_PORT "$TEMPLATE_CMD"

    case "$FROM_IMAGE" in
        "scratch") STAGE1_IMAGE="mjbright/demo-static-binary";;
        "alpine")  STAGE1_IMAGE="mjbright/demo-dynamic-binary";;

        *)  die "Unknown FROM_IMAGE type <$FROM_IMAGE>";;
    esac

    #set -euo pipefail

    # Pull the latest version of the image, in order to populate the build cache:
    TIME docker pull $STAGE1_IMAGE || true
    TIME docker pull $IMAGE_TAG    || true

    # Build the compile stage:
    TIME docker build --target build-env     --cache-from=$STAGE1_IMAGE --tag $STAGE1_IMAGE .

    # Build the runtime stage, using cached compile stage:
    TIME docker build --target runtime-image --cache-from=$STAGE1_IMAGE \
                     --cache-from=$IMAGE_TAG --tag $IMAGE_TAG .
    echo "CMD=<$TEMPLATE_CMD>"
    [ "$TEMPLATE_CMD" = "CMD" ] && die "Missing command in <$TEMPLATE_CMD>"

    docker run -d --name BUILD_TEST -p 8181:$EXPOSE_PORT $IMAGE_TAG
    CONTAINERID=$(docker ps -ql)
    curl -sL 127.0.0.1:8181/1 ||
        die "Failed to interrogate container <$CONTAINERID> 'BUILD_TEST' from image <$IMAGE_TAG>"
    docker stop $CONTAINERID
    docker rm $CONTAINERID

    # Push the new versions:
    TIME docker push $STAGE1_IMAGE
    TIME docker push $IMAGE_TAG
}

function write_dockerfile {
    IMAGE_TAG=$1; shift
    FROM_IMAGE=$1; shift
    EXPOSE_PORT=$1; shift
    TEMPLATE_CMD="$*"; set --

    #echo "EXPOSE_PORT=$EXPOSE_PORT"
    [ "$TEMPLATE_CMD" = "CMD" ] && die "write_dockerfile: Missing command in <$TEMPLATE_CMD>"

    STATIC_STAGE1_BUILD="CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -a -ldflags '-w' -o demo-binary *.go"
    DYNAMIC_STAGE1_BUILD="CGO_ENABLED=0 go build -a -o demo-binary"

    case "$FROM_IMAGE" in
        "scratch") STAGE1_BUILD=$STATIC_STAGE1_BUILD;;
        "alpine")  STAGE1_BUILD=$DYNAMIC_STAGE1_BUILD;;
        *)  die "Unknown FROM_IMAGE type <$FROM_IMAGE>";;
    esac

    sed  < Dockerfile.tmpl > Dockerfile \
        -e "s/__FROM_IMAGE__/$FROM_IMAGE/" \
        -e "s/__EXPOSE_PORT__/$EXPOSE_PORT/" \
        -e "s/__STAGE1_BUILD__/$STAGE1_BUILD/" \
        -e "s?__TEMPLATE_CMD__?/$TEMPLATE_CMD?" \

    grep __ Dockerfile && die "Uninstantiated variables in Dockerfile"
    mkdir -p tmp

    DFID=$(echo $IMAGE_TAG | sed -e 's/\//_/g')
    cp -a Dockerfile tmp/Dockerfile.${DFID}
}

function basic_2stage_build {
    IMAGE_TAG=$1; shift
    FROM_IMAGE=$1; shift
    EXPOSE_PORT=$1; shift
    TEMPLATE_CMD="$*"; set --

    write_dockerfile $IMAGE_TAG $FROM_IMAGE $EXPOSE_PORT "$TEMPLATE_CMD"
    docker build -t $IMAGE_TAG .
}

function push {
    IMAGE_TAG=$1; shift
    FROM_IMAGE=$1; shift

    docker push $IMAGE_TAG 
}

function build_and_push {
    #IMAGE_TAG=$1; shift
    #build $IMAGE_TAG
    #push $IMAGE_TAG

    #[ "$TEMPLATE_CMD" = "CMD" ] && die "build: Missing command in <$TEMPLATE_CMD>"
    echo $4
    build $*
    push  $*
}

# START: TIMER FUNCTIONS ================================================

function TIMER_START { START_S=`date +%s`; }

function TIMER_STOP {
    END_S=`date +%s`
    let TOOK=END_S-START_S

    TIMER_hhmmss $TOOK
    return 0
}

function TIME {
    CMD=$*

    echo "---- $CMD"
    TIMER_START
    $CMD
    TIMER_STOP
    echo "Took $TOOK secs [${HRS}h${MINS}m${SECS}]"
    return 0
}

function TIMER_hhmmss {
    _REM_SECS=$1; shift
    let SECS=_REM_SECS%60
    let _REM_SECS=_REM_SECS-SECS
    let MINS=_REM_SECS/60%60
    let _REM_SECS=_REM_SECS-60*MINS
    let HRS=_REM_SECS/3600

    [ $SECS -lt 10 ] && SECS="0$SECS"
    [ $MINS -lt 10 ] && MINS="0$MINS"
    return 0
}

# END: TIMER FUNCTIONS ================================================

check_build main.go

# Incremental builds:

docker login

TIMER_START; START0_S=$START_S

REPO_NAMES="ckad-demo k8s-demo docker-demo"
TAGS=$(seq 6)

for REPO_NAME in $REPO_NAMES; do
    echo; echo "---- Building images <$REPO_NAME> --------"
    for TAG in $TAGS; do
        REPO="mjbright/$REPO_NAME"
        PORT=80

        IMAGE="${REPO}:${TAG}"
	#CMD="/app/demo-binary --listen :$PORT -l 10 -r 10 -i $IMAGE"
	CMD="['/app/demo-binary','--listen',':$PORT','-l','10','-r','10','-i','$IMAGE']"
        build_and_push $IMAGE scratch $PORT $CMD

        IMAGE="${REPO}:alpine${TAG}"
	#CMD="/app/demo-binary --listen :$PORT -l 10 -r 10 -i $IMAGE"
	CMD="['/app/demo-binary','--listen',':$PORT','-l','10','-r','10','-i','$IMAGE']"
        build_and_push $IMAGE alpine  $PORT $CMD

        ## IMAGE="${REPO}:bad${TAG}"
        ## build_and_push $IMAGE alpine  $PORT  "--listen :$PORT -l 10 -r 10 -i $IMAGE"
    done
done

START_S=$START0_S; TIMER_STOP; echo "SCRIPT Took $TOOK secs [${HRS}h${MINS}m${SECS}]"


#build_and_push "mjbright/ckad-demo:alpine1" "alpine" 

