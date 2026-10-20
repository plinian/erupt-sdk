<?php

namespace Erupt;

use Erupt\Attribute\Field;

/** A compiled #[Field]: builds its erupt field JSON and coerces browser values. */
final class FieldSpec
{
    public const REFERENCES = ['REFERENCE_TABLE', 'REFERENCE_TREE'];
    /** many records of another model, stored as the JSON list of their keys */
    public const COLLECTIONS = ['CHECKBOX', 'TAB_TREE'];
    /** the edit attribute that names a fetchHandler, by the type that fetches options */
    public const FETCHED = ['CHOICE' => 'choiceType', 'MULTI_CHOICE' => 'multiChoiceType', 'TAGS' => 'tagsType'];
    /** invoke kind -> the #[Field] attribute naming its code */
    public const INVOKED = ['options' => 'fetch', 'onchange' => 'onchange', 'autocomplete' => 'complete', 'button' => 'click'];

    /** edit type -> python-equivalent value kind */
    private const KINDS = [
        'INPUT' => 'string', 'TEXTAREA' => 'string', 'CHOICE' => 'string', 'NUMBER' => 'number',
        'BOOLEAN' => 'bool', 'DATE' => 'date', 'DATE_TIME' => 'datetime',
        'TAGS' => 'string', 'AUTO_COMPLETE' => 'string', 'ATTACHMENT' => 'string', 'HTML_EDITOR' => 'string',
        'MARKDOWN' => 'string', 'CODE_EDITOR' => 'string',
    ];

    /** what a JSON field holds: an `array` property a list, an `object` property an object */
    public const JSON_ARRAY = 'array';
    public const JSON_OBJECT = 'object';

    public readonly ?string $type;

    /** @param array<string, \Closure> $code invoke kind -> the field's own code */
    public function __construct(public readonly string $name, public readonly Field $decl, ?string $type,
                                public readonly ?string $json = null, public readonly array $code = [])
    {
        $this->type = $type;
    }

    public function isPk(): bool
    {
        return $this->decl->pk;
    }

    public function isReference(): bool
    {
        return in_array($this->type, self::REFERENCES, true);
    }

    public function isCollection(): bool
    {
        return in_array($this->type, self::COLLECTIONS, true);
    }

    /** The referenced model, for a reference or collection field. */
    public function target(): Model
    {
        return Model::of($this->decl->ref);
    }

    public function build(): array
    {
        $d = $this->decl;
        $tpl = Schema::defaults()['fields'][$d->pk ? 'id' : $this->type];
        $tpl['fieldName'] = $this->name;
        $tpl['componentValue'] = null;
        if ($d->pk) {
            return $tpl;
        }
        $edit = $tpl['eruptFieldJson']['edit'];
        // a BUTTON is a form element only: its template has no table column
        $view = $tpl['eruptFieldJson']['views'][0] ?? [];
        $edit['title'] = $d->title;
        $edit['notNull'] = $d->notNull;
        $edit['show'] = $d->form;
        $edit['search']['value'] = $d->search;
        $view['title'] = $d->title;
        $view['sortable'] = $d->sortable;
        if ($this->type === 'DATE') {
            $view['type'] = 'DATE';
        } elseif ($this->isReference()) {
            $target = $this->target();
            $tpl['fieldReturnName'] = $target->name;
            $key = $this->type === 'REFERENCE_TABLE' ? 'referenceTableType' : 'referenceTreeType';
            $edit[$key]['id'] = $target->pk;
            $edit[$key]['label'] = $d->label;
            if ($this->type === 'REFERENCE_TREE') {
                $edit[$key]['pid'] = $d->tree;
            }
            $view['column'] = $d->label;
        } elseif ($this->isCollection()) {
            // the server lists a CHECKBOX by the view column, a TAB_TREE by the target's own tree
            $tpl['fieldReturnName'] = $this->target()->name;
            $view['column'] = $d->label;
        }
        if (isset($this->code['options'], self::FETCHED[$this->type])) {
            $edit[self::FETCHED[$this->type]]['fetchHandler'] = ['invoke'];
        }
        if (isset($this->code['onchange'])) {
            $edit['onchange'] = 'invoke';
        }
        $tpl['eruptFieldJson']['edit'] = Model::merge($edit, $d->edit);
        $tpl['eruptFieldJson']['views'] = $d->table && $tpl['eruptFieldJson']['views'] ? [Model::merge($view, $d->view)] : [];
        if ($d->choices !== null) { // CHOICE, or MULTI_CHOICE over an array
            $tpl['componentValue'] = [];
            foreach ($d->choices ?? [] as $value => $label) {
                $tpl['componentValue'][] = ['value' => (string) $value, 'label' => $label, 'desc' => null, 'color' => null, 'disable' => false];
            }
        }
        return $tpl;
    }

