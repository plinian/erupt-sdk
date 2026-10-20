package erupt

import (
	"bytes"
	"context"
	"crypto/subtle"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"math"
	"net/http"
	"regexp"
	"strings"
	"sync"
	"sync/atomic"
	"time"
)

// Version is reported to the server at registration.
const Version = "0.1.0"

// User is the acting user of a request, as the server forwards it.
type User struct {
	UID      int64   `json:"uid"`
	Account  string  `json:"account"`
	Name     string  `json:"name"`
	TenantID *string `json:"tenantId"`
}

type userKey struct{}

// UserFrom returns the acting user of the request being served, nil without one.
func UserFrom(ctx context.Context) *User {
	u, _ := ctx.Value(userKey{}).(*User)
	return u
}

// Config configures a node.
type Config struct {
	Name        string   // the node name created on the erupt server
	AccessToken string   // that node's access token
	Servers     []string // erupt server base URLs, used round robin
	// Address is the base URL the server calls this node on; ListenAndServe derives it from the local
	// interface and the listening port when empty.
	Address string
	// Heartbeat is the registration interval, 15s by default.
	Heartbeat time.Duration
	// Logger receives errors and warnings; log.Default() when nil.
	Logger *log.Logger
	// RequireSignature refuses server calls without a valid Erupt-Signature, so the plain access token
	// alone no longer passes (servers sign since erupt 2.3.x).
	RequireSignature bool
}

// Node serves registered models to an erupt cloud server (erupt-cloud/PROTOCOL.md). It is an
// http.Handler, so it can be mounted in any Go server; ListenAndServe also registers it.
type Node struct {
	cfg     Config
	mu      sync.RWMutex
	models  map[string]*registered
	names   []string
	client  *http.Client
	next    atomic.Uint64
	powerMu sync.Mutex
	powers  map[[2]string]cachedPower
}

type registered struct {
	model *Model
	repo  Repository
}

type cachedPower struct {
	until time.Time
	power map[string]bool
}

// Features whose endpoints this SDK does not serve yet: hidden from the UI instead of failing there.
var unsupportedPower = map[string]bool{"print": false, "ai": false}

// Rights the server decides per user; the node ANDs them onto the declared power.
var serverPower = []string{"add", "edit", "delete", "viewDetails", "export", "importable"}

var queryOps = map[string]bool{"EQ": true, "NEQ": true, "GT": true, "GTE": true, "LT": true, "LTE": true, "LIKE": true,
	"NOT_LIKE": true, "RANGE": true, "IN": true, "NOT_IN": true, "NULL": true, "NOT_NULL": true}

const (
	maxPageSize = 1000
)

// NewNode creates a node; register models on it before serving.
func NewNode(cfg Config) (*Node, error) {
	if cfg.Name == "" || cfg.AccessToken == "" || len(cfg.Servers) == 0 {
		return nil, errors.New("erupt: Name, AccessToken and Servers are required")
	}
	for i, s := range cfg.Servers {
		cfg.Servers[i] = strings.TrimRight(s, "/")
	}
	if cfg.Heartbeat <= 0 {
		cfg.Heartbeat = 15 * time.Second
	}
	if cfg.Logger == nil {
		cfg.Logger = log.Default()
	}
	return &Node{cfg: cfg, models: map[string]*registered{}, client: &http.Client{Timeout: 10 * time.Second},
		powers: map[[2]string]cachedPower{}}, nil
}

// Register serves a model from a repository. A referenced model must be registered first.
func (n *Node) Register(m *Model, repo Repository) error {
	n.mu.Lock()
	defer n.mu.Unlock()
	if n.models[m.name] != nil {
		return fmt.Errorf("erupt '%s' registered twice", m.name)
	}
	if m.pk == "" {
		return fmt.Errorf("%s has no pk field; only an operation form may omit it", m.name)
	}
	if err := m.resolve(func(name string) *Model {
		if r := n.models[name]; r != nil {
			return r.model
		}
		return nil
	}); err != nil {
		return err
	}
	if b, ok := repo.(Binder); ok {
		if err := b.Bind(m); err != nil {
			return err
		}
	}
	n.models[m.name] = &registered{m, repo}
	n.names = append(n.names, m.name)
	return nil
}

