<?php

namespace Erupt;

/**
 * A table behind PDO. Identifiers come from the model (already whitelisted) and are quoted for the
 * driver; every value is a bound parameter; LIKE wildcards are escaped. With $autoCreate the table is
 * created on SQLite when missing; on other databases create it yourself. Dates are stored as text
 * (`2026-01-05`, `2026-01-05T10:30:00.000`), booleans as 0 / 1. Paging uses LIMIT / OFFSET.
 */
final class PdoRepository implements Repository
{
    private const SQL_OPS = ['EQ' => '=', 'NEQ' => '<>', 'GT' => '>', 'GTE' => '>=', 'LT' => '<', 'LTE' => '<='];
    private const SQLITE_TYPES = ['NUMBER' => 'NUMERIC', 'BOOLEAN' => 'INTEGER', 'REFERENCE_TABLE' => 'INTEGER', 'REFERENCE_TREE' => 'INTEGER'];

    private const TYPED = ['BOOLEAN', 'NUMBER', 'DATE', 'DATE_TIME'];

    private Model $model;

    private ?string $driver = null;

    public function __construct(private readonly \PDO $pdo, private readonly string $table, private readonly bool $autoCreate = true)
    {
        if (!preg_match('/^[A-Za-z_][A-Za-z0-9_]*$/', $table)) {
            throw new \InvalidArgumentException("illegal table name '$table'");
        }
        // the connection belongs to the application: its error mode is left alone and every call is checked
    }

    public function bind(Model $model): void
    {
        $this->model = $model;
        if (!$this->autoCreate || $this->pdo->getAttribute(\PDO::ATTR_DRIVER_NAME) !== 'sqlite') {
            return;
        }
        $columns = [];
        foreach ($model->fields as $f) {
            $columns[] = $this->q($f->name) . ' ' . ($f->isPk() ? 'INTEGER PRIMARY KEY AUTOINCREMENT' : (self::SQLITE_TYPES[$f->type] ?? 'TEXT'));
        }
        $this->checked($this->pdo->exec('CREATE TABLE IF NOT EXISTS ' . $this->q($this->table) . ' (' . implode(', ', $columns) . ')'), $this->pdo);
    }

    private function q(string $identifier): string
    {
        $quote = $this->pdo->getAttribute(\PDO::ATTR_DRIVER_NAME) === 'mysql' ? '`' : '"';
        return $quote . str_replace($quote, $quote . $quote, $identifier) . $quote;
    }

    /** @return array{0: string, 1: list<mixed>} */
    private function where(Query $query): array
    {
        $clauses = [];
        $params = [];
        foreach ($query->filters as [$sql, $values]) {
            // the developer's own SQL, as written; with values, each '?' is one of them, bound like every other value
            if ($values && substr_count($sql, '?') !== count($values)) {
                throw new \InvalidArgumentException('filter: ' . substr_count($sql, '?') . " '?' for " . count($values) . " params in '$sql'");
            }
            $clauses[] = "($sql)";
            array_push($params, ...$values);
        }
        foreach ($query->conditions as $c) {
            $col = $this->q($c->field);
            switch ($c->op) {
                case 'LIKE':
                case 'NOT_LIKE':
                    $clauses[] = "$col " . ($c->op === 'NOT_LIKE' ? 'NOT ' : '') . "LIKE ? ESCAPE '!'";
                    $params[] = '%' . strtr((string) $c->value, ['!' => '!!', '%' => '!%', '_' => '!_']) . '%';
                    break;
                case 'RANGE':
                    $clauses[] = "$col BETWEEN ? AND ?";
                    array_push($params, $c->value[0], $c->value[1]);
                    break;
                case 'IN':
                case 'NOT_IN':
                    if (!$c->value) {
                        $clauses[] = $c->op === 'IN' ? '1=0' : '1=1';
                        break;
                    }
                    $clauses[] = "$col " . ($c->op === 'NOT_IN' ? 'NOT ' : '') . 'IN (' . implode(', ', array_fill(0, count($c->value), '?')) . ')';
                    array_push($params, ...$c->value);
                    break;
                case 'NULL':
                case 'NOT_NULL':
                    $clauses[] = "$col IS " . ($c->op === 'NOT_NULL' ? 'NOT ' : '') . 'NULL';
                    break;
                default:
                    $clauses[] = "$col " . self::SQL_OPS[$c->op] . ' ?';
                    $params[] = $c->value;
            }
        }
        return [$clauses ? ' WHERE ' . implode(' AND ', $clauses) : '', $params];
    }

