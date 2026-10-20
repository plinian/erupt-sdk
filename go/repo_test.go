package erupt

import (
	"context"
	"database/sql"
	"encoding/base64"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"reflect"
	"strings"
	"testing"
	"time"

	_ "modernc.org/sqlite"
)

func newSQLite(t *testing.T) *sql.DB {
	t.Helper()
	db, err := sql.Open("sqlite", ":memory:")
	if err != nil {
		t.Fatal(err)
	}
	db.SetMaxOpenConns(1) // one connection, one in-memory database
	t.Cleanup(func() { db.Close() })
	return db
}

func repositories(t *testing.T) map[string]func() Repository {
	return map[string]func() Repository{
		"memory": func() Repository { return NewMemoryRepository() },
		"sqlite": func() Repository { return &SQLRepository{DB: newSQLite(t), Table: "article", AutoCreate: true} },
	}
}

func TestRepositories(t *testing.T) {
	ctx := context.Background()
	for name, factory := range repositories(t) {
		t.Run(name, func(t *testing.T) {
			_, article := testModels(t)
			repo := factory()
			if err := repo.(Binder).Bind(article); err != nil {
				t.Fatal(err)
			}
			day := func(d int) time.Time { return time.Date(2026, 1, d, 0, 0, 0, 0, time.UTC) }
			for i, title := range []string{"100% pure", "100 points", "under_score", "plain"} {
				rec := Record{"title": title, "views": int64(i), "featured": i%2 == 0, "publish_date": day(i + 1),
					"review_at": time.Date(2026, 1, 1, 10, i, 0, 0, time.UTC), "status": "draft"}
				if err := repo.Add(ctx, rec); err != nil {
					t.Fatal(err)
				}
			}
			titles := func(q Query) []string {
				total, records, err := repo.Page(ctx, q)
				if err != nil {
					t.Fatal(err)
				}
				out := []string{}
				for _, r := range records {
					out = append(out, r["title"].(string))
				}
				if q.Limit == 0 && int(total) != len(out) {
					t.Errorf("total %d for %d rows", total, len(out))
				}
				return out
			}
			asc := []Order{{Field: "views"}}
			check := func(what string, got, want []string) {
				t.Helper()
				if !reflect.DeepEqual(got, want) {
					t.Errorf("%s: got %v, want %v", what, got, want)
				}
			}
			check("LIKE escapes %", titles(Query{Conditions: []Cond{{"title", "LIKE", "100%"}}, Sort: asc, Limit: 10}), []string{"100% pure"})
			check("LIKE escapes _", titles(Query{Conditions: []Cond{{"title", "LIKE", "R_S"}}, Sort: asc, Limit: 10}), []string{"under_score"})
			check("NOT_LIKE", titles(Query{Conditions: []Cond{{"title", "NOT_LIKE", "100"}}, Sort: asc, Limit: 10}), []string{"under_score", "plain"})
			check("RANGE date", titles(Query{Conditions: []Cond{{"publish_date", "RANGE", []any{day(2), day(3)}}}, Sort: asc, Limit: 10}), []string{"100 points", "under_score"})
			check("GTE", titles(Query{Conditions: []Cond{{"views", "GTE", int64(2)}}, Sort: asc, Limit: 10}), []string{"under_score", "plain"})
			check("EQ bool", titles(Query{Conditions: []Cond{{"featured", "EQ", true}}, Sort: asc, Limit: 10}), []string{"100% pure", "under_score"})
			check("IN", titles(Query{Conditions: []Cond{{"views", "IN", []any{int64(0), int64(3)}}}, Sort: asc, Limit: 10}), []string{"100% pure", "plain"})
			check("empty IN", titles(Query{Conditions: []Cond{{"views", "IN", []any{}}}, Limit: 10}), []string{})
			check("NULL", titles(Query{Conditions: []Cond{{"body", "NULL", nil}}, Sort: asc, Limit: 10}), []string{"100% pure", "100 points", "under_score", "plain"})
			check("default order is primary key ascending", titles(Query{Limit: 10}), []string{"100% pure", "100 points", "under_score", "plain"})
			check("LIKE escapes !", titles(Query{Conditions: []Cond{{"title", "LIKE", "!"}}, Limit: 10}), []string{})
			check("sort desc + page", titles(Query{Sort: []Order{{Field: "views", Desc: true}}, Offset: 1, Limit: 2}), []string{"under_score", "100 points"})

			_, records, _ := repo.Page(ctx, Query{Sort: asc, Limit: 1})
			got := records[0]
			if got["publish_date"] != day(1) || got["review_at"] != time.Date(2026, 1, 1, 10, 0, 0, 0, time.UTC) || got["featured"] != true {
				t.Errorf("round trip: %#v", got)
			}
			pk := got["id"]
			if err := repo.Update(ctx, pk, Record{"title": "renamed", "id": int64(999)}); err != nil {
				t.Fatal(err)
			}
			if r, _ := repo.Get(ctx, pk); r == nil || r["title"] != "renamed" || r["views"] != int64(0) {
				t.Errorf("update: %#v", r)
			}
			if err := repo.Delete(ctx, []any{pk}); err != nil {
				t.Fatal(err)
			}
			if r, _ := repo.Get(ctx, pk); r != nil {
				t.Errorf("deleted record still there: %#v", r)
			}
		})
	}
}

