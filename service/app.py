import os
import socket

from flask import Flask, jsonify


app = Flask(__name__)


def config_value(name: str, default: str) -> str:
    """Read an environment value, with an optional projected-file override."""
    file_path = os.environ.get(f"{name}_FILE")
    if file_path:
        try:
            with open(file_path, encoding="utf-8") as config_file:
                return config_file.read().strip()
        except OSError:
            pass

    return os.environ.get(name, default)


@app.get("/")
def index():
    return jsonify(
        app=config_value("APP_NAME", "demo-service"),
        version=config_value("VERSION", "unknown"),
        pod=socket.gethostname(),
    )


@app.get("/healthz")
def healthz():
    return jsonify(status="ok"), 200


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=8080)