// reply is a bare status answer (403 / 404).
type reply struct{ status int }

func (r reply) Error() string { return http.StatusText(r.status) }

type request struct {
	r        *http.Request
	ctx      context.Context
	model    *Model
	repo     Repository
	args     []string
	body     []byte
	enforced map[string]bool // checks the server ran, from a verified Erupt-Enforced
}

type route struct {
	method  string
	pattern *regexp.Regexp
	handle  func(*Node, *request) (any, error)
}

var routes = []route{
	{"GET", regexp.MustCompile(`^/erupt-api/build/([^/]+)$`), (*Node).build},
	{"POST", regexp.MustCompile(`^/erupt-api/data/table/([^/]+)$`), (*Node).table},
	{"GET", regexp.MustCompile(`^/erupt-api/data/init-value/([^/]+)$`), (*Node).initValue},
	{"GET", regexp.MustCompile(`^/erupt-api/data/([^/]+)/([^/]+)$`), (*Node).get},
	{"POST", regexp.MustCompile(`^/erupt-api/data/modify/([^/]+)$`), (*Node).add},
	{"POST", regexp.MustCompile(`^/erupt-api/data/modify/([^/]+)/update$`), (*Node).update},
	{"POST", regexp.MustCompile(`^/erupt-api/data/modify/([^/]+)/delete$`), (*Node).delete},
	{"POST", regexp.MustCompile(`^/erupt-api/invoke/([^/]+)/([^/]+)/([^/]+)$`), (*Node).invoke},
}

func r(success bool, message, data any) M {
	status := "SUCCESS"
	if !success {
		status = "ERROR"
	}
	return M{"success": success, "status": status, "message": message, "data": data, "promptWay": "MESSAGE"}
}

// ServeHTTP answers the requests the erupt server forwards.
func (n *Node) ServeHTTP(w http.ResponseWriter, hr *http.Request) {
	status, body := n.dispatchSafely(hr)
	var payload []byte
	contentType := "application/json; charset=utf-8"
	if s, ok := body.(string); ok {
		payload, contentType = []byte(s), "text/plain; charset=utf-8"
	} else {
		var buf bytes.Buffer
		enc := json.NewEncoder(&buf)
		enc.SetEscapeHTML(false)
		if err := enc.Encode(body); err != nil {
			n.cfg.Logger.Printf("erupt node: encode %s: %v", hr.URL.Path, err)
			status, payload = 500, []byte(`{"status":500,"error":"erupt exception"}`)
		} else {
			payload = bytes.TrimRight(buf.Bytes(), "\n")
		}
	}
	w.Header().Set("Content-Type", contentType)
	w.WriteHeader(status)
	_, _ = w.Write(payload)
}

func (n *Node) dispatchSafely(hr *http.Request) (status int, body any) {
	defer func() {
		if p := recover(); p != nil {
			n.cfg.Logger.Printf("erupt node: panic serving %s: %v", hr.URL.Path, p)
			status, body = 500, M{"path": hr.URL.Path, "status": 500, "error": "erupt exception", "message": fmt.Sprint(p)}
		}
	}()
	result, err := n.dispatch(hr)
	if err == nil {
		return 200, result
	}
	var rep reply
	if errors.As(err, &rep) {
		return rep.status, ""
	}
	if f, ok := isFail(err); ok {
		return 200, r(false, f.Message, nil)
	}
	// message only, the details stay in the node log
	n.cfg.Logger.Printf("erupt node: %s: %v", hr.URL.Path, err)
	return 500, M{"path": hr.URL.Path, "status": 500, "error": "erupt exception", "message": err.Error()}
}

