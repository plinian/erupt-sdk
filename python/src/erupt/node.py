"""Erupt cloud node runtime: registers with the server, then answers the requests it forwards.
The wire contract is erupt-cloud/PROTOCOL.md (Level 0)."""
import base64
import contextvars
import hmac
import io
import itertools
import json
import logging
import math
import re
import socket
import threading
import time
import traceback
import urllib.parse
import urllib.request
from socketserver import ThreadingMixIn
from wsgiref.simple_server import WSGIRequestHandler, WSGIServer, make_server

from . import _signature
from .model import to_json_value
from .repo import Cond, Query

log = logging.getLogger("erupt")

__version__ = "0.1.0"

_user = contextvars.ContextVar("erupt_user", default=None)

# Features whose endpoints this SDK does not serve yet: hidden from the UI instead of failing there
_UNSUPPORTED_POWER = {"print": False, "ai": False}

# Rights the server decides per user; the node ANDs them onto the declared power
_SERVER_POWER = ("add", "edit", "delete", "viewDetails", "export", "importable")

_OPS = {"EQ", "NEQ", "GT", "GTE", "LT", "LTE", "LIKE", "NOT_LIKE", "RANGE", "IN", "NOT_IN", "NULL", "NOT_NULL"}

_MAX_PAGE_SIZE = 1000



def current_user():
    """The acting user of the request being served: ``{"uid", "account", "name", "tenantId"}``."""
    return _user.get()


class OperationContext:
    """What an ``@operation`` method receives."""

    def __init__(self, rows, param, repo, model, user):
        self.rows = rows    # selected records as the repository returned them; empty for BUTTON mode
        self.param = param  # coerced form values, or None without a form
        self.repo, self.model, self.user = repo, model, user


class _Reply(Exception):
    def __init__(self, status, body):
        self.status, self.body = status, body


# invoke kind -> the Field attribute holding its code
_INVOKED = {"options": "fetch", "onchange": "onchange", "autocomplete": "complete", "button": "click"}


class Fail(Exception):
    """A business error shown to the user as a message: raise it from a DataProxy hook or an operation."""


def _r(success=True, message=None, data=None):
    return {"success": success, "status": "SUCCESS" if success else "ERROR", "message": message, "data": data,
            "promptWay": "MESSAGE"}


