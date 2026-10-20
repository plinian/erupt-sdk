<?php

namespace Erupt;

/**
 * Erupt cloud node: answers the requests the erupt server forwards (handle() / run()) and registers with
 * the server from a long-running process (heartbeat()). Under php-fpm or `php -S` each request builds a
 * fresh Node, so run the heartbeat as its own process. The wire contract is erupt-cloud/PROTOCOL.md.
 */
final class Node
{
    public const VERSION = '0.1.0';

    // Features whose endpoints this SDK does not serve yet: hidden from the UI instead of failing there
    private const UNSUPPORTED_POWER = ['print' => false, 'ai' => false];

    // Rights the server decides per user; the node ANDs them onto the declared power
    private const SERVER_POWER = ['add', 'edit', 'delete', 'viewDetails', 'export', 'importable'];

    private const OPS = ['EQ', 'NEQ', 'GT', 'GTE', 'LT', 'LTE', 'LIKE', 'NOT_LIKE', 'RANGE', 'IN', 'NOT_IN', 'NULL', 'NOT_NULL'];

    private const MAX_PAGE_SIZE = 1000;

    private const ROUTES = [
        ['GET', '#^/erupt-api/build/([^/]+)$#', 'build'],
        ['POST', '#^/erupt-api/data/table/([^/]+)$#', 'table'],
        ['GET', '#^/erupt-api/data/init-value/([^/]+)$#', 'initValue'],
        ['GET', '#^/erupt-api/data/([^/]+)/([^/]+)$#', 'get'],
        ['POST', '#^/erupt-api/data/modify/([^/]+)$#', 'add'],
        ['POST', '#^/erupt-api/data/modify/([^/]+)/update$#', 'update'],
        ['POST', '#^/erupt-api/data/modify/([^/]+)/delete$#', 'delete'],
        ['POST', '#^/erupt-api/invoke/([^/]+)/([^/]+)/([^/]+)$#', 'invoke'],
    ];

    private static ?array $user = null;

    /** @var list<string> */
    private readonly array $servers;
    /** @var array<string, array{0: Model, 1: Repository}> */
    private array $models = [];
    private array $powerCache = [];
    /** @var list<string> checks the server ran for the request being served, from a verified Erupt-Enforced */
    private array $enforced = [];
    private int $nextServer = 0;
    private bool $stopping = false;
    private string $instanceId;

    /** @param string|list<string> $servers erupt server addresses, round-robined */
    public function __construct(
        public readonly string $name,
        private readonly string $accessToken,
        string|array $servers,
        private ?string $address = null,
        private readonly int $heartbeatSeconds = 15,
        // refuse server calls without a valid Erupt-Signature, so the plain access token alone no longer passes
        private readonly bool $requireSignature = false,
    ) {
        if ($accessToken === '') {
            throw new \InvalidArgumentException('access token is required');
        }
        $this->servers = array_map(fn($s) => rtrim($s, '/'), (array) $servers);
        $this->instanceId = bin2hex(random_bytes(3));
    }

    /** The acting user of the request being served: ['uid', 'account', 'name', 'tenantId']. */
    public static function currentUser(): ?array
    {
        return self::$user;
    }

    /** @param class-string $class an #[Erupt] class with a primary key */
    public function register(string $class, Repository $repository): self
    {
        $model = Model::of($class);
        if (isset($this->models[$model->name])) {
            throw new \InvalidArgumentException("erupt '$model->name' registered twice");
        }
        if ($model->pk === null) {
            throw new \InvalidArgumentException("$model->name has no #[Field(pk: true)]; only an operation form may omit it");
        }
        $repository->bind($model);
        $this->models[$model->name] = [$model, $repository];
        return $this;
    }

    // ---------------------------------------------------------------- serving

