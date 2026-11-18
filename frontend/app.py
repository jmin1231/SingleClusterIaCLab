"""Lab Todo: list, add, update and delete items in the database through PostgREST on be-1."""

import json
import os
import urllib.error
import urllib.request

from flask import Flask, redirect, render_template, request

API = os.environ.get("API_URL", "http://10.3.1.10:8000") + "/items"

app = Flask(__name__)


def api(method: str, query: str = "", body: dict | None = None) -> list | None:
    """Call PostgREST and return the decoded JSON reply, or None when the reply is empty."""
    req = urllib.request.Request(
        API + query,
        method=method,
        data=json.dumps(body).encode() if body is not None else None,
        headers={"Content-Type": "application/json"},
    )
    with urllib.request.urlopen(req, timeout=5) as resp:
        data = resp.read()
    return json.loads(data) if data else None


@app.get("/")
def index():
    return render_template("items.html", items=api("GET", "?order=id"), error=None)


@app.post("/add")
def add():
    api("POST", body={"name": request.form["name"]})
    return redirect("/", code=303)


@app.post("/update/<int:item_id>")
def update(item_id: int):
    api("PATCH", f"?id=eq.{item_id}", {"name": request.form["name"]})
    return redirect("/", code=303)


@app.post("/delete/<int:item_id>")
def delete(item_id: int):
    api("DELETE", f"?id=eq.{item_id}")
    return redirect("/", code=303)


@app.errorhandler(urllib.error.URLError)
@app.errorhandler(TimeoutError)
def api_error(err: Exception):
    return render_template("items.html", items=[], error=f"API error: {err}"), 502