func (n *Node) dispatch(hr *http.Request) (any, error) {
	path := hr.URL.Path
	if path == "/node-health" {
		return n.cfg.Name, nil
	}
	if !strings.HasPrefix(path, "/erupt-api/") {
		return nil, reply{404}
	}
	// server-to-server only: an Origin header means a browser reached the node directly
	if hr.Header.Get("Origin") != "" {
		return nil, reply{403}
	}
	body, err := io.ReadAll(io.LimitReader(hr.Body, 32<<20))
	if err != nil {
		return nil, err
	}
	enforced, err := n.authenticate(hr, body)
	if err != nil {
		return nil, err
	}
	erupt := hr.Header.Get("erupt")
	for _, rt := range routes {
		groups := rt.pattern.FindStringSubmatch(path)
		if groups == nil || rt.method != hr.Method {
			continue
		}
		name := groups[1]
		n.mu.RLock()
		reg := n.models[name]
		n.mu.RUnlock()
		if erupt != name || reg == nil {
			return nil, reply{404}
		}
		parent := hr.Header.Get("eruptParent")
		if parent == "" {
			parent = hr.URL.Query().Get("_eruptParent")
		}
		// nesting is not supported yet, so a parent can only vouch for itself
		if parent != "" && parent[strings.LastIndex(parent, ".")+1:] != name {
			return nil, reply{404}
		}
		ctx := hr.Context()
		if header := hr.Header.Get("user"); header != "" {
			raw, err := base64.StdEncoding.DecodeString(header)
			if err != nil {
				return nil, fmt.Errorf("illegal user header: %w", err)
			}
			var user User
			if err := json.Unmarshal(raw, &user); err != nil {
				return nil, fmt.Errorf("illegal user header: %w", err)
			}
			ctx = context.WithValue(ctx, userKey{}, &user)
		}
		return rt.handle(n, &request{r: hr, ctx: ctx, model: reg.model, repo: reg.repo, args: groups[2:], body: body, enforced: enforced})
	}
	return nil, reply{404}
}

// authenticate admits a server call: a signed call must verify and then stands for the token; its
// Erupt-Enforced is trusted only then. Unsigned calls present the access token.
func (n *Node) authenticate(hr *http.Request, body []byte) (map[string]bool, error) {
	signature := hr.Header.Get(HeaderSignature)
	if signature == "" {
		if n.cfg.RequireSignature || subtle.ConstantTimeCompare([]byte(hr.Header.Get("Access-Token")), []byte(n.cfg.AccessToken)) != 1 {
			return nil, reply{403}
		}
		return nil, nil
	}
	pathAndQuery := hr.URL.EscapedPath()
	if hr.URL.RawQuery != "" {
		pathAndQuery += "?" + hr.URL.RawQuery
	}
	signed := body
	if strings.Contains(hr.Header.Get("Content-Type"), "multipart/form-data") {
		signed = nil
	} else if signed == nil {
		signed = []byte{}
	}
	enforced := hr.Header.Get(HeaderEnforced)
	if !VerifySignature(n.cfg.AccessToken, hr.Method, pathAndQuery, hr.Header.Get(HeaderTimestamp), enforced,
		hr.Header.Get("user"), signed, signature, time.Now().Unix()) {
		return nil, reply{403}
	}
	checks := map[string]bool{}
	for _, c := range strings.Split(enforced, ",") {
		if c = strings.TrimSpace(c); c != "" {
			checks[c] = true
		}
	}
	return checks, nil
}

// json decodes the request body, nil when empty.
func (q *request) json() (any, error) {
	if len(bytes.TrimSpace(q.body)) == 0 {
		return nil, nil
	}
	var v any
	if err := decode(q.body, &v); err != nil {
		return nil, Fail("malformed JSON body")
	}
	return v, nil
}