func TestSQLGeneration(t *testing.T) {
	_, article := testModels(t)
	repo := &SQLRepository{Table: "article", Dollar: true, Quote: `"`}
	repo.model = article
	_, countArgs, page, args := repo.pageSQL(Query{Filters: []Filter{{SQL: "owner = ? OR shared", Params: []any{"admin"}}}, Conditions: []Cond{
		{"title", "LIKE", `50%_off!`}, {"views", "IN", []any{int64(1), int64(2)}}, {"publish_date", "RANGE", []any{time.Date(2026, 1, 1, 0, 0, 0, 0, time.UTC), time.Date(2026, 2, 1, 0, 0, 0, 0, time.UTC)}},
	}, Sort: []Order{{Field: "title", Desc: true}}, Offset: 20, Limit: 10})
	want := `SELECT "id", "title", "status", "views", "featured", "publish_date", "review_at", "body", "category", "topic" FROM "article"` +
		` WHERE (owner = $1 OR shared) AND "title" LIKE $2 ESCAPE '!' AND "views" IN ($3, $4) AND "publish_date" BETWEEN $5 AND $6 ORDER BY "title" DESC LIMIT $7 OFFSET $8`
	if page != want {
		t.Errorf("page SQL\n got %s\nwant %s", page, want)
	}
	if !reflect.DeepEqual(args, []any{"admin", "%50!%!_off!!%", int64(1), int64(2), "2026-01-01", "2026-02-01", 10, 20}) {
		t.Errorf("args %#v", args)
	}
	if len(countArgs) != 6 {
		t.Errorf("count args %#v", countArgs)
	}
	if got := (&SQLRepository{Quote: "`"}).q("a`b"); got != "`a``b`" {
		t.Errorf("quote %s", got)
	}
	if err := (&SQLRepository{Table: "x; DROP TABLE y"}).Bind(article); err == nil {
		t.Error("an illegal table name was accepted")
	}
}