    /** Serve the current PHP SAPI request (php-fpm, `php -S`): read the globals, emit the response. */
    public function run(): void
    {
        $headers = function_exists('getallheaders') ? getallheaders() : [];
        if (!$headers) {
            foreach ($_SERVER as $key => $value) {
                if (str_starts_with($key, 'HTTP_')) {
                    $headers[str_replace('_', '-', substr($key, 5))] = $value;
                }
            }
        }
        $target = $_SERVER['REQUEST_URI'] ?? '/';
        $response = $this->handle($_SERVER['REQUEST_METHOD'] ?? 'GET', parse_url($target, PHP_URL_PATH) ?: '/',
            $headers, (string) file_get_contents('php://input'), $_GET, $target);
        http_response_code($response->status);
        header('Content-Type: ' . $response->contentType);
        echo $response->body;
    }

    /**
     * Framework-neutral entry: one forwarded request in, one Response out.
     *
     * @param array<string, string> $headers any case
     * @param array<string, mixed> $query parsed query string
     * @param ?string $target the raw request target (path and query, as received below the mount point) a signed
     *                        call is verified against; defaults to $path plus the re-encoded $query
     */
    public function handle(string $method, string $path, array $headers, string $body = '', array $query = [], ?string $target = null): Response
    {
        $headers = array_change_key_case($headers, CASE_LOWER);
        $target ??= $path . ($query === [] ? '' : '?' . http_build_query($query));
        try {
            [$status, $payload] = $this->dispatch(strtoupper($method), $path, $headers, $body, $query, $target);
        } catch (Reply $reply) {
            [$status, $payload] = [$reply->status, ''];
        } catch (Fail $e) {
            [$status, $payload] = [200, self::r(false, $e->getMessage())];
        } catch (\Throwable $e) { // never leak internals: message only, the stack stays in the node log
            error_log("erupt node error: $e");
            [$status, $payload] = [500, ['path' => $path, 'status' => 500, 'error' => 'erupt exception', 'message' => $e->getMessage()]];
        } finally {
            self::$user = null;
            $this->enforced = [];
        }
        return is_string($payload)
            ? new Response($status, 'text/plain; charset=utf-8', $payload)
            : new Response($status, 'application/json; charset=utf-8', Json::encode($payload));
    }

    private function dispatch(string $method, string $path, array $headers, string $body, array $query, string $target): array
    {
        if ($path === '/node-health') {
            return [200, $this->name];
        }
        if (!str_starts_with($path, '/erupt-api/')) {
            throw new Reply(404);
        }
        // server-to-server only: an Origin header means a browser reached the node directly
        if (($headers['origin'] ?? '') !== '') {
            throw new Reply(403);
        }
        $this->authenticate($method, $headers, $body, $target);
        $erupt = $headers['erupt'] ?? null;
        foreach (self::ROUTES as [$verb, $pattern, $handler]) {
            if ($verb !== $method || !preg_match($pattern, $path, $m)) {
                continue;
            }
            $name = rawurldecode($m[1]);
            if ($erupt !== $name || !isset($this->models[$name])) {
                throw new Reply(404);
            }
            $parent = ($headers['eruptparent'] ?? '') ?: ($query['_eruptParent'] ?? '');
            // nesting is not supported yet, so a parent can only vouch for itself
            if (is_string($parent) && $parent !== '' && substr(strrchr(".$parent", '.'), 1) !== $name) {
                throw new Reply(404);
            }
            $user = $headers['user'] ?? '';
            self::$user = $user === '' ? null : json_decode((string) base64_decode($user, true), true);
            [$model, $repo] = $this->models[$name];
            $args = array_map('rawurldecode', array_slice($m, 2));
            return [200, $this->$handler($model, $repo, new Request($headers, $body), ...$args)];
        }
        throw new Reply(404);
    }

