# Release backend image (API + worker). Build context: build/work/src/backend
# (a filtered COPY of main). Mirrors main's backend/Dockerfile package-for-package;
# differences are listed in docs-internal/build-inputs.md:
#   + tzdata (TZ takes effect for report timestamps), ca-certificates
#   + /var/lib/sentinelcore/staging created with the shared group
#   - no --reload, no tests in the image
ARG BASE_IMAGE=python:3.11-slim-trixie
FROM ${BASE_IMAGE}

ENV PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1

WORKDIR /app

RUN echo "wireshark-common wireshark-common/install-setuid boolean false" | debconf-set-selections \
    && DEBIAN_FRONTEND=noninteractive apt-get update \
    && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        build-essential \
        libpango-1.0-0 \
        libpangocairo-1.0-0 \
        libgdk-pixbuf-2.0-0 \
        libcairo2 \
        libffi-dev \
        shared-mime-info \
        fonts-dejavu-core \
        tshark \
        tzdata \
        ca-certificates \
    && rm -rf /var/lib/apt/lists/*

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt \
    && apt-get purge -y --auto-remove build-essential \
    && rm -rf /var/lib/apt/lists/* /root/.cache

COPY . .

# GID 2000 / UID 1000 match main (helper socket is 0660 root:sentinelcore).
RUN groupadd -g 2000 sentinelcore \
    && chmod +x /app/entrypoint.sh \
    && useradd -m -u 1000 -G sentinelcore appuser \
    && chown -R appuser:appuser /app

# Seeded into fresh named volumes at first mount, so ownership here is what the
# volumes get. setgid keeps new files in the shared group.
RUN mkdir -p /var/lib/sentinelcore/reports /var/lib/sentinelcore/pcap /var/lib/sentinelcore/staging \
    && chown -R appuser:sentinelcore /var/lib/sentinelcore \
    && chmod -R 2770 /var/lib/sentinelcore

USER appuser

EXPOSE 8000

ENTRYPOINT ["/app/entrypoint.sh"]
CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8000"]