// TestNodeOverSQLite drives the HTTP handler against a fake erupt server, with SQLite storage.
func TestNodeOverSQLite(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_, _ = w.Write([]byte(`{"add":true,"edit":true,"delete":true,"viewDetails":true}`))
	}))
	defer server.Close()
	category, article := testModels(t)
	node, err := NewNode(Config{Name: "n", AccessToken: "secret", Servers: []string{server.URL}})
	if err != nil {
		t.Fatal(err)
	}
	db := newSQLite(t)
	if err := node.Register(category, &SQLRepository{DB: db, Table: "category", AutoCreate: true}); err != nil {
		t.Fatal(err)
	}
	if err := node.Register(article, &SQLRepository{DB: db, Table: "article", AutoCreate: true}); err != nil {
		t.Fatal(err)
	}
	user := base64.StdEncoding.EncodeToString([]byte(`{"uid":1,"account":"admin"}`))
	call := func(method, path, erupt, body string) (int, any) {
		req := httptest.NewRequest(method, path, strings.NewReader(body))
		req.Header.Set("Access-Token", "secret")
		req.Header.Set("erupt", erupt)
		req.Header.Set("user", user)
		w := httptest.NewRecorder()
		node.ServeHTTP(w, req)
		data, _ := io.ReadAll(w.Body)
		var v any
		_ = json.Unmarshal(data, &v)
		return w.Code, v
	}
	for _, name := range []string{"Tech", "Python"} {
		if code, r := call("POST", "/erupt-api/data/modify/Category", "Category", `{"name":"`+name+`"}`); code != 200 || r.(map[string]any)["success"] != true {
			t.Fatalf("add category: %d %v", code, r)
		}
	}
	body := `{"title":"100% pure","status":"draft","views":"7","featured":true,"publish_date":"2026-03-01","review_at":"2026-03-01 08:15:00","category":{"id":"2","name":"Python"}}`
	if code, r := call("POST", "/erupt-api/data/modify/Article", "Article", body); code != 200 || r.(map[string]any)["success"] != true {
		t.Fatalf("add article: %d %v", code, r)
	}
	call("POST", "/erupt-api/data/modify/Article", "Article", `{"title":"100 points"}`)
	code, page := call("POST", "/erupt-api/data/table/Article", "Article",
		`{"pageIndex":1,"pageSize":10,"condition":[{"key":"title","expression":"LIKE","value":"100%"},{"key":"publish_date","expression":"RANGE","value":["2026-02-01","2026-04-01"]}]}`)
	list := page.(map[string]any)["list"].([]any)
	if code != 200 || len(list) != 1 {
		t.Fatalf("table: %d %v", code, page)
	}
	row := list[0].(map[string]any)
	want := map[string]any{"title": "100% pure", "views": 7.0, "featured": true, "publish_date": "2026-03-01",
		"review_at": "2026-03-01T08:15:00.000", "category": 2.0}
	for k, v := range want {
		if !reflect.DeepEqual(row[k], v) {
			t.Errorf("%s: got %#v, want %#v", k, row[k], v)
		}
	}
	// a reference travels as its key; the server adds the label and the flattened column
	if _, ok := row["category_name"]; ok {
		t.Errorf("category_name is the server's to add: %v", row)
	}
	// operations and their form values run through invoke, under the operation code
	ids := `{"ids":[` + str(row["id"]) + `],"param":{"note":"go"}}`
	if code, r := call("POST", "/erupt-api/invoke/Article/operation/feature", "Article", ids); code != 200 || r.(map[string]any)["success"] != true {
		t.Errorf("operation: %d %v", code, r)
	}
	if code, _ := call("POST", "/erupt-api/invoke/Article/operation/missing", "Article", `{}`); code != 404 {
		t.Errorf("unknown operation: %d", code)
	}
	for op, want := range map[string]any{"publish": map[string]any{"note": nil}, "feature": nil} {
		if _, r := call("POST", "/erupt-api/invoke/Article/operation-form/"+op, "Article", `{}`); !reflect.DeepEqual(r.(map[string]any)["data"], want) {
			t.Errorf("form value of %s: %v", op, r)
		}
	}
	// the picker and the old operator routes are the server's
	for _, path := range []string{"reference-table/category", "operator/feature", "operator/publish/form-value"} {
		if code, _ := call("POST", "/erupt-api/data/Article/"+path, "Article", ids); code != 404 {
			t.Errorf("%s: %d", path, code)
		}
	}
}

type memo struct {
	ID   int64  `json:"id" erupt:"pk"`
	Text string `json:"text" erupt:"title=Text"`
}

type memoProxy struct {
	BaseDataProxy
	calls []string
}

func (p *memoProxy) SearchCondition(_ context.Context, condition M) error {
	condition["text"] = "hi"
	return nil
}

func (p *memoProxy) AfterFetch(_ context.Context, rows []M) error {
	for _, row := range rows {
		row["text"] = strings.ToUpper(row["text"].(string))
	}
	return nil
}

func (p *memoProxy) AddBehavior(_ context.Context, record Record) error {
	record["text"] = "new"
	return nil
}

func (p *memoProxy) EditBehavior(_ context.Context, record Record) error {
	record["text"] = record["text"].(string) + "?"
	return nil
}

func (p *memoProxy) Validate(_ context.Context, record Record) error {
	if record["text"] == "forbidden" {
		return Fail("forbidden text")
	}
	return nil
}

// the write hooks only record that they ran, with the text they saw
func (p *memoProxy) call(name string, record Record) error {
	p.calls = append(p.calls, name+" "+record["text"].(string))
	return nil
}

