#!/bin/bash

# Usage:
# ./build.sh --local # -l: Build local binary for none-container testing
# ./build.sh       l #     Build and test a single Docker image
# ./build.sh --full  # -f: Build all repos/tags and test and push images ...
# ./build.sh --build # -b: Build and test all repos/tags


RESET_ANSI='\033[0m' 

USAGE() {
    cat <<EOF
   ./build.sh         # Build and test main repo with tag 1
   ./build.sh --local # -l: Build binary, not image
   ./build.sh --test  # -t: Test all repos/tags
   ./build.sh --all   # -a: Build and test all repos/tags
   ./build.sh --build # -b: Build and test selected repos/tags
   ./build.sh --full  # -f: Build all repos/tags and test and push images ...
EOF
}

VERBOSE=0

# Log output:

DATE_VERSION=$(date +%Y-%b-%d_%02Hh%02Mm%02S)
APP_BIN=/app/demo-binary

LOG_DIR=$PWD/logs

mkdir -p $LOG_DIR

BUILD_LOG=$LOG_DIR/build.log
cp /dev/null $BUILD_LOG

LOG=$LOG_DIR/${0}.${DATE_VERSION}.log
PUSH_LOG=$LOG_DIR/docker_push.${DATE_VERSION}.log
LOG_LINK=$LOG_DIR/${0}.log
PUSH_LOG_LINK=$LOG_DIR/docker_push.log

[ -h $LOG_LINK ] && rm $LOG_LINK
[ -h $PUSH_LOG_LINK ] && rm $PUSH_LOG_LINK
ln -s $LOG $LOG_LINK
ln -s $PUSH_LOG $PUSH_LOG_LINK
exec 2>&1 > >( stdbuf -oL tee $LOG )  
echo "Logging output to '$LOG'"
echo "Logging image pushes to '$PUSH_LOG'"

mkdir -p logs
mkdir -p ~/tmp

# Detect if running under WSL, if so use nocache (for now)
#DOCKER_BUILD="docker build"
#[ ! -z "$WSLENV" ] && DOCKER_BUILD="nocache docker build"

DOCKER_BUILD="docker buildx build --platform linux/amd64,linux/arm64,linux/arm/v7 --push"
#docker buildx build --platform linux/amd64,linux/arm64,linux/arm/v7 -t mjbright/demo:latest --push 


STAGE1_STATIC_IMAGE="mjbright/demo-static-binary"
STAGE1_DYNAMIC_IMAGE="mjbright/demo-dynamic-binary"

# -- Functions: --------------------------------------------------------

function die {
    echo "$0: die - $*" >&2
    for i in 0 1 2 3 4 5 6 7 8 9 10;do
        CALLER_INFO=`caller $i`
        [ -z "$CALLER_INFO" ] && break
        echo "    Line: $CALLER_INFO" >&2
    done
    exit 1
}          

function DOCKER_LOGIN {
    [ "$LOCAL" = "1" ] && return

    echo
    echo "(use --local option to avoid 'docker login')"
    #echo "docker login:"
    #docker login > ~/tmp/docker.login.op 2>&1 || {
    docker login || {
        cat ~/tmp/docker.login.op
        die "Failed to login to Docker Hub"
    }
}

function AWK_IMAGE_TAG {
    awk '!/^REPOSITORY *TAG/ { printf "%s:%s\n", $1, $2; }'
}

function check_build {
    SRC_GO=$1; shift

    [ ! -f $SRC_GO ] && die "No such src file <$SRC_GO>"

    echo; echo "---- Building binary ----------"
    [ -f demo-binary ] && rm -f demo-binary ]
    CGO_ENABLED=0 go build -a -o demo-binary $SRC_GO
    [ ! -x demo-binary ] && die "Failed to build binary"
    ls -alh demo-binary

    echo; echo "---- Checking binary version ----------"
    VERSION=$(./demo-binary --version 2>&1)
    echo $VERSION | grep $DATE_VERSION || die "Bad version '$DATE_VERSION' not found in '$VERSION'"

    echo; echo "---- Testing  binary ----------"
    LISTEN=127.0.0.1:8080
    echo
    echo "./demo-binary -l $LISTEN &"
    ./demo-binary -l $LISTEN &
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

