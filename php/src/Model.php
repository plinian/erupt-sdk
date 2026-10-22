<?php

namespace Erupt;

use Erupt\Attribute\Erupt;
use Erupt\Attribute\Field;
use Erupt\Attribute\Operation;
use Erupt\Types\EditType;

/**
 * An #[Erupt] class compiled into erupt build JSON. Nothing re-implements annotation semantics: every
 * field and operation starts from the template the Java proxies emit (resources/erupt-node-defaults.json)
 * and a declaration only overrides values on top of it.
 */
final class Model
{
    private const IDENTIFIER = '/^[A-Za-z_][A-Za-z0-9_]*$/';

    /** @var array<class-string, Model> */
    private static array $compiled = [];
    /** @var array<class-string, true> */
    private static array $compiling = [];

    public readonly string $name;
    public readonly string $title;
    /** Primary key field, or null for a model that only serves as an operation form. */
    public readonly ?string $pk;
    public readonly array $power;
    /** @var list<array{0: string, 1: bool}> default sort, [field, descending] */
    public readonly array $orderBy;
    /** @var array<string, FieldSpec> stored and served, in declaration order */
    public readonly array $fields;
    /** @var list<FieldSpec> every field in order, virtual ones included, for the build */
    public readonly array $declared;
    /** @var array<string, OperationSpec> */
    public readonly array $operations;
    /** @var list<DataProxy> */
    public readonly array $proxies;
    /** @var array<string, array{0: list<array{0: string, 1: list<mixed>}>, 1: list<array{0: string, 1: bool}>}> view code -> [filters, sort] */
    public readonly array $vis;
    /** @var array{0: string, 1: bool}|null [field, dependNode] of a @LinkTree: the reference the tree beside the table filters */
    public readonly ?array $linkTree;
    /** @var array<string, array{erupt: string, column: string, join: string, condition: string}> drill code -> its link, applied by the node */
    public readonly array $drills;
    private readonly array $raw;

    /** The compiled model of an #[Erupt] class; cached, so declarations are checked once. */
    public static function of(string $class): self
    {
        if (isset(self::$compiled[$class])) {
            return self::$compiled[$class];
        }
        if (isset(self::$compiling[$class])) {
            throw new \InvalidArgumentException("$class references itself (directly or through another model)");
        }
        self::$compiling[$class] = true;
        try {
            return self::$compiled[$class] = new self(new \ReflectionClass($class));
        } finally {
            unset(self::$compiling[$class]);
        }
    }