func (p *memoProxy) BeforeAdd(_ context.Context, r Record) error    { return p.call("BeforeAdd", r) }
func (p *memoProxy) AfterAdd(_ context.Context, r Record) error     { return p.call("AfterAdd", r) }
func (p *memoProxy) BeforeUpdate(_ context.Context, r Record) error { return p.call("BeforeUpdate", r) }
func (p *memoProxy) AfterUpdate(_ context.Context, r Record) error  { return p.call("AfterUpdate", r) }
func (p *memoProxy) BeforeDelete(_ context.Context, r Record) error { return p.call("BeforeDelete", r) }
func (p *memoProxy) AfterDelete(_ context.Context, r Record) error  { return p.call("AfterDelete", r) }

func TestDataProxy(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_, _ = w.Write([]byte(`{"add":true,"edit":true,"delete":true,"viewDetails":true}`))
	}))
	defer server.Close()
	proxy := &memoProxy{}
	m, err := NewModel(memo{}, "Memo", WithName("Memo"), WithDataProxy(proxy))
	if err != nil {
		t.Fatal(err)
	}
	node, err := NewNode(Config{Name: "n", AccessToken: "secret", Servers: []string{server.URL}})
	if err != nil {
		t.Fatal(err)
	}
	if err := node.Register(m, NewMemoryRepository()); err != nil {
		t.Fatal(err)
	}
	call := func(method, path, body string) map[string]any {
		req := httptest.NewRequest(method, path, strings.NewReader(body))
		req.Header.Set("Access-Token", "secret")
		req.Header.Set("erupt", "Memo")
		w := httptest.NewRecorder()
		node.ServeHTTP(w, req)
		var v map[string]any
		_ = json.Unmarshal(w.Body.Bytes(), &v)
		return v
	}
	if got := call("GET", "/erupt-api/build/Memo", "")["eruptModel"].(map[string]any)["searchCondition"]; !reflect.DeepEqual(got, map[string]any{"text": "hi"}) {
		t.Errorf("searchCondition %v", got)
	}
	if got := call("GET", "/erupt-api/data/init-value/Memo", "")["text"]; got != "new" {
		t.Errorf("init-value %v", got)
	}
	if r := call("POST", "/erupt-api/data/modify/Memo", `{"text":"forbidden"}`); r["success"] != false || r["message"] != "forbidden text" {
		t.Errorf("validate %v", r)
	}
	if r := call("POST", "/erupt-api/data/modify/Memo", `{"text":"a"}`); r["success"] != true {
		t.Fatalf("add %v", r)
	}
	list := call("POST", "/erupt-api/data/table/Memo", `{}`)["list"].([]any)
	if len(list) != 1 || list[0].(map[string]any)["text"] != "A" {
		t.Fatalf("afterFetch %v", list)
	}
	row := list[0].(map[string]any)
	pk := str(row["id"])
	if got := call("GET", "/erupt-api/data/Memo/"+pk, "")["text"]; got != "a?" {
		t.Errorf("editBehavior %v", got)
	}
	if r := call("POST", "/erupt-api/data/modify/Memo/update", `{"id":`+pk+`,"text":"b"}`); r["success"] != true {
		t.Fatalf("update %v", r)
	}
	if r := call("POST", "/erupt-api/data/modify/Memo/delete", `[`+pk+`]`); r["success"] != true {
		t.Fatalf("delete %v", r)
	}
	want := []string{"BeforeAdd a", "AfterAdd a", "BeforeUpdate b", "AfterUpdate b", "BeforeDelete b", "AfterDelete b"}
	if !reflect.DeepEqual(proxy.calls, want) {
		t.Errorf("calls %v", proxy.calls)
	}
}

type task struct {
	ID    int64  `json:"id" erupt:"pk"`
	Title string `json:"title" erupt:"title=Title;search"`
	Owner string `json:"owner" erupt:"title=Owner"`
	Done  bool   `json:"done" erupt:"title=Done"`
}

type taskProxy struct{ BaseDataProxy }

func (taskProxy) BeforeFetch(ctx context.Context, _ []Cond) (Filter, error) {
	return Filter{SQL: "owner = ?", Params: []any{UserFrom(ctx).Account}}, nil
}

type openProxy struct{ BaseDataProxy }

func (openProxy) BeforeFetch(context.Context, []Cond) (Filter, error) {
	return Filter{SQL: "done = 0"}, nil
}