    public function page(Query $query): array
    {
        [$where, $params] = $this->where($query);
        $table = $this->q($this->table);
        $total = (int) $this->run("SELECT COUNT(*) FROM $table$where", $params)->fetchColumn();
        // nulls last ascending and first descending on every database, like MemoryRepository
        $order = implode(', ', array_map(fn($s) => '(' . $this->q($s[0]) . ' IS NULL)' . ($s[1] ? ' DESC, ' : ' ASC, ')
            . $this->q($s[0]) . ($s[1] ? ' DESC' : ' ASC'), $query->sort)) ?: $this->q($this->model->pk) . ' ASC';
        $statement = $this->prepare("SELECT * FROM $table$where ORDER BY $order LIMIT ? OFFSET ?");
        foreach (array_values($params) as $i => $value) {
            $this->bindValue($statement, $i + 1, $value);
        }
        $statement->bindValue(count($params) + 1, $query->limit, \PDO::PARAM_INT);
        $statement->bindValue(count($params) + 2, $query->offset, \PDO::PARAM_INT);
        $this->checked($statement->execute(), $statement);
        return [$total, array_map([$this, 'record'], $statement->fetchAll(\PDO::FETCH_ASSOC))];
    }

    public function get(int|string $pk): ?array
    {
        $row = $this->run('SELECT * FROM ' . $this->q($this->table) . ' WHERE ' . $this->q($this->model->pk) . ' = ?', [$pk])->fetch(\PDO::FETCH_ASSOC);
        return $row ? $this->record($row) : null;
    }

    public function add(array $record): void
    {
        $record = $this->store($record);
        $columns = implode(', ', array_map([$this, 'q'], array_keys($record)));
        $this->run('INSERT INTO ' . $this->q($this->table) . " ($columns) VALUES (" . implode(', ', array_fill(0, count($record), '?')) . ')', array_values($record));
    }

    public function update(int|string $pk, array $record): void
    {
        $record = $this->store($record);
        if (!$record) {
            return;
        }
        $sets = implode(', ', array_map(fn($k) => $this->q($k) . ' = ?', array_keys($record)));
        $this->run('UPDATE ' . $this->q($this->table) . " SET $sets WHERE " . $this->q($this->model->pk) . ' = ?', [...array_values($record), $pk]);
    }

    public function delete(array $pks): void
    {
        if (!$pks) {
            return;
        }
        $this->run('DELETE FROM ' . $this->q($this->table) . ' WHERE ' . $this->q($this->model->pk) . ' IN ('
            . implode(', ', array_fill(0, count($pks), '?')) . ')', array_values($pks));
    }

    // Values as columns hold them: a JSON value as its text
    private function store(array $record): array
    {
        unset($record[$this->model->pk]);
        foreach ($record as $name => $value) {
            if ($value !== null && ($this->model->fields[$name] ?? null)?->json !== null) {
                $record[$name] = json_encode($value, JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES | JSON_THROW_ON_ERROR);
            }
        }
        return $record;
    }

    // Drivers disagree on types (pdo_mysql returns numbers as strings, every database its own datetime text),
    // so values are read back through the same coercion the node applies to the browser's input
    private function record(array $row): array
    {
        foreach ($this->model->fields as $f) {
            $value = $row[$f->name] ?? null;
            if ($value !== null && ($f->isPk() || $f->isReference() || $f->json !== null || in_array($f->type, self::TYPED, true))) {
                $row[$f->name] = $f->coerce($value);
            }
        }
        return $row;
    }

    private function run(string $sql, array $params): \PDOStatement
    {
        $statement = $this->prepare($sql);
        foreach (array_values($params) as $i => $value) {
            $this->bindValue($statement, $i + 1, $value);
        }
        $this->checked($statement->execute(), $statement);
        return $statement;
    }

    private function prepare(string $sql): \PDOStatement
    {
        $statement = $this->pdo->prepare($sql);
        $this->checked($statement, $this->pdo);
        return $statement;
    }

    // Under ERRMODE_SILENT / WARNING a failure is only a false return; raise it the way ERRMODE_EXCEPTION would
    private function checked(mixed $result, \PDO|\PDOStatement $source): void
    {
        if ($result === false) {
            $error = $source->errorInfo();
            throw new \RuntimeException('database error ' . ($error[0] ?? '') . ': ' . ($error[2] ?? 'unknown'));
        }
    }

    private function bindValue(\PDOStatement $statement, int $position, mixed $value): void
    {
        if ($value instanceof \DateTimeInterface) {
            $value = $value->format('Y-m-d\TH:i:s.v');
        }
        if (is_bool($value)) {
            // PostgreSQL's boolean takes no integer; SQLite and MySQL store booleans as 0 / 1
            $this->driver ??= $this->pdo->getAttribute(\PDO::ATTR_DRIVER_NAME);
            $this->driver === 'pgsql'
                ? $statement->bindValue($position, $value, \PDO::PARAM_BOOL)
                : $statement->bindValue($position, (int) $value, \PDO::PARAM_INT);
            return;
        }
        $statement->bindValue($position, $value, match (true) {
            $value === null => \PDO::PARAM_NULL,
            is_int($value) => \PDO::PARAM_INT,
            default => \PDO::PARAM_STR,
        });
    }
}
