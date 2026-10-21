# erupt-sdk (Python)

Serve Python models as an erupt admin UI. Zero dependencies, Python 3.9+.

```bash
pip install erupt-sdk
```

```python
import datetime, os
from erupt import Field, Node, SqliteRepository, erupt

@erupt("Article", order_by="id desc")
class Article:
    id: int = Field(pk=True)
    title: str = Field("Title", search=True, not_null=True, sortable=True)
    status: str = Field("Status", choices={"draft": "Draft", "published": "Published"}, search=True)
    publish_date: datetime.date = Field("Publish Date", search=True)
    body: str = Field("Body", type="TEXTAREA", table=False)

node = Node("blog", os.environ["ERUPT_ACCESS_TOKEN"], "http://erupt-server:8080")
node.register(Article, SqliteRepository("blog.db", "article"))
node.serve(port=9090)
```

1. On the erupt server create node `blog` (Node Config) and copy its access token.
2. Add a menu of type `table` with value `blog.Article`.
3. Run the node. The server must be able to reach it on `http://<node ip>:9090`; set `address=` otherwise.

The edit type follows the Python annotation (`str` INPUT, `int`/`float` NUMBER, `bool` BOOLEAN,
`date` DATE, `datetime` DATE_TIME, `choices=` CHOICE) unless `type=` is given. `view={...}` / `edit={...}`
on a field and keyword arguments on `@erupt` pass raw annotation attributes through.

## References

Annotate a field with another `@erupt` class (declared earlier, registered on the same node). The repository
stores the referenced primary key; the UI shows `label` (default `name`).

```python
@erupt("Category")
class Category:
    id: int = Field(pk=True)
    name: str = Field("Name", search=True)
    parent: int = Field("Parent Id")

class Article:
    category: Category = Field("Category", search=True)       # table picker
    topic: Category = Field("Topic", tree="parent")           # tree picker over Category.parent
```

## Row operations

```python
@erupt("Publish Options")
class PublishForm:                       # a form model needs no primary key
    publish_date: datetime.date = Field("Publish Date", not_null=True)

class Article:
    @operation("Publish", form=PublishForm, if_expr="item.status !== 'published'")
    def publish(op):                     # op.rows, op.param, op.repo, op.user
        for row in op.rows:
            op.repo.update(row["id"], {"status": "published", "publish_date": op.param["publish_date"]})
```

`mode`: `SINGLE` / `MULTI` (default) / `MULTI_ONLY` / `BUTTON`. `confirm=False` skips the dialog, a string
replaces its text. `show=lambda user: ...` hides the operation and refuses to run it. A returned string is
executed as JavaScript in the browser, so return only code you wrote.

## Storage

Storage is any `Repository` (`page`, `get`, `add`, `update`, `delete`). Shipped:

- `MemoryRepository` for tests and demos;
- `SqliteRepository(path, table)`, which creates the table;
- `SqlRepository(connect, table, dialect=..., release=..., paramstyle=...)` over any DB-API 2.0 driver.
  `dialect` (`sqlite`, `postgres`, `mysql`, `mssql`, `oracle`) decides identifier quotes and paging; the
  driver's paramstyle is detected. Create the tables yourself, with columns named like the fields.

```python
import psycopg                      # PostgreSQL
repo = SqlRepository(lambda: psycopg.connect(DSN), "article", dialect="postgres")

from psycopg_pool import ConnectionPool
pool = ConnectionPool(DSN)          # pooled: hand connections back instead of closing them
repo = SqlRepository(pool.getconn, "article", dialect="postgres", release=pool.putconn)

import pymysql                      # MySQL
repo = SqlRepository(lambda: pymysql.connect(**MYSQL), "article", dialect="mysql")
```

Without a sort, every repository returns rows by primary key ascending. `erupt.current_user()` returns the
acting user inside a repository call.

Not yet: sub-tables (TAB_TABLE_*), TPL operations, depend fields of references, tree models, file upload, Excel, i18n of messages.

## Without a registry

From the repository, without PyPI:

```bash
pip install "erupt-sdk @ git+https://github.com/erupt-io/erupt-sdk@python/v0.1.0#subdirectory=python"
```

Or copy `python/src/erupt/` into your project as the package `erupt`; it has no dependencies, keep the two
`.json` files next to the code. A copy does not update itself: when erupt changes the protocol or the annotation schema, replace the whole directory with the next release instead of merging by hand, and leave `__version__` in `node.py` untouched so the server shows which release the node runs.

## Generated code

`src/erupt/_types.py` (TypedDicts and Literals for every annotation attribute: `Edit`, `View`, `Erupt`,
`RowOperation`, `EditType`, …) is generated from the erupt annotation JSON Schema. Raw `view=` / `edit=` /
`@erupt(...)` / `@operation(...)` attributes are checked against the same schema when a model is declared,
so a misspelt key or enum value fails at import instead of silently doing nothing in the browser.

After an annotation change in erupt (regenerate there with `-Derupt.node-schema.write=true` /
`-Derupt.node-defaults.write=true`):

```bash
python tools/gen_types.py <erupt repo>/schema          # sync schemas, regenerate _types.py
python tools/gen_types.py <erupt repo>/schema --check  # CI: fail when stale
```

Tests: `PYTHONPATH=src python -m unittest discover -s tests`
