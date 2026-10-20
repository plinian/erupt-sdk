package erupt

import (
	"context"
	"errors"
	"fmt"
	"reflect"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"time"
)

var identifier = regexp.MustCompile(`^[A-Za-z_][A-Za-z0-9_]*$`)

// M is a raw JSON object, e.g. an annotation override.
type M = map[string]any

// Ptr returns a pointer to v, handy for the optional fields of the generated annotation types.
func Ptr[T any](v T) *T { return &v }

const (
	typeReferenceTable = "REFERENCE_TABLE"
	typeReferenceTree  = "REFERENCE_TREE"
	typeDateTime       = "DATE_TIME" // a template key, not an EditType: a DATE field holding a time of day
)

type choice struct{ value, label string }

type field struct {
	name, title, typ              string
	pk, search, notNull, sortable bool
	table, form                   bool
	virtual                       bool // declared in the build only: no column, never read or written
	json                          bool // a slice or map: a JSON value, stored as JSON text by SQL repositories
	choices                       []choice
	ref, label, tree              string
	target                        *Model
	view, edit                    map[string]any
}

func (f *field) isReference() bool { return f.typ == typeReferenceTable || f.typ == typeReferenceTree }

// stored lists the fields a repository keeps, in declaration order: every field but the virtual ones.
func (m *Model) stored() []*field {
	fields := make([]*field, 0, len(m.fields))
	for _, f := range m.fields {
		if !f.virtual {
			fields = append(fields, f)
		}
	}
	return fields
}

// Model is a declared erupt model: the struct it was declared from only describes it, records travel as
// Record maps keyed by field name.
type Model struct {
	name, title string
	power       map[string]bool
	raw         map[string]any
	fields      []*field
	byName      map[string]*field
	operations  []*Operation
	pk          string
	orderBy     []Order
	proxies     []DataProxy
	vis         map[string]view // view code -> what the node applies to that view's table queries
}

// view is a @Vis view's own filter and order, run on the node and kept out of the build.
type view struct {
	filters []Filter
	orderBy []Order
}

// NodeVis is a Vis with the attributes the node applies to its table queries, kept out of the build as Java
// keeps them @Transient: Filter is SQL ANDed as written, OrderBy as WithOrderBy. Pass it where a raw vis
// entry goes: WithRaw(M{"vis": []NodeVis{...}}); in an M, the keys are "filter" (a string or a list) and "orderBy".
type NodeVis struct {
	Vis
	Filter  []string `json:"filter,omitempty"`
	OrderBy string   `json:"orderBy,omitempty"`
}

// Name is the erupt name the server addresses as "<node>.<Name>".
func (m *Model) Name() string { return m.name }

// PK is the primary key field, "" for a model that only serves as an operation form.
func (m *Model) PK() string { return m.pk }

// FieldNames lists the fields in declaration order.
func (m *Model) FieldNames() []string {
	names := make([]string, len(m.fields))
	for i, f := range m.fields {
		names[i] = f.name
	}
	return names
}

// FieldType is the edit type of a field (DATE_TIME for a DATE with a time of day), "" for the primary key.
func (m *Model) FieldType(name string) string {
	if f := m.byName[name]; f != nil {
		return f.typ
	}
	return ""
}

type modelConfig struct {
	name    string
	power   map[string]bool
	orderBy string
	raw     any
	edits   map[string]any
	views   map[string]any
	ops     []Operation
	proxies []DataProxy
}

// ModelOption configures NewModel.
type ModelOption func(*modelConfig)

// WithName sets the erupt name; it defaults to the struct name.
func WithName(name string) ModelOption { return func(c *modelConfig) { c.name = name } }

// WithPower switches features off, e.g. map[string]bool{"delete": false}.
func WithPower(power map[string]bool) ModelOption {
	return func(c *modelConfig) {
		for k, v := range power {
			c.power[k] = v
		}
	}
}

// WithOrderBy is the default table order, applied by the node: "views desc, id".
func WithOrderBy(orderBy string) ModelOption { return func(c *modelConfig) { c.orderBy = orderBy } }

// WithRaw passes raw @Erupt attributes (an M or an Erupt) merged onto the defaults.
func WithRaw(raw any) ModelOption { return func(c *modelConfig) { c.raw = raw } }