    /** A signed call must verify, and then stands for the token; its Erupt-Enforced is trusted only then. */
    private function authenticate(string $method, array $headers, string $body, string $target): void
    {
        $signature = $headers[strtolower(Signature::HEADER_SIGNATURE)] ?? null;
        if ($signature === null) {
            if ($this->requireSignature || !hash_equals($this->accessToken, (string) ($headers['access-token'] ?? ''))) {
                throw new Reply(403);
            }
            return;
        }
        $multipart = str_contains((string) ($headers['content-type'] ?? ''), 'multipart/form-data');
        $enforced = $headers[strtolower(Signature::HEADER_ENFORCED)] ?? null;
        if (!Signature::verify($this->accessToken, $method, $target, $headers[strtolower(Signature::HEADER_TIMESTAMP)] ?? null,
            $enforced, $headers['user'] ?? null, $multipart ? null : $body, (string) $signature, time())) {
            throw new Reply(403);
        }
        $this->enforced = array_values(array_filter(explode(',', (string) $enforced)));
    }

    // ---------------------------------------------------------------- endpoints

    private function build(Model $model, Repository $repo, Request $request): array
    {
        return $model->buildModel($this->power($model, $request), self::$user);
    }

    private function table(Model $model, Repository $repo, Request $request): array
    {
        $this->requirePower($model, $request, 'query');
        return $this->page($model, $repo, $request->object());
    }

    private function page(Model $model, Repository $repo, array $body): array
    {
        $pageIndex = max((int) (($body['pageIndex'] ?? null) ?: 1), 1);
        $pageSize = min(max((int) (($body['pageSize'] ?? null) ?: 10), 1), self::MAX_PAGE_SIZE);
        $query = new Query([], [], ($pageIndex - 1) * $pageSize, $pageSize);
        foreach ((array) ($body['condition'] ?? []) as $c) {
            array_push($query->conditions, ...$this->conditions($model, is_array($c) ? $c : []));
        }
        foreach ((array) ($body['sort'] ?? []) as $s) {
            $f = is_array($s) && is_string($s['field'] ?? null) ? ($model->fields[$s['field']] ?? null) : null;
            if ($f === null || !($f->decl->sortable || $f->isPk())) {
                throw new Fail("illegal sort field '" . (is_array($s) ? json_encode($s['field'] ?? null) : '') . "'");
            }
            $query->sort[] = [$f->name, strtoupper((string) ($s['direction'] ?? 'ASC')) === 'DESC'];
        }
        // a @LinkTree table shows the rows under the picked tree keys; with dependNode, none until one is picked
        $picked = $body['linkTreeVal'] ?? null;
        if ($model->linkTree && $picked !== null) {
            $query->conditions[] = $this->condition($model->fields[$model->linkTree[0]], 'IN', $picked);
        }
        // a @Vis view's own filter and order, then the DataProxy's
        [$filters, $sort] = is_string($body['vis'] ?? null) ? ($model->vis[$body['vis']] ?? [[], []]) : [[], []];
        if (!$query->sort) {
            $query->sort = $sort ?: $model->orderBy;
        }
        $query->filters = [...$filters, ...$model->filters($query->conditions)];
        [$total, $records] = $model->linkTree && $model->linkTree[1] && $picked === null ? [0, []] : $repo->page($query);
        $rows = $this->rows($model, $records);
        $model->hook('afterFetch', $rows);
        return ['pageIndex' => $pageIndex, 'pageSize' => $pageSize, 'total' => $total,
            'totalPage' => (int) ceil($total / $pageSize), 'list' => $rows,
            'sort' => null, 'alert' => null, 'extraContent' => null];
    }