func (q *request) object() (map[string]any, error) {
	v, err := q.json()
	if err != nil || v == nil {
		return map[string]any{}, err
	}
	obj, ok := v.(map[string]any)
	if !ok {
		return nil, Fail("a JSON object is required")
	}
	return obj, nil
}

// ---------------------------------------------------------------- endpoints

func (n *Node) build(q *request) (any, error) {
	build := q.model.buildModel(n.power(q, q.model), UserFrom(q.ctx))
	condition := M{}
	if err := hook(q.ctx, q.model, DataProxy.SearchCondition, condition); err != nil {
		return nil, err
	}
	build["eruptModel"].(M)["searchCondition"] = condition
	return build, nil
}

func (n *Node) table(q *request) (any, error) {
	if err := n.require(q, "query"); err != nil {
		return nil, err
	}
	body, err := q.object()
	if err != nil {
		return nil, err
	}
	return n.page(q.ctx, q.model, q.repo, body)
}

func number(v any, fallback int) int {
	if f, ok := toFloat(v); ok && f != 0 {
		return int(f)
	}
	return fallback
}

func (n *Node) page(ctx context.Context, m *Model, repo Repository, body map[string]any) (any, error) {
	pageIndex := number(body["pageIndex"], 1)
	if pageIndex < 1 {
		pageIndex = 1
	}
	pageSize := number(body["pageSize"], 10)
	pageSize = int(math.Min(math.Max(float64(pageSize), 1), maxPageSize))
	q := Query{Offset: (pageIndex - 1) * pageSize, Limit: pageSize}
	conditions, _ := body["condition"].([]any)
	for _, c := range conditions {
		obj, ok := c.(map[string]any)
		if !ok {
			return nil, Fail("illegal condition")
		}
		cond, err := condition(m, obj)
		if err != nil {
			return nil, err
		}
		q.Conditions = append(q.Conditions, cond)
	}
	sorts, _ := body["sort"].([]any)
	for _, s := range sorts {
		obj, _ := s.(map[string]any)
		f := m.byName[str(obj["field"])]
		if f == nil || !(f.sortable || f.pk) {
			return nil, Fail("illegal sort field '%s'", str(obj["field"]))
		}
		q.Sort = append(q.Sort, Order{Field: f.name, Desc: strings.EqualFold(str(obj["direction"]), "DESC")})
	}
	// a @LinkTree table shows the rows under the picked tree keys; with dependNode, none until one is picked
	picked := body["linkTreeVal"]
	if m.linkTree != "" && picked != nil {
		cond, err := fieldCondition(m.byName[m.linkTree], "IN", picked)
		if err != nil {
			return nil, err
		}
		q.Conditions = append(q.Conditions, cond)
	}
	// a @Vis view's own filter and order, then the DataProxy's
	code, _ := body["vis"].(string)
	v := m.vis[code]
	if len(q.Sort) == 0 {
		q.Sort = append([]Order{}, v.orderBy...)
	}
	if len(q.Sort) == 0 {
		q.Sort = append([]Order{}, m.orderBy...)
	}
	q.Filters = append(q.Filters, v.filters...)
	for _, p := range m.proxies {
		f, err := p.BeforeFetch(ctx, q.Conditions)
		if err != nil {
			return nil, err
		}
		if f.SQL != "" {
			q.Filters = append(q.Filters, f)
		}
	}
	total, records := int64(0), []Record{}
	if !m.dependNode || picked != nil {
		var err error
		if total, records, err = repo.Page(ctx, q); err != nil {
			return nil, err
		}
	}
	rows, err := n.rows(ctx, m, records)
	if err != nil {
		return nil, err
	}
	if err := hook(ctx, m, DataProxy.AfterFetch, rows); err != nil {
		return nil, err
	}
	return M{"pageIndex": pageIndex, "pageSize": pageSize, "total": total,
		"totalPage": int64(math.Ceil(float64(total) / float64(pageSize))), "list": rows,
		"sort": nil, "alert": nil, "extraContent": nil}, nil
}

