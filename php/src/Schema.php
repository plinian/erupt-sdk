<?php

namespace Erupt;

/**
 * The erupt annotation JSON Schema and field templates (resources/, synced by tools/gen-types.php).
 * check() rejects a misspelt attribute or an unknown enum value when a model is declared instead of
 * letting it silently do nothing in the browser.
 */
final class Schema
{
    private static ?array $defs = null;
    private static ?array $defaults = null;

    public static function defs(): array
    {
        return self::$defs ??= Json::decode(file_get_contents(__DIR__ . '/../resources/erupt-annotations.schema.json'))['$defs'];
    }

    /** The resolved templates: erupt, power, rowOperation and fields by edit type. */
    public static function defaults(): array
    {
        return self::$defaults ??= Json::decode(file_get_contents(__DIR__ . '/../resources/erupt-node-defaults.json'));
    }

    /** The declared defaults of an annotation, as Java fills an attribute left out. */
    public static function declaredDefaults(string $name): array
    {
        return array_map(fn($p) => $p['default'], array_filter(self::defs()[$name]['properties'], fn($p) => array_key_exists('default', $p)));
    }

    /**
     * Throw \InvalidArgumentException unless $value fits definition $name. $partial (an override) lets every
     * attribute be omitted; otherwise the attributes the Java side always emits must be present.
     */
    public static function check(string $name, mixed $value, ?string $path = null, bool $partial = true): void
    {
        self::walk(['$ref' => "#/\$defs/$name"], $value, $path ?? $name, $partial);
    }

    private static function walk(array $schema, mixed $value, string $path, bool $partial): void
    {
        if (isset($schema['$ref'])) {
            $name = substr(strrchr($schema['$ref'], '/'), 1);
            $def = self::defs()[$name];
            if (isset($def['enum'])) {
                if (!is_string($value) || !in_array($value, $def['enum'], true)) {
                    throw new \InvalidArgumentException("$path: '" . self::show($value) . "' is not a $name, expected one of " . implode(', ', $def['enum']));
                }
                return;
            }
            $value = self::object($value, "$path: expected an object ($name)");
            foreach ($value as $key => $item) {
                if (!array_key_exists($key, $def['properties'])) {
                    throw new \InvalidArgumentException("$path: $name has no attribute '$key'");
                }
                self::walk($def['properties'][$key], $item, "$path.$key", $partial);
            }
            if (!$partial && ($missing = array_diff($def['required'] ?? [], array_map('strval', array_keys($value))))) {
                throw new \InvalidArgumentException("$path: missing " . implode(', ', $missing));
            }
            return;
        }
        switch ($schema['type']) {
            case 'array':
                if (!is_array($value) || !array_is_list($value)) {
                    throw new \InvalidArgumentException("$path: expected an array");
                }
                foreach ($value as $i => $item) {
                    self::walk($schema['items'], $item, "{$path}[$i]", $partial);
                }
                return;
            case 'object':
                $value = self::object($value, "$path: expected an object");
                if (isset($schema['additionalProperties'])) {
                    foreach ($value as $key => $item) {
                        self::walk($schema['additionalProperties'], $item, "$path.$key", $partial);
                    }
                }
                return;
        }
        $ok = match ($schema['type']) {
            'string' => is_string($value),
            'integer' => is_int($value),
            'number' => is_int($value) || is_float($value),
            'boolean' => is_bool($value),
        };
        if (!$ok) {
            throw new \InvalidArgumentException("$path: expected {$schema['type']}, got " . self::show($value));
        }
    }

    /** An object arrives as an associative array, an empty array or a stdClass. */
    private static function object(mixed $value, string $error): array
    {
        if ($value instanceof \stdClass) {
            return get_object_vars($value);
        }
        if (!is_array($value) || ($value && array_is_list($value))) {
            throw new \InvalidArgumentException($error);
        }
        return $value;
    }

    private static function show(mixed $value): string
    {
        return is_string($value) ? $value : json_encode($value);
    }
}