    /** @return list<Cond> */
    private function conditions(Model $model, array $c): array
    {
        $key = $c['key'] ?? null;
        $f = is_string($key) ? ($model->fields[$key] ?? null) : null;
        if ($f === null || $f->isPk() || !$f->decl->search) {
            throw new Fail("illegal search field '" . (is_scalar($key) ? $key : json_encode($key)) . "'");
        }
        $op = ($c['expression'] ?? null) ?: 'EQ';
        if (!in_array($op, self::OPS, true)) {
            throw new Fail("illegal operator '" . (is_scalar($op) ? $op : json_encode($op)) . "'");
        }
        $value = $c['value'] ?? null;
        if ($f->json === null) {
            return [$this->condition($f, $op, $value)];
        }
        // a JSON value (MULTI_CHOICE) holds every value searched for, matched as "<value>" in its text
        if (!in_array($op, ['EQ', 'IN', 'NEQ', 'NOT_IN'], true)) {
            throw new Fail("illegal operator '$op' for {$f->decl->title}");
        }
        $like = in_array($op, ['EQ', 'IN'], true) ? 'LIKE' : 'NOT_LIKE';
        $values = is_array($value) && array_is_list($value) ? $value : [$value];
        return array_map(fn($v) => new Cond($f->name, $like, json_encode(is_scalar($v) ? (string) $v : json_encode($v))), $values);
    }

    private function condition(FieldSpec $f, string $op, mixed $value): Cond
    {
        if ($op === 'NULL' || $op === 'NOT_NULL') {
            return new Cond($f->name, $op);
        }
        if ($f->isReference() && !in_array($op, ['EQ', 'NEQ', 'IN', 'NOT_IN'], true)) {
            throw new Fail("illegal operator '$op' for a reference");
        }
        if ($op === 'LIKE' || $op === 'NOT_LIKE') {
            return new Cond($f->name, $op, is_scalar($value) ? (string) $value : json_encode($value));
        }
        try {
            if ($op === 'RANGE') {
                if (!is_array($value) || !array_is_list($value) || count($value) !== 2) {
                    throw new \InvalidArgumentException('range needs two values');
                }
                return new Cond($f->name, $op, array_map([$f, 'coerce'], $value));
            }
            if ($op === 'IN' || $op === 'NOT_IN') {
                $list = is_array($value) && array_is_list($value) ? $value : [$value];
                return new Cond($f->name, $op, array_map([$f, 'coerce'], $list));
            }
            return new Cond($f->name, $op, $f->coerce($value));
        } catch (\InvalidArgumentException $e) {
            throw new Fail($e->getMessage());
        }
    }

    private function initValue(Model $model, Repository $repo, Request $request): array
    {
        $this->requirePower($model, $request, 'add');
        $record = array_fill_keys(array_keys($model->fields), null);
        $model->hook('addBehavior', $record);
        return $this->rows($model, [$record])[0];
    }

    private function get(Model $model, Repository $repo, Request $request, string $pk): array
    {
        $power = $this->power($model, $request);
        if (!$power['edit'] && !$power['viewDetails']) {
            throw new Reply(403);
        }
        $record = $repo->get(self::pk($model, $pk)) ?? throw new Fail('record not found');
        $model->hook('editBehavior', $record);
        return $this->rows($model, [$record])[0];
    }

    private function add(Model $model, Repository $repo, Request $request): array
    {
        $this->requirePower($model, $request, 'add');
        $record = self::record($model, $request->object());
        $model->hook('validate', $record);
        $model->hook('beforeAdd', $record);
        $repo->add($record);
        $model->hook('afterAdd', $record);
        return self::r();
    }

    private function update(Model $model, Repository $repo, Request $request): array
    {
        $this->requirePower($model, $request, 'edit');
        $body = $request->object();
        $pk = self::pk($model, $body[$model->pk] ?? null);
        if ($repo->get($pk) === null) {
            throw new Fail('record not found');
        }
        $record = self::record($model, $body);
        $model->hook('validate', $record);
        $model->hook('beforeUpdate', $record);
        $repo->update($pk, $record);
        $model->hook('afterUpdate', $record);
        return self::r();
    }

