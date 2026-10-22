package erupt

import (
	"os"
	"strings"
	"testing"
	"time"

	"github.com/erupt-io/erupt-sdk/go/internal/gentypes"
)

type testCategory struct {
	ID     int64  `json:"id" erupt:"pk"`
	Name   string `json:"name" erupt:"title=Name;search"`
	Parent int64  `json:"parent" erupt:"title=Parent"`
}

type testForm struct {
	Note string `json:"note" erupt:"title=Note;notNull"`
}

type testArticle struct {
	ID          int64     `json:"id" erupt:"pk"`
	Title       string    `json:"title" erupt:"title=Title;search;notNull;sortable"`
	Status      string    `json:"status" erupt:"title=Status;choices=draft:Draft,published:Published;search"`
	Views       float64   `json:"views" erupt:"title=Views;sortable"`
	Featured    *bool     `json:"featured" erupt:"title=Featured;search"`
	PublishDate time.Time `json:"publish_date" erupt:"title=Publish Date;type=DATE;search"`
	ReviewAt    time.Time `json:"review_at" erupt:"title=Review At"`
	Body        string    `json:"body" erupt:"title=Body;type=TEXTAREA;hideTable"`
	Category    int64     `json:"category" erupt:"title=Category;ref=Category;search"`
	Topic       int64     `json:"topic" erupt:"title=Topic;ref=Category;tree=parent"`
	Ignored     string
}

func testModels(t *testing.T) (category, article *Model) {
	t.Helper()
	var err error
	if category, err = NewModel(testCategory{}, "Category", WithName("Category")); err != nil {
		t.Fatal(err)
	}
	form, err := NewModel(&testForm{}, "Publish Options", WithName("PublishForm"))
	if err != nil {
		t.Fatal(err)
	}
	article, err = NewModel(testArticle{}, "Article", WithName("Article"), WithOrderBy("id desc"),
		WithFieldEdit("title", Edit{InputType: &InputType{Length: Ptr[int64](64)}}),
		WithRaw(M{"layout": M{"pageSize": 30}}),
		WithOperations(
			Operation{Code: "publish", Title: "Publish", Form: form, Handler: func(*OpContext) (string, error) { return "", nil }},
			Operation{Code: "feature", Title: "Feature", Mode: RowOperationModeSingle, NoConfirm: true,
				Handler: func(*OpContext) (string, error) { return "", nil }},
		))
	if err != nil {
		t.Fatal(err)
	}
	if err := article.resolve(func(name string) *Model {
		if name == "Category" {
			return category
		}
		return nil
	}); err != nil {
		t.Fatal(err)
	}
	return category, article
}

func TestDeclaration(t *testing.T) {
	_, article := testModels(t)
	want := map[string]string{"id": "", "title": "INPUT", "status": "CHOICE", "views": "NUMBER", "featured": "BOOLEAN",
		"publish_date": "DATE", "review_at": "DATE_TIME", "body": "TEXTAREA", "category": "REFERENCE_TABLE", "topic": "REFERENCE_TREE"}
	if got := strings.Join(article.FieldNames(), ","); got != "id,title,status,views,featured,publish_date,review_at,body,category,topic" {
		t.Fatalf("fields %s", got)
	}
	for name, typ := range want {
		if got := article.FieldType(name); got != typ {
			t.Errorf("%s: type %q, want %q", name, got, typ)
		}
	}
	build := article.buildModel(defaults.Power, nil)
	model := build["eruptModel"].(M)
	erupt := model["eruptJson"].(map[string]any)
	if v := erupt["layout"].(map[string]any)["pageSize"]; str(v) != "30" {
		t.Errorf("raw erupt override: %v", v)
	}
	if _, ok := erupt["orderBy"]; ok {
		t.Error("orderBy is @Transient and must not be emitted")
	}
	title := model["eruptFieldModels"].([]any)[1].(map[string]any)["eruptFieldJson"].(map[string]any)["edit"].(map[string]any)
	if str(title["inputType"].(map[string]any)["length"]) != "64" {
		t.Errorf("typed edit override: %v", title["inputType"])
	}
}

func TestBuildMatchesSchema(t *testing.T) {
	category, article := testModels(t)
	for _, m := range []*Model{category, article} {
		build := m.buildModel(defaults.Power, nil)
		models := []any{build["eruptModel"]}
		if forms, ok := build["operationErupts"].(M); ok {
			for _, f := range forms {
				models = append(models, f)
			}
		}
		for _, x := range models {
			v, err := toJSONValue(x)
			if err != nil {
				t.Fatal(err)
			}
			em := v.(map[string]any)
			name := em["eruptName"].(string)
			if err := checkSchema("Erupt", em["eruptJson"], name, false); err != nil {
				t.Error(err)
			}
			for _, op := range em["eruptJson"].(map[string]any)["rowOperation"].([]any) {
				if err := checkSchema("RowOperation", op, name+".op", false); err != nil {
					t.Error(err)
				}
			}
			for _, f := range em["eruptFieldModels"].([]any) {
				fm := f.(map[string]any)
				if err := checkSchema("EruptField", fm["eruptFieldJson"], name+"."+fm["fieldName"].(string), false); err != nil {
					t.Error(err)
				}
			}
		}
	}
}

type bad struct {
	ID    int64  `json:"id" erupt:"pk"`
	Title string `json:"title" erupt:"title=T"`
}

