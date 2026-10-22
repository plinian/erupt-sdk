"""Checks annotation JSON against erupt-annotations.schema.json (the same schema ``_types.py`` is generated
from), so a misspelt attribute or an unknown enum value fails when the model is declared instead of
silently doing nothing in the browser."""
import json
from importlib import resources

_SCHEMA = json.loads(resources.files(__package__).joinpath("_schema.json").read_text("utf-8"))
DEFS = _SCHEMA["$defs"]

_PRIMITIVES = {
    "string": lambda v: isinstance(v, str),
    "integer": lambda v: isinstance(v, int) and not isinstance(v, bool),
    "number": lambda v: isinstance(v, (int, float)) and not isinstance(v, bool),
    "boolean": lambda v: isinstance(v, bool),
}


def defaults(name):
    """The declared defaults of an annotation, as Java fills an attribute left out."""
    return {k: v["default"] for k, v in DEFS[name]["properties"].items() if "default" in v}


def enum_values(name):
    return tuple(DEFS[name]["enum"])


def check(name, value, path=None, partial=True):
    """Raise ``ValueError`` unless ``value`` fits definition ``name``. ``partial`` (an override) lets every
    attribute be omitted; otherwise the attributes the Java side always emits must be present."""
    _check({"$ref": "#/$defs/" + name}, value, path or name, partial)


def _check(schema, value, path, partial):
    if "$ref" in schema:
        name = schema["$ref"].rsplit("/", 1)[1]
        d = DEFS[name]
        if "enum" in d:
            if value not in d["enum"]:
                raise ValueError(f"{path}: '{value}' is not a {name}, expected one of {', '.join(d['enum'])}")
            return
        if not isinstance(value, dict):
            raise ValueError(f"{path}: expected an object ({name})")
        props = d["properties"]
        for key, item in value.items():
            if key not in props:
                raise ValueError(f"{path}: {name} has no attribute '{key}'")
            _check(props[key], item, f"{path}.{key}", partial)
        if not partial:
            missing = [k for k in d.get("required", ()) if k not in value]
            if missing:
                raise ValueError(f"{path}: missing {', '.join(missing)}")
        return
    kind = schema["type"]
    if kind == "array":
        if not isinstance(value, list):
            raise ValueError(f"{path}: expected an array")
        for i, item in enumerate(value):
            _check(schema["items"], item, f"{path}[{i}]", partial)
    elif kind == "object":
        if not isinstance(value, dict):
            raise ValueError(f"{path}: expected an object")
        if "additionalProperties" not in schema:
            return
        for key, item in value.items():
            _check(schema["additionalProperties"], item, f"{path}.{key}", partial)
    elif not _PRIMITIVES[kind](value):
        raise ValueError(f"{path}: expected {kind}, got {json.dumps(value)}")
