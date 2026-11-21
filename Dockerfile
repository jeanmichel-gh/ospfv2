#   docker build -t ospfv2 --build-context bfd4r=../bfd4r .
#   docker run --rm -p 8080:8080 ospfv2                         # demo, no router needed
#   docker run --rm --network host --cap-add NET_RAW \
#     -v $PWD/lab.yml:/lab.yml ospfv2 run /lab.yml --web 0.0.0.0:8080
#
# The library uses the standard library and bfd4r, the owner's BFD gem.
# bfd4r is a sibling checkout, handed in as a named build context, since
# the gem is not published (as isis takes datalink-socket). It brings
# BFD::Client for ospfd, and bfdd4r, which with-bfdd4r starts beside
# whatever the container runs.

ARG RUBY_VERSION=4.0
FROM ruby:${RUBY_VERSION}-slim AS base

LABEL org.opencontainers.image.title="ospfv2" \
      org.opencontainers.image.description="OSPFv2 neighbor and topology simulator" \
      org.opencontainers.image.source="https://github.com/jeanmichel-gh/ospfv2" \
      org.opencontainers.image.licenses="GPL-3.0-or-later"

WORKDIR /app
# bfd4r's require path is its root: bfd/ and bfd4r.rb.
COPY --from=bfd4r bfd/ /bfd4r/bfd/
COPY --from=bfd4r bfd4r.rb LICENSE.txt /bfd4r/
COPY --from=bfd4r exe/ /bfd4r/exe/
COPY lib/ lib/
COPY bin/ bin/
COPY examples/ examples/
COPY routescope/ routescope/
COPY ospfv2.gemspec LICENSE.txt COPYING README.md changelog.txt ./
ENV PATH=/app/bin:/bfd4r/exe:$PATH \
    RUBYLIB=/bfd4r \
    RUBYOPT=--disable-did_you_mean

# ---- tests: docker build --target test --build-context bfd4r=../bfd4r .
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
RUN apt-get update -qq && apt-get install -y -qq --no-install-recommends tcpdump iproute2 && rm -rf /var/lib/apt/lists/*
EXPOSE 8080
WORKDIR /work
# bfdd4r runs beside every role, started again if it fails (bfd4r
# exe/with-bfdd4r). A lab that sets its own entrypoint and wants BFD puts
# with-bfdd4r first, as routescope/labs/ospf-bfd does.
ENTRYPOINT ["with-bfdd4r", "ospfv2"]
CMD ["demo", "--web", "0.0.0.0:8080", "--log", "-"]