// WithFieldEdit passes raw @Edit attributes (an M or an Edit) for one field.
func WithFieldEdit(field string, edit any) ModelOption {
	return func(c *modelConfig) { c.edits[field] = edit }
}

// WithFieldView passes raw @View attributes (an M or a View) for one field.
func WithFieldView(field string, view any) ModelOption {
	return func(c *modelConfig) { c.views[field] = view }
}

// WithOperations declares row operations.
func WithOperations(ops ...Operation) ModelOption {
	return func(c *modelConfig) { c.ops = append(c.ops, ops...) }
}

// WithDataProxy declares hooks run around every read and write of the model, in declaration order.
func WithDataProxy(proxies ...DataProxy) ModelOption {
	return func(c *modelConfig) { c.proxies = append(c.proxies, proxies...) }
}

// DataProxy hooks around a model's data, as erupt's Java DataProxy: embed BaseDataProxy, override what you
// need and pass it to WithDataProxy. A record is what the repository stores, a row what the browser reads;
// change them in place. Return Fail(...) to refuse with a message.
type DataProxy interface {
	SearchCondition(ctx context.Context, condition M) error // default values of the search bar: condition[field] = value
	// BeforeFetch returns SQL ANDed to a table page's WHERE, as written; with Params, each '?' is bound to one:
	// Filter{SQL: "owner = ?", Params: []any{uid}}; an empty SQL adds nothing. conditions are the search
	// bar's. Only SQL repositories apply it; MemoryRepository refuses the page.
	BeforeFetch(ctx context.Context, conditions []Cond) (Filter, error)
	AfterFetch(ctx context.Context, rows []M) error        // the rows of a table page, before they are sent
	AddBehavior(ctx context.Context, record Record) error  // the values a new record's form opens with
	EditBehavior(ctx context.Context, record Record) error // a record read by its key (edit form, detail view)
	Validate(ctx context.Context, record Record) error     // a record about to be added or updated
	BeforeAdd(ctx context.Context, record Record) error
	AfterAdd(ctx context.Context, record Record) error
	BeforeUpdate(ctx context.Context, record Record) error
	AfterUpdate(ctx context.Context, record Record) error
	BeforeDelete(ctx context.Context, record Record) error
	AfterDelete(ctx context.Context, record Record) error
}

// BaseDataProxy is a DataProxy whose hooks do nothing, to embed.
type BaseDataProxy struct{}

func (BaseDataProxy) SearchCondition(context.Context, M) error            { return nil }
func (BaseDataProxy) BeforeFetch(context.Context, []Cond) (Filter, error) { return Filter{}, nil }
func (BaseDataProxy) AfterFetch(context.Context, []M) error               { return nil }
func (BaseDataProxy) AddBehavior(context.Context, Record) error           { return nil }
func (BaseDataProxy) EditBehavior(context.Context, Record) error          { return nil }
func (BaseDataProxy) Validate(context.Context, Record) error              { return nil }
func (BaseDataProxy) BeforeAdd(context.Context, Record) error             { return nil }
func (BaseDataProxy) AfterAdd(context.Context, Record) error              { return nil }
func (BaseDataProxy) BeforeUpdate(context.Context, Record) error          { return nil }
func (BaseDataProxy) AfterUpdate(context.Context, Record) error           { return nil }
func (BaseDataProxy) BeforeDelete(context.Context, Record) error          { return nil }
func (BaseDataProxy) AfterDelete(context.Context, Record) error           { return nil }

// hook runs one DataProxy hook (a method expression, DataProxy.Validate) on every proxy of a model, in
// declaration order, until one refuses.
func hook[T any](ctx context.Context, m *Model, h func(DataProxy, context.Context, T) error, v T) error {
	for _, p := range m.proxies {
		if err := h(p, ctx, v); err != nil {
			return err
		}
	}
	return nil
}