    private function __construct(\ReflectionClass $class)
    {
        $attribute = $class->getAttributes(Erupt::class)[0] ?? null;
        if ($attribute === null) {
            throw new \InvalidArgumentException("{$class->getName()} has no #[Erupt] attribute");
        }
        $decl = $attribute->newInstance();
        $this->name = $decl->name ?? $class->getShortName();
        if (!preg_match(self::IDENTIFIER, $this->name)) {
            throw new \InvalidArgumentException("erupt name '$this->name' must be an identifier");
        }
        $this->title = $decl->title;
        $proxies = [];
        foreach (is_array($decl->dataProxy) ? $decl->dataProxy : [$decl->dataProxy] as $p) {
            $p = is_string($p) && is_subclass_of($p, DataProxy::class) ? new $p() : $p;
            if (!$p instanceof DataProxy) {
                throw new \InvalidArgumentException("$this->name: dataProxy must be a DataProxy");
            }
            $proxies[] = $p;
        }
        $this->proxies = $proxies;
        [$raw, $vis] = self::pullVis($decl->raw);
        [$raw, $this->drills] = self::pullDrills($raw);
        Schema::check('Erupt', $raw, "#[Erupt] $this->name");
        $this->raw = $raw;
        $defaults = Schema::defaults()['power'];
        if ($unknown = array_diff_key($decl->power, $defaults)) {
            throw new \InvalidArgumentException("$this->name: unknown power " . implode(', ', array_keys($unknown)));
        }
        $this->power = array_merge($defaults, $decl->power);

        $fields = $declared = [];
        foreach ($class->getProperties() as $property) {
            $field = $property->getAttributes(Field::class)[0] ?? null;
            if ($field !== null) {
                $declared[] = $spec = $this->field($property, $field->newInstance());
                if (!$spec->decl->virtual) {
                    $fields[$property->getName()] = $spec;
                }
            }
        }
        $this->fields = $fields;
        $this->declared = $declared;
        $pks = array_keys(array_filter($fields, fn(FieldSpec $f) => $f->isPk()));
        if (count($pks) > 1) {
            throw new \InvalidArgumentException("$this->name: at most one #[Field(pk: true)]");
        }
        $this->pk = $pks[0] ?? null;
        $this->orderBy = $this->parseOrder($decl->orderBy);
        $link = $raw['linkTree'] ?? [];
        $this->linkTree = isset($link['field']) ? [$link['field'], (bool) ($link['dependNode'] ?? false)] : null;
        if ($this->linkTree && !($fields[$this->linkTree[0]] ?? null)?->isReference()) {
            throw new \InvalidArgumentException("$this->name: linkTree.field '{$this->linkTree[0]}' must be a reference field");
        }
        // view code -> [filters, sort] the node applies to that view's table queries
        $this->vis = array_map(fn($v) => [array_map(fn($f) => [$f, []], $v[0]), $this->parseOrder($v[1])], $vis);

        $operations = [];
        foreach ($class->getMethods() as $method) {
            $op = $method->getAttributes(Operation::class)[0] ?? null;
            if ($op === null) {
                continue;
            }
            if (!$method->isStatic() || !$method->isPublic()) {
                throw new \InvalidArgumentException("$this->name::{$method->getName()}: an operation must be a public static method");
            }
            $op = $op->newInstance();
            $show = null;
            if ($op->show !== null) {
                if (!$class->hasMethod($op->show) || !$class->getMethod($op->show)->isStatic()) {
                    throw new \InvalidArgumentException("$this->name::{$method->getName()}: show must name a static method of $this->name");
                }
                $show = \Closure::fromCallable([$class->getName(), $op->show]);
            }
            $spec = new OperationSpec($op, [$class->getName(), $method->getName()], $method->getName(), $show);
            if (isset($operations[$spec->code])) {
                throw new \InvalidArgumentException("$this->name: operation code '$spec->code' declared twice");
            }
            $operations[$spec->code] = $spec;
        }
        $this->operations = $operations;
    }

