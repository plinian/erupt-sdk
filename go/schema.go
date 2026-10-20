package erupt

import (
	"bytes"
	_ "embed"
	"encoding/json"
	"fmt"
	"strconv"
	"strings"
)

//go:embed erupt-annotations.schema.json
var annotationSchema []byte

//go:embed erupt-node-defaults.json
var nodeDefaults []byte

// defaults holds the templates the Java proxies emit (erupt-test NodeDefaultsTest): every field and
// operation starts from one, a declaration only overrides values on top of it.
var defaults struct {
	Erupt        map[string]any            `json:"erupt"`
	Fields       map[string]map[string]any `json:"fields"`
	Power        map[string]bool           `json:"power"`
	RowOperation map[string]any            `json:"rowOperation"`
}

// schemaDefs are the definitions of erupt-annotations.schema.json, the schema types.go is generated from.
var schemaDefs map[string]map[string]any

func init() {
	if err := decode(nodeDefaults, &defaults); err != nil {
		panic(err)
	}
	var root map[string]any
	if err := decode(annotationSchema, &root); err != nil {
		panic(err)
	}
	schemaDefs = map[string]map[string]any{}
	for name, def := range root["$defs"].(map[string]any) {
		schemaDefs[name] = def.(map[string]any)
	}
}

// decode unmarshals keeping numbers exact (json.Number), so integers stay integers.
func decode(data []byte, v any) error {
	d := json.NewDecoder(bytes.NewReader(data))
	d.UseNumber()
	return d.Decode(v)
}

// toJSONValue normalizes a user value (map, generated struct, ...) into decoded JSON.
func toJSONValue(v any) (any, error) {
	data, err := json.Marshal(v)
	if err != nil {
		return nil, err
	}
	var out any
	return out, decode(data, &out)
}

// schemaDefaults are the declared defaults of an annotation, as Java fills an attribute left out.
func schemaDefaults(name string) map[string]any {
	out := map[string]any{}
	props, _ := schemaDefs[name]["properties"].(map[string]any)
	for k, p := range props {
		if v, ok := p.(map[string]any)["default"]; ok {
			out[k] = deepCopy(v)
		}
	}
	return out
}

// checkSchema returns an error unless value fits definition name. partial (an override) lets every
// attribute be omitted; otherwise the attributes the Java side always emits must be present.
func checkSchema(name string, value any, path string, partial bool) error {
	return checkNode(map[string]any{"$ref": "#/$defs/" + name}, value, path, partial)
}

func checkNode(s map[string]any, value any, path string, partial bool) error {
	if ref, ok := s["$ref"].(string); ok {
		name := ref[strings.LastIndex(ref, "/")+1:]
		def := schemaDefs[name]
		if enum, ok := def["enum"].([]any); ok {
			str, _ := value.(string)
			for _, v := range enum {
				if v == str && value != nil {
					return nil
				}
			}
			values := make([]string, len(enum))
			for i, v := range enum {
				values[i] = v.(string)
			}
			return fmt.Errorf("%s: '%v' is not a %s, expected one of %s", path, value, name, strings.Join(values, ", "))
		}
		obj, ok := value.(map[string]any)
		if !ok {
			return fmt.Errorf("%s: expected an object (%s)", path, name)
		}
		props, _ := def["properties"].(map[string]any)
		for _, key := range sortedKeys(obj) {
			prop, ok := props[key].(map[string]any)
			if !ok {
				return fmt.Errorf("%s: %s has no attribute '%s'", path, name, key)
			}
			if err := checkNode(prop, obj[key], path+"."+key, partial); err != nil {
				return err
			}
		}
		if !partial {
			var missing []string
			required, _ := def["required"].([]any)
			for _, k := range required {
				if _, ok := obj[k.(string)]; !ok {
					missing = append(missing, k.(string))
				}
			}
			if len(missing) > 0 {
				return fmt.Errorf("%s: missing %s", path, strings.Join(missing, ", "))
			}
		}
		return nil
	}
	switch kind, _ := s["type"].(string); kind {
	case "array":
		list, ok := value.([]any)
		if !ok {
			return fmt.Errorf("%s: expected an array", path)
		}
		for i, item := range list {
			if err := checkNode(s["items"].(map[string]any), item, fmt.Sprintf("%s[%d]", path, i), partial); err != nil {
				return err
			}
		}
	case "object":
		obj, ok := value.(map[string]any)
		if !ok {
			return fmt.Errorf("%s: expected an object", path)
		}
		item, ok := s["additionalProperties"].(map[string]any)
		if !ok {
			return nil
		}
		for _, key := range sortedKeys(obj) {
			if err := checkNode(item, obj[key], path+"."+key, partial); err != nil {
				return err
			}
		}
	default:
		if !primitiveOK(kind, value) {
			got, _ := json.Marshal(value)
			return fmt.Errorf("%s: expected %s, got %s", path, kind, got)
		}
	}
	return nil
}

func primitiveOK(kind string, value any) bool {
	switch kind {
	case "string":
		_, ok := value.(string)
		return ok
	case "boolean":
		_, ok := value.(bool)
		return ok
	case "integer":
		n, ok := value.(json.Number)
		if !ok {
			return false
		}
		_, err := strconv.ParseInt(n.String(), 10, 64)
		return err == nil
	case "number":
		n, ok := value.(json.Number)
		if !ok {
			return false
		}
		_, err := n.Float64()
		return err == nil
	}
	return false
}

// deepCopy copies decoded JSON so a template is never shared between builds.
func deepCopy(v any) any {
	switch t := v.(type) {
	case map[string]any:
		out := make(map[string]any, len(t))
		for k, x := range t {
			out[k] = deepCopy(x)
		}
		return out
	case []any:
		out := make([]any, len(t))
		for i, x := range t {
			out[i] = deepCopy(x)
		}
		return out
	}
	return v
}

// merge overlays override onto target, recursing into objects present on both sides.
func merge(target, override map[string]any) map[string]any {
	for k, v := range override {
		if o, ok := v.(map[string]any); ok {
			if t, ok := target[k].(map[string]any); ok {
				merge(t, o)
				continue
			}
		}
		target[k] = deepCopy(v)
	}
	return target
}