class Node:

    def __init__(self, name, access_token, servers, *, address=None, heartbeat=15, require_signature=False):
        """``require_signature`` refuses server calls without a valid Erupt-Signature, so the plain access
        token alone no longer passes (servers sign since erupt 2.3.x)."""
        if not access_token:
            raise ValueError("access_token is required")
        self.name, self.access_token, self.require_signature = name, access_token, require_signature
        self.servers = [s.rstrip("/") for s in ([servers] if isinstance(servers, str) else servers)]
        self.address, self.heartbeat = address, heartbeat
        self.models = {}
        self._server_cycle = itertools.cycle(self.servers)
        self._power_cache = {}
        self._stop = threading.Event()
        self._routes = [
            ("GET", re.compile(r"^/erupt-api/build/([^/]+)$"), self._build),
            ("POST", re.compile(r"^/erupt-api/data/table/([^/]+)$"), self._table),
            ("GET", re.compile(r"^/erupt-api/data/init-value/([^/]+)$"), self._init_value),
            ("GET", re.compile(r"^/erupt-api/data/([^/]+)/([^/]+)$"), self._get),
            ("POST", re.compile(r"^/erupt-api/data/modify/([^/]+)$"), self._add),
            ("POST", re.compile(r"^/erupt-api/data/modify/([^/]+)/update$"), self._update),
            ("POST", re.compile(r"^/erupt-api/data/modify/([^/]+)/delete$"), self._delete),
            ("POST", re.compile(r"^/erupt-api/invoke/([^/]+)/([^/]+)/([^/]+)$"), self._invoke),
        ]

    def register(self, cls, repository):
        model = getattr(cls, "__erupt__", None)
        if model is None:
            raise ValueError(f"{cls.__name__} is not decorated with @erupt")
        if model.name in self.models:
            raise ValueError(f"erupt '{model.name}' registered twice")
        if model.pk is None:
            raise ValueError(f"{model.name} has no Field(pk=True); only an operation form may omit it")
        repository.bind(model)
        self.models[model.name] = (model, repository)
        return self

    def __call__(self, environ, start_response):
        try:
            status, body = self._dispatch(environ)
        except _Reply as reply:
            status, body = reply.status, reply.body
        except Fail as e:
            status, body = 200, _r(False, str(e))
        except Exception as e:  # never leak internals: message only, stack stays in the node log
            log.error("erupt node error\n%s", traceback.format_exc())
            status, body = 500, {"path": environ.get("PATH_INFO"), "status": 500, "error": "erupt exception",
                                 "message": str(e)}
        if isinstance(body, str):
            payload, content_type = body.encode(), "text/plain; charset=utf-8"
        else:
            payload, content_type = json.dumps(body, ensure_ascii=False).encode(), "application/json; charset=utf-8"
        start_response(f"{status} {_REASONS.get(status, '')}", [("Content-Type", content_type),
                                                                 ("Content-Length", str(len(payload)))])
        return [payload]

    def _dispatch(self, environ):
        path, method = environ.get("PATH_INFO", ""), environ["REQUEST_METHOD"]
        if path == "/node-health":
            return 200, self.name
        if not path.startswith("/erupt-api/"):
            raise _Reply(404, "")
        # server-to-server only: an Origin header means a browser reached the node directly
        if environ.get("HTTP_ORIGIN"):
            raise _Reply(403, "")
        self._authenticate(environ)
        erupt = environ.get("HTTP_ERUPT")
        for verb, pattern, handler in self._routes:
            match = pattern.match(path)
            if verb == method and match:
                name = urllib.parse.unquote(match.group(1))
                if erupt != name or name not in self.models:
                    raise _Reply(404, "")
                parent = environ.get("HTTP_ERUPTPARENT") or _query_param(environ, "_eruptParent")
                # nesting is not supported yet, so a parent can only vouch for itself
                if parent and parent.rsplit(".", 1)[-1] != name:
                    raise _Reply(404, "")
                user = environ.get("HTTP_USER")
                _user.set(json.loads(base64.b64decode(user)) if user else None)
                model, repo = self.models[name]
                args = [urllib.parse.unquote(g) for g in match.groups()[1:]]
                return 200, handler(model, repo, environ, *args)
        raise _Reply(404, "")

    def _authenticate(self, environ):
        """A signed call must verify, and then stands for the token; its Erupt-Enforced is trusted only then."""
        environ["erupt.enforced"] = frozenset()
        signature = environ.get("HTTP_ERUPT_SIGNATURE")
        if signature is None:
            if self.require_signature or not hmac.compare_digest(environ.get("HTTP_ACCESS_TOKEN", "").encode(), self.access_token.encode()):
                raise _Reply(403, "")
            return
        length = int(environ.get("CONTENT_LENGTH") or 0)
        body = environ["wsgi.input"].read(length) if length > 0 else b""
        environ["wsgi.input"] = io.BytesIO(body)  # handed on to the endpoint unchanged
        multipart = "multipart/form-data" in environ.get("CONTENT_TYPE", "")
        enforced = environ.get("HTTP_ERUPT_ENFORCED")
        if not _signature.verify(self.access_token, environ["REQUEST_METHOD"], _path_and_query(environ),
                                 environ.get("HTTP_ERUPT_TIMESTAMP"), enforced, environ.get("HTTP_USER"),
                                 None if multipart else body, signature, int(time.time())):
            raise _Reply(403, "")
        environ["erupt.enforced"] = frozenset(filter(None, (enforced or "").split(",")))

    # ---------------------------------------------------------------- endpoints

    def _build(self, model, repo, environ):
        return model.build_model(self._power(model, environ), current_user())

    def _table(self, model, repo, environ):
        self._require(model, environ, "query")
        return self._page(model, repo, _read_json(environ) or {})

    def _page(self, model, repo, body):
        page_index = max(int(body.get("pageIndex") or 1), 1)
        page_size = min(max(int(body.get("pageSize") or 10), 1), _MAX_PAGE_SIZE)
        query = Query(offset=(page_index - 1) * page_size, limit=page_size)
        for c in body.get("condition") or []:
            query.conditions.extend(self._conditions(model, c))
        for s in body.get("sort") or []:
            f = model.fields.get(s.get("field"))
            if f is None or not (f.sortable or f.pk):
                raise Fail(f"illegal sort field '{s.get('field')}'")
            query.sort.append((f.name, str(s.get("direction", "ASC")).upper() == "DESC"))
        # a @LinkTree table shows the rows under the picked tree keys; with dependNode, none until one is picked
        picked = body.get("linkTreeVal")
        if model.link_tree and picked is not None:
            query.conditions.append(self._condition(model.fields[model.link_tree[0]], "IN", picked))
        # a @Vis view's own filter and order, then the DataProxy's
        filters, sort = model.vis.get(body.get("vis"), ([], []))
        if not query.sort:
            query.sort = list(sort or model.order_by)
        query.filters = filters + model.filters(query.conditions)
        total, records = (0, []) if model.link_tree and model.link_tree[1] and picked is None else repo.page(query)
        rows = self._rows(model, records)
        model.hook("after_fetch", rows)
        return {"pageIndex": page_index, "pageSize": page_size, "total": total,
                "totalPage": math.ceil(total / page_size), "list": rows,
                "sort": None, "alert": None, "extraContent": None}

    @staticmethod
    def _conditions(model, c):
        f = model.fields.get(c.get("key"))
        if f is None or f.pk or not f.search:
            raise Fail(f"illegal search field '{c.get('key')}'")
        op = c.get("expression") or "EQ"
        if op not in _OPS:
            raise Fail(f"illegal operator '{op}'")
        value = c.get("value")
        if f.json:
            # a JSON value (MULTI_CHOICE) holds every value searched for, matched as "<value>" in its text
            if op not in ("EQ", "IN", "NEQ", "NOT_IN"):
                raise Fail(f"illegal operator '{op}' for {f.title}")
            like = "LIKE" if op in ("EQ", "IN") else "NOT_LIKE"
            return [Cond(f.name, like, json.dumps(str(v))) for v in (value if isinstance(value, list) else [value])]
        return [Node._condition(f, op, value)]

    @staticmethod
    def _condition(f, op, value):
        if op in ("NULL", "NOT_NULL"):
            return Cond(f.name, op)
        if f.type in ("REFERENCE_TABLE", "REFERENCE_TREE") and op not in ("EQ", "NEQ", "IN", "NOT_IN"):
            raise Fail(f"illegal operator '{op}' for a reference")
        if op in ("LIKE", "NOT_LIKE"):
            return Cond(f.name, op, str(value))
        try:
            if op == "RANGE":
                if not isinstance(value, list) or len(value) != 2:
                    raise ValueError("range needs two values")
                return Cond(f.name, op, [f.coerce(v) for v in value])
            if op in ("IN", "NOT_IN"):
                return Cond(f.name, op, [f.coerce(v) for v in (value if isinstance(value, list) else [value])])
            return Cond(f.name, op, f.coerce(value))
        except (TypeError, ValueError) as e:
            raise Fail(str(e))

    def _init_value(self, model, repo, environ):
        self._require(model, environ, "add")
        record = {name: None for name in model.fields}
        model.hook("add_behavior", record)
        return self._rows(model, [record])[0]

    def _get(self, model, repo, environ, pk):
        power = self._power(model, environ)
        if not (power["edit"] or power["viewDetails"]):
            raise _Reply(403, "")
        record = repo.get(self._pk(model, pk))
        if record is None:
            raise Fail("record not found")
        model.hook("edit_behavior", record)
        return self._rows(model, [record])[0]

    def _add(self, model, repo, environ):
        self._require(model, environ, "add")
        record = self._record(model, _read_json(environ) or {})
        model.hook("validate", record)
        model.hook("before_add", record)
        repo.add(record)
        model.hook("after_add", record)
        return _r()

    def _update(self, model, repo, environ):
        self._require(model, environ, "edit")
        body = _read_json(environ) or {}
        pk = self._pk(model, body.get(model.pk))
        if repo.get(pk) is None:
            raise Fail("record not found")
        record = self._record(model, body)
        model.hook("validate", record)
        model.hook("before_update", record)
        repo.update(pk, record)
        model.hook("after_update", record)
        return _r()

    def _delete(self, model, repo, environ):
        self._require(model, environ, "delete")
        body = _read_json(environ)
        if not isinstance(body, list):
            raise Fail("a list of ids is required")
        pks = [self._pk(model, pk) for pk in body]
        # the hooks see each record as it was; reading them costs nothing without a proxy
        records = [r for r in (repo.get(pk) for pk in pks) if r is not None] if model.proxies else []
        for record in records:
            model.hook("before_delete", record)
        repo.delete(pks)
        for record in records:
            model.hook("after_delete", record)
        return _r()

    def _invoke(self, model, repo, environ, kind, name):
        """The node's own code (erupt-cloud/PROTOCOL.md §5.5): a row operation and its form values under the
        operation code, or a field's fetched options, onchange, auto-complete or button with the form's values."""
        if kind == "operation":
            return self._operation(model, repo, environ, name)
        if kind == "operation-form":
            return _r(data=self._operation_form_value(model, name))
        f = next((f for f in model.declared if f.name == name), None)
        fn = getattr(f, _INVOKED.get(kind, ""), None) if f else None
        if fn is None:
            raise _Reply(404, "")
        body = _read_json(environ) or {}
        form = body.get("form") or {}
        if kind == "autocomplete":
            return _r(data=list(fn(form, body.get("value") or "")))
        answer = fn(form)
        if kind == "options" and f.type != "TAGS":
            # {value: label} or [(value, label)], as the choices of a field
            answer = [{"value": str(v), "label": label} for v, label in (answer.items() if isinstance(answer, dict) else answer)]
        return _r(data=answer)

    @staticmethod
    def _rows(model, records):
        """Records to browser rows. A reference stays its key: the server resolves its label, the flattened
        <field>_<label> column and the tree (erupt-cloud/PROTOCOL.md §7.3)."""
        return [{name: to_json_value(record.get(name)) for name in model.fields} for record in records]

    def _operation_of(self, model, code):
        op = model.operations.get(code)
        # a hidden operation does not exist for this user, exactly like the Java proxy filters it out
        if op is None or not op.visible(current_user()):
            raise _Reply(404 if op is None else 403, "")
        return op

    def _operation_form_value(self, model, code):
        op = self._operation_of(model, code)
        # none without a form: the server answers the browser a 404, and it opens an empty one
        return {name: None for name in op.form_model.fields} if op.form else None

    def _operation(self, model, repo, environ, code):
        op = self._operation_of(model, code)
        body = _read_json(environ) or {}
        param = None
        if op.form:
            param = self._record(op.form_model, body.get("param") or {})
        rows = []
        if op.mode != "BUTTON":
            ids = body.get("ids")
            if not isinstance(ids, list) or not ids:
                raise Fail("select at least one row")
            if op.mode == "SINGLE" and len(ids) != 1:
                raise Fail("select exactly one row")
            for pk in ids:
                record = repo.get(self._pk(model, pk))
                if record is None:
                    raise Fail(f"record '{pk}' not found")
                rows.append(record)
        result = op.fn(OperationContext(rows, param, repo, model, current_user()))
        if isinstance(result, str) and result:
            return _r(data=result)
        return _r(message="Executed successfully")

    @staticmethod
    def _pk(model, value):
        try:
            return model.fields[model.pk].coerce(value)
        except (TypeError, ValueError):
            raise Fail(f"illegal id '{value}'")

    @staticmethod
    def _record(model, body):
        record = {}
        for f in model.fields.values():
            if f.pk or not f.form:
                continue
            try:
                value = f.coerce(body.get(f.name))
            except (TypeError, ValueError) as e:
                raise Fail(f"{f.title}: {e}")
            if f.not_null and value is None:
                raise Fail(f"{f.title} cannot be empty")
            record[f.name] = value
        return record

    # ---------------------------------------------------------------- permissions (PROTOCOL.md §6.1)

    def _require(self, model, environ, right):
        if not self._power(model, environ)[right]:
            raise _Reply(403, "")

    def _power(self, model, environ):
        if "power" in environ.get("erupt.enforced", ()):
            # the server checked the user's rights and restricts the build's power itself: the model's own
            # declaration is all that is left to apply here
            return {**model.power, **_UNSUPPORTED_POWER}
        token = environ.get("HTTP_TOKEN") or ""
        key = (token, model.name)
        cached = self._power_cache.get(key)
        if cached and cached[0] > time.monotonic():
            return cached[1]
        power = {**model.power, **_UNSUPPORTED_POWER}
        try:
            remote = self._server_get("/erupt-cloud-api/erupt-power",
                                      {"nodeName": self.name, "eruptName": model.name}, {"token": token})
        except Exception as e:  # fail closed: without the server's verdict nothing is writable
            log.warning("erupt-power unavailable: %s", e)
            remote = {}
        for right in _SERVER_POWER:
            power[right] = power[right] and bool(remote.get(right))
        self._power_cache[key] = (time.monotonic() + 5, power)
        if len(self._power_cache) > 10000:
            self._power_cache.clear()
        return power

    # ---------------------------------------------------------------- server calls

    def _server_get(self, path, params, headers):
        url = next(self._server_cycle) + path + "?" + urllib.parse.urlencode(params)
        with urllib.request.urlopen(urllib.request.Request(url, headers=headers), timeout=5) as resp:
            return json.loads(resp.read() or b"null")

    def _node_info(self):
        return {"instanceId": self._instance_id, "nodeName": self.name, "accessToken": self.access_token,
                "version": f"python-{__version__}", "nodeAddress": [self.address],
                "eruptModules": [], "erupts": list(self.models), "resources": {}, "capabilities": ["invoke"]}

    def _heartbeat_loop(self):
        failing = False
        while not self._stop.is_set():
            server = next(self._server_cycle)
            try:
                req = urllib.request.Request(server + "/erupt-cloud-api/register-node", method="POST",
                                             data=json.dumps(self._node_info()).encode(),
                                             headers={"Content-Type": "application/json"})
                urllib.request.urlopen(req, timeout=10).close()
                if failing:
                    log.info("%s -> connection success", server)
                failing = False
                self._stop.wait(self.heartbeat)
            except Exception as e:
                failing = True
                log.error("%s -> register failed: %s", server, e)
                self._stop.wait(self.heartbeat / 2)

    def _deregister(self):
        form = urllib.parse.urlencode({"nodeName": self.name, "accessToken": self.access_token,
                                       "locations": self.address}).encode()
        try:
            urllib.request.urlopen(urllib.request.Request(next(self._server_cycle) + "/erupt-cloud-api/remove-instance-node",
                                                          data=form, method="POST"), timeout=5).close()
        except Exception as e:
            log.error("deregister failed: %s", e)

    def serve(self, host="0.0.0.0", port=9090):
        """Serve forever: HTTP first (the server probes /node-health while registering), then heartbeat."""
        import secrets
        self._instance_id = secrets.token_hex(3)
        self.address = (self.address or f"http://{_local_ip(self.servers[0])}:{port}").rstrip("/")
        httpd = make_server(host, port, self, server_class=_ThreadingWSGIServer, handler_class=_QuietHandler)
        threading.Thread(target=self._heartbeat_loop, name="erupt-heartbeat", daemon=True).start()
        log.info("erupt node '%s' at %s -> %s", self.name, self.address, ", ".join(self.servers))
        try:
            httpd.serve_forever()
        except KeyboardInterrupt:
            pass
        finally:
            self._stop.set()
            self._deregister()
            httpd.server_close()


