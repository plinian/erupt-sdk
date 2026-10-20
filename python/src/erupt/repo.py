"""Storage adapters. A repository only sees field names the node has already checked against the model,
so it may use them as identifiers; values always travel as parameters."""
import datetime
import decimal
import json
import sqlite3
import sys
import threading
from dataclasses import dataclass, field

from .model import _parse_datetime


@dataclass
class Cond:
    field: str
    op: str  # EQ NEQ GT GTE LT LTE LIKE NOT_LIKE RANGE IN NOT_IN NULL NOT_NULL
    value: object = None


@dataclass
class Query:
    conditions: list = field(default_factory=list)
    sort: list = field(default_factory=list)  # [(field, descending)]
    filters: list = field(default_factory=list)  # [(sql, params)] of a @Vis view and DataProxy.before_fetch, ANDed as written
    offset: int = 0
    limit: int = 10


class Repository:
    """Implement these five methods to put an erupt model on any storage."""

    def bind(self, model):
        self.model = model

    def page(self, query):
        """Return ``(total, [record, ...])``; a record is a dict keyed by field name."""
        raise NotImplementedError

    def get(self, pk):
        raise NotImplementedError

    def add(self, record):
        raise NotImplementedError

    def update(self, pk, record):
        raise NotImplementedError

    def delete(self, pks):
        raise NotImplementedError


def _match(value, cond):
    op, expect = cond.op, cond.value
    if op == "NULL":
        return value is None
    if op == "NOT_NULL":
        return value is not None
    if value is None:
        return False
    if op == "EQ":
        return value == expect
    if op == "NEQ":
        return value != expect
    text = json.dumps(value) if isinstance(value, (list, dict)) else str(value)  # a JSON value is matched as its text
    if op == "LIKE":
        return str(expect).lower() in text.lower()
    if op == "NOT_LIKE":
        return str(expect).lower() not in text.lower()
    if op == "IN":
        return value in expect
    if op == "NOT_IN":
        return value not in expect
    if op == "RANGE":
        return expect[0] <= value <= expect[1]
    return {"GT": value > expect, "GTE": value >= expect, "LT": value < expect, "LTE": value <= expect}[op]


class MemoryRepository(Repository):

    def __init__(self, records=()):
        self._lock = threading.Lock()
        self._rows = {}
        self._seq = 0
        self._pending = list(records)

    def bind(self, model):
        super().bind(model)
        for record in self._pending:
            self.add(record)

    def page(self, query):
        if query.filters:
            raise ValueError("MemoryRepository cannot apply SQL filters (a view filter, before_fetch)")
        with self._lock:
            rows = [r for r in self._rows.values() if all(_match(r.get(c.field), c) for c in query.conditions)]
        for name, desc in reversed(query.sort):
            rows.sort(key=lambda r: (r.get(name) is None, r.get(name)), reverse=desc)
        return len(rows), [dict(r) for r in rows[query.offset:query.offset + query.limit]]

    def get(self, pk):
        row = self._rows.get(pk)
        return dict(row) if row else None

    def add(self, record):
        with self._lock:
            self._seq += 1
            record = {**record, self.model.pk: self._seq}
            self._rows[self._seq] = record

    def update(self, pk, record):
        with self._lock:
            if pk in self._rows:
                self._rows[pk].update(record)

    def delete(self, pks):
        with self._lock:
            for pk in pks:
                self._rows.pop(pk, None)


_SQL_OPS = {"EQ": "=", "NEQ": "<>", "GT": ">", "GTE": ">=", "LT": "<", "LTE": "<="}

_SQLITE_TYPES = {"NUMBER": "NUMERIC", "BOOLEAN": "INTEGER", "DATE": "DATE", "DATE_TIME": "TIMESTAMP",
                 "REFERENCE_TABLE": "INTEGER", "REFERENCE_TREE": "INTEGER"}

# dialect -> (identifier quotes, paging); LIMIT/OFFSET or the SQL:2008 OFFSET ... FETCH form
_DIALECTS = {
    "sqlite": ('"', '"', "limit"), "postgres": ('"', '"', "limit"), "mysql": ("`", "`", "limit"),
    "mssql": ("[", "]", "fetch"), "oracle": ('"', '"', "fetch"),
}

_PARAMSTYLES = ("qmark", "format", "pyformat", "numeric", "named")


class _Sql:
    """SQL text with ``\0`` markers for parameters, rendered once the driver's paramstyle is known."""

    def __init__(self):
        self.parts, self.params = [], []

    def p(self, value):
        self.params.append(value)
        return "\0"

    def render(self, sql, paramstyle):
        pieces = sql.split("\0")
        marks = {"qmark": lambda i: "?", "format": lambda i: "%s", "pyformat": lambda i: f"%(p{i})s",
                 "numeric": lambda i: f":{i + 1}", "named": lambda i: f":p{i}"}[paramstyle]
        text = pieces[0] + "".join(marks(i) + piece for i, piece in enumerate(pieces[1:]))
        if paramstyle in ("pyformat", "named"):
            return text, {f"p{i}": v for i, v in enumerate(self.params)}
        return text, list(self.params)


