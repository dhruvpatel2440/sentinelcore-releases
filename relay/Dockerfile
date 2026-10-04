FROM python:3.11-slim

ENV PYTHONUNBUFFERED=1 PYTHONDONTWRITEBYTECODE=1
WORKDIR /srv

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY app ./app
COPY shim ./shim

# Non-root. Data dir for the sqlite store (mount a volume here in prod).
RUN useradd -m -u 1000 relay && mkdir -p /data && chown relay:relay /data
USER relay
VOLUME ["/data"]

EXPOSE 8080
CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8080"]
