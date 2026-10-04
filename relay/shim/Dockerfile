# Brevo-compatible shim sidecar. Ships INSIDE the install (release image
# sentinelcore/relay-shim), aliased to api.brevo.com on the compose network.
# Terminates TLS with the install-local CA (mounted) so the backend's
# verify=True egress to https://api.brevo.com trusts it.
ARG BASE_IMAGE=python:3.11-slim-trixie
FROM ${BASE_IMAGE}

ENV PYTHONUNBUFFERED=1 PYTHONDONTWRITEBYTECODE=1
WORKDIR /srv

# Only what the shim needs.
RUN pip install --no-cache-dir fastapi==0.115.0 "uvicorn[standard]==0.30.6" httpx==0.27.2 "pydantic[email]==2.9.2"

COPY shim ./shim

RUN useradd -m -u 1000 shim
USER shim

EXPOSE 443
# TLS cert/key for CN=api.brevo.com are mounted at /tls (see release compose);
# uvicorn serves HTTPS so the backend's verify=True egress is satisfied.
CMD ["uvicorn", "shim.app:app", "--host", "0.0.0.0", "--port", "443", \
     "--ssl-certfile", "/tls/api.brevo.com.crt", "--ssl-keyfile", "/tls/api.brevo.com.key"]
