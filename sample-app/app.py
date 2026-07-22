import os
import socket
from datetime import datetime, timezone

from flask import Flask, jsonify

app = Flask(__name__)

APP_VERSION = os.environ.get("APP_VERSION", "dev")
# Edit this message and push to trigger the CI/CD pipeline.
MESSAGE = "Testing: Hello from the OpenShift CI/CD demo pipeline! (v6 - webhook instant sync)"


@app.route("/")
def index():
    return f"""<!doctype html>
<html>
  <head><title>Sample App</title></head>
  <body style="font-family: sans-serif; margin: 3rem;">
    <h1>{MESSAGE}</h1>
    <ul>
      <li><b>Version:</b> {APP_VERSION}</li>
      <li><b>Pod:</b> {socket.gethostname()}</li>
      <li><b>Served at:</b> {datetime.now(timezone.utc).isoformat()}</li>
    </ul>
    <p>Built by GitLab CI, deployed by ArgoCD.</p>
  </body>
</html>"""


@app.route("/health")
def health():
    return jsonify(status="ok", version=APP_VERSION), 200