    private function field(\ReflectionProperty $property, Field $decl): FieldSpec
    {
        $name = $property->getName();
        $path = "$this->name.$name";
        if ($decl->type !== null && EditType::tryFrom($decl->type) === null) {
            throw new \InvalidArgumentException("$path.type: '$decl->type' is not a EditType, expected one of "
                . implode(', ', array_column(EditType::cases(), 'value')));
        }
        Schema::check('View', $decl->view, "$path.view");
        // referenceTableType.dependColumn is @Transient in Java: kept out of the schema check, the build carries it
        $edit = $decl->edit;
        if (is_array($edit['referenceTableType'] ?? null)) {
            unset($edit['referenceTableType']['dependColumn']);
        }
        Schema::check('Edit', $edit, "$path.edit");
        if ($decl->pk) {
            return new FieldSpec($name, $decl, null);
        }
        $hint = $property->getType() instanceof \ReflectionNamedType ? $property->getType()->getName() : null;
        if ($decl->ref === null && $hint !== null && class_exists($hint) && (new \ReflectionClass($hint))->getAttributes(Erupt::class)) {
            $decl->ref = $hint;
        }
        $collection = in_array($decl->type, FieldSpec::COLLECTIONS, true);
        $type = match (true) {
            $collection => $decl->type,
            $decl->ref !== null => $decl->tree !== null ? 'REFERENCE_TREE' : 'REFERENCE_TABLE',
            $decl->type !== null => $decl->type,
            $decl->choices !== null || $decl->fetch !== null => $hint === 'array' ? 'MULTI_CHOICE' : 'CHOICE',
            $hint === 'bool' => 'BOOLEAN',
            $hint === 'int', $hint === 'float' => 'NUMBER',
            $hint !== null && is_a($hint, \DateTimeInterface::class, true) => 'DATE_TIME',
            default => 'INPUT',
        };
        if (!isset(Schema::defaults()['fields'][$type])) {
            throw new \InvalidArgumentException("$path: edit type $type is not supported yet");
        }
        if ($collection && $decl->ref === null) {
            throw new \InvalidArgumentException("$path: $type needs ref");
        }
        $decl->virtual = $decl->virtual || $type === 'BUTTON';
        $json = $collection ? FieldSpec::JSON_ARRAY : ($decl->ref === null ? match ($hint) {
            'array' => FieldSpec::JSON_ARRAY,
            'object', \stdClass::class => FieldSpec::JSON_OBJECT,
            default => null,
        } : null);
        $code = [];
        foreach (FieldSpec::INVOKED as $kind => $attr) {
            if ($decl->$attr !== null) {
                $class = $property->getDeclaringClass();
                if (!$class->hasMethod($decl->$attr) || !$class->getMethod($decl->$attr)->isStatic()) {
                    throw new \InvalidArgumentException("$path: $attr must name a static method of $this->name");
                }
                $code[$kind] = $class->getMethod($decl->$attr)->getClosure();
            }
        }
        if ((isset($code['options']) && !isset(FieldSpec::FETCHED[$type])) || (isset($code['autocomplete']) && $type !== 'AUTO_COMPLETE')
            || (isset($code['button']) && $type !== 'BUTTON')) {
            throw new \InvalidArgumentException("$path: fetch, complete and click belong to CHOICE / MULTI_CHOICE / TAGS, AUTO_COMPLETE and BUTTON");
        }
        $spec = new FieldSpec($name, $decl, $type, $json, $code);
        if ($spec->isReference() || $collection) {
            $target = Model::of($decl->ref);
            if ($target->pk === null) {
                throw new \InvalidArgumentException("$path: $target->name has no primary key");
            }
            foreach (array_filter([$decl->label, $decl->tree]) as $key) {
                if (!isset($target->fields[$key])) {
                    throw new \InvalidArgumentException("$path: $target->name has no field '$key'");
                }
            }
        }
        return $spec;
    }

    /**
     * `filter` and `orderBy` of a `vis` entry run on the node, as Java keeps them off the build (`@Transient`):
     * taken out before the schema check. A view without a `code` is addressed by its title.
     */
    private static function pullVis(array $raw): array
    {
        $vis = $entries = [];
        foreach (is_array($raw['vis'] ?? null) ? $raw['vis'] : [] as $entry) {
            if (!is_array($entry)) {
                return [$raw, []]; // left to the schema check
            }
            $entry += ['code' => $entry['title'] ?? ''];
            $filters = array_values((array) ($entry['filter'] ?? []));
            if (array_filter($filters, fn($f) => !is_string($f)) || !is_string($entry['orderBy'] ?? '')) {
                throw new \InvalidArgumentException("vis '{$entry['code']}': filter must be SQL strings, orderBy a string");
            }
            $vis[$entry['code']] = [$filters, $entry['orderBy'] ?? null];
            unset($entry['filter'], $entry['orderBy']);
            $entries[] = $entry;
        }
        if (is_array($raw['vis'] ?? null)) {
            $raw['vis'] = $entries;
        }
        return [$raw, $vis];
    }

    /**
     * `link.column` / `link.joinColumn` of a drill: the source row's column (`id` by default) and the linked
     * model's field holding it (its first path segment), applied by the node and kept out of the build, as Java
     * keeps them `@Transient`. The rest is filled from the schema defaults; a drill without a `code` is
     * addressed by its title.
     */
    private static function pullDrills(array $raw): array
    {
        $drills = $entries = [];
        foreach (is_array($raw['drills'] ?? null) ? $raw['drills'] : [] as $entry) {
            if (!is_array($entry) || !is_array($entry['link'] ?? [])) {
                return [$raw, []]; // left to the schema check
            }
            $link = $entry['link'] ?? [];
            $column = $link['column'] ?? 'id';
            $join = $link['joinColumn'] ?? null;
            if (!is_string($join) || $join === '' || !is_string($link['linkErupt'] ?? null) || $link['linkErupt'] === '' || !is_string($column)) {
                throw new \InvalidArgumentException("drill '" . (is_string($entry['title'] ?? null) ? $entry['title'] : '') . "' needs link.linkErupt and link.joinColumn");
            }
            unset($link['column'], $link['joinColumn']);
            $entry = array_merge(Schema::declaredDefaults('Drill'), ['code' => $entry['title'] ?? ''], $entry,
                ['link' => array_merge(Schema::declaredDefaults('Link'), $link)]);
            $drills[$entry['code']] = ['erupt' => $link['linkErupt'], 'column' => $column, 'join' => explode('.', $join)[0],
                'condition' => is_string($link['linkCondition'] ?? null) ? $link['linkCondition'] : ''];
            $entries[] = $entry;
        }
        if (is_array($raw['drills'] ?? null)) {
            $raw['drills'] = $entries;
        }
        return [$raw, $drills];
    }

