# Build context: gold_backend
ARG ELIXIR_IMAGE_TAG=1.18.4-erlang-27.3.4.15-ubuntu-jammy-20260627
FROM hexpm/elixir:${ELIXIR_IMAGE_TAG} AS builder
RUN apt-get update && apt-get install -y --no-install-recommends build-essential git \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /app
ENV MIX_ENV=prod
RUN mix local.hex --force && mix local.rebar --force
COPY mix.exs mix.lock ./
RUN mix deps.get --only prod
COPY config/config.exs config/prod.exs config/
RUN mix deps.compile
COPY lib lib
COPY priv priv
RUN mix compile --warnings-as-errors
COPY config/runtime.exs config/
RUN mix release

# Reuse the same Ubuntu Jammy base as the builder so the runner does not
# need a separate docker.io/library/ubuntu pull (IPv6/auth failures on CI).
FROM hexpm/elixir:${ELIXIR_IMAGE_TAG} AS runner
RUN apt-get update && apt-get install -y --no-install-recommends \
    libstdc++6 openssl libncurses6 ca-certificates curl locales \
    && sed -i '/en_US.UTF-8/s/^# //g' /etc/locale.gen && locale-gen \
    && rm -rf /var/lib/apt/lists/*
ENV LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8 MIX_ENV=prod PHX_SERVER=true PORT=4000 HOME=/app
WORKDIR /app
RUN useradd --system --home-dir /app app
COPY --from=builder --chown=app:app /app/_build/prod/rel/gold_backend ./
USER app
EXPOSE 4000
HEALTHCHECK --interval=10s --timeout=5s --start-period=30s --retries=6 \
    CMD curl -fsS --max-time 5 http://127.0.0.1:4000/api/health >/dev/null || exit 1
ENTRYPOINT ["/app/bin/gold_backend"]
CMD ["start"]