func condition(m *Model, c map[string]any) (Cond, error) {
	key := str(c["key"])
	f := m.byName[key]
	if f == nil || f.pk || !f.search {
		return Cond{}, Fail("illegal search field '%s'", key)
	}
	op := str(c["expression"])
	if op == "" {
		op = "EQ"
	}
	if !queryOps[op] {
		return Cond{}, Fail("illegal operator '%s'", op)
	}
	return fieldCondition(f, op, c["value"])
}

// fieldCondition coerces a condition's value to the field's type.
func fieldCondition(f *field, op string, value any) (Cond, error) {
	switch {
	case op == "NULL" || op == "NOT_NULL":
		return Cond{Field: f.name, Op: op}, nil
	case f.isReference() && op != "EQ" && op != "NEQ" && op != "IN" && op != "NOT_IN":
		return Cond{}, Fail("illegal operator '%s' for a reference", op)
	case op == "LIKE" || op == "NOT_LIKE":
		return Cond{Field: f.name, Op: op, Value: str(value)}, nil
	case op == "RANGE":
		bounds, ok := value.([]any)
		if !ok || len(bounds) != 2 {
			return Cond{}, Fail("range needs two values")
		}
		values, err := coerceAll(f, bounds)
		return Cond{Field: f.name, Op: op, Value: values}, err
	case op == "IN" || op == "NOT_IN":
		list, ok := value.([]any)
		if !ok {
			list = []any{value}
		}
		values, err := coerceAll(f, list)
		return Cond{Field: f.name, Op: op, Value: values}, err
	}
	v, err := f.coerce(value)
	if err != nil {
		return Cond{}, Fail("%s", err.Error())
	}
	return Cond{Field: f.name, Op: op, Value: v}, nil
}

func coerceAll(f *field, values []any) ([]any, error) {
	out := make([]any, len(values))
	for i, v := range values {
		c, err := f.coerce(v)
		if err != nil {
			return nil, Fail("%s", err.Error())
		}
		out[i] = c
	}
	return out, nil
}

func (n *Node) initValue(q *request) (any, error) {
	if err := n.require(q, "add"); err != nil {
		return nil, err
	}
	record := emptyRow(q.model)
	if err := hook(q.ctx, q.model, DataProxy.AddBehavior, record); err != nil {
		return nil, err
	}
	rows, err := n.rows(q.ctx, q.model, []Record{record})
	if err != nil {
		return nil, err
	}
	return rows[0], nil
}

func emptyRow(m *Model) M {
	row := M{}
	for _, f := range m.stored() {
		row[f.name] = nil
	}
	return row
}

func (n *Node) get(q *request) (any, error) {
	power := n.power(q, q.model)
	if !power["edit"] && !power["viewDetails"] {
		return nil, reply{403}
	}
	pk, err := primaryKey(q.model, q.args[0])
	if err != nil {
		return nil, err
	}
	record, err := q.repo.Get(q.ctx, pk)
	if err != nil {
		return nil, err
	}
	if record == nil {
		return nil, Fail("record not found")
	}
	if err := hook(q.ctx, q.model, DataProxy.EditBehavior, record); err != nil {
		return nil, err
	}
	rows, err := n.rows(q.ctx, q.model, []Record{record})
	if err != nil {
		return nil, err
	}
	return rows[0], nil
}

func (n *Node) add(q *request) (any, error) {
	if err := n.require(q, "add"); err != nil {
		return nil, err
	}
	body, err := q.object()
	if err != nil {
		return nil, err
	}
	record, err := toRecord(q.model, body)
	if err != nil {
		return nil, err
	}
	if err := hook(q.ctx, q.model, DataProxy.Validate, record); err != nil {
		return nil, err
	}
	if err := hook(q.ctx, q.model, DataProxy.BeforeAdd, record); err != nil {
		return nil, err
	}
	if err := q.repo.Add(q.ctx, record); err != nil {
		return nil, err
	}
	if err := hook(q.ctx, q.model, DataProxy.AfterAdd, record); err != nil {
		return nil, err
	}
	return r(true, nil, nil), nil
}