func TestBeforeFetch(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_, _ = w.Write([]byte(`{"add":true,"edit":true,"delete":true,"viewDetails":true}`))
	}))
	defer server.Close()
	node, err := NewNode(Config{Name: "n", AccessToken: "secret", Servers: []string{server.URL}})
	if err != nil {
		t.Fatal(err)
	}
	register := func(name string, repo Repository) {
		m, err := NewModel(task{}, "Task", WithName(name), WithDataProxy(taskProxy{}, openProxy{}), WithRaw(M{"vis": []any{
			M{"code": "q", "title": "Question", "type": "TABLE", "filter": "title = 'a?'"},
			NodeVis{Vis: Vis{Title: Ptr("Reversed"), Type: VisTypeTable}, Filter: []string{"1 = 1", "2 = 2"}, OrderBy: "title desc"},
		}}))
		if err != nil {
			t.Fatal(err)
		}
		if err := node.Register(m, repo); err != nil {
			t.Fatal(err)
		}
	}
	register("Task", &SQLRepository{DB: newSQLite(t), Table: "task", AutoCreate: true})
	register("MemoryTask", NewMemoryRepository())
	call := func(path, erupt, account, body string) (int, map[string]any) {
		req := httptest.NewRequest("POST", path, strings.NewReader(body))
		req.Header.Set("Access-Token", "secret")
		req.Header.Set("erupt", erupt)
		req.Header.Set("user", base64.StdEncoding.EncodeToString([]byte(`{"uid":1,"account":"`+account+`"}`)))
		w := httptest.NewRecorder()
		node.ServeHTTP(w, req)
		var v map[string]any
		_ = json.Unmarshal(w.Body.Bytes(), &v)
		return w.Code, v
	}
	for _, body := range []string{`{"title":"a","owner":"admin","done":false}`, `{"title":"b","owner":"admin","done":true}`,
		`{"title":"c","owner":"root","done":false}`, `{"title":"a?","owner":"admin","done":false}`} {
		if _, r := call("/erupt-api/data/modify/Task", "Task", "admin", body); r["success"] != true {
			t.Fatalf("add %v", r)
		}
	}
	titles := func(page map[string]any) []string {
		out := []string{}
		for _, row := range page["list"].([]any) {
			out = append(out, row.(map[string]any)["title"].(string))
		}
		return out
	}
	if _, page := call("/erupt-api/data/table/Task", "Task", "admin", `{}`); !reflect.DeepEqual(titles(page), []string{"a", "a?"}) || page["total"] != 2.0 {
		t.Errorf("admin %v", page)
	}
	if _, page := call("/erupt-api/data/table/Task", "Task", "root", `{"condition":[{"key":"title","expression":"EQ","value":"a"}]}`); !reflect.DeepEqual(titles(page), []string{}) {
		t.Errorf("root %v", page)
	}
	// a view's own filter and order run on the node, and stay out of the build
	if _, page := call("/erupt-api/data/table/Task", "Task", "admin", `{"vis":"q"}`); !reflect.DeepEqual(titles(page), []string{"a?"}) {
		t.Errorf("vis q %v", page)
	}
	if _, page := call("/erupt-api/data/table/Task", "Task", "admin", `{"vis":"Reversed"}`); !reflect.DeepEqual(titles(page), []string{"a?", "a"}) {
		t.Errorf("vis Reversed %v", page)
	}
	req := httptest.NewRequest("GET", "/erupt-api/build/Task", nil)
	req.Header.Set("Access-Token", "secret")
	req.Header.Set("erupt", "Task")
	w := httptest.NewRecorder()
	node.ServeHTTP(w, req)
	var build struct {
		EruptModel struct {
			EruptJSON struct{ Vis []map[string]any }
		}
	}
	if err := json.Unmarshal(w.Body.Bytes(), &build); err != nil {
		t.Fatal(err)
	}
	var codes []string
	for _, v := range build.EruptModel.EruptJSON.Vis {
		codes = append(codes, str(v["code"]))
		if _, ok := v["filter"]; ok {
			t.Errorf("filter in the build %v", v)
		}
		if _, ok := v["orderBy"]; ok {
			t.Errorf("orderBy in the build %v", v)
		}
	}
	if !reflect.DeepEqual(codes, []string{"q", "Reversed"}) {
		t.Errorf("vis codes %v", codes)
	}
	if code, _ := call("/erupt-api/data/table/MemoryTask", "MemoryTask", "admin", `{}`); code != 500 {
		t.Errorf("memory repository answered %d, want 500", code)
	}
	if _, _, err := (&SQLRepository{DB: newSQLite(t), Table: "task"}).Page(context.Background(), Query{Filters: []Filter{{SQL: "owner = ? AND done = ?", Params: []any{"admin"}}}}); err == nil {
		t.Error("a '?' without its param was accepted")
	}
}