function set_build_vars {
    case "$1" in
        scratch|static)
            STAGE1_IMAGE=$STAGE1_STATIC_IMAGE
            BUILD_ENV_TARGET="build-env-static"
            FROM_IMAGE=scratch
            #STAGE1_BUILD="CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -a -ldflags '-w' -o demo-binary main.build.go"
            STAGE1_BUILD="CGO_ENABLED=0 GOOS=linux go build -a -ldflags '-w' -o demo-binary main.build.go"
            ;;
        alpine|dynamic)
            STAGE1_IMAGE=$STAGE1_DYNAMIC_IMAGE
            BUILD_ENV_TARGET="build-env-dynamic"
            FROM_IMAGE=alpine
            STAGE1_BUILD="CGO_ENABLED=0 go build -a -o demo-binary main.build.go"
            ;;
        *) die "Bad build mode <$1>"
            ;;
    esac
}

# Build a Docker image containing a statically-linked binary of the demo-app:
function docker_build_static_base {
    [ $VERBOSE -ne 0 ] && echo "FN: docker_build_static_base $*"
    set_build_vars "static"

    template_dockerfile "$IMAGE_TAG" "$FROM_IMAGE" "$EXPOSE_PORT" "$TEMPLATE_CMD" "$DATE_VERSION" "$IMAGE_NAME_VERSION" "$IMAGE_VERSION" "$PICTURE_PATH_BASE" "$BUILD_ENV_TARGET"
    TIME docker pull $STAGE1_IMAGE || true

    # Build the compile stage:
    echo "$(date): $DOCKER_BUILD --target $BUILD_ENV_TARGET --cache-from=$STAGE1_IMAGE --tag $STAGE1_IMAGE" >> $BUILD_LOG
    TIME $DOCKER_BUILD --target $BUILD_ENV_TARGET --cache-from=$STAGE1_IMAGE --tag $STAGE1_IMAGE . || die "Build failed" 
    #TIME $DOCKER_BUILD --target $BUILD_ENV_TARGET --tag $STAGE1_IMAGE . || die "Build failed" 
}

# Build a Docker image containing a dynamically-linked binary of the demo-app:
function docker_build_dynamic_base {
    [ $VERBOSE -ne 0 ] && echo "FN: docker_build_dynamic_base $*"
    set_build_vars "dynamic"
    template_dockerfile "$IMAGE_TAG" "$FROM_IMAGE" "$EXPOSE_PORT" "$TEMPLATE_CMD" "$DATE_VERSION" "$IMAGE_NAME_VERSION" "$IMAGE_VERSION" "$PICTURE_PATH_BASE" "$BUILD_ENV_TARGET"
    TIME docker pull $STAGE1_IMAGE || true
}

