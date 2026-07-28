import json
import logging
import os
import socket
import sys
from datetime import datetime, timezone

from flask import Flask, jsonify, request

APP_VERSION = os.environ.get("APP_VERSION", "dev")
APP_NAME = os.environ.get("APP_NAME", "sample-app")
APP_ENV = os.environ.get("APP_ENV", "dev")
MESSAGE = "Hello from the OpenShift CI/CD demo pipeline!"


def _json_log(record: logging.LogRecord) -> str:
    return json.dumps({
        "ts": datetime.now(timezone.utc).isoformat(timespec="milliseconds"),
        "level": record.levelname,
        "msg": record.getMessage(),
        "logger": record.name,
        "app": APP_NAME,
        "env": APP_ENV,
        "version": APP_VERSION,
        "pod": socket.gethostname(),
    })


class _JsonFormatter(logging.Formatter):
    def format(self, record: logging.LogRecord) -> str:  # noqa: A003
        return _json_log(record)


handler = logging.StreamHandler(sys.stdout)
handler.setFormatter(_JsonFormatter())
logging.basicConfig(level=logging.INFO, handlers=[handler])
log = logging.getLogger("sample-app")

app = Flask(__name__)


@app.route("/")
def index():
    log.info("request served path=/")
    return f"""<!doctype html>
<html>
  <head><title>{APP_NAME} ({APP_ENV})</title></head>
  <body style="font-family: sans-serif; margin: 3rem;">
    <h1>{MESSAGE}</h1>
    <ul>
      <li><b>Environment:</b> {APP_ENV}</li>
      <li><b>Version:</b> {APP_VERSION}</li>
      <li><b>Pod:</b> {socket.gethostname()}</li>
      <li><b>Served at:</b> {datetime.now(timezone.utc).isoformat()}</li>
    </ul>
    <p>Built by GitLab CI, deployed by ArgoCD.</p>
  </body>
</html>"""


@app.route("/health")
def health():
    return jsonify(status="ok", version=APP_VERSION, env=APP_ENV), 200