    /** Run one DataProxy hook on every proxy, in declaration order. */
    public function hook(string $name, array &$arg): void
    {
        foreach ($this->proxies as $p) {
            $p->$name($arg);
        }
    }

    /**
     * The SQL every proxy's beforeFetch adds, in declaration order.
     *
     * @param list<Cond> $conditions
     * @return list<array{0: string, 1: list<mixed>}>
     */
    public function filters(array $conditions): array
    {
        $filters = [];
        foreach ($this->proxies as $p) {
            $sql = $p->beforeFetch($conditions);
            if ($sql) {
                $filters[] = is_string($sql) ? [$sql, []] : [$sql[0], array_values($sql[1])];
            }
        }
        return $filters;
    }

    /** `'views desc, id'` -> `[['views', true], ['id', false]]`, fields checked against the model. */
    private function parseOrder(?string $orderBy): array
    {
        $sort = [];
        foreach (array_filter(array_map('trim', explode(',', $orderBy ?? ''))) as $part) {
            $words = preg_split('/\s+/', $part);
            if (count($words) > 2 || !isset($this->fields[$words[0]])
                || (count($words) === 2 && !in_array(strtolower($words[1]), ['asc', 'desc'], true))) {
                throw new \InvalidArgumentException("$this->name: illegal orderBy '$part'");
            }
            $sort[] = [$words[0], count($words) === 2 && strtolower($words[1]) === 'desc'];
        }
        return $sort;
    }

    /** @param list<OperationSpec> $operations */
    public function buildErupt(array $operations = []): array
    {
        $erupt = self::merge(Schema::defaults()['erupt'], ['primaryKeyCol' => $this->pk ?? 'id']);
        $erupt['rowOperation'] = array_map(fn(OperationSpec $op) => $op->build(), $operations);
        return [
            'eruptName' => $this->name,
            'eruptJson' => self::merge($erupt, $this->raw),
            'eruptFieldModels' => array_map(fn(FieldSpec $f) => $f->build(), $this->declared),
            'searchCondition' => $this->searchCondition() ?: new \stdClass(),
            'extraRow' => false,
            'tags' => new \stdClass(),
        ];
    }

    private function searchCondition(): array
    {
        $condition = [];
        $this->hook('searchCondition', $condition);
        return $condition;
    }

    public function buildModel(array $power, ?array $user): array
    {
        $operations = array_values(array_filter($this->operations, fn(OperationSpec $op) => $op->visible($user)));
        $forms = [];
        foreach ($operations as $op) {
            if ($op->decl->form !== null) {
                $forms[$op->code] = $op->formModel()->buildErupt();
            }
        }
        return [
            'eruptModel' => $this->buildErupt($operations),
            'power' => $power,
            'tabErupts' => null,
            'combineErupts' => null,
            'operationErupts' => $forms ?: null,
        ];
    }

    /** Deep merge of JSON objects; lists and scalars are replaced. */
    public static function merge(array $target, array $override): array
    {
        foreach ($override as $key => $value) {
            if (is_array($value) && !array_is_list($value) && isset($target[$key]) && is_array($target[$key]) && !array_is_list($target[$key])) {
                $target[$key] = self::merge($target[$key], $value);
            } else {
                $target[$key] = $value;
            }
        }
        return $target;
    }
}