    private function delete(Model $model, Repository $repo, Request $request): array
    {
        $this->requirePower($model, $request, 'delete');
        $body = $request->json();
        if (!is_array($body) || !array_is_list($body)) {
            throw new Fail('a list of ids is required');
        }
        $pks = array_map(fn($pk) => self::pk($model, $pk), $body);
        // the hooks see each record as it was; reading them costs nothing without a proxy
        $records = $model->proxies ? array_values(array_filter(array_map([$repo, 'get'], $pks), fn($r) => $r !== null)) : [];
        foreach ($records as &$record) {
            $model->hook('beforeDelete', $record);
        }
        $repo->delete($pks);
        foreach ($records as &$record) {
            $model->hook('afterDelete', $record);
        }
        return self::r();
    }

    /**
     * The node's own code (erupt-cloud/PROTOCOL.md §5.5): a row operation and its form values under the
     * operation code, or a field's fetched options, onchange, auto-complete or button with the form's values.
     */
    private function invoke(Model $model, Repository $repo, Request $request, string $kind, string $field): array
    {
        if ($kind === 'operation') {
            return $this->operation($model, $repo, $request, $field);
        }
        if ($kind === 'operation-form') {
            return self::r(data: $this->operationFormValue($model, $field));
        }
        $f = current(array_filter($model->declared, fn(FieldSpec $f) => $f->name === $field)) ?: null;
        $fn = $f?->code[$kind] ?? throw new Reply(404);
        $body = $request->object();
        $form = is_array($body['form'] ?? null) ? $body['form'] : [];
        if ($kind === 'autocomplete') {
            return self::r(data: array_values($fn($form, is_scalar($body['value'] ?? null) ? (string) $body['value'] : '')));
        }
        $answer = $fn($form);
        if ($kind === 'options') {
            // value => label, as the choices of a field; a TAGS answers its list of tags
            $answer = $f->type === 'TAGS' ? array_values($answer)
                : array_map(fn($v, $label) => ['value' => (string) $v, 'label' => $label], array_keys($answer), $answer);
        }
        return self::r(data: $answer);
    }

    /**
     * Records to browser rows. A reference stays its key: the server resolves its label, the flattened
     * <field>_<label> column and the tree (erupt-cloud/PROTOCOL.md §7.3).
     */
    private function rows(Model $model, array $records): array
    {
        $rows = [];
        foreach ($records as $record) {
            $row = [];
            foreach ($model->fields as $name => $f) {
                $row[$name] = $f->toJson($record[$name] ?? null);
            }
            $rows[] = $row;
        }
        return $rows;
    }

    private function operationOf(Model $model, string $code): OperationSpec
    {
        $op = $model->operations[$code] ?? throw new Reply(404);
        // a hidden operation does not exist for this user, exactly like the Java proxy filters it out
        if (!$op->visible(self::$user)) {
            throw new Reply(403);
        }
        return $op;
    }

    private function operationFormValue(Model $model, string $code): ?array
    {
        // none without a form: the server answers the browser a 404, and it opens an empty one
        $form = $this->operationOf($model, $code)->formModel();
        return $form ? array_fill_keys(array_keys($form->fields), null) : null;
    }

    private function operation(Model $model, Repository $repo, Request $request, string $code): array
    {
        $op = $this->operationOf($model, $code);
        $body = $request->object();
        $param = null;
        if ($form = $op->formModel()) {
            $param = self::record($form, is_array($body['param'] ?? null) ? $body['param'] : []);
        }
        $rows = [];
        if ($op->decl->mode !== 'BUTTON') {
            $ids = $body['ids'] ?? null;
            if (!is_array($ids) || !array_is_list($ids) || !$ids) {
                throw new Fail('select at least one row');
            }
            if ($op->decl->mode === 'SINGLE' && count($ids) !== 1) {
                throw new Fail('select exactly one row');
            }
            foreach ($ids as $pk) {
                $rows[] = $repo->get(self::pk($model, $pk)) ?? throw new Fail("record '" . (is_scalar($pk) ? $pk : '') . "' not found");
            }
        }
        $result = $op->run(new OperationContext($rows, $param, $repo, $model, self::$user));
        return is_string($result) && $result !== '' ? self::r(true, null, $result) : self::r(true, 'Executed successfully');
    }