func TestDeclarationErrors(t *testing.T) {
	noop := func(*OpContext) (string, error) { return "", nil }
	cases := []struct {
		decl any
		opts []ModelOption
		want string
	}{
		{bad{}, []ModelOption{WithFieldEdit("title", M{"inputTyp": M{"length": 9}})}, "Edit has no attribute 'inputTyp'"},
		{bad{}, []ModelOption{WithFieldView("title", M{"sortable": "yes"})}, "expected boolean"},
		{bad{}, []ModelOption{WithFieldEdit("title", M{"search": M{"operator": "ABOUT"}})}, "is not a QueryExpression"},
		{bad{}, []ModelOption{WithFieldEdit("missing", M{})}, "names no field 'missing'"},
		{bad{}, []ModelOption{WithRaw(M{"orderBy": "id"})}, "Erupt has no attribute 'orderBy'"},
		{bad{}, []ModelOption{WithRaw(M{"layout": M{"pageSize": "10"}})}, "expected integer"},
		{bad{}, []ModelOption{WithOrderBy("missing desc")}, "illegal order_by"},
		{bad{}, []ModelOption{WithPower(map[string]bool{"fly": false})}, "unknown power 'fly'"},
		{bad{}, []ModelOption{WithOperations(Operation{Code: "go", Mode: "ALL", Handler: noop})}, "is not a RowOperationMode"},
		{bad{}, []ModelOption{WithOperations(Operation{Code: "go", Raw: M{"colour": "red"}, Handler: noop})}, "RowOperation has no attribute 'colour'"},
		{bad{}, []ModelOption{WithOperations(Operation{Code: "go"})}, "needs a Code and a Handler"},
		{bad{}, []ModelOption{WithOperations(Operation{Code: "go", Handler: noop}, Operation{Code: "go", Handler: noop})}, "declared twice"},
		{struct {
			T string `erupt:"type=INPUTT"`
		}{}, nil, "is not a EditType"},
		{struct {
			T string `erupt:"type=TAB_TABLE_ADD"`
		}{}, nil, "is not supported yet"},
		{struct {
			T string `erupt:"colour=red"`
		}{}, nil, "unknown erupt tag 'colour'"},
		{struct {
			A int64 `erupt:"pk"`
			B int64 `erupt:"pk"`
		}{}, nil, "at most one pk"},
		{"text", nil, "declared with a struct"},
	}
	for _, c := range cases {
		_, err := NewModel(c.decl, "Bad", append([]ModelOption{WithName("Bad")}, c.opts...)...)
		if err == nil || !strings.Contains(err.Error(), c.want) {
			t.Errorf("want error containing %q, got %v", c.want, err)
		}
	}
}

func TestRegisterChecksReferences(t *testing.T) {
	node, err := NewNode(Config{Name: "n", AccessToken: "t", Servers: []string{"http://x"}})
	if err != nil {
		t.Fatal(err)
	}
	article, err := NewModel(testArticle{}, "Article")
	if err != nil {
		t.Fatal(err)
	}
	if err := node.Register(article, NewMemoryRepository()); err == nil || !strings.Contains(err.Error(), "register it first") {
		t.Fatalf("unregistered reference: %v", err)
	}
	type noName struct {
		ID int64 `json:"id" erupt:"pk"`
	}
	category, _ := NewModel(noName{}, "Category", WithName("Category"))
	if err := node.Register(category, NewMemoryRepository()); err != nil {
		t.Fatal(err)
	}
	if err := node.Register(article, NewMemoryRepository()); err == nil || !strings.Contains(err.Error(), "has no field 'name'") {
		t.Fatalf("missing label: %v", err)
	}
	form, _ := NewModel(testForm{}, "Form")
	if err := node.Register(form, NewMemoryRepository()); err == nil || !strings.Contains(err.Error(), "no pk field") {
		t.Fatalf("form registered: %v", err)
	}
}

func TestCoerce(t *testing.T) {
	_, article := testModels(t)
	f := article.byName
	cases := []struct {
		field string
		in    any
		want  any
	}{
		{"views", "3", int64(3)}, {"views", 2.5, 2.5}, {"featured", "1", true}, {"featured", "no", false},
		{"publish_date", "2026-01-05T10:30:00Z", time.Date(2026, 1, 5, 0, 0, 0, 0, time.UTC)},
		{"review_at", "2026-01-05 10:30:00.123456", time.Date(2026, 1, 5, 10, 30, 0, 123456000, time.UTC)},
		{"review_at", "2026-01-05 10:30", time.Date(2026, 1, 5, 10, 30, 0, 0, time.UTC)},
		{"category", M{"id": "2", "name": "x"}, int64(2)}, {"title", "", nil}, {"status", "draft", "draft"},
	}
	for _, c := range cases {
		got, err := f[c.field].coerce(c.in)
		if err != nil || !equalOrNil(got, c.want) {
			t.Errorf("%s(%v) = %v, %v; want %v", c.field, c.in, got, err, c.want)
		}
	}
	for _, in := range []struct {
		field string
		v     any
	}{{"views", "many"}, {"publish_date", "someday"}, {"status", "deleted"}, {"id", "abc"}} {
		if _, err := f[in.field].coerce(in.v); err == nil {
			t.Errorf("%s(%v) accepted", in.field, in.v)
		}
	}
	if got := f["review_at"].jsonValue(time.Date(2026, 1, 5, 10, 30, 0, 123999999, time.UTC)); got != "2026-01-05T10:30:00.123" {
		t.Errorf("datetime output %v", got)
	}
}

func equalOrNil(a, b any) bool {
	if a == nil || b == nil {
		return a == b
	}
	return equal(a, b)
}

func TestGeneratedTypesAreCurrent(t *testing.T) {
	want, err := gentypes.Generate(annotationSchema)
	if err != nil {
		t.Fatal(err)
	}
	got, err := os.ReadFile("types.go")
	if err != nil {
		t.Fatal(err)
	}
	if string(got) != string(want) {
		t.Fatal("types.go is stale: go run ./cmd/gentypes ../schema")
	}
}