    /**
     * Turn a JSON value from the browser into the value the repository stores; throws
     * \InvalidArgumentException. Dates are stored as wall-clock strings: DATE `2026-01-05`, DATE_TIME
     * `2026-01-05T10:30:00.000`.
     */
    public function coerce(mixed $value): mixed
    {
        if ($this->isReference()) {
            // the browser sends the picked record as {<id>: ..., <label>: ...}
            $target = $this->target();
            if (is_array($value)) {
                $value = $value[$target->pk] ?? null;
            }
            return $target->fields[$target->pk]->coerce($value);
        }
        if ($this->isCollection()) {
            // picked records arrive as [{id: key}] (CHECKBOX) or [{<pk>: key}] (TAB_TREE), and are stored as keys
            $items = is_string($value) && $value !== '' ? json_decode($value, true, 512, JSON_THROW_ON_ERROR) : ($value ?: []);
            $pk = $this->target()->fields[$this->target()->pk];
            return array_map(fn($v) => $pk->coerce(is_array($v) ? ($v ? reset($v) : null) : $v), array_values((array) $items));
        }
        if ($value === null || $value === '') {
            return null;
        }
        if ($this->json !== null) {
            return $this->json($value);
        }
        if ($this->decl->pk) {
            if (is_int($value) || (is_float($value) && floor($value) == $value)) {
                return (int) $value;
            }
            if (is_string($value) && preg_match('/^\s*-?\d+\s*$/', $value)) {
                return (int) $value;
            }
            throw new \InvalidArgumentException("illegal integer '" . self::show($value) . "'");
        }
        switch (self::KINDS[$this->type]) {
            case 'bool':
                return is_bool($value) ? $value : in_array(strtolower(is_scalar($value) ? (string) $value : ''), ['true', '1'], true);
            case 'number':
                if (is_bool($value)) {
                    return (int) $value;
                }
                if (!is_int($value) && !is_float($value) && !(is_string($value) && is_numeric(trim($value)))) {
                    throw new \InvalidArgumentException("illegal number '" . self::show($value) . "'");
                }
                $number = (float) (is_string($value) ? trim($value) : $value);
                return is_finite($number) && floor($number) == $number && abs($number) < 2 ** 53 ? (int) $number : $number;
            case 'datetime':
                return self::parseDate($value)->format('Y-m-d\TH:i:s.v');
            case 'date':
                return self::parseDate($value)->format('Y-m-d');
        }
        if (!is_scalar($value)) {
            throw new \InvalidArgumentException('expected text');
        }
        $text = is_bool($value) ? ($value ? 'True' : 'False') : (string) $value;
        if ($this->type === 'CHOICE' && $this->decl->choices !== null
            && !in_array($text, array_map('strval', array_keys($this->decl->choices)), true)) {
            throw new \InvalidArgumentException("illegal option '$text'");
        }
        return $text;
    }

    /** A JSON value: a list as an array, an object as a stdClass (so an empty one stays `{}`). */
    private function json(mixed $value): array|\stdClass
    {
        if (is_string($value)) {
            $value = json_decode($value, $this->json === self::JSON_ARRAY, 512, JSON_THROW_ON_ERROR);
        }
        if ($this->json === self::JSON_OBJECT && (is_array($value) || $value instanceof \stdClass)) {
            return (object) $value;
        }
        if (!is_array($value) || !array_is_list($value)) {
            throw new \InvalidArgumentException('must be a JSON array');
        }
        if ($this->decl->choices !== null
            && array_diff(array_map('strval', $value), array_map('strval', array_keys($this->decl->choices)))) {
            throw new \InvalidArgumentException('illegal option in ' . json_encode($value));
        }
        return $value;
    }

    /** A stored value to JSON for the browser. */
    public function toJson(mixed $value): mixed
    {
        if ($value instanceof \DateTimeInterface) {
            return $value->format($this->type === 'DATE' ? 'Y-m-d' : 'Y-m-d\TH:i:s.v');
        }
        if ($this->type === 'BOOLEAN' && is_int($value)) {
            return (bool) $value;
        }
        return $value;
    }

    /** Accepts what python's strptime formats accept: `Y-m-d`, `Y-m-d H:i`, `Y-m-d H:i:s`, `Y-m-d H:i:s.u`, with `T` / `Z`. */
    public static function parseDate(mixed $value): \DateTimeImmutable
    {
        $text = is_scalar($value) ? rtrim(str_replace('T', ' ', (string) $value), 'Z') : '';
        if (preg_match('/^(\d{4})-(\d{1,2})-(\d{1,2})(?: (\d{1,2}):(\d{1,2})(?::(\d{1,2})(?:\.(\d{1,6}))?)?)?$/', $text, $m)
            && checkdate((int) $m[2], (int) $m[3], (int) $m[1])
            && (int) ($m[4] ?? 0) < 24 && (int) ($m[5] ?? 0) < 60 && (int) ($m[6] ?? 0) < 60) {
            return (new \DateTimeImmutable('@0'))
                ->setDate((int) $m[1], (int) $m[2], (int) $m[3])
                ->setTime((int) ($m[4] ?? 0), (int) ($m[5] ?? 0), (int) ($m[6] ?? 0), (int) str_pad($m[7] ?? '0', 6, '0'));
        }
        throw new \InvalidArgumentException("illegal date '" . self::show($value) . "'");
    }

    private static function show(mixed $value): string
    {
        return is_scalar($value) ? (string) $value : json_encode($value);
    }
}
