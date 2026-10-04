# Release helper image (privileged boundary: nmap, Suricata, iptables).
# Build context: build/work/src/helper (filtered COPY of main). Package set is
# identical to main's helper/Dockerfile. Only addition: main's own
# docker/suricata/logrotate.conf is installed and actually run (main ships the
# file but never runs logrotate), via .release/helper-start.sh which the build
# script copies into the context.
ARG BASE_IMAGE=python:3.11-slim-trixie
FROM ${BASE_IMAGE}

ENV PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1

WORKDIR /opt/helper

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        nmap \
        iproute2 \
        iptables \
        libpcap0.8 \
        suricata \
        suricata-update \
        logrotate \
        procps \
    && rm -rf /var/lib/apt/lists/*

RUN groupadd -g 2000 sentinelcore

RUN mkdir -p /var/log/suricata /var/lib/suricata/rules /var/run/suricata \
        /var/lib/sentinelcore/staging /var/lib/logrotate \
    && touch /var/lib/suricata/rules/sentinelcore.rules

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt && rm -rf /root/.cache

COPY . .

RUN install -m 0644 .release/logrotate.conf /etc/logrotate.d/suricata \
    && install -m 0755 .release/helper-start.sh /usr/local/bin/sentinelcore-helper-start \
    && rm -rf .release

ENV PYTHONPATH=/opt/helper

# Root by design; capabilities come ONLY from compose (cap_drop ALL + 4 adds).
CMD ["/usr/local/bin/sentinelcore-helper-start"]