func (n *Node) update(q *request) (any, error) {
	if err := n.require(q, "edit"); err != nil {
		return nil, err
	}
	body, err := q.object()
	if err != nil {
		return nil, err
	}
	pk, err := primaryKey(q.model, body[q.model.pk])
	if err != nil {
		return nil, err
	}
	existing, err := q.repo.Get(q.ctx, pk)
	if err != nil {
		return nil, err
	}
	if existing == nil {
		return nil, Fail("record not found")
	}
	record, err := toRecord(q.model, body)
	if err != nil {
		return nil, err
	}
	if err := hook(q.ctx, q.model, DataProxy.Validate, record); err != nil {
		return nil, err
	}
	if err := hook(q.ctx, q.model, DataProxy.BeforeUpdate, record); err != nil {
		return nil, err
	}
	if err := q.repo.Update(q.ctx, pk, record); err != nil {
		return nil, err
	}
	if err := hook(q.ctx, q.model, DataProxy.AfterUpdate, record); err != nil {
		return nil, err
	}
	return r(true, nil, nil), nil
}

func (n *Node) delete(q *request) (any, error) {
	if err := n.require(q, "delete"); err != nil {
		return nil, err
	}
	body, err := q.json()
	if err != nil {
		return nil, err
	}
	ids, ok := body.([]any)
	if !ok {
		return nil, Fail("a list of ids is required")
	}
	pks := make([]any, len(ids))
	for i, id := range ids {
		if pks[i], err = primaryKey(q.model, id); err != nil {
			return nil, err
		}
	}
	// the hooks see each record as it was; reading them costs nothing without a proxy
	var records []Record
	for i := 0; i < len(pks) && len(q.model.proxies) > 0; i++ {
		record, err := q.repo.Get(q.ctx, pks[i])
		if err != nil {
			return nil, err
		}
		if record != nil {
			records = append(records, record)
		}
	}
	for _, record := range records {
		if err := hook(q.ctx, q.model, DataProxy.BeforeDelete, record); err != nil {
			return nil, err
		}
	}
	if err := q.repo.Delete(q.ctx, pks); err != nil {
		return nil, err
	}
	for _, record := range records {
		if err := hook(q.ctx, q.model, DataProxy.AfterDelete, record); err != nil {
			return nil, err
		}
	}
	return r(true, nil, nil), nil
}

// invoke runs the node's own code (erupt-cloud/PROTOCOL.md §5.5): a row operation and its form values under the
// operation code, or a field's fetched options, onchange, auto-complete or button with the form's values.
func (n *Node) invoke(q *request) (any, error) {
	switch q.args[0] {
	case "operation":
		return n.operation(q, q.args[1])
	case "operation-form":
		return n.operationFormValue(q, q.args[1])
	}
	f := q.model.byName[q.args[1]]
	if f == nil {
		return nil, reply{404}
	}
	body, err := q.object()
	if err != nil {
		return nil, err
	}
	form, _ := body["form"].(map[string]any)
	if form == nil {
		form = M{}
	}
	var data any
	switch c := f.code; {
	case q.args[0] == "options" && c.Fetch != nil:
		var options []Option
		options, err = c.Fetch(q.ctx, form)
		data = append([]Option{}, options...)
	case q.args[0] == "options" && c.Tags != nil:
		var tags []string
		tags, err = c.Tags(q.ctx, form)
		data = append([]string{}, tags...)
	case q.args[0] == "onchange" && c.Onchange != nil:
		data, err = c.Onchange(q.ctx, form)
	case q.args[0] == "autocomplete" && c.Complete != nil:
		typed, _ := body["value"].(string)
		var suggestions []string
		suggestions, err = c.Complete(q.ctx, form, typed)
		data = append([]string{}, suggestions...)
	case q.args[0] == "button" && c.Click != nil:
		data, err = c.Click(q.ctx, form)
	default:
		return nil, reply{404}
	}
	if err != nil {
		return nil, err
	}
	return r(true, nil, data), nil
}

