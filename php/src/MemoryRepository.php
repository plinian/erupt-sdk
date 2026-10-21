<?php

namespace Erupt;

/**
 * Records in a PHP array. State lives as long as the process: fine for tests and long-running servers
 * (RoadRunner, Swoole, ReactPHP), useless under php-fpm or `php -S`, where every request starts empty.
 */
final class MemoryRepository implements Repository
{
    private Model $model;
    private array $rows = [];
    private int $seq = 0;

    /** @param list<array<string, mixed>> $records seeded on bind */
    public function __construct(private readonly array $records = [])
    {
    }

    public function bind(Model $model): void
    {
        $this->model = $model;
        foreach ($this->records as $record) {
            $this->add($record);
        }
    }

    public function page(Query $query): array
    {
        if ($query->filters) {
            throw new \LogicException('MemoryRepository cannot apply SQL filters (a view filter, beforeFetch)');
        }
        $rows = array_values(array_filter($this->rows, function (array $row) use ($query) {
            foreach ($query->conditions as $c) {
                if (!self::match($row[$c->field] ?? null, $c)) {
                    return false;
                }
            }
            return true;
        }));
        foreach (array_reverse($query->sort) as [$name, $desc]) {
            // stable, nulls last ascending (and first descending), like python's sort
            $keyed = array_map(null, array_keys($rows), $rows);
            usort($keyed, function ($a, $b) use ($name, $desc) {
                $x = $a[1][$name] ?? null;
                $y = $b[1][$name] ?? null;
                $c = [$x === null, $x] <=> [$y === null, $y];
                return ($desc ? -$c : $c) ?: $a[0] <=> $b[0];
            });
            $rows = array_column($keyed, 1);
        }
        return [count($rows), array_slice($rows, $query->offset, $query->limit)];
    }

    public function get(int|string $pk): ?array
    {
        return $this->rows[$pk] ?? null;
    }

    public function add(array $record): void
    {
        $record[$this->model->pk] = ++$this->seq;
        $this->rows[$this->seq] = $record;
    }

    public function update(int|string $pk, array $record): void
    {
        if (isset($this->rows[$pk])) {
            $this->rows[$pk] = array_merge($this->rows[$pk], $record);
        }
    }

    public function delete(array $pks): void
    {
        foreach ($pks as $pk) {
            unset($this->rows[$pk]);
        }
    }

    private static function match(mixed $value, Cond $c): bool
    {
        $expect = $c->value;
        if ($c->op === 'NULL') {
            return $value === null;
        }
        if ($c->op === 'NOT_NULL') {
            return $value !== null;
        }
        if ($value === null) {
            return false;
        }
        if (is_array($value) || $value instanceof \stdClass) {
            $value = json_encode($value, JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES); // a JSON value is matched as its text
        }
        return match ($c->op) {
            'EQ' => self::same($value, $expect),
            'NEQ' => !self::same($value, $expect),
            'LIKE' => str_contains(mb_strtolower((string) $value), mb_strtolower((string) $expect)),
            'NOT_LIKE' => !str_contains(mb_strtolower((string) $value), mb_strtolower((string) $expect)),
            'IN' => self::in($value, $expect),
            'NOT_IN' => !self::in($value, $expect),
            'RANGE' => ($value <=> $expect[0]) >= 0 && ($value <=> $expect[1]) <= 0,
            'GT' => $value > $expect,
            'GTE' => $value >= $expect,
            'LT' => $value < $expect,
            'LTE' => $value <= $expect,
        };
    }

    // numbers compare by value (1 == 1.0), everything else strictly: "1" is not "01"
    private static function same(mixed $a, mixed $b): bool
    {
        return (is_int($a) || is_float($a)) && (is_int($b) || is_float($b)) ? $a == $b : $a === $b;
    }

    private static function in(mixed $value, array $list): bool
    {
        foreach ($list as $item) {
            if (self::same($value, $item)) {
                return true;
            }
        }
        return false;
    }
}
