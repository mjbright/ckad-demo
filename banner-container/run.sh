#!/bin/bash

docker run -d -p 8080:80 mjbright/banner:hello1
curl 127.0.0.1:8080
docker run -d -p 8081:80 mjbright/banner:quiz
curl 127.0.0.1:8081
docker run -d -p 8082:80 mjbright/banner:vote
curl 127.0.0.1:8082





