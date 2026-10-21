# erupt-sdk (PHP)

Serve PHP models as erupt admin pages. PHP 8.1+, no Composer dependencies (ext-json, ext-pdo;
ext-pdo_sqlite for SQLite, ext-pcntl to deregister on shutdown).

```bash
composer require erupt-io/erupt-sdk      # or: require 'erupt-sdk/php/autoload.php';
```

```php
use Erupt\Attribute\{Erupt, Field, Operation};
use Erupt\{Node, OperationContext, PdoRepository};

#[Erupt('Article', orderBy: 'id desc')]
final class Article
{
    #[Field(pk: true)] public int $id;
    #[Field('Title', search: true, notNull: true, sortable: true)] public string $title;
    #[Field('Status', choices: ['draft' => 'Draft', 'published' => 'Published'], search: true)] public string $status;
    #[Field('Publish Date', type: 'DATE', search: true)] public string $publish_date;
    #[Field('Body', type: 'TEXTAREA', table: false)] public string $body;
}

$node = (new Node('blog', getenv('ERUPT_ACCESS_TOKEN'), 'http://erupt-server:8080'))
    ->register(Article::class, new PdoRepository(new PDO('sqlite:blog.db'), 'article'));
```

1. On the erupt server create node `blog` (Node Config) and copy its access token.
2. Add a menu of type `table` with value `blog.Article`.
3. Serve requests and run the heartbeat (below). The server must reach the node on
   `http://<node ip>:<port>`; pass `address:` to `Node` otherwise.

## Running: two processes

Under php-fpm or `php -S` every request is a fresh process, so registration cannot live in the request
path. A node is a front controller plus one long-running heartbeat process:

```bash
php -S 0.0.0.0:9090 examples/blog/router.php     # requests: (require 'app.php')->run();
PORT=9090 php examples/blog/heartbeat.php        # registration: (require 'app.php')->heartbeat(9090);
```

`heartbeat()` registers every 15 seconds and, with ext-pcntl, deregisters on SIGINT / SIGTERM. Without a
configured `address` it detects the interface the server is reached through (IPv4 first; an IPv6 address
is bracketed).

For the same reason `MemoryRepository` only suits tests and long-running servers (RoadRunner, Swoole,
ReactPHP): under php-fpm it starts empty on every request. Use `PdoRepository` (SQLite tables are
created when missing; elsewhere create them yourself) or your own `Repository`.

## Inside a framework

`run()` serves the PHP globals. `handle(method, path, headers, body, query)` is the framework-neutral
core and returns a `Response` (status, content type, body). Laravel:

```php
Route::any('{path}', function (Illuminate\Http\Request $request) {
    $r = app(Erupt\Node::class)->handle($request->method(), '/' . $request->path(),
        array_map(fn($v) => $v[0], $request->headers->all()), $request->getContent(), $request->query());
    return response($r->body, $r->status)->header('Content-Type', $r->contentType);
})->where('path', '(erupt-api/.*|node-health)')->withoutMiddleware([
    \Illuminate\Foundation\Http\Middleware\VerifyCsrfToken::class,
]);
```

Run `$node->heartbeat($port)` from an artisan command kept alive by your process manager.

## Fields

The edit type follows the property type: `string` INPUT, `int` / `float` NUMBER, `bool` BOOLEAN,
`DateTimeInterface` DATE_TIME, another #[Erupt] class a reference; `type:` overrides it (`'DATE'`,
`'TEXTAREA'`), `choices:` makes a CHOICE. Options: `search`, `notNull`, `sortable`, `table` (column),
`form`, and raw `view:` / `edit:` attributes. #[Erupt] takes `power: ['delete' => false]`,
`orderBy: 'views desc, id'` (applied by the node) and raw `raw:` attributes (`['layout' => ['pageSize' => 30]]`).

Raw attributes are described by the generated array shapes in `Erupt\Types\Annotations` and the enums
in `Erupt\Types` (`EditType`, `RowOperationMode`, ...), and checked against the erupt annotation schema
when the model is compiled, so a misspelt key or enum value throws at startup instead of silently doing
nothing in the browser.

Records are associative arrays. Dates are stored as wall-clock strings: DATE `2026-01-05`, DATE_TIME
`2026-01-05T10:30:00.000`.

## References

```php
#[Erupt('Category')]
final class Category
{
    #[Field(pk: true)] public int $id;
    #[Field('Name', search: true)] public string $name;
    #[Field('Parent Id')] public ?int $parent;
}

    #[Field('Category', search: true)] public ?Category $category;   // table picker
    #[Field('Topic', tree: 'parent')] public ?Category $topic;       // tree picker over Category.parent
```

The repository stores the referenced primary key; the UI shows `label:` (default `name`). Register the
referenced model on the same node.

## Row operations

```php
#[Erupt('Publish Options')]
final class PublishForm                  // a form model needs no primary key and is not registered
{
    #[Field('Publish Date', type: 'DATE', notNull: true)] public string $publish_date;
}

    #[Operation('Publish', form: PublishForm::class, ifExpr: "item.status !== 'published'")]
    public static function publish(OperationContext $op): void   // $op->rows, ->param, ->repo, ->user
    {
        foreach ($op->rows as $row) {
            $op->repo->update($row['id'], ['status' => 'published', 'publish_date' => $op->param['publish_date']]);
        }
    }
```

`mode:` `SINGLE` / `MULTI` (default) / `MULTI_ONLY` / `BUTTON`. `confirm: false` skips the dialog, a
string replaces its text. `show: 'isRoot'` names a static method taking the user (`?array`) that hides
the operation and refuses to run it. A returned string is executed as JavaScript in the browser, so
return only code you wrote. Throw `Erupt\Fail` to show the user a message; any other exception answers 500.
`Node::currentUser()` returns the acting user anywhere in a request.

## Without a registry

Without Packagist, point Composer at the read-only split repository:

```json
{
  "repositories": [{ "type": "vcs", "url": "https://github.com/erupt-io/erupt-sdk-php" }],
  "require": { "erupt-io/erupt-sdk": "^0.1" }
}
```

Or copy `php/` (`autoload.php`, `src/` and `resources/`) into your project and `require` its `autoload.php`.
A copy does not update itself: when erupt changes the protocol or the annotation schema, replace the whole directory with the next release instead of merging by hand, and leave `Node::VERSION` untouched so the server shows which release the node runs.

## Differences from the Python SDK

- Operation code defaults to the method name; `show` names a static method instead of taking a lambda.
- Dates are stored as wall-clock strings, not date objects.
- `PdoRepository` sorts nulls last (first when descending) on every database and LIKE-escapes with `!`.
- A request body that is not a JSON object counts as empty instead of answering 500.

## Generated code

`src/Types/` (enums and annotation array shapes) and `resources/` (schema and field templates) come
from the erupt schema:

```bash
php tools/gen-types.php ../schema          # sync, regenerate
php tools/gen-types.php ../schema --check  # CI: exit 1 when stale
```

Tests: `php tests/run.php`. Conformance (from the repository root):
`python conformance/run.py -- php php/examples/conformance.php`.
