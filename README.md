# sure-custom: thin homelab overlay on Sure

The upstream [Sure](https://github.com/we-promise/sure) image (AGPL-3.0) plus a small
overlay of added files. It is not a fork: the Dockerfile builds `FROM` a pinned upstream digest,
checks that the upstream files we override or depend on are unchanged, copies `overlay/` onto
`/rails`, and re-runs bootsnap and `assets:precompile`.

Plan and feature design: `docs/sure-custom-image-plan.md` in the homelab monorepo.

Status: phase 2 (transfer API) built and tested locally; not pushed or deployed. Phase 1 (skeleton)
is done.

## Features

**Transfer API** (`app/controllers/api/v1/transfer_writes_controller.rb`, routes in
`config/initializers/zz_homelab_routes.rb`; upstream only has GET for transfers):

- `POST /api/v1/transfers` (`read_write` key),
  `{"transfer": {"inflow_transaction_id", "outflow_transaction_id", "notes"?}}`:
  - links the pair as a confirmed transfer (201), or confirms the pending auto-match for the
    same pair (200); repeating it returns 200 with no new transfer;
  - an earlier rejection of the pair is deleted;
  - same path as the web UI: save + `confirm!` in one DB transaction, then
    `sync_account_later` on both accounts;
  - errors: 404 `record_not_found`, 403 `insufficient_scope` / `forbidden` (needs write on
    both accounts), 422 `validation_failed` / `same_account` / `not_transferable` /
    `opposite_amounts`, 409 `transfer_conflict`.
- `PATCH /api/v1/transfers/:id`, `{"transfer": {"status": "confirmed" | "rejected"}}`:
  `confirm!` returns the transfer; `reject!` returns the `RejectedTransfer`.
- Responses use the upstream `api/v1/transfers/show` and
  `api/v1/rejected_transfers/_rejected_transfer` jbuilder views.

## Layout

| Path | Purpose |
|---|---|
| `Dockerfile` | `FROM ghcr.io/we-promise/sure:<tag>@sha256:<digest>`, pin check, overlay copy, precompile |
| `overlay/` | Files copied onto `/rails` (same relative paths as upstream) |
| `overlay/UPSTREAM_PINS` | `sha256sum -c` list of upstream files (paths relative to `/rails`) that must not change |

`overlay/UPSTREAM_PINS` itself is also copied to `/rails/UPSTREAM_PINS`, which documents the
pins inside the image.

The image keeps the upstream `USER 1000:1000`, `ENTRYPOINT` (`/rails/bin/docker-entrypoint`,
which runs `db:prepare` on `rails server`), `CMD`, `WORKDIR` and `ENV`. It adds only the env var
`HOMELAB_OVERLAY_SHA` and labels.

## Build

```sh
cd services/sure-custom
docker buildx build --load -t sure-custom:dev \
  --build-arg HOMELAB_OVERLAY_SHA=$(git rev-parse HEAD:services/sure-custom) .
```

`HOMELAB_OVERLAY_SHA` is the git **tree** hash of `services/sure-custom/`. It is identical to
the root tree of the matching commit in the public overlay repo (`git rev-parse HEAD^{tree}`
there), so anyone can map an image to its source. It only works once the directory is committed
and ignores uncommitted edits; for local work builds pass any marker, e.g.
`--build-arg HOMELAB_OVERLAY_SHA=local-dirty`.

Smoke checks:

```sh
docker run --rm sure-custom:dev sh -c 'id && cat .sure-version'
docker run --rm -e SECRET_KEY_BASE_DUMMY=1 sure-custom:dev \
  ./bin/rails runner 'puts Rails.application.routes.routes.count'
```

Tests (run inside the image against postgres + redis; see the workflow for the exact
command): `bin/rails test test/controllers/api/v1/transfer_writes_controller_test.rb …` and
`bundle exec rspec --pattern spec/requests/api/v1/transfer_writes_spec.rb`. The `--pattern` is
required: upstream `.rspec` sets a pattern that otherwise loads every API spec, many of which
already fail upstream. Keep `PARALLEL_WORKERS` low (4), because one worker per CPU hangs.

CI (`.github/workflows/sure-custom-image.yml`) builds amd64 and runs the tests in the image
against postgres 16 and redis 7, then builds amd64 + arm64 on native runners, pushes by digest
and publishes `ghcr.io/surejaj/homelabservices/sure:<upstream>-hl.<run_number>` and
`:sha-<short>`. The first push creates a private GHCR package; set it to public once (the
cluster pulls without an `imagePullSecret`). Unverified: whether the `image.source` label
pointing at the public overlay repo (not this monorepo) affects GHCR package linking or the
`GITHUB_TOKEN` push permission on later pushes (`gbrain-images.yml` overrides the label to keep
its packages linked to this repo). If a push is denied, link the package to this repo in its
GHCR settings.

## Upgrade / pin procedure

1. Bump the `FROM` tag **and** digest in `Dockerfile` together (stable tags only, no `-alpha`),
   and `UPSTREAM_VERSION` in the workflow.
2. Build. `sha256sum -c` fails on each pinned file that changed upstream.
3. For each failing file:
   - **Overridden** (a copy lives under `overlay/`): diff the old and new upstream versions,
     re-copy the new upstream file into `overlay/`, re-apply our branch.
   - **Depended-on** (no copy in `overlay/`): read the upstream diff, adjust the overlay code
     and tests if needed.
4. Recompute the pins from the new image (not from a live pod):

   ```sh
   IMG='ghcr.io/we-promise/sure:<tag>@sha256:<digest>'
   docker run --rm --entrypoint sh "$IMG" -c "cd /rails && sha256sum $(awk '{print $2}' overlay/UPSTREAM_PINS | tr '\n' ' ')" \
     > /tmp/UPSTREAM_PINS.new \
     && diff overlay/UPSTREAM_PINS /tmp/UPSTREAM_PINS.new; \
     [ "$(wc -l < /tmp/UPSTREAM_PINS.new)" -eq "$(wc -l < overlay/UPSTREAM_PINS)" ] \
     && mv /tmp/UPSTREAM_PINS.new overlay/UPSTREAM_PINS
   ```

   The line-count check stops a pin from silently disappearing if a file was removed upstream
   (`sha256sum` then errors and writes fewer lines).

5. Rebuild, run CI, then the staging check from the plan if transfers or register files changed.

## Publishing the overlay

The source lives in this (private) monorepo under `services/sure-custom/` and is mirrored to the
public repo `https://github.com/surejaj/sure-homelab-overlay`, which the image's
`org.opencontainers.image.source` label points to. Mirror it before (or with) every image that
is pushed:

```sh
git subtree split --prefix services/sure-custom -b sure-overlay-public
git push git@github.com:surejaj/sure-homelab-overlay.git sure-overlay-public:main
```

This is done by hand (the CI workflow does not push to the public repo). The directory must
never hold secrets or personal data.

## License notice (AGPL-3.0)

Sure is licensed under the GNU Affero General Public License v3.0. This overlay modifies Sure
and is distributed under the same license; the upstream `LICENSE` and notices are kept
unchanged in the image at `/rails/LICENSE`.

- Corresponding source for any image built from here: the upstream Sure source at the tag and
  commit in the image labels (`org.opencontainers.image.base.name`, upstream
  `BUILD_COMMIT_SHA`), plus this overlay at the tree hash in `HOMELAB_OVERLAY_SHA`, published at
  `https://github.com/surejaj/sure-homelab-overlay`.
- Users who interact with the modified Sure over a network are offered this source (AGPL §13);
  publishing the image publicly also conveys it (§6).
- Every overridden upstream file under `overlay/` carries a header comment
  `Modified by homelab overlay, <date>`.