type doc struct {
	ID    int64  `json:"id" erupt:"pk"`
	Title string `json:"title" erupt:"title=Title"`
	Topic int64  `json:"topic" erupt:"title=Topic;ref=Category;tree=parent"`
}

func TestLinkTree(t *testing.T) {
	if _, err := NewModel(doc{}, "Doc", WithRaw(M{"linkTree": M{"field": "title"}})); err == nil {
		t.Error("a linkTree on a non-reference field was accepted")
	}
	category, _ := testModels(t)
	m, err := NewModel(doc{}, "Doc", WithName("Doc"), WithRaw(M{"linkTree": LinkTree{Field: Ptr("topic"), DependNode: Ptr(true)}}))
	if err != nil {
		t.Fatal(err)
	}
	node, _ := NewNode(Config{Name: "n", AccessToken: "secret", Servers: []string{"http://127.0.0.1:1"}})
	if err := node.Register(category, NewMemoryRepository()); err != nil {
		t.Fatal(err)
	}
	if err := node.Register(m, NewMemoryRepository(Record{"title": "a", "topic": 1}, Record{"title": "b", "topic": 2}, Record{"title": "c", "topic": 3})); err != nil {
		t.Fatal(err)
	}
	titles := func(body string) []string {
		req := httptest.NewRequest("POST", "/erupt-api/data/table/Doc", strings.NewReader(body))
		req.Header.Set("Access-Token", "secret")
		req.Header.Set("erupt", "Doc")
		w := httptest.NewRecorder()
		node.ServeHTTP(w, req)
		var page struct{ List []map[string]any }
		_ = json.Unmarshal(w.Body.Bytes(), &page)
		out := []string{}
		for _, row := range page.List {
			out = append(out, str(row["title"]))
		}
		return out
	}
	// dependNode: nothing until a tree node is picked
	for body, want := range map[string][]string{`{}`: {}, `{"linkTreeVal":[2]}`: {"b"}, `{"linkTreeVal":["1","2"]}`: {"a", "b"}} {
		if got := titles(body); !reflect.DeepEqual(got, want) {
			t.Errorf("%s: %v, want %v", body, got, want)
		}
	}
}

// A virtual field is in the build only; a slice or map field round-trips as a JSON value.
func TestVirtualAndJSONFields(t *testing.T) {
	type Widget struct {
		ID    int64             `json:"id" erupt:"pk"`
		Name  string            `json:"name" erupt:"title=Name"`
		Note  string            `json:"note" erupt:"title=Note;virtual"`
		Roles []string          `json:"roles" erupt:"title=Roles"`
		Attrs map[string]string `json:"attrs" erupt:"title=Attrs"`
	}
	ctx := context.Background()
	for name, factory := range repositories(t) {
		t.Run(name, func(t *testing.T) {
			m, err := NewModel(Widget{}, "Widget", WithFieldEdit("note", M{"type": "DIVIDE"}))
			if err != nil {
				t.Fatal(err)
			}
			repo := factory()
			if err := repo.(Binder).Bind(m); err != nil {
				t.Fatal(err)
			}
			build := m.buildErupt(nil)["eruptFieldModels"].([]any)
			if len(build) != 5 {
				t.Fatalf("build has %d fields", len(build))
			}
			record, err := toRecord(m, M{"name": "A", "note": "ignored", "roles": []any{"ADMIN", "USER"}, "attrs": M{"env": "prod"}})
			if err != nil {
				t.Fatal(err)
			}
			if _, ok := record["note"]; ok {
				t.Fatal("virtual field reached the record")
			}
			if err := repo.Add(ctx, record); err != nil {
				t.Fatal(err)
			}
			_, records, err := repo.Page(ctx, Query{Limit: 10})
			if err != nil {
				t.Fatal(err)
			}
			got := records[0]
			if !reflect.DeepEqual(got["roles"], []any{"ADMIN", "USER"}) || !reflect.DeepEqual(got["attrs"], map[string]any{"env": "prod"}) {
				t.Fatalf("json values: %#v %#v", got["roles"], got["attrs"])
			}
			if _, ok := got["note"]; ok {
				t.Fatal("virtual field read back")
			}
			if _, err := toRecord(m, M{"name": "B", "roles": "ADMIN"}); err == nil {
				t.Fatal("a string accepted for a JSON field")
			}
		})
	}
	type Bad struct {
		ID   int64    `json:"id" erupt:"pk"`
		Tags []string `json:"tags" erupt:"search"`
	}
	if _, err := NewModel(Bad{}, "Bad"); err == nil {
		t.Fatal("a searchable JSON field accepted")
	}
}

