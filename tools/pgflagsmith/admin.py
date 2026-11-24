"""A small client for Flagsmith's Admin API (the endpoints the dashboard uses).

Used by the demo seed script and by `flagshift apply`. Authenticate with a user
token (`Authorization: Token ...`) or an organisation master API key
(`Authorization: Api-Key ...`).
"""
from __future__ import annotations

import time
from typing import Any

import requests


class FlagsmithAdminError(RuntimeError):
    pass


class FlagsmithAdmin:
    def __init__(self, api_url: str, token: str | None = None, api_key: str | None = None, timeout: float = 30):
        self.base = api_url.rstrip("/") + "/"
        self.s = requests.Session()
        self.timeout = timeout
        if token:
            self.s.headers["Authorization"] = f"Token {token}"
        elif api_key:
            self.s.headers["Authorization"] = f"Api-Key {api_key}"

    # -- plumbing ---------------------------------------------------------
    def request(self, method: str, path: str, **kw) -> Any:
        url = path if path.startswith("http") else self.base + path.lstrip("/")
        for attempt in range(4):
            r = self.s.request(method, url, timeout=self.timeout, **kw)
            if r.status_code in (502, 503, 504) and attempt < 3:
                time.sleep(1 + attempt)
                continue
            break
        if r.status_code >= 400:
            raise FlagsmithAdminError(f"{method} {path}: {r.status_code} {r.text[:800]}")
        if r.status_code == 204 or not r.content:
            return None
        return r.json()

    def get(self, path: str, **kw):
        return self.request("GET", path, **kw)

    def post(self, path: str, body: Any = None, **kw):
        return self.request("POST", path, json=body, **kw)

    def patch(self, path: str, body: Any = None, **kw):
        return self.request("PATCH", path, json=body, **kw)

    def put(self, path: str, body: Any = None, **kw):
        return self.request("PUT", path, json=body, **kw)

    def all(self, path: str, **params) -> list:
        """Every row of a (possibly paginated) list endpoint."""
        out, url = [], path
        params = {"page_size": 999, **params}
        while url:
            data = self.request("GET", url, params=params)
            params = None
            if isinstance(data, list):
                return data
            out += data.get("results", [])
            url = data.get("next")
        return out

    # -- auth -------------------------------------------------------------
    @classmethod
    def login(cls, api_url: str, email: str, password: str, register: bool = False) -> "FlagsmithAdmin":
        anon = cls(api_url)
        if register:
            try:
                anon.post("auth/users/", {"email": email, "password": password, "re_password": password,
                                          "first_name": "pg_flagsmith", "last_name": "demo"})
            except FlagsmithAdminError as e:
                if "already exists" not in str(e) and "400" not in str(e):
                    raise
        key = anon.post("auth/login/", {"email": email, "password": password})["key"]
        return cls(api_url, token=key)

    # -- organisations, projects, environments ----------------------------
    def organisation(self, name: str) -> dict:
        for o in self.all("organisations/"):
            if o["name"] == name:
                return o
        return self.post("organisations/", {"name": name})

    def project(self, org_id: int, name: str) -> dict:
        for p in self.all("projects/", organisation=org_id):
            if p["name"] == name:
                return p
        return self.post("projects/", {"name": name, "organisation": org_id})

    def environment(self, project_id: int, name: str) -> dict:
        for e in self.all("environments/", project=project_id):
            if e["name"] == name:
                return e
        return self.post("environments/", {"name": name, "project": project_id})

    def update_environment(self, env_key: str, **fields) -> dict:
        return self.patch(f"environments/{env_key}/", fields)

    def server_key(self, env_key: str, name: str = "pg_flagsmith") -> str:
        for k in self.all(f"environments/{env_key}/api-keys/"):
            if k["name"] == name and k.get("active", True):
                return k["key"]
        return self.post(f"environments/{env_key}/api-keys/", {"name": name})["key"]

    def environment_document(self, server_key: str) -> dict:
        r = requests.get(self.base + "environment-document/", headers={"X-Environment-Key": server_key},
                         timeout=self.timeout)
        r.raise_for_status()
        return r.json()

    # -- features ---------------------------------------------------------
    def features(self, project_id: int, env_id: int | None = None) -> list[dict]:
        params = {"environment": env_id} if env_id else {}
        return self.all(f"projects/{project_id}/features/", **params)

    def feature(self, project_id: int, name: str, **fields) -> dict:
        for f in self.features(project_id):
            if f["name"] == name:
                return f
        return self.post(f"projects/{project_id}/features/", {"name": name, **fields})

    def mv_option(self, project_id: int, feature_id: int, key: str, value: Any, allocation: float) -> dict:
        for o in self.all(f"projects/{project_id}/features/{feature_id}/mv-options/"):
            if o.get("key") == key:
                return o
        body = {"feature": feature_id, "key": key, "default_percentage_allocation": allocation,
                **_typed_value(value, prefix="")}
        return self.post(f"projects/{project_id}/features/{feature_id}/mv-options/", body)

    def feature_states(self, env_key: str, feature_id: int | None = None) -> list[dict]:
        params = {"feature": feature_id} if feature_id else {}
        return self.all(f"environments/{env_key}/featurestates/", **params)

    def set_default(self, env_key: str, feature_id: int, enabled: bool | None = None, value: Any = ...) -> dict:
        fs = [f for f in self.feature_states(env_key, feature_id)
              if f.get("feature_segment") is None and f.get("identity") is None][0]
        body: dict[str, Any] = {}
        if enabled is not None:
            body["enabled"] = enabled
        if value is not ...:
            body["feature_state_value"] = value
        return self.patch(f"environments/{env_key}/featurestates/{fs['id']}/", body)

    # -- segments ---------------------------------------------------------
    def segment(self, project_id: int, name: str, rules: list[dict]) -> dict:
        for s in self.all(f"projects/{project_id}/segments/"):
            if s["name"] == name:
                return s
        return self.post(f"projects/{project_id}/segments/", {"name": name, "project": project_id, "rules": rules})

    def segment_override(self, env_key: str, feature_id: int, segment_id: int, enabled: bool, value: Any,
                         priority: int | None = None) -> dict:
        fsv = _feature_state_value(value)
        body: dict[str, Any] = {"enabled": enabled, "feature_state_value": fsv,
                                "feature_segment": {"segment": segment_id}}
        if priority is not None:
            body["feature_segment"]["priority"] = priority
        return self.post(f"environments/{env_key}/features/{feature_id}/create-segment-override/", body)

    def segment_overrides(self, env_id: int, feature_id: int) -> list[dict]:
        return self.all("features/feature-segments/", environment=env_id, feature=feature_id)

    # -- identities -------------------------------------------------------
    def identity(self, env_key: str, identifier: str) -> dict:
        for i in self.all(f"environments/{env_key}/identities/", q=identifier):
            if i["identifier"] == identifier:
                return i
        return self.post(f"environments/{env_key}/identities/", {"identifier": identifier})

    def identity_override(self, env_key: str, identifier: str, feature_id: int, enabled: bool, value: Any) -> dict:
        ident = self.identity(env_key, identifier)
        for fs in self.all(f"environments/{env_key}/identities/{ident['id']}/featurestates/"):
            if fs["feature"] == feature_id:
                return self.patch(f"environments/{env_key}/identities/{ident['id']}/featurestates/{fs['id']}/",
                                  {"enabled": enabled, "feature_state_value": value})
        return self.post(f"environments/{env_key}/identities/{ident['id']}/featurestates/",
                         {"feature": feature_id, "enabled": enabled, "feature_state_value": value})

    # -- webhooks ---------------------------------------------------------
    def webhook(self, env_key: str, url: str, secret: str = "") -> dict:
        for w in self.all(f"environments/{env_key}/webhooks/"):
            if w["url"] == url:
                return w
        return self.post(f"environments/{env_key}/webhooks/", {"url": url, "enabled": True, "secret": secret})


def _typed_value(value: Any, prefix: str = "") -> dict:
    if isinstance(value, bool):
        return {"type": "bool", "boolean_value": value}
    if isinstance(value, int):
        return {"type": "int", "integer_value": value}
    return {"type": "unicode", "string_value": None if value is None else str(value)}


def _feature_state_value(value: Any) -> dict:
    return _typed_value(value)
