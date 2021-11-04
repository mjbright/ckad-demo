
# -- build stage ---------------------------------------------
FROM golang:alpine AS build-env

ADD .        /src
#ADD main.go /src
#ADD static  /src/static

# Command works:

# VERSION to use with 'FROM alpine' below:
#RUN cd /src && go build -o docker-demo

# VERSION to use with 'FROM scratch' below:
#RUN cd /src && CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -a -ldflags '-w' -o docker-demo *.go
RUN cd /src  && CGO_ENABLED=0 go mod init banner && CGO_ENABLED=0 go build -a -o banner-demo

# -- final stage ---------------------------------------------

# TODO LATER have base image here as a VARIABLE - scratch or alpine => produce different images
#FROM scratch
FROM alpine

ADD static    /app/static
#ADD templates /app/templates

WORKDIR /app
COPY    --from=build-env /src/banner-demo /app/

EXPOSE 80
ENTRYPOINT ["/app/banner-demo"]
CMD ["-listen=:80"]