// NewModel declares an erupt model from a struct whose fields carry `erupt:"..."` tags:
//
//	pk                    the primary key
//	title=Title           column and form label
//	search, notNull, sortable, hideTable, hideForm
//	virtual               in the build only (DIVIDE, CALLOUT, EMPTY, GROUP): no column, never read or written
//	type=TEXTAREA         an EditType; otherwise inferred from the Go type
//	choices=a:A,b:B       a CHOICE field
//	ref=Category          references a record of another model (registered first); label=name, tree=parent
//
// A slice or map field (MULTI_CHOICE, KEY_VALUE) holds a JSON value, kept as JSON text by SQL repositories.
// The field name is the json tag name, else the Go field name. Every raw attribute is checked against the
// erupt annotation schema here, so a misspelt key fails at declaration instead of in the browser.
func NewModel(declaration any, title string, opts ...ModelOption) (*Model, error) {
	t := reflect.TypeOf(declaration)
	for t != nil && t.Kind() == reflect.Pointer {
		t = t.Elem()
	}
	if t == nil || t.Kind() != reflect.Struct {
		return nil, errors.New("erupt: a model is declared with a struct")
	}
	cfg := &modelConfig{power: map[string]bool{}, edits: map[string]any{}, views: map[string]any{}}
	for _, opt := range opts {
		opt(cfg)
	}
	m := &Model{name: cfg.name, title: title, byName: map[string]*field{}, proxies: cfg.proxies}
	if m.name == "" {
		m.name = t.Name()
	}
	if !identifier.MatchString(m.name) {
		return nil, fmt.Errorf("erupt name '%s' must be an identifier", m.name)
	}
	pulled, views, err := pullVis(cfg.raw, "@erupt "+m.name)
	if err != nil {
		return nil, err
	}
	raw, err := rawObject(pulled, "Erupt", "@erupt "+m.name)
	if err != nil {
		return nil, err
	}
	m.raw = raw
	m.power = map[string]bool{}
	for k, v := range defaults.Power {
		m.power[k] = v
	}
	for k, v := range cfg.power {
		if _, ok := defaults.Power[k]; !ok {
			return nil, fmt.Errorf("%s: unknown power '%s'", m.name, k)
		}
		m.power[k] = v
	}
	for i := 0; i < t.NumField(); i++ {
		sf := t.Field(i)
		tag, ok := sf.Tag.Lookup("erupt")
		if !ok || tag == "-" {
			continue
		}
		f, err := parseField(m.name, sf, tag)
		if err != nil {
			return nil, err
		}
		if m.byName[f.name] != nil {
			return nil, fmt.Errorf("%s: field '%s' declared twice", m.name, f.name)
		}
		m.fields = append(m.fields, f)
		m.byName[f.name] = f
	}
	for name, edit := range cfg.edits {
		if m.byName[name] == nil {
			return nil, fmt.Errorf("%s: WithFieldEdit names no field '%s'", m.name, name)
		}
		if m.byName[name].edit, err = rawObject(edit, "Edit", m.name+"."+name+".edit"); err != nil {
			return nil, err
		}
	}
	for name, view := range cfg.views {
		if m.byName[name] == nil {
			return nil, fmt.Errorf("%s: WithFieldView names no field '%s'", m.name, name)
		}
		if m.byName[name].view, err = rawObject(view, "View", m.name+"."+name+".view"); err != nil {
			return nil, err
		}
	}
	for _, f := range m.fields {
		if f.pk {
			if m.pk != "" {
				return nil, fmt.Errorf("%s: at most one pk field", m.name)
			}
			m.pk = f.name
		}
	}
	for i := range cfg.ops {
		op, err := newOperation(m.name, cfg.ops[i])
		if err != nil {
			return nil, err
		}
		for _, other := range m.operations {
			if other.Code == op.Code {
				return nil, fmt.Errorf("%s: operation code '%s' declared twice", m.name, op.Code)
			}
		}
		m.operations = append(m.operations, op)
	}
	if m.orderBy, err = m.parseOrder(cfg.orderBy); err != nil {
		return nil, err
	}
	m.vis = map[string]view{}
	for code, v := range views {
		orders, err := m.parseOrder(v.OrderBy)
		if err != nil {
			return nil, err
		}
		filters := make([]Filter, len(v.Filter))
		for i, sql := range v.Filter {
			filters[i] = Filter{SQL: sql}
		}
		m.vis[code] = view{filters, orders}
	}
	return m, nil
}