class _ThreadingWSGIServer(ThreadingMixIn, WSGIServer):
    daemon_threads = True


class _QuietHandler(WSGIRequestHandler):
    def log_message(self, fmt, *args):
        log.debug(fmt, *args)


_REASONS = {200: "OK", 403: "Forbidden", 404: "Not Found", 500: "Internal Server Error"}


def _read_json(environ):
    length = int(environ.get("CONTENT_LENGTH") or 0)
    if length <= 0:
        return None
    try:
        return json.loads(environ["wsgi.input"].read(length))
    except ValueError:
        raise Fail("malformed JSON body")


def _path_and_query(environ):
    """The request target as the server signed it: the raw path below the mount point, plus the query."""
    raw = environ.get("RAW_URI") or environ.get("REQUEST_URI")
    if raw:
        mount = environ.get("SCRIPT_NAME", "")
        return raw[len(mount):] if mount and raw.startswith(mount) else raw
    query = environ.get("QUERY_STRING", "")
    return urllib.parse.quote(environ.get("PATH_INFO", ""), safe="/") + ("?" + query if query else "")


def _query_param(environ, name):
    values = urllib.parse.parse_qs(environ.get("QUERY_STRING", "")).get(name)
    return values[0] if values else None


def _local_ip(server):
    """The interface address the server would see us on."""
    host = urllib.parse.urlparse(server).hostname or "127.0.0.1"
    try:
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as s:
            s.connect((host, 80))
            return s.getsockname()[0]
    except OSError:
        return "127.0.0.1"
