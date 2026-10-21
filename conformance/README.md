# Conformance

One set of HTTP checks that every language's node SDK must pass. `run.py` plays the erupt server
(registration with a `/node-health` probe, `erupt-power` per session token, deregistration) and sends the
requests the real server would forward.

```bash
python conformance/run.py -- python3 python/examples/conformance.py
(cd go && go build -o /tmp/erupt-go-conformance ./examples/conformance) && python conformance/run.py -- /tmp/erupt-go-conformance
python conformance/run.py -- node ts/dist/examples/conformance.js
python conformance/run.py -- php php/examples/conformance.php
(cd rust && cargo build --release --example conformance) && python conformance/run.py -- rust/target/release/examples/conformance
python conformance/run.py -- ruby ruby/examples/conformance.rb
(cd swift && swift build -c release --product Conformance) && python conformance/run.py -- swift/.build/release/Conformance
mvn -B -q -f jvm/examples/pom.xml -pl conformance package && python conformance/run.py -- java -jar jvm/examples/conformance/target/erupt-conformance.jar
(cd dotnet && dotnet build -c Release) && python conformance/run.py -- dotnet dotnet/examples/Conformance/bin/Release/net8.0/Conformance.dll
```

The command starts the fixture below, reading `ERUPT_ACCESS_TOKEN`, `ERUPT_SERVER` and `PORT` from the
environment, listening on `127.0.0.1:$PORT`, registering `nodeAddress` `http://127.0.0.1:$PORT`, and
deregistering on SIGINT. Set `CONFORMANCE_TRACE=1` for stack traces.

Shared repository rules (not all reachable over HTTP, so each SDK also unit-tests them): without a sort,
rows come back by primary key ascending; SQL repositories bind every value, quote whitelisted identifiers
and escape LIKE with `ESCAPE '!'`, which every database reads the same way.

Server calls are checked both ways: with the plain `Access-Token`, and signed (`Erupt-Signature`, no token)
the way erupt 2.3.x servers call. A node verifies the signature with the algorithm of
[`signature-vectors.json`](signature-vectors.json) (computed by the Java reference; every SDK unit-tests
against it), trusts `Erupt-Enforced` only under a valid signature, and skips the `erupt-power` callback when it
lists `power`. A reference travels as its key: the server resolves labels, flattened columns and trees, so a
node answers 404 for `reference-tree`.

## Fixture

Node name `conformance`. Every repository is in memory (PHP: a temporary SQLite file, since `php -S` keeps
nothing between requests).

**Category**: `id` pk; `name` Name (INPUT, search); `parent` Parent (NUMBER). Seeded in this order:
`Tech` (parent null), `Python` (parent 1), `Life` (parent null), so ids 1, 2, 3.

**PublishForm** (title "Publish Options", operation form only, not registered): `note` Note (INPUT, not null).

**Article**, default order `id desc`, fields in this order:

| Field | Title | Type | Flags |
|-------|-------|------|-------|
| `id` | | pk | |
| `title` | Title | INPUT | search, not null, sortable, raw edit `{"inputType": {"length": 64}}` |
| `status` | Status | CHOICE `draft` Draft, `published` Published | search |
| `views` | Views | NUMBER | sortable |
| `featured` | Featured | BOOLEAN | search |
| `publish_date` | Publish Date | DATE | search |
| `review_at` | Review At | DATE_TIME | |
| `body` | Body | TEXTAREA | hidden from the table |
| `category` | Category | REFERENCE_TABLE to Category, label `name` | search |
| `topic` | Topic | REFERENCE_TREE to Category, label `name`, pid `parent` | |

Operations, in this order:

| Code | Title | Mode | Other | Effect |
|------|-------|------|-------|--------|
| `publish` | Publish | MULTI | icon `fa fa-paper-plane`, form PublishForm, if_expr `item.status !== 'published'` | sets `status` to `published` on every row |
| `feature` | Feature | SINGLE | no confirm dialog | returns the script `alert('featured')` |
| `rebuild` | Rebuild | BUTTON | shown only when the user's account is `root` | none |

**Note**, power `delete` off: `id` pk; `text` Text (INPUT).