// pullVis takes "filter" and "orderBy" out of every raw vis entry before the schema check, as they run on the
// node; a view without a code is addressed by its title.
func pullVis(raw any, path string) (any, map[string]NodeVis, error) {
	if raw == nil {
		return nil, nil, nil
	}
	v, err := toJSONValue(raw)
	if err != nil {
		return nil, nil, fmt.Errorf("%s: %w", path, err)
	}
	obj, _ := v.(map[string]any)
	entries, _ := obj["vis"].([]any)
	views := map[string]NodeVis{}
	for i, e := range entries {
		entry, ok := e.(map[string]any)
		if !ok {
			continue // the schema check reports it
		}
		if _, ok := entry["code"]; !ok {
			entry["code"] = str(entry["title"])
		}
		var nv NodeVis
		switch f := entry["filter"].(type) {
		case nil:
		case string:
			nv.Filter = []string{f}
		case []any:
			for _, sql := range f {
				s, ok := sql.(string)
				if !ok {
					return nil, nil, fmt.Errorf("%s.vis[%d].filter: a SQL string or a list of them", path, i)
				}
				nv.Filter = append(nv.Filter, s)
			}
		default:
			return nil, nil, fmt.Errorf("%s.vis[%d].filter: a SQL string or a list of them", path, i)
		}
		if o, ok := entry["orderBy"]; ok {
			if nv.OrderBy, ok = o.(string); !ok {
				return nil, nil, fmt.Errorf("%s.vis[%d].orderBy: a string such as \"title desc, id\"", path, i)
			}
		}
		delete(entry, "filter")
		delete(entry, "orderBy")
		views[str(entry["code"])] = nv
	}
	return v, views, nil
}

func parseField(model string, sf reflect.StructField, tag string) (*field, error) {
	f := &field{name: sf.Name, table: true, form: true, label: "name"}
	if j := strings.Split(sf.Tag.Get("json"), ",")[0]; j != "" && j != "-" {
		f.name = j
	}
	path := model + "." + f.name
	if !identifier.MatchString(f.name) {
		return nil, fmt.Errorf("field '%s' must be an identifier", f.name)
	}
	for _, part := range strings.Split(tag, ";") {
		key, value, _ := strings.Cut(strings.TrimSpace(part), "=")
		switch key {
		case "":
		case "pk":
			f.pk = true
		case "title":
			f.title = value
		case "search":
			f.search = true
		case "notNull":
			f.notNull = true
		case "sortable":
			f.sortable = true
		case "hideTable":
			f.table = false
		case "hideForm":
			f.form = false
		case "virtual":
			f.virtual = true
		case "type":
			if err := checkEnum(EditTypeValues, value, "EditType", path+".type"); err != nil {
				return nil, err
			}
			f.typ = value
		case "choices":
			for _, kv := range strings.Split(value, ",") {
				v, label, ok := strings.Cut(kv, ":")
				if !ok {
					label = v
				}
				f.choices = append(f.choices, choice{strings.TrimSpace(v), strings.TrimSpace(label)})
			}
		case "ref":
			f.ref = value
		case "label":
			f.label = value
		case "tree":
			f.tree = value
		default:
			return nil, fmt.Errorf("%s: unknown erupt tag '%s'", path, key)
		}
	}
	if f.pk {
		f.typ = ""
		return f, nil
	}
	f.typ = resolveType(f, sf.Type)
	ft := sf.Type
	for ft.Kind() == reflect.Pointer {
		ft = ft.Elem()
	}
	f.json = ft.Kind() == reflect.Map || (ft.Kind() == reflect.Slice && ft.Elem().Kind() != reflect.Uint8)
	if f.virtual && (f.search || f.sortable || f.notNull) {
		return nil, fmt.Errorf("%s: a virtual field cannot be searched, sorted or required", path)
	}
	if f.json && (f.search || f.sortable) {
		return nil, fmt.Errorf("%s: a JSON field cannot be searched or sorted", path)
	}
	if _, ok := defaults.Fields[f.typ]; !ok {
		return nil, fmt.Errorf("%s: edit type %s is not supported yet", path, f.typ)
	}
	return f, nil
}

func resolveType(f *field, t reflect.Type) string {
	if f.ref != "" {
		if f.tree != "" {
			return typeReferenceTree
		}
		return typeReferenceTable
	}
	if f.typ != "" {
		return f.typ
	}
	if f.choices != nil {
		return "CHOICE"
	}
	for t.Kind() == reflect.Pointer {
		t = t.Elem()
	}
	if t == reflect.TypeOf(time.Time{}) {
		return typeDateTime
	}
	switch t.Kind() {
	case reflect.Bool:
		return "BOOLEAN"
	case reflect.Int, reflect.Int8, reflect.Int16, reflect.Int32, reflect.Int64, reflect.Uint, reflect.Uint8,
		reflect.Uint16, reflect.Uint32, reflect.Uint64, reflect.Float32, reflect.Float64:
		return "NUMBER"
	}
	return "INPUT"
}

