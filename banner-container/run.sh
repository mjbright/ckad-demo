#!/bin/bash

docker run -d -p 4321:4321 mjbright/banner-demo:hello1
curl 127.0.0.1:4321
docker run -d -p 4322:4322 mjbright/banner-demo:quiz
curl 127.0.0.1:4322
docker run -d -p 4323:4323 mjbright/banner-demo:vote
curl 127.0.0.1:4323