# Properly cached 2stage_build:
#   See https://pythonspeed.com/articles/faster-multi-stage-builds/
function docker_build {
    [ $VERBOSE -ne 0 ] && echo "FN: docker_build $*"
    IMAGE_TAG=$1; shift
    FROM_IMAGE=$1; shift
    EXPOSE_PORT=$1; shift
    TEMPLATE_CMD="$*"; set --

    IMAGE_NAME_VERSION=$IMAGE_TAG
    IMAGE_VERSION=${IMAGE_TAG#*:}

    SET_picture_paths $IMAGE_TAG
    set_build_vars $FROM_IMAGE
    [ "$TEMPLATE_CMD" = "CMD" ] && die "build: Missing command in <$TEMPLATE_CMD>"
    template_dockerfile "$IMAGE_TAG" "$FROM_IMAGE" "$EXPOSE_PORT" "$TEMPLATE_CMD" "$DATE_VERSION" "$IMAGE_NAME_VERSION" "$IMAGE_VERSION" "$PICTURE_PATH_BASE" "$BUILD_ENV_TARGET"

    #set -euo pipefail

    # Pull the latest version of the image, in order to populate the build cache:
    #### XXXXXX TIME docker pull $IMAGE_TAG    || true

    # Build the runtime stage, using cached compile stage:
    TIME $DOCKER_BUILD --target runtime-image \
                 --cache-from=$STAGE1_IMAGE \
                 --cache-from=$IMAGE_TAG --tag $IMAGE_TAG . || die "Build failed"
    echo "$(date): $DOCKER_BUILD --target runtime-image --cache-from=$STAGE1_IMAGE --cache-from=$IMAGE_TAG --tag $IMAGE_TAG ." >> $BUILD_LOG
    #TIME $DOCKER_BUILD --target runtime-image \
    #             --tag $IMAGE_TAG . || die "Build failed"
    #echo "CMD=<$TEMPLATE_CMD>"
    [ "$TEMPLATE_CMD" = "CMD" ] && die "Missing command in <$TEMPLATE_CMD>"

    echo; echo "---- [docker] Checking $IMAGE_TAG command ----------"
    docker history --no-trunc $IMAGE_TAG | awk '/CMD / { FS="CMD"; $0=$0; print "CMD",$2; } '

    ITAG=$(echo $IMAGE_TAG | sed 's?[/:_]?-?g')
    echo; echo "---- [docker] Checking $IMAGE_TAG version ----------"
    docker rm --force name versiontest-$ITAG 2>/dev/null
    #set -x
    VERSION=$(docker run --rm --name versiontest-$ITAG $IMAGE_TAG $APP_BIN --version 2>&1)
    #set +x
    [ -z "$VERSION" ] && die "Failed to create container <versiontest-${ITAG}>"
    ## echo $VERSION | grep $DATE_VERSION || die "Bad version '$DATE_VERSION' not found in '$VERSION'"
    echo $VERSION | grep $DATE_VERSION || echo "[DISABLED FAIL] Bad version '$DATE_VERSION' not found in '$VERSION'"

    echo; echo "---- [docker] Testing  $IMAGE_TAG ----------"
    let DELAY=LIVE+READY
    [ $DELAY -ne 0 ] && { echo "Waiting for live/ready $LIVE/$READY secs"; sleep $DELAY; }
    #kubernetes_test_image

    # Push the new versions:
    ## XXXX docker_push $STAGE1_IMAGE
    ## XXXX docker_push $IMAGE_TAG
}

function DOCKER_test_image {
    # build_and_push $IMAGE scratch $PORT $CMD
    [ $VERBOSE -ne 0 ] && echo "FN: test_image $*"
    IMAGE_TAG=$1; shift
    FROM_IMAGE=$1; shift
    PORT=$1; shift
    CMD=$1; shift

    SET_picture_paths $IMAGE_TAG
    ITAG=$(echo $IMAGE_TAG | sed 's?[/:_]?-?g')
    CONTAINERNAME=buildtest-$ITAG
    docker rm --force name $CONTAINERNAME 2>/dev/null

    # Use default command:
    docker image ls $IMAGE_TAG | AWK_IMAGE_TAG | grep $IMAGE_TAG || die "No such image (not pulling) <$IMAGE_TAG>"
    #die "OK??"
    #CMD="docker run --rm -d --name $CONTAINERNAME -p 8181:$PORT $IMAGE_TAG"
    CMD="docker run -d --name $CONTAINERNAME -p 8181:$PORT $IMAGE_TAG"
    echo "---- [DOCKER_test_image] $CMD"
    $CMD
    CONTAINERID=$(docker ps -ql)

    #echo -n "Sample asciitext lines: " $( curl -sL 127.0.0.1:8181/ | head -2 )
    echo "Sample asciitext lines: " $( curl -sL 127.0.0.1:8181/ | head -2 )
    echo -ne $RESET_ANSI

    curl -sL 127.0.0.1:8181/1 || {
      docker ps -a | grep $CONTAINERID
      docker logs $CONTAINERID
      die "---- [DOCKER_test_image] Failed to interrogate container <$CONTAINERID> $CONTAINERNAME from image <$IMAGE_TAG>"
    }
    #ATEXT_LINE=$(curl -sL 127.0.0.1:8181/ | head -10 | tail -1)
    #echo "Sample asciitext line: $ATEXT_LINE"

    TXT_PATH="${PICTURE_PATH_BASE}.txt"
    [ ! -f $TXT_PATH ] && die "No such txt file <$TXT_PATH>"
    PNG_PATH="${PICTURE_PATH_BASE}.png"
    [ ! -f $PNG_PATH ] && die "No such png file <$PNG_PATH>"

    #set -x
    #CMD="curl -sL 127.0.0.1:8181/${TXT_PATH} | wc -c"
    CURL_CMD="curl -sL 127.0.0.1:8181/${TXT_PATH}"
    CURL_TXT_SIZE=$($CURL_CMD | wc -c)
    [ "$CURL_TXT_SIZE" = "0" ] && {
        echo $CURL_CMD 
        $CURL_CMD
        $CURL_CMD | wc -c
        die "curl command failed <$CMD> - returned 0 bytes"
    }
    
    [ -z "$CURL_TXT_SIZE" ] && {
        echo $CURL_CMD 
        $CURL_CMD
        $CURL_CMD | wc -c
        die "curl command failed <$CMD> = failed to count bytes"
    }
    #set +x

    #CMD="wc -c < ${TXT_PATH}"
    CMD="cat ${TXT_PATH}"
    FILE_TXT_SIZE=$($CMD | wc -c)
    [ -z "$FILE_TXT_SIZE" ] && die "wc command failed <$CMD>"

    [ "$CURL_TXT_SIZE" != "$FILE_TXT_SIZE" ] && {
        echo $CURL_CMD 
        $CURL_CMD
        $CURL_CMD | wc -c
        die "Different text image sizes [ $CURL_TXT_SIZE != $FILE_TXT_SIZE ] ($TXT_PATH)"
    }

    CMD="curl -sL 127.0.0.1:8181/${PNG_PATH}"
    CURL_PNG_SIZE=$($CMD | wc -c)
    [ -z "$CURL_PNG_SIZE" ] && die "curl command failed <$CMD>"

    CMD="wc -c < ${PNG_PATH}"
    CMD="cat ${PNG_PATH}"
    FILE_PNG_SIZE=$($CMD | wc -c)
    [ -z "$FILE_PNG_SIZE" ] && die "wc command failed <$CMD>"

    [ "$CURL_PNG_SIZE" != "$FILE_PNG_SIZE" ] && die "Different PNG image sizes [ $CURL_PNG_SIZE != $FILE_PNG_SIZE ] ($PNG_PATH)"

    docker ps -a | grep $CONTAINERID &&
        docker rm -f $CONTAINERID

    #docker stop $CONTAINERID
    #docker rm $CONTAINERID
}

function kubernetes_test_image {
    # NO USE as this CAN ONLY BE DONE AFTER push

    JOBNAME=kubejobtest-$ITAG
    # Prints to log, but difficult to manage, keeps restarting Pod
    #kubectl run --rm --image-pull-policy '' --generator=run-pod/v1 --image=mjbright/ckad-demo:1 testerckad -it -- -v -die
    # Don't want --image-pull-policy '' as this will force pull from .... docker hub!!

    echo; echo "---- [kubernetes] Checking $IMAGE_TAG version ----------"
    kubectl delete job $JOBNAME 2>/dev/null
    kubectl create job --image=$IMAGE_TAG $JOBNAME -- $APP_BIN --version || die "Failed to create job <$JOBNAME>"

    MAX_LOOPS=10
    while ! kubectl get jobs/$JOBNAME | grep "1/1"; do
        let MAX_LOOPS=MAX_LOOPS-1; [ $MAX_LOOPS -eq 0 ] && die "Stopping ..."
        echo "Waiting for job to complete ..."; sleep 2;

    done

    VERSION=$(kubectl logs jobs/$JOBNAME |& grep -i version | tail -1)
    echo $VERSION | grep $DATE_VERSION || { 
        kubectl delete jobs/$JOBNAME;
        die "Bad version '$DATE_VERSION' not found in '$VERSION'"
    }
    kubectl delete jobs/$JOBNAME

    echo; echo "---- [kubernetes] Testing  $IMAGE_TAG ----------"
    let DELAY=LIVE+READY
    [ $DELAY -ne 0 ] && { echo "Waiting for live/ready $LIVE/$READY secs"; sleep $DELAY; }

    PODNAME=kubetest-$ITAG
    kubectl delete pod $PODNAME 2>/dev/null
    # Use default command:
    #TIME kubectl run --generator=run-pod/v1 --image=$IMAGE_TAG $PODNAME $APP_BIN -- -l 127.0.0.1:80
    TIME kubectl run --generator=run-pod/v1 --image=$IMAGE_TAG $PODNAME

    MAX_LOOPS=10
    while ! kubectl get pods/$PODNAME | grep "Running"; do
        let MAX_LOOPS=MAX_LOOPS-1; [ $MAX_LOOPS -eq 0 ] && die "Stopping ..."
        echo "Waiting for pod to reach Running state ..."; sleep 1;
    done

    kubectl port-forward pod/$PODNAME 8181:80 &
    PID=$!
    sleep 2

    curl -sL 127.0.0.1:8181/1 || {
        #kubectl delete pod/$PODNAME
        echo "----- ERROR"
        echo "Test then 'kubectl delete pod/$PODNAME'"
        echo "Test then 'kill -9 $PID' # port-forward"
        die "Failed to interrogate pod <$PODNAME> from image <$IMAGE_TAG>"
    }

    CURL_TXT_SIZE=$(curl -sL 127.0.0.1:8181/${PICTURE_PATH_BASE}.txt | wc -c)
    FILE_TXT_SIZE=$(wc -c < ${PICTURE_PATH_BASE}.txt)
    [ $CURL_TXT_SIZE -ne $FILE_TXT_SIZE ] && die "Different text image sizes [ $CURL_TXT_SIZE -ne $FILE_TXT_SIZE ]"
    CURL_PNG_SIZE=$(curl -sL 127.0.0.1:8181/${PICTURE_PATH_BASE}.Pgt | wc -c)
    FILE_PNG_SIZE=$(wc -c < ${PICTURE_PATH_BASE}.txt)
    [ $CURL_PNG_SIZE -ne $FILE_PNG_SIZE ] && die "Different PNG image sizes [ $CURL_PNG_SIZE -ne $FILE_PNG_SIZE ]"

    # NEED TO KILL POD
    kill -9 $PID
    kubectl delete pod/$PODNAME
}

function SET_picture_paths {
    [ $VERBOSE -ne 0 ] && echo "FN: set_picture_paths $*"
    IMAGE_TAG=$1; shift

    PICTURE_TYPE=""
    case $IMAGE_TAG in
        mjbright/docker-demo*) PICTURE_TYPE="docker";;
        mjbright/k8s-demo*)    PICTURE_TYPE="kubernetes";;
        mjbright/ckad-demo*)   PICTURE_TYPE="kubernetes";;
        *)   die "Unknown image base: <$IMAGE_TAG>";;
    esac

    COLOUR=""
    case $IMAGE_TAG in
        *:1|*:alpine1) COLOUR="blue";;
        *:2|*:alpine2) COLOUR="green";;
        *:3|*:alpine3) COLOUR="red";;
        *:4|*:alpine4) COLOUR="cyan";;
        *:5|*:alpine5) COLOUR="yellow";;
        *:6|*:alpine6) COLOUR="white";;
        *)   die "Unknown image tag: <$IMAGE_TAG>";;
    esac

    PICTURE_BASE="${PICTURE_TYPE}_${COLOUR}"
    PICTURE_PATH_BASE="static/img/${PICTURE_BASE}"
    PICTURE_COLOUR="${COLOUR}"

    [ ! -f "${PICTURE_PATH_BASE}.png" ] && die "No such file <${PICTURE_PATH_BASE}.png>"
    [ ! -f "${PICTURE_PATH_BASE}.txt" ] && die "No such file <${PICTURE_PATH_BASE}.txt>"
}

