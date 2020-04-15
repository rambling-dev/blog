FROM alpine:latest

RUN apk add --no-cache hugo bash

ADD ci/build /

ENTRYPOINT ["/ci/build"]
