# Production image for the Simple Linear Regression Calculator.
# Julia version is pinned to match Manifest.toml (julia_version = "1.13.3").
FROM julia:1.13.3-bookworm

# Keep the package depot inside the image so Pkg.instantiate/precompile runs at
# build time, not on every cold start. Render's free plan has 0.1 CPU / 512 MB,
# so the app runs single-threaded.
ENV JULIA_DEPOT_PATH=/opt/julia-depot \
    JULIA_NUM_THREADS=1 \
    JULIA_PKG_PRECOMPILE_AUTO=0

WORKDIR /app

# 1) Resolve dependencies first: this layer is cached until Project/Manifest change.
COPY Project.toml Manifest.toml ./
RUN julia --project=. -e 'using Pkg; Pkg.instantiate(); Pkg.precompile()'

# 2) Then copy the sources the server reads at runtime.
#    src/main.jl loads src/*.jl and reads ../static/style.css relative to @__DIR__,
#    so the src/ + static/ layout must be preserved.
COPY src ./src
COPY static ./static

# Render injects PORT (default 10000) and requires binding on 0.0.0.0.
ENV HOST=0.0.0.0 \
    PORT=10000
EXPOSE 10000

CMD ["julia", "--project=.", "src/main.jl"]