function check_vars_set {
    for var in $*; do
        eval val=\$var
        [ -z "$val" ] && die "Variable \$var is unset"
    done
}

function template_dockerfile {
    # e.g. template_dockerfile mjbright/ckad-demo:1 scratch 80 ["/app/demo-binary","-l","80","-L","0","-R","0"]
    [ $VERBOSE -ne 0 ] && echo "FN: template_dockerfile $*"
    IMAGE_TAG=$1; shift
    FROM_IMAGE=$1; shift
    EXPOSE_PORT=$1; shift
    TEMPLATE_CMD="$1"; shift #set --
    DATE_VERSION=$1; shift
    IMAGE_NAME_VERSION=$1; shift
    IMAGE_VERSION=$1; shift
    PICTURE_PATH_BASE=$1; shift
    BUILD_ENV_TARGET=$1; shift

    [ -z "$EXPOSE_PORT" ] && die "EXPOSE_PORT is unset"
    #[ -z "$EXPOSE_PORT" ] && EXPOSE_PORT=80

    #echo "EXPOSE_PORT=$EXPOSE_PORT"
    [ "$TEMPLATE_CMD" = "CMD" ] && die "template_dockerfile: Missing command in <$TEMPLATE_CMD>"

    set_build_vars $FROM_IMAGE

    check_vars_set FROM_IMAGE EXPOSE_PORT STAGE1_BUILD TEMPLATE_CMD
    check_vars_set DATE_VERSION IMAGE_NAME_VERSION IMAGE_VERSION PICTURE_PATH_BASE
    check_vars_set BUILD_ENV_TARGET

    #echo "IMAGE_NAME_VERSION='$IMAGE_NAME_VERSION'"
    sed  < templates/Dockerfile.tmpl > Dockerfile \
        -e "s/__FROM_IMAGE__/$FROM_IMAGE/" \
        -e "s/__EXPOSE_PORT__/$EXPOSE_PORT/" \
        -e "s/__STAGE1_BUILD__/$STAGE1_BUILD/" \
        -e "s/__DATE_VERSION__/$DATE_VERSION/" \
        -e "s/__IMAGE_VERSION__/$IMAGE_VERSION/" \
        -e "s?__TEMPLATE_CMD__?$TEMPLATE_CMD?" \
        -e "s?__PICTURE_PATH_BASE__?$PICTURE_PATH_BASE?" \
        -e "s?__PICTURE_COLOUR__?$PICTURE_COLOUR?" \
        -e "s?__IMAGE_NAME_VERSION__?$IMAGE_NAME_VERSION?" \
        -e "s?__BUILD_ENV_TARGET__?$BUILD_ENV_TARGET?" \

    [ $VERBOSE -ne 0 ] && grep ENV Dockerfile

    #echo $DATE_VERSION
    #grep DATE_VERSION Dockerfile
    #die "X"

    [ ! -s Dockerfile ] && die "Empty Dockerfile"
    grep -v "^#" Dockerfile | grep __ && die "Uninstantiated variables in '${BUILD_SRC}'"
    mkdir -p tmp

    DFID=$(echo $IMAGE_TAG | sed -e 's/\//_/g')
    cp -a Dockerfile tmp/Dockerfile.${DFID}
    cp -a main.build.go tmp/main.build.go.${DFID}
}

