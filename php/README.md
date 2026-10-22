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
`orderBy: 'views desc, id'` (applied by the node), `dataProxy:` ([DataProxy](#dataproxy)) and raw `raw:` attributes (`['layout' => ['pageSize' => 30]]`).

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

## DataProxy

Hooks around a model's reads and writes, as erupt's Java `DataProxy`. Extend `Erupt\DataProxy` and override
what you need; records and rows come by reference, change them in place. Throw `Erupt\Fail` to refuse with a
message the user sees.

```php
use Erupt\{DataProxy, Fail, Node};

final class ArticleProxy extends DataProxy
{
    public function addBehavior(array &$record): void      // the new form's values
    {
        $record['status'] = 'draft';
    }

    public function validate(array &$record): void         // before every add and update
    {
        if (str_contains($record['title'] ?? '', 'spam')) {
            throw new Fail('no spam');
        }
    }

    public function beforeFetch(array $conditions): string|array|null   // SQL ANDed to the table's WHERE, values bound
    {
        return ['owner = ?', [Node::currentUser()['uid']]];
    }

    public function afterFetch(array &$rows): void         // a table page, before it is sent
    {
        foreach ($rows as &$row) {
            $row['title'] = trim($row['title']);
        }
    }
}

#[Erupt('Article', dataProxy: ArticleProxy::class)]   // one proxy or a list, classes or instances
final class Article { /* ... */ }
```

| Hook | Runs |
|------|------|
| `searchCondition(&$condition)` | building the model: default values of the search bar |
| `beforeFetch($conditions)` | before a table page is read: SQL ANDed to its WHERE as written, `'sql'` or `['sql with ?', [values]]` (with values, each `?` is one of them); SQL repositories only, `MemoryRepository` refuses it |
| `afterFetch(&$rows)` | after a table page is read |
| `addBehavior(&$record)` | for the new record form (`init-value`) |
| `editBehavior(&$record)` | after a record is read by its key (edit form, detail view) |
| `validate(&$record)` | before an add or an update |
| `beforeAdd` / `afterAdd(&$record)` | around `Repository::add` |
| `beforeUpdate` / `afterUpdate(&$record)` | around `Repository::update`, with the submitted values |
| `beforeDelete` / `afterDelete(&$record)` | around `Repository::delete`, once per record as stored |

## Views

`raw: ['vis' => ...]` declares the extra views of `@Erupt(vis = ...)`. A view's `filter` (one SQL string or a
list, ANDed as written) and `orderBy` (as the model's `orderBy`) are applied by the node when the table is read
for that view, and kept out of the build, as Java keeps them `@Transient`; they are not in the generated
`Erupt\Types\Annotations`. A view without a `code` is addressed by its title. Like `beforeFetch`, a filter needs
a SQL repository.

```php
#[Erupt('Task', raw: ['vis' => [
    ['title' => 'Board', 'type' => 'BOARD', 'boardView' => ['groupField' => 'status'], 'filter' => 'archived = 0'],
    ['title' => 'Recent', 'type' => 'TABLE', 'orderBy' => 'created desc'],
]])]
final class Task { /* ... */ }
```

Dragging on a board, calendar or gantt view is saved by the erupt server through the node's `get` and `update`.

## Trees

`raw: ['tree' => ['id' => 'id', 'label' => 'name', 'pid' => 'parent']]` shows the model as a tree, and
`raw: ['linkTree' => ['field' => 'category']]` puts the tree of a reference field beside the table: the erupt
server builds both trees from the node's table, and the node keeps the rows under the picked tree node
(`'dependNode' => true` shows none until one is picked). `linkTree.field` must be a reference field.

## Field types and field code

Besides the inferred types, `type:` takes `TAGS`, `AUTO_COMPLETE`, `ATTACHMENT` (the erupt server stores the
upload, the node keeps its path), `HTML_EDITOR`, `MARKDOWN`, `CODE_EDITOR` (all text), `BUTTON` (form only),
and `CHECKBOX` / `TAB_TREE` with `ref:`: the picked records, stored as the JSON list of their keys. An
`array` property with `choices` is a `MULTI_CHOICE`.

A field can run its own code: `fetch`, `onchange`, `complete` and `click` name a static method of the model
class, which the erupt server calls through the node's `invoke` endpoint with the form's values:

```php
#[Erupt('Order')]
final class Order
{
    #[Field(pk: true)] public int $id;
    #[Field('Status', fetch: 'statusOptions')] public string $status;      // options, also TAGS: [...]
    #[Field('Qty', onchange: 'qtyChanged')] public int $qty;
    #[Field('City', type: 'AUTO_COMPLETE', complete: 'cities')] public string $city;
    #[Field('Total')] public float $total;
    #[Field('Recalc', type: 'BUTTON', click: 'recalc')] public ?string $recalc;
    #[Field('Tags', type: 'CHECKBOX', ref: Tag::class)] public array $tags;

    public static function statusOptions(array $form): array { return ['new' => 'New', 'paid' => 'Paid']; }
    public static function qtyChanged(array $form): array { return ['formData' => ['total' => $form['qty'] * 9], 'editExpr' => new \stdClass()]; }
    public static function cities(array $form, string $typed): array { return lookup($typed); }
    public static function recalc(array $form): array { return ['eval' => "alert('done')", 'formData' => new \stdClass()]; }
}
```

`fetch` belongs to `CHOICE` / `MULTI_CHOICE` (`value => label`) and `TAGS` (a list), `complete` to
`AUTO_COMPLETE`, `click` to `BUTTON`; `onchange` to any field. Throw `Fail` to refuse with a message.

Also: `COLOR`, `ICON`, `SIGNATURE`, `MAP`, `HIDDEN` (text), `RATE`, `SLIDER` (numbers) and `TRANSFER` (like
`CHECKBOX`). A reference table depending on another field takes
`edit: ['referenceTableType' => ['dependField' => 'province', 'dependColumn' => 'province']]`: the erupt server
keeps the picked model's rows whose `dependColumn` holds the depend field's value.

## Drills

```php
#[Erupt('Author', raw: ['drills' => [['title' => 'Books', 'link' => ['linkErupt' => 'Book', 'joinColumn' => 'author']]]])]
```

opens `Book` filtered to the rows whose `author` holds the author's `id` (`link.column`, `id` by default);
`link.linkCondition` adds SQL as written (a SQL repository then). Both models must be on the node.

## Server config and user info

`$node->config()` and `$node->groupConfig()` return the config text set for the node and its group on the erupt
server; `$node->userInfo()` the acting user's full info (roles, org, post), while a request is served.

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

- Operation code defaults to the method name; `show` names a static method instead of taking a lambda, and so
  do a field's `fetch`, `onchange`, `complete` and `click`.
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
