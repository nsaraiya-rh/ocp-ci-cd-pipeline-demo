# Red Hat UBI Python base — runs as non-root (uid 1001), OpenShift-friendly.
FROM registry.access.redhat.com/ubi9/python-311:latest

ARG APP_VERSION=dev
ENV APP_VERSION=${APP_VERSION}

WORKDIR /opt/app-root/src

COPY requirements.txt ./
RUN pip install --no-cache-dir -r requirements.txt

COPY app.py ./

EXPOSE 8080
CMD ["gunicorn", "--bind", "0.0.0.0:8080", "--workers", "2", "app:app"]