#function basic_2stage_build {
#    [ $VERBOSE -ne 0 ] && echo "FN: basic_2stage_build $*"
#    IMAGE_TAG=$1; shift
#    FROM_IMAGE=$1; shift
#    EXPOSE_PORT=$1; shift
#    TEMPLATE_CMD="$*"; set --
#
#    template_dockerfile "$IMAGE_TAG" "$FROM_IMAGE" "$EXPOSE_PORT" "$TEMPLATE_CMD"
#    $DOCKER_BUILD -t $IMAGE_TAG .
#}

function docker_push {
    [ $VERBOSE -ne 0 ] && echo "FN: docker_push $*"
    local PUSH_IMAGE=$1; shift
    #FROM_IMAGE=$1; shift
    [ $PUSH -eq 0 ] && return 0 # SKIPPGIN PUSH

    CMD="docker push $PUSH_IMAGE "
    TIME $CMD
    RET=$?
    echo "[$RET] $(date) $CMD" >> $PUSH_LOG

    ALREADY=$(grep -c ": Layer already exists" $CMD_OP)
    PUSHED=$(grep -c ": Pushed" $CMD_OP)
    let LAYERS=ALREADY+PUSHED
    echo "Pushed $PUSHED of $LAYERS layers"
}

function DOCKER_build_image {
    [ $VERBOSE -ne 0 ] && echo "FN: build_image $*"
    IMAGE_TAG=$1; shift
    FROM_IMAGE=$1; shift
    PORT=$1; shift
    CMD=$1; shift

    echo "docker_build $IMAGE_TAG $FROM_IMAGE $PORT $CMD"
    docker_build $IMAGE_TAG $FROM_IMAGE $PORT $CMD
}

