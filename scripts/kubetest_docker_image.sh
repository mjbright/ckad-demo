
POD_NAME=manualtest-mjbright-ckad-demo-a1
EXT_PORT=8282

press() {
    echo $*
    echo "Press <return>"
    read DUMMY
    [ "$DUMMY" = "q" ] && exit 0
    [ "$DUMMY" = "Q" ] && exit 0
}

kubectl run --generator=run-pod/v1 --image=mjbright/ckad-demo:alpine1 $POD_NAME

#sleep 2
#kubectl get pods

RUN_LABEL="run=$POD_NAME"
while [[ $(kubectl get pods -l $RUN_LABEL -o 'jsonpath={..status.conditions[?(@.type=="Ready")].status}') != "True" ]]; do echo "waiting for pod" && sleep 1; done

#press "Wait for Pod to be running"

kubectl get pods
echo; echo "Now curl to 127.0.0.1:${EXT_PORT}"

kubectl port-forward pod/$POD_NAME ${EXT_PORT}:80