class SqlRepository(Repository):
    """A table behind any DB-API 2.0 (PEP 249) driver: sqlite3, psycopg, PyMySQL / mysqlclient, oracledb,
    pyodbc / pymssql. ``connect()`` returns a connection; ``release(conn)`` hands it back after every call
    (``conn.close()`` by default, ``pool.putconn`` for a pool). The driver's ``paramstyle`` is detected from
    its module unless given. Column names are the model's field names (quoted, so case sensitive on
    PostgreSQL and Oracle); every value is a bound parameter. Without a sort, rows come back by primary key
    ascending. ``auto_create`` only applies to SQLite: create production tables yourself."""

    def __init__(self, connect, table, *, dialect="sqlite", paramstyle=None, release=None, auto_create=False):
        if dialect not in _DIALECTS:
            raise ValueError(f"dialect must be one of {', '.join(_DIALECTS)}")
        if paramstyle is not None and paramstyle not in _PARAMSTYLES:
            raise ValueError(f"paramstyle must be one of {', '.join(_PARAMSTYLES)}")
        if not table.replace("_", "a").isalnum() or table[0].isdigit():
            raise ValueError(f"illegal table name '{table}'")
        self.connect, self.table, self.dialect = connect, table, dialect
        self.paramstyle, self.auto_create = paramstyle, auto_create
        self.release = release or (lambda conn: conn.close())

    def _q(self, identifier):
        open_, close, _ = _DIALECTS[self.dialect]
        return open_ + identifier.replace(close, close + close) + close

    # ------------------------------------------------------------------ execution

    def _run(self, sql, write=False):
        """Execute a ``_Sql`` (text, builder) and return rows as dicts keyed by field name."""
        text, builder = sql
        conn = self.connect()
        try:
            style = self.paramstyle or _driver_paramstyle(conn)
            rendered, params = builder.render(text, style)
            cursor = conn.cursor()
            try:
                cursor.execute(rendered, params)
                rows = [] if write or cursor.description is None else self._rows(cursor)
            finally:
                cursor.close()
            conn.commit()  # also ends the read transaction PostgreSQL opens for a SELECT
            return rows
        except Exception:
            _rollback(conn)
            raise
        finally:
            self.release(conn)

    def _rows(self, cursor):
        # match columns to fields case-insensitively: Oracle and unquoted DDL may report upper case
        names = {name.lower(): name for name in self.model.fields}
        columns = [names.get(d[0].lower(), d[0]) for d in cursor.description]
        return [self._record(dict(zip(columns, row))) for row in cursor.fetchall()]

    def _record(self, record):
        for f in self.model.fields.values():
            value = record.get(f.name)
            if value is None:
                continue
            if f.json:
                record[f.name] = json.loads(value) if isinstance(value, str) else value
            elif f.type == "BOOLEAN":
                record[f.name] = bool(value)
            elif isinstance(value, decimal.Decimal):  # NUMERIC columns of PostgreSQL / MySQL / Oracle
                record[f.name] = int(value) if value == value.to_integral_value() else float(value)
            elif f.type in ("DATE", "DATE_TIME") and isinstance(value, str):
                value = _parse_datetime(value)
                record[f.name] = value.date() if f.type == "DATE" else value
            elif f.type == "DATE" and isinstance(value, datetime.datetime):
                record[f.name] = value.date()
        return record

    # ------------------------------------------------------------------ Repository

    def bind(self, model):
        super().bind(model)
        if not (self.auto_create and self.dialect == "sqlite"):
            return
        cols = []
        for f in model.fields.values():
            if f.pk:
                cols.append(f"{self._q(f.name)} INTEGER PRIMARY KEY AUTOINCREMENT")
            else:
                cols.append(f"{self._q(f.name)} {_SQLITE_TYPES.get(f.type, 'TEXT')}")
        self._run((f"CREATE TABLE IF NOT EXISTS {self._q(self.table)} ({', '.join(cols)})", _Sql()), write=True)

    def _where(self, query, b):
        clauses = []
        for sql, params in query.filters:
            # the developer's own SQL, as written; with params, each '?' is one of them, bound like every other value
            pieces = sql.split("?") if params else [sql]
            if len(pieces) - 1 != len(params):
                raise ValueError(f"filter: {len(pieces) - 1} '?' for {len(params)} params in {sql!r}")
            clauses.append("(" + pieces[0] + "".join(b.p(v) + piece for v, piece in zip(params, pieces[1:])) + ")")
        conditions = query.conditions
        for c in conditions:
            col = self._q(c.field)
            if c.op in _SQL_OPS:
                clauses.append(f"{col} {_SQL_OPS[c.op]} {b.p(c.value)}")
            elif c.op in ("LIKE", "NOT_LIKE"):
                # '!' rather than a backslash: MySQL reads a backslash inside a string literal as an escape itself
                escaped = str(c.value).replace("!", "!!").replace("%", "!%").replace("_", "!_")
                clauses.append(f"{col} {'NOT ' if c.op == 'NOT_LIKE' else ''}LIKE {b.p(f'%{escaped}%')} ESCAPE '!'")
            elif c.op == "RANGE":
                clauses.append(f"{col} BETWEEN {b.p(c.value[0])} AND {b.p(c.value[1])}")
            elif c.op in ("IN", "NOT_IN"):
                if not c.value:
                    clauses.append("1=0" if c.op == "IN" else "1=1")
                    continue
                clauses.append(f"{col} {'NOT ' if c.op == 'NOT_IN' else ''}IN ({', '.join(b.p(v) for v in c.value)})")
            elif c.op in ("NULL", "NOT_NULL"):
                clauses.append(f"{col} IS {'NOT ' if c.op == 'NOT_NULL' else ''}NULL")
        return (" WHERE " + " AND ".join(clauses)) if clauses else ""

    def page(self, query):
        table = self._q(self.table)
        b = _Sql()
        where = self._where(query, b)
        total = next(iter(self._run((f"SELECT COUNT(*) AS n FROM {table}{where}", b))[0].values()))
        b = _Sql()
        where = self._where(query, b)
        order = ", ".join(f"{self._q(n)} {'DESC' if d else 'ASC'}" for n, d in query.sort) or self._q(self.model.pk) + " ASC"
        if _DIALECTS[self.dialect][2] == "limit":
            paging = f"LIMIT {b.p(query.limit)} OFFSET {b.p(query.offset)}"
        else:
            paging = f"OFFSET {b.p(query.offset)} ROWS FETCH NEXT {b.p(query.limit)} ROWS ONLY"
        return total, self._run((f"SELECT * FROM {table}{where} ORDER BY {order} {paging}", b))

    def get(self, pk):
        b = _Sql()
        rows = self._run((f"SELECT * FROM {self._q(self.table)} WHERE {self._q(self.model.pk)} = {b.p(pk)}", b))
        return rows[0] if rows else None

    def _store(self, record):
        """Values as columns hold them: a JSON value as its text."""
        return {k: json.dumps(v) if self.model.fields[k].json and v is not None else v
                for k, v in record.items() if k != self.model.pk}

    def add(self, record):
        record = self._store(record)
        b = _Sql()
        values = ", ".join(b.p(v) for v in record.values())
        self._run((f"INSERT INTO {self._q(self.table)} ({', '.join(self._q(k) for k in record)}) VALUES ({values})", b), write=True)

    def update(self, pk, record):
        record = self._store(record)
        if not record:
            return
        b = _Sql()
        sets = ", ".join(f"{self._q(k)} = {b.p(v)}" for k, v in record.items())
        self._run((f"UPDATE {self._q(self.table)} SET {sets} WHERE {self._q(self.model.pk)} = {b.p(pk)}", b), write=True)

    def delete(self, pks):
        if not pks:
            return
        b = _Sql()
        marks = ", ".join(b.p(pk) for pk in pks)
        self._run((f"DELETE FROM {self._q(self.table)} WHERE {self._q(self.model.pk)} IN ({marks})", b), write=True)