function DOCKER_push_image {
    # build_and_push $IMAGE scratch $PORT $CMD
    [ $VERBOSE -ne 0 ] && echo "FN: push_image $*"
    IMAGE_TAG=$1; shift
    FROM_IMAGE=$1; shift
    PORT=$1; shift
    CMD=$1; shift

    ## docker_push  $IMAGE_TAG # $FROM_IMAGE $PORT $CMD
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

    #FILE_SUFFIX=$(echo $CMD | sed 's/\(\"| |\,|\>|\<|\/)*/_/g' | tr "'" "_") 
    FILE_SUFFIX=$(echo $CMD | tr -s  "\"\\\/ '<>,:" "_")
    CMD_OP=tmp/cmd.op.$FILE_SUFFIX
    #echo CMD_OP=$CMD_OP
    touch $CMD_OP || die "Failed to touch <$CMD_OP>"

    CMD_TIME=$(date +%Y-%b-%d_%02Hh%02Mm%02S)
    echo "---- [$CMD_TIME] $CMD"
    TIMER_START
    #$CMD > $CMD_OP 2>&1; RET=$?
    $CMD ; RET=$?
    TIMER_STOP
    echo "Took $TOOK secs [${HRS}h${MINS}m${SECS}]"
    [ $RET -ne 0 ] && {
        cat $CMD_OP
        die "ERROR: returned $RET"
    }
    return $RET
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

function template_go_src {
    SRC=$1;       shift
    BUILD_SRC=$1; shift

    cp -a $SRC $BUILD_SRC
    grep -v "^#" ${BUILD_SRC} | grep __ && die "Uninstantiated variables in '${BUILD_SRC}'"
    [ ! -s "$BUILD_SRC" ] && die "Empty source file '$BUILD_SRC'"
}

function BUILD_ALL_REPOS_ALL_TAGS {
    
    #docker_test_image
    for REPO_NAME in $REPO_NAMES; do
        echo; echo "---- ${ACTION}ing images <$REPO_NAME> --------"
        for TAG in $TAGS; do
            REPO="mjbright/$REPO_NAME"
            PORT=80

            IMAGE="${REPO}:${TAG}"
            CMD="[\"$APP_BIN\",\"-l\",\"$PORT\",\"-L\",\"$LIVE\",\"-R\",\"$READY\"]"
            [ $BUILD -ne 0 ] && DOCKER_build_image $IMAGE scratch $PORT $CMD
            [ $TEST  -ne 0 ] && DOCKER_test_image  $IMAGE scratch $PORT $CMD
            [ $PUSH  -ne 0 ] && DOCKER_push_image  $IMAGE scratch $PORT $CMD

            IMAGE="${REPO}:alpine${TAG}"
            CMD="[\"$APP_BIN\",\"-l\",\"$PORT\",\"-L\",\"$LIVE\",\"-R\",\"$READY\"]"
            [ $BUILD -ne 0 ] && DOCKER_build_image $IMAGE alpine $PORT $CMD
            [ $TEST  -ne 0 ] && DOCKER_test_image  $IMAGE alpine $PORT $CMD
            [ $PUSH  -ne 0 ] && DOCKER_push_image  $IMAGE alpine $PORT $CMD

            ## IMAGE="${REPO}:bad${TAG}"
            ## build_and_push $IMAGE alpine  $PORT  "-l $PORT -L 10 -R 10 -i $IMAGE"
        done
    done
}

RUN_LOCAL_TEST() {
    PICTURE_TYPE="kubernetes"
    COLOUR="blue"

    echo
    export PICTURE_BASE="${PICTURE_TYPE}_${COLOUR}"
    export PICTURE_PATH_BASE="static/img/${PICTURE_BASE}"
    export PICTURE_COLOUR="${COLOUR}"
    export IMAGE_NAME_VERSION="static-binary:$DATE_VERSION"
    export IMAGE_VERSION="$DATE_VERSION"
    env | grep -E "IMAGE_|PICTURE_"
    ls -al ./demo-binary
    echo; echo "./demo-binary -l 8000"
    ./demo-binary -l 8000
}

# END: TIMER FUNCTIONS ================================================

IMAGE_NAME_VERSION=""
IMAGE_VERSION=""

## -- Args: -------------------------------------------------------------

ALL_REPO_NAMES="ckad-demo k8s-demo docker-demo"
ALL_TAGS=$(seq 6)

REPO_NAMES="ckad-demo"
TAGS=""

BUILD=1
TEST=1
PUSH=0
CLEAN_IMAGES=0
LOCAL=0

while [ ! -z "$1" ]; do
    case $1 in
        --verbose|-v)     VERBOSE=1;;
        --help|-h)        USAGE; exit 0;;

	# ACTIONS:
        --full|-f)        TEST=1;BUILD=1;PUSH=1; TAGS=$ALL_TAGS; REPO_NAMES=$ALL_REPO_NAMES;;
        --clean|-c)       CLEAN_IMAGES=1;;
        --build|-b)       BUILD=1; TEST=1;;
        --push|-p)        PUSH=1;;
        --local|-l)       BUILD=1;LOCAL=1;PUSH=0;TEST=1;;
        --run-local|-rl)  RUN_LOCAL_TEST; exit;;
        --test|-T)        BUILD=0;PUSH=0;TEST=1;;
        --push-only|-P)   TEST=0;BUILD=0;PUSH=1;;

	# IMAGE TAGS:
        [0-9]*)           TAGS+=" $1";;
        --tag|-t)         shift; TAGS=$1;;
        --all-tags|-at)   TAGS=$ALL_TAGS;;

	# REPOS:
        --repos|-r)       shift; REPO_NAMES=$1;;
        --all-images|-ai) REPO_NAMES=$ALL_REPO_NAMES;;
        --dd)             REPO_NAMES="docker-demo";;
        ++dd)             REPO_NAMES+=" docker-demo";;
        --kd)             REPO_NAMES="k8s-demo";;
        ++kd)             REPO_NAMES+=" k8s-demo";;

	# ALL IMAGE TAGS & REPOS:
        --all|-a)         TAGS=$ALL_TAGS; REPO_NAMES=$ALL_REPO_NAMES;;
    esac
    shift