    private static function pk(Model $model, mixed $value): int|string
    {
        try {
            return $model->fields[$model->pk]->coerce($value) ?? throw new \InvalidArgumentException();
        } catch (\InvalidArgumentException) {
            throw new Fail("illegal id '" . (is_scalar($value) ? $value : json_encode($value)) . "'");
        }
    }

    private static function record(Model $model, array $body): array
    {
        $record = [];
        foreach ($model->fields as $name => $f) {
            if ($f->isPk() || !$f->decl->form) {
                continue;
            }
            try {
                $value = $f->coerce($body[$name] ?? null);
            } catch (\InvalidArgumentException $e) {
                throw new Fail("{$f->decl->title}: {$e->getMessage()}");
            }
            if ($f->decl->notNull && $value === null) {
                throw new Fail("{$f->decl->title} cannot be empty");
            }
            $record[$name] = $value;
        }
        return $record;
    }

    private static function r(bool $success = true, ?string $message = null, mixed $data = null): array
    {
        return ['success' => $success, 'status' => $success ? 'SUCCESS' : 'ERROR', 'message' => $message, 'data' => $data, 'promptWay' => 'MESSAGE'];
    }

    // ---------------------------------------------------------------- permissions (PROTOCOL.md §6.1)

    private function requirePower(Model $model, Request $request, string $right): void
    {
        if (!$this->power($model, $request)[$right]) {
            throw new Reply(403);
        }
    }

    /** Declared power AND the server's verdict for the session; cached for this Node's lifetime (one request under php-fpm). */
    private function power(Model $model, Request $request): array
    {
        if (in_array('power', $this->enforced, true)) {
            // the server checked the user's rights and restricts the build's power itself: the model's own
            // declaration is all that is left to apply here
            return array_merge($model->power, self::UNSUPPORTED_POWER);
        }
        $token = (string) ($request->headers['token'] ?? '');
        $key = $token . "\0" . $model->name;
        if (isset($this->powerCache[$key]) && $this->powerCache[$key][0] > microtime(true)) {
            return $this->powerCache[$key][1];
        }
        $power = array_merge($model->power, self::UNSUPPORTED_POWER);
        try {
            [$status, $body] = Http::request('GET', $this->server() . '/erupt-cloud-api/erupt-power?'
                . http_build_query(['nodeName' => $this->name, 'eruptName' => $model->name]), ['token' => $token]);
            $remote = $status === 200 ? json_decode($body, true) : null;
            if (!is_array($remote)) {
                throw new \RuntimeException("erupt-power answered $status");
            }
        } catch (\Throwable $e) { // fail closed: without the server's verdict nothing is writable
            error_log("erupt-power unavailable: {$e->getMessage()}");
            $remote = [];
        }
        foreach (self::SERVER_POWER as $right) {
            $power[$right] = $power[$right] && !empty($remote[$right]);
        }
        if (count($this->powerCache) > 10000) {
            $this->powerCache = [];
        }
        $this->powerCache[$key] = [microtime(true) + 5, $power];
        return $power;
    }

    // ---------------------------------------------------------------- registration

    private function server(): string
    {
        return $this->servers[$this->nextServer++ % count($this->servers)];
    }

    /** The address the server should call this node on; auto-detected from $port when not configured. */
    public function address(?int $port = null): string
    {
        if ($this->address === null) {
            if ($port === null) {
                throw new \InvalidArgumentException('pass the port, or configure the node address');
            }
            $this->address = self::nodeAddress(self::localIp($this->servers[0]), $port);
        }
        return rtrim($this->address, '/');
    }

