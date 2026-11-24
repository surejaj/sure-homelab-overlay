# syntax=docker/dockerfile:1
#
# Thin homelab overlay on the upstream Sure image (AGPL-3.0).
# Source of this overlay: https://github.com/surejaj/sure-homelab-overlay
# Plan: docs/sure-custom-image-plan.md (in the homelab monorepo).
#
# Only adds files under /rails. USER (1000:1000), ENTRYPOINT
# (/rails/bin/docker-entrypoint), CMD (./bin/rails server), WORKDIR and the
# upstream ENV (RAILS_ENV, BUNDLE_*, BUILD_COMMIT_SHA) are inherited unchanged.
#
# Upgrading upstream: bump the tag AND digest below together, then rebuild.
# The pin check fails if any file in overlay/UPSTREAM_PINS changed upstream;
# see README.md "Upgrade procedure".
FROM ghcr.io/we-promise/sure:0.7.6-hotfix.1@sha256:002cde609f3af4b69ba2564c2482f3996e1fe29092dd169962b9b6ed943fcb10

# Fail the build on upstream drift of any overridden or depended-on file.
# The pins file is bind-mounted, so it leaves nothing behind in this layer.
RUN --mount=type=bind,source=overlay/UPSTREAM_PINS,target=/tmp/UPSTREAM_PINS \
    cd /rails && sha256sum -c --strict /tmp/UPSTREAM_PINS

# Overlay files land on top of the upstream tree. /rails itself is root-owned
# upstream, but every subdirectory is owned by rails (1000), as are these files.
COPY --chown=1000:1000 overlay/ /rails/

# Rebuild the bootsnap cache and assets (Tailwind scans app/views/**) as the
# upstream image does. Runs as the inherited USER 1000:1000; tmp/, public/assets
# and app/assets/builds are rails-owned upstream, so no root step is needed.
RUN cd /rails \
 && bundle exec bootsnap precompile -j 0 app/ lib/ \
 && SECRET_KEY_BASE_DUMMY=1 ./bin/rails assets:precompile

# Last, so a new overlay commit does not invalidate the layers above.
ARG HOMELAB_OVERLAY_SHA=unknown
ENV HOMELAB_OVERLAY_SHA=${HOMELAB_OVERLAY_SHA}
LABEL org.opencontainers.image.source="https://github.com/surejaj/sure-homelab-overlay" \
      org.opencontainers.image.url="https://github.com/surejaj/sure-homelab-overlay" \
      org.opencontainers.image.licenses="AGPL-3.0" \
      org.opencontainers.image.title="Sure (homelab overlay)" \
      org.opencontainers.image.description="Upstream Sure 0.7.6-hotfix.1 plus a thin homelab overlay" \
      org.opencontainers.image.vendor="surejaj" \
      org.opencontainers.image.base.name="ghcr.io/we-promise/sure:0.7.6-hotfix.1" \
      org.opencontainers.image.base.digest="sha256:002cde609f3af4b69ba2564c2482f3996e1fe29092dd169962b9b6ed943fcb10" \
      io.github.surejaj.homelab-overlay.sha="${HOMELAB_OVERLAY_SHA}"
