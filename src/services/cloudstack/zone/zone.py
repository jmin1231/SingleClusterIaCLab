"""CloudStack zone, networks, pod, cluster and host, built through the signed API."""

import base64
import hashlib
import hmac
import json
import logging
import sys
import urllib.error
import urllib.parse
import urllib.request

from src.services.cloudstack.config.cloudstack_config import CS_API

log = logging.getLogger(__name__)


def cs_api(keys: dict, command: str, **params) -> dict:
    """Call one CloudStack API command, signed with admin's keys, and return its response."""

    query_params = {**params, "command": command, "apikey": keys["api_key"], "response": "json"}
    query = urllib.parse.urlencode(sorted(query_params.items()),
                                   quote_via=urllib.parse.quote)

    signature_string = query.lower()

    digest = hmac.new(
        keys["secret_key"].encode("utf-8"),
        signature_string.encode("utf-8"),
        hashlib.sha1,
    ).digest()

    signature = base64.b64encode(digest).decode("ascii")

    encoded_signature = urllib.parse.quote(signature, safe="")

    url = f"{CS_API}?{query}&signature={encoded_signature}"

    try:
        with urllib.request.urlopen(url, timeout=30) as resp:
            body = json.load(resp)
    except urllib.error.HTTPError as err:
        text = err.read().decode(errors="replace")[:300]
        log.error("CloudStack %s failed (HTTP %d): %s", command, err.code, text)
        sys.exit(1)

    return body[f"{command.lower()}response"]