func checkEnum[T ~string](values []T, value, name, path string) error {
	for _, v := range values {
		if string(v) == value {
			return nil
		}
	}
	return checkSchema(name, value, path, true) // the schema produces the same message
}

// rawObject normalizes a raw override and checks it against a schema definition.
func rawObject(raw any, def, path string) (map[string]any, error) {
	if raw == nil {
		return map[string]any{}, nil
	}
	v, err := toJSONValue(raw)
	if err != nil {
		return nil, fmt.Errorf("%s: %w", path, err)
	}
	if err := checkSchema(def, v, path, true); err != nil {
		return nil, err
	}
	return v.(map[string]any), nil
}

// parseOrder turns "views desc, id" into orders, fields checked against the model.
func (m *Model) parseOrder(orderBy string) ([]Order, error) {
	var orders []Order
	for _, part := range strings.Split(orderBy, ",") {
		words := strings.Fields(part)
		if len(words) == 0 {
			continue
		}
		if len(words) > 2 || m.byName[words[0]] == nil || (len(words) == 2 && !strings.EqualFold(words[1], "asc") && !strings.EqualFold(words[1], "desc")) {
			return nil, fmt.Errorf("%s: illegal order_by '%s'", m.name, strings.TrimSpace(part))
		}
		orders = append(orders, Order{Field: words[0], Desc: len(words) == 2 && strings.EqualFold(words[1], "desc")})
	}
	return orders, nil
}

// resolve binds reference fields to their target models.
func (m *Model) resolve(lookup func(string) *Model) error {
	for _, f := range m.fields {
		if !f.isReference() {
			continue
		}
		target := lookup(f.ref)
		if target == nil {
			return fmt.Errorf("%s.%s: referenced erupt '%s' is not registered on this node (register it first)", m.name, f.name, f.ref)
		}
		if f.target != nil && f.target != target {
			return fmt.Errorf("%s.%s: already bound to another '%s'", m.name, f.name, f.ref)
		}
		if target.pk == "" {
			return fmt.Errorf("%s.%s: %s has no primary key", m.name, f.name, target.name)
		}
		keys := []string{f.label}
		if f.tree != "" {
			keys = append(keys, f.tree)
		}
		for _, key := range keys {
			if target.byName[key] == nil {
				return fmt.Errorf("%s.%s: %s has no field '%s'", m.name, f.name, target.name, key)
			}
		}
		f.target = target
	}
	for _, op := range m.operations {
		if op.Form != nil {
			if err := op.Form.resolve(lookup); err != nil {
				return err
			}
		}
	}
	return nil
}

func (f *field) build() map[string]any {
	key := f.typ
	if f.pk {
		key = "id"
	}
	tpl := deepCopy(defaults.Fields[key]).(map[string]any)
	tpl["fieldName"] = f.name
	tpl["componentValue"] = nil
	if f.pk {
		return tpl
	}
	efj := tpl["eruptFieldJson"].(map[string]any)
	edit := efj["edit"].(map[string]any)
	view := efj["views"].([]any)[0].(map[string]any)
	edit["title"], edit["notNull"], edit["show"] = f.title, f.notNull, f.form
	edit["search"].(map[string]any)["value"] = f.search
	view["title"], view["sortable"] = f.title, f.sortable
	switch f.typ {
	case "DATE":
		view["type"] = "DATE"
	case typeReferenceTable:
		tpl["fieldReturnName"] = f.target.name
		merge(edit["referenceTableType"].(map[string]any), M{"id": f.target.pk, "label": f.label})
		view["column"] = f.label
	case typeReferenceTree:
		tpl["fieldReturnName"] = f.target.name
		merge(edit["referenceTreeType"].(map[string]any), M{"id": f.target.pk, "label": f.label, "pid": f.tree})
		view["column"] = f.label
	}
	merge(edit, f.edit)
	merge(view, f.view)
	if !f.table {
		efj["views"] = []any{}
	}
	if len(f.choices) > 0 { // a CHOICE, or a MULTI_CHOICE by raw edit: the options travel as componentValue
		options := make([]any, len(f.choices))
		for i, c := range f.choices {
			options[i] = M{"value": c.value, "label": c.label, "desc": nil, "color": nil, "disable": false}
		}
		tpl["componentValue"] = options
	}
	return tpl
}