def _driver_paramstyle(conn):
    module = sys.modules.get(type(conn).__module__.split(".")[0])
    style = getattr(module, "paramstyle", None)
    if style not in _PARAMSTYLES:
        raise ValueError(f"cannot detect the paramstyle of {type(conn).__module__}; pass paramstyle=")
    return style


def _rollback(conn):
    try:
        conn.rollback()
    except Exception:  # the original error matters more than a failed rollback
        pass


class SqliteRepository(SqlRepository):
    """SQLite table, created on first use when missing. One connection per thread, kept open."""

    def __init__(self, path, table):
        self.path = path
        self._local = threading.local()
        super().__init__(self._thread_conn, table, dialect="sqlite", paramstyle="qmark",
                         release=lambda conn: None, auto_create=True)

    def _thread_conn(self):
        if not hasattr(self._local, "conn"):
            self._local.conn = sqlite3.connect(self.path, detect_types=sqlite3.PARSE_DECLTYPES)
        return self._local.conn


sqlite3.register_adapter(datetime.datetime, lambda v: v.isoformat(" "))
sqlite3.register_adapter(datetime.date, lambda v: v.isoformat())
sqlite3.register_converter("TIMESTAMP", lambda b: datetime.datetime.fromisoformat(b.decode()))
sqlite3.register_converter("DATE", lambda b: datetime.date.fromisoformat(b.decode()))
