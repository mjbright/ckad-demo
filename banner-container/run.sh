#!/bin/bash

docker ps | grep -q banner:hello1 || 
    docker run -d -p 8080:80 mjbright/banner:hello1
curl -sL 127.0.0.1:8080
curl -sL -A Mozilla 127.0.0.1:8080 | grep img

docker ps | grep -q banner:quiz || 
    docker run -d -p 8081:80 mjbright/banner:quiz
curl -sL 127.0.0.1:8081
curl -sL -A Mozilla 127.0.0.1:8081 | grep img

docker ps | grep -q banner:vote || 
    docker run -d -p 8082:80 mjbright/banner:vote
curl -sL 127.0.0.1:8082
curl -sL -A Mozilla 127.0.0.1:8082 | grep img