func (m *Model) buildErupt(ops []*Operation) map[string]any {
	pk := m.pk
	if pk == "" {
		pk = "id"
	}
	erupt := merge(deepCopy(defaults.Erupt).(map[string]any), M{"primaryKeyCol": pk})
	rows := make([]any, len(ops))
	for i, op := range ops {
		rows[i] = op.build()
	}
	erupt["rowOperation"] = rows
	merge(erupt, m.raw)
	fields := make([]any, len(m.fields))
	for i, f := range m.fields {
		fields[i] = f.build()
	}
	return M{"eruptName": m.name, "eruptJson": erupt, "eruptFieldModels": fields,
		"searchCondition": M{}, "extraRow": false, "tags": M{}}
}

func (m *Model) buildModel(power map[string]bool, user *User) map[string]any {
	var visible []*Operation
	forms := M{}
	for _, op := range m.operations {
		if op.visible(user) {
			visible = append(visible, op)
			if op.Form != nil {
				forms[op.Code] = op.Form.buildErupt(nil)
			}
		}
	}
	build := M{"eruptModel": m.buildErupt(visible), "power": power, "tabErupts": nil, "combineErupts": nil,
		"operationErupts": nil}
	if len(forms) > 0 {
		build["operationErupts"] = forms
	}
	return build
}

// coerce turns a JSON value from the browser into the value a repository stores.
func (f *field) coerce(v any) (any, error) {
	if f.isReference() {
		// the browser sends the picked record as {<id>: ..., <label>: ...}
		if obj, ok := v.(map[string]any); ok {
			v = obj[f.target.pk]
		}
		return f.target.byName[f.target.pk].coerce(v)
	}
	if v == nil || v == "" {
		return nil, nil
	}
	if f.json {
		switch v.(type) {
		case []any, map[string]any:
			return v, nil
		}
		return nil, fmt.Errorf("illegal value '%s'", str(v))
	}
	switch {
	case f.pk:
		if s, ok := v.(string); ok {
			n, err := strconv.ParseInt(strings.TrimSpace(s), 10, 64)
			if err != nil {
				return nil, fmt.Errorf("illegal integer '%s'", s)
			}
			return n, nil
		}
		n, ok := toFloat(v)
		if !ok {
			return nil, fmt.Errorf("illegal integer '%s'", str(v))
		}
		return int64(n), nil
	case f.typ == "NUMBER":
		var n float64
		switch t := v.(type) {
		case bool:
			if t {
				n = 1
			}
		case string:
			parsed, err := strconv.ParseFloat(strings.TrimSpace(t), 64)
			if err != nil {
				return nil, fmt.Errorf("illegal number '%s'", t)
			}
			n = parsed
		default:
			parsed, ok := toFloat(v)
			if !ok {
				return nil, fmt.Errorf("illegal number '%s'", str(v))
			}
			n = parsed
		}
		if n == float64(int64(n)) {
			return int64(n), nil
		}
		return n, nil
	case f.typ == "BOOLEAN":
		if b, ok := v.(bool); ok {
			return b, nil
		}
		s := strings.ToLower(str(v))
		return s == "true" || s == "1", nil
	case f.typ == typeDateTime:
		return parseDateTime(v)
	case f.typ == "DATE":
		t, err := parseDateTime(v)
		if err != nil {
			return nil, err
		}
		return time.Date(t.Year(), t.Month(), t.Day(), 0, 0, 0, 0, time.UTC), nil
	case f.typ == "CHOICE" && len(f.choices) > 0:
		s := str(v)
		for _, c := range f.choices {
			if c.value == s {
				return s, nil
			}
		}
		return nil, fmt.Errorf("%s: illegal option '%s'", f.title, s)
	}
	return str(v), nil
}

// jsonValue renders a stored value for the browser.
func (f *field) jsonValue(v any) any {
	if t, ok := v.(time.Time); ok {
		if f.typ == "DATE" {
			return t.Format(dateLayout)
		}
		return t.Format(dateTimeLayout)
	}
	return v
}

func sortedKeys[V any](m map[string]V) []string {
	keys := make([]string, 0, len(m))
	for k := range m {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	return keys
}