    /** `http://ip:port`, with an IPv6 address in brackets as a URL requires. */
    public static function nodeAddress(string $ip, int $port): string
    {
        return 'http://' . (str_contains($ip, ':') ? "[$ip]" : $ip) . ":$port";
    }

    /** The interface address the server would see us on, preferring IPv4 ("localhost" may resolve to ::1 first). */
    public static function localIp(string $server): string
    {
        $host = trim((string) (parse_url($server, PHP_URL_HOST) ?: '127.0.0.1'), '[]');
        $targets = filter_var($host, FILTER_VALIDATE_IP) ? [$host] : (gethostbynamel($host) ?: []);
        usort($targets, fn($a, $b) => (int) str_contains($a, ':') <=> (int) str_contains($b, ':'));
        foreach ($targets as $ip) {
            $socket = @stream_socket_client('udp://' . (str_contains($ip, ':') ? "[$ip]" : $ip) . ':80', $errno, $error, 1);
            if ($socket === false) {
                continue;
            }
            $name = (string) stream_socket_get_name($socket, false);
            fclose($socket);
            $local = trim(substr($name, 0, (int) strrpos($name, ':')), '[]');
            if (filter_var($local, FILTER_VALIDATE_IP)) {
                return $local;
            }
        }
        return '127.0.0.1';
    }

    /** One registration call; the server probes /node-health first, so the HTTP side must already be up. */
    public function registerOnce(?int $port = null): bool
    {
        $server = $this->server();
        $info = ['instanceId' => $this->instanceId, 'nodeName' => $this->name, 'accessToken' => $this->accessToken,
            'version' => 'php-' . self::VERSION, 'nodeAddress' => [$this->address($port)], 'eruptModules' => [],
            'erupts' => array_keys($this->models), 'resources' => new \stdClass(), 'capabilities' => ['invoke']];
        try {
            [$status] = Http::request('POST', "$server/erupt-cloud-api/register-node", ['Content-Type' => 'application/json'], Json::encode($info), 10);
            if ($status >= 200 && $status < 300) {
                return true;
            }
            error_log("$server -> register failed: HTTP $status");
        } catch (\Throwable $e) {
            error_log("$server -> register failed: {$e->getMessage()}");
        }
        return false;
    }

    /**
     * Register every heartbeat until SIGINT / SIGTERM (or stop()), then deregister. Run it as a long-lived
     * CLI process next to php-fpm / `php -S`; without ext-pcntl a signal ends the process without deregistering.
     */
    public function heartbeat(?int $port = null): void
    {
        $address = $this->address($port);
        if (function_exists('pcntl_async_signals')) {
            pcntl_async_signals(true);
            pcntl_signal(SIGINT, fn() => $this->stop());
            pcntl_signal(SIGTERM, fn() => $this->stop());
        }
        error_log("erupt node '$this->name' at $address -> " . implode(', ', $this->servers));
        $failing = false;
        while (!$this->stopping) {
            $ok = $this->registerOnce();
            if ($ok && $failing) {
                error_log('erupt: connection success');
            }
            $failing = !$ok;
            $until = microtime(true) + ($ok ? $this->heartbeatSeconds : $this->heartbeatSeconds / 2);
            while (!$this->stopping && microtime(true) < $until) {
                usleep(100000);
            }
        }
        $this->deregister();
    }

    public function stop(): void
    {
        $this->stopping = true;
    }

    /** Tell the server this instance is gone, so it stops routing to it at once. */
    public function deregister(): void
    {
        try {
            Http::request('POST', $this->server() . '/erupt-cloud-api/remove-instance-node', ['Content-Type' => 'application/x-www-form-urlencoded'],
                http_build_query(['nodeName' => $this->name, 'accessToken' => $this->accessToken, 'locations' => $this->address]));
        } catch (\Throwable $e) {
            error_log("deregister failed: {$e->getMessage()}");
        }
    }
}
