#   docker build -t ospfv2 .
#   docker run --rm -p 8080:8080 ospfv2                         # demo, no router needed
#   docker run --rm --network host --cap-add NET_RAW \
#     -v $PWD/lab.yml:/lab.yml ospfv2 run /lab.yml --web 0.0.0.0:8080
#
# The library uses the standard library only, so the image needs no gems.

ARG RUBY_VERSION=4.0
FROM ruby:${RUBY_VERSION}-slim AS base

LABEL org.opencontainers.image.title="ospfv2" \
      org.opencontainers.image.description="OSPFv2 neighbor and topology simulator" \
      org.opencontainers.image.source="https://github.com/jeanmichel-gh/ospfv2" \
      org.opencontainers.image.licenses="GPL-3.0-or-later"

WORKDIR /app
COPY lib/ lib/
COPY bin/ bin/
COPY examples/ examples/
COPY ospfv2.gemspec LICENSE.txt COPYING README.md changelog.txt ./
ENV PATH=/app/bin:$PATH \
    RUBYOPT=--disable-did_you_mean

# ---- tests: docker build --target test .
FROM base AS test
COPY test/ test/
RUN ruby -Ilib -Itest -e 'Dir["test/unit/**/*_test.rb"].sort.each { |f| require "./#{f}" }'

# ---- runtime
FROM base AS runtime
# Raw IP sockets need CAP_NET_RAW, granted at run time (--cap-add NET_RAW).
# ospfd installing routes also needs NET_ADMIN. The name makes iproute2
# print our routes as "proto ospfv2".
RUN mkdir -p /etc/iproute2/rt_protos.d && echo '89 ospfv2' > /etc/iproute2/rt_protos.d/ospfv2.conf
# tcpdump for "ospfv2 capture": a console captures next to a router with
# docker run --network container:NAME --cap-add NET_RAW ospfv2 capture.
RUN apt-get update -qq && apt-get install -y -qq --no-install-recommends tcpdump && rm -rf /var/lib/apt/lists/*
EXPOSE 8080
WORKDIR /work
ENTRYPOINT ["ospfv2"]
CMD ["demo", "--web", "0.0.0.0:8080", "--log", "-"]
