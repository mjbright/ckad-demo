
let V=1

die() {
    echo "$0: die - $*" >&2
    exit 1
}

press() {
    echo $*
    echo "Press <return>"
    read DUMMY
    [ "$DUMMY" = "q" ] && exit 0
    [ "$DUMMY" = "Q" ] && exit 0
}

if [ ! -z "$1" ]; then
    case $1 in
        [1-6]) V=$1;;
        *) die "Unknown option <$1>";;
    esac
    shift
fi

POD_NAME=manualtest-mjbright-ckad-demo-a$V
EXT_PORT=828$V

kubectl run --generator=run-pod/v1 --image=mjbright/ckad-demo:alpine$V $POD_NAME

#sleep 2
#kubectl get pods

RUN_LABEL="run=$POD_NAME"
while [[ $(kubectl get pods -l $RUN_LABEL -o 'jsonpath={..status.conditions[?(@.type=="Ready")].status}') != "True" ]]; do echo "waiting for pod" && sleep 1; done

#press "Wait for Pod to be running"

kubectl get pods
echo; echo "Now curl to 127.0.0.1:${EXT_PORT}"

CMD="kubectl port-forward pod/$POD_NAME ${EXT_PORT}:80"
echo $CMD
$CMD