// rows turns records into browser rows. A reference stays its key: the server resolves its label, the
// flattened <field>_<label> column and the tree (erupt-cloud/PROTOCOL.md §7.3).
func (n *Node) rows(_ context.Context, m *Model, records []Record) ([]M, error) {
	rows := make([]M, len(records))
	for i, record := range records {
		row := M{}
		for _, f := range m.stored() {
			row[f.name] = f.jsonValue(record[f.name])
		}
		rows[i] = row
	}
	return rows, nil
}

func (n *Node) operationOf(q *request, code string) (*Operation, error) {
	for _, op := range q.model.operations {
		if op.Code == code {
			// a hidden operation does not exist for this user, exactly like the Java proxy filters it out
			if !op.visible(UserFrom(q.ctx)) {
				return nil, reply{403}
			}
			return op, nil
		}
	}
	return nil, reply{404}
}

func (n *Node) operationFormValue(q *request, code string) (any, error) {
	op, err := n.operationOf(q, code)
	if err != nil {
		return nil, err
	}
	// none without a form: the server answers the browser a 404, and it opens an empty one
	if op.Form == nil {
		return r(true, nil, nil), nil
	}
	return r(true, nil, emptyRow(op.Form)), nil
}

func (n *Node) operation(q *request, code string) (any, error) {
	op, err := n.operationOf(q, code)
	if err != nil {
		return nil, err
	}
	body, err := q.object()
	if err != nil {
		return nil, err
	}
	var param Record
	if op.Form != nil {
		values, _ := body["param"].(map[string]any)
		if param, err = toRecord(op.Form, values); err != nil {
			return nil, err
		}
	}
	var rows []Record
	if op.Mode != RowOperationModeButton {
		ids, _ := body["ids"].([]any)
		if len(ids) == 0 {
			return nil, Fail("select at least one row")
		}
		if op.Mode == RowOperationModeSingle && len(ids) != 1 {
			return nil, Fail("select exactly one row")
		}
		for _, id := range ids {
			pk, err := primaryKey(q.model, id)
			if err != nil {
				return nil, err
			}
			record, err := q.repo.Get(q.ctx, pk)
			if err != nil {
				return nil, err
			}
			if record == nil {
				return nil, Fail("record '%s' not found", str(id))
			}
			rows = append(rows, record)
		}
	}
	script, err := op.Handler(&OpContext{Context: q.ctx, Rows: rows, Param: param, Repo: q.repo, Model: q.model, User: UserFrom(q.ctx)})
	if err != nil {
		return nil, err
	}
	if script != "" {
		return r(true, nil, script), nil
	}
	return r(true, "Executed successfully", nil), nil
}

func primaryKey(m *Model, v any) (any, error) {
	pk, err := m.byName[m.pk].coerce(v)
	if err != nil {
		return nil, Fail("illegal id '%s'", str(v))
	}
	return pk, nil
}

// toRecord coerces and checks the form fields of a body.
func toRecord(m *Model, body map[string]any) (Record, error) {
	record := Record{}
	for _, f := range m.stored() {
		if f.pk || !f.form {
			continue
		}
		v, err := f.coerce(body[f.name])
		if err != nil {
			return nil, Fail("%s: %s", f.title, err.Error())
		}
		if f.notNull && v == nil {
			return nil, Fail("%s cannot be empty", f.title)
		}
		record[f.name] = v
	}
	return record, nil
}
