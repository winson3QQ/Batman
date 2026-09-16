# Batman payload: OpenTAKServer (TAK server) — arm64, non-root by design.
#
# Pinned to OTS 1.7.13 == commit 67903c26d95552738d85be4bc3c3ff3321378dbe
# (pin by SHA, not tag: a tag can be moved; a SHA is immutable — reproducible build).
#
# One image serves all four OTS service roles via command override:
#   ots(API, default entrypoint) / cot_parser / eud_handler / eud_handler --ssl
# The venv exposes /app/venv/bin/{opentakserver,cot_parser,eud_handler}.
#
# Build:  deploy/ots/build-arm64.sh  (WSL native docker+buildx+qemu; upstream ships
#         amd64-only images, so we build & own the arm64 set — see the WSL arm64 note).
#
# NOTE: this image is the app only. CA + DB schema are stateful and created at deploy
# time by the app on first boot (do NOT bake create-ca into the image).
FROM python:3.13

RUN addgroup --gid 1024 ots \
 && adduser --home /app --disabled-password --gecos "" --force-badname --gid 1024 ots \
 && apt-get update && apt-get install -y ffmpeg && rm -rf /var/lib/apt/lists/*

USER ots
WORKDIR /app/opentakserver
RUN chown -R ots:ots /app
RUN python -m venv /app/venv
ENV PATH="/app/venv/bin:$PATH"

# Override at build time with --build-arg OTS_REF=<sha|tag> to bump the pin.
ARG OTS_REF=67903c26d95552738d85be4bc3c3ff3321378dbe
RUN pip install --no-cache-dir "git+https://github.com/brian7704/OpenTAKServer.git@${OTS_REF}"

EXPOSE 8081
ENTRYPOINT ["opentakserver"]
STOPSIGNAL SIGINT
HEALTHCHECK --interval=1m CMD curl --fail http://localhost:8081/api/health || exit 1