done

[ $CLEAN_IMAGES -ne 0 ] && {
    for REPO in $REPO_NAMES; do
        #docker rmi $(docker image ls mjbright/docker-demo | awk '!/^REPOSITORY *TAG/ { printf "%s:%s\n", $1, $2; }')
	      IMAGE_TAGS=$(docker image ls $REPO | AWK_IMAGE_TAG)
        echo "---- docker rmi $IMAGE_TAGS"
	      if [ ! -z "$IMAGE_TAGS" ]; then
            docker rmi $IMAGE_TAGS
        else
            echo "No matching images for $REPO"
	      fi
    done
    exit 0
}

[ -z "$TAGS" ] && TAGS="1"

ACTION=""
[ $BUILD -ne 0 ] && ACTION+="Build"
[ $TEST  -ne 0 ] && ACTION+="/Test"
[ $PUSH  -ne 0 ] && ACTION+="/Push"
ACTION=${ACTION#/}

## -- Main: -------------------------------------------------------------

echo; echo "---- ${ACTION}ing images for repos<$REPO_NAMES> tags<"$TAGS">"


DOCKER_LOGIN

if [ $BUILD -ne 0 ]; then
    # Incremental builds:
    #SET_picture_paths $IMAGE_TAG
    #### COLOUR="blue"
    #### PICTURE_TYPE="kubernetes"
    #### export PICTURE_BASE="${PICTURE_TYPE}_${COLOUR}"
    #### export PICTURE_PATH_BASE="static/img/${PICTURE_BASE}"
    #### export PICTURE_COLOUR="${COLOUR}"
    template_go_src main.go main.build.go
    #check_build main.build.go
    [ $LOCAL -ne 0 ] && {
        # LOCAL static binary build:
        GOLANG_IMAGE=golang:alpine
        ENVS="-e CGO_ENABLED=0"

        set -x
          docker run -v $PWD:/mnt --rm $ENVS golang:alpine go build -a -o /mnt/demo-binary /mnt/main.build.go ||
              die "Build failed"
          ls -arhl demo-binary
        set +x
        RUN_LOCAL_TEST
        exit
    }

    # PERFORM test image builds:
    EXPOSE_PORT=80
    docker_build_static_base
    docker_build_dynamic_base

    TIME docker pull alpine:latest || true
fi

# Now build the various images/tags:
TIMER_START; START0_S=$START_S
    LIVE=0
    READY=0

    #LIVE=03
    #READY=03

    BUILD_ALL_REPOS_ALL_TAGS
START_S=$START0_S; TIMER_STOP; echo "SCRIPT Took $TOOK secs [${HRS}h${MINS}m${SECS}]"

echo "Output logged to '$LOG'"
echo "Image pushes were logged to '$PUSH_LOG'"