type order struct {
	ID       int64   `json:"id" erupt:"pk"`
	Status   string  `json:"status" erupt:"title=Status"`
	Tags     string  `json:"tags" erupt:"title=Tags;type=TAGS"`
	Qty      int64   `json:"qty" erupt:"title=Qty"`
	Note     string  `json:"note" erupt:"title=Note"`
	City     string  `json:"city" erupt:"title=City;type=AUTO_COMPLETE"`
	Body     string  `json:"body" erupt:"title=Body;type=MARKDOWN"`
	Files    string  `json:"files" erupt:"title=Files;type=ATTACHMENT"`
	Cats     []int64 `json:"cats" erupt:"title=Categories;type=CHECKBOX;ref=Category"`
	Sections []int64 `json:"sections" erupt:"title=Sections;type=TAB_TREE;ref=Category"`
	Calc     any     `json:"calc" erupt:"title=Calc;type=BUTTON"`
	Stop     any     `json:"stop" erupt:"title=Stop;type=BUTTON"`
}

func TestFieldTypesAndInvoke(t *testing.T) {
	type picks struct {
		ID    int64    `json:"id" erupt:"pk"`
		Roles []string `json:"roles" erupt:"title=Roles;choices=a:A,b:B"`
	}
	if m, err := NewModel(picks{}, "Picks"); err != nil || m.FieldType("roles") != "MULTI_CHOICE" {
		t.Errorf("a slice field with choices: %v %v", m, err)
	}
	complete := FieldCode{Complete: func(context.Context, M, string) ([]string, error) { return nil, nil }}
	if _, err := NewModel(order{}, "Order", WithFieldCode("note", complete)); err == nil {
		t.Error("Complete on an INPUT was accepted")
	}
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_, _ = w.Write([]byte(`{"add":true,"edit":true,"delete":true,"viewDetails":true}`))
	}))
	defer server.Close()
	category, _ := testModels(t)
	m, err := NewModel(order{}, "Order", WithName("Order"),
		WithFieldCode("status", FieldCode{Fetch: func(_ context.Context, form M) ([]Option, error) {
			note, _ := form["note"].(string)
			return []Option{{"new", "New"}, {note, "From form"}}, nil
		}}),
		WithFieldCode("tags", FieldCode{Tags: func(context.Context, M) ([]string, error) { return []string{"red", "blue"}, nil }}),
		WithFieldCode("qty", FieldCode{Onchange: func(_ context.Context, form M) (Change, error) {
			return Change{FormData: M{"note": str(form["qty"]) + " items"}}, nil
		}}),
		WithFieldCode("city", FieldCode{Complete: func(_ context.Context, _ M, typed string) ([]string, error) {
			var out []string
			for _, c := range []string{"Paris", "Tokyo"} {
				if strings.Contains(strings.ToLower(c), strings.ToLower(typed)) {
					out = append(out, c)
				}
			}
			return out, nil
		}}),
		WithFieldCode("calc", FieldCode{Click: func(context.Context, M) (Click, error) {
			return Click{Eval: "alert(1)", FormData: M{"qty": 2}}, nil
		}}),
		WithFieldCode("stop", FieldCode{Click: func(context.Context, M) (Click, error) { return Click{}, Fail("not now") }}))
	if err != nil {
		t.Fatal(err)
	}
	node, _ := NewNode(Config{Name: "n", AccessToken: "secret", Servers: []string{server.URL}})
	if err := node.Register(category, NewMemoryRepository()); err != nil {
		t.Fatal(err)
	}
	if err := node.Register(m, NewMemoryRepository()); err != nil {
		t.Fatal(err)
	}
	call := func(method, path, body string) (int, map[string]any) {
		req := httptest.NewRequest(method, path, strings.NewReader(body))
		req.Header.Set("Access-Token", "secret")
		req.Header.Set("erupt", "Order")
		w := httptest.NewRecorder()
		node.ServeHTTP(w, req)
		var v map[string]any
		_ = json.Unmarshal(w.Body.Bytes(), &v)
		return w.Code, v
	}
	_, build := call("GET", "/erupt-api/build/Order", "")
	fields, edit := map[string]map[string]any{}, map[string]map[string]any{}
	for _, f := range build["eruptModel"].(map[string]any)["eruptFieldModels"].([]any) {
		f := f.(map[string]any)
		fields[str(f["fieldName"])] = f
		edit[str(f["fieldName"])] = f["eruptFieldJson"].(map[string]any)["edit"].(map[string]any)
	}
	for name, attr := range map[string]string{"status": "choiceType", "tags": "tagsType"} {
		if got := edit[name][attr].(map[string]any)["fetchHandler"]; !reflect.DeepEqual(got, []any{"invoke"}) {
			t.Errorf("%s fetchHandler %v", name, got)
		}
	}
	if edit["qty"]["onchange"] != "invoke" || edit["body"]["type"] != "MARKDOWN" || edit["files"]["type"] != "ATTACHMENT" || edit["calc"]["type"] != "BUTTON" {
		t.Errorf("edits %v %v %v %v", edit["qty"]["onchange"], edit["body"]["type"], edit["files"]["type"], edit["calc"]["type"])
	}
	if fields["cats"]["fieldReturnName"] != "Category" || fields["sections"]["fieldReturnName"] != "Category" {
		t.Errorf("fieldReturnName %v %v", fields["cats"]["fieldReturnName"], fields["sections"]["fieldReturnName"])
	}
	invoke := func(kind, field, body string) (int, map[string]any) {
		return call("POST", "/erupt-api/invoke/Order/"+kind+"/"+field, body)
	}
	data := func(kind, field, body string) any {
		_, r := invoke(kind, field, body)
		return r["data"]
	}
	for _, c := range []struct {
		kind, field, body string
		want              any
	}{
		{"options", "status", `{"form":{"note":"n"}}`, []any{M{"value": "new", "label": "New"}, M{"value": "n", "label": "From form"}}},
		{"options", "tags", `{}`, []any{"red", "blue"}},
		{"onchange", "qty", `{"form":{"qty":3}}`, M{"formData": M{"note": "3 items"}}},
		{"autocomplete", "city", `{"form":{},"value":"pa"}`, []any{"Paris"}},
		{"button", "calc", `{"form":{}}`, M{"eval": "alert(1)", "formData": M{"qty": float64(2)}}},
	} {
		if got := data(c.kind, c.field, c.body); !reflect.DeepEqual(got, c.want) {
			t.Errorf("%s %s: %#v", c.kind, c.field, got)
		}
	}
	if _, r := invoke("button", "stop", `{}`); r["success"] != false || r["message"] != "not now" {
		t.Errorf("a refused click %v", r)
	}
	for _, field := range []string{"button/qty", "options/missing"} {
		if status, _ := call("POST", "/erupt-api/invoke/Order/"+field, `{}`); status != 404 {
			t.Errorf("%s: %d", field, status)
		}
	}
	// picked records arrive as [{id: key}] and are stored as their keys
	if _, r := call("POST", "/erupt-api/data/modify/Order", `{"cats":[{"id":1},{"id":"2"}],"sections":[{"id":3}],"tags":"[\"red\"]"}`); r["success"] != true {
		t.Fatalf("add %v", r)
	}
	_, page := call("POST", "/erupt-api/data/table/Order", `{}`)
	row := page["list"].([]any)[0].(map[string]any)
	if !reflect.DeepEqual(row["cats"], []any{float64(1), float64(2)}) || !reflect.DeepEqual(row["sections"], []any{float64(3)}) {
		t.Errorf("keys %v %v", row["cats"], row["sections"])
	}
	if _, ok := row["calc"]; ok {
		t.Error("a BUTTON reached the row")
	}
}
