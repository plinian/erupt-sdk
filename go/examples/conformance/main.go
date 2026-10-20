// The conformance fixture (conformance/README.md) in Go.
package main

import (
	"context"
	"fmt"
	"log"
	"os"
	"time"

	erupt "github.com/erupt-io/erupt-sdk/go"
)

type Category struct {
	ID     int64  `json:"id" erupt:"pk"`
	Name   string `json:"name" erupt:"title=Name;search"`
	Parent int64  `json:"parent" erupt:"title=Parent"`
}

type PublishForm struct {
	Note string `json:"note" erupt:"title=Note;notNull"`
}

type Article struct {
	ID          int64     `json:"id" erupt:"pk"`
	Title       string    `json:"title" erupt:"title=Title;search;notNull;sortable"`
	Status      string    `json:"status" erupt:"title=Status;choices=draft:Draft,published:Published;search"`
	Views       int64     `json:"views" erupt:"title=Views;sortable"`
	Featured    bool      `json:"featured" erupt:"title=Featured;search"`
	PublishDate time.Time `json:"publish_date" erupt:"title=Publish Date;type=DATE;search"`
	ReviewAt    time.Time `json:"review_at" erupt:"title=Review At"`
	Body        string    `json:"body" erupt:"title=Body;type=TEXTAREA;hideTable"`
	Category    int64     `json:"category" erupt:"title=Category;ref=Category;search"`
	Topic       int64     `json:"topic" erupt:"title=Topic;ref=Category;tree=parent"`
}

type Note struct {
	ID   int64  `json:"id" erupt:"pk"`
	Text string `json:"text" erupt:"title=Text"`
	Ping any    `json:"ping" erupt:"title=Ping;type=BUTTON"`
}

type NoteProxy struct{ erupt.BaseDataProxy }

func (NoteProxy) AddBehavior(_ context.Context, record erupt.Record) error {
	record["text"] = "new"
	return nil
}

func (NoteProxy) Validate(_ context.Context, record erupt.Record) error {
	if record["text"] == "forbidden" {
		return erupt.Fail("forbidden text")
	}
	return nil
}

func main() {
	category := must(erupt.NewModel(Category{}, "Category",
		erupt.WithRaw(erupt.M{"drills": []erupt.M{{"title": "Articles", "link": erupt.M{"linkErupt": "Article", "joinColumn": "category"}}}})))
	form := must(erupt.NewModel(PublishForm{}, "Publish Options"))
	article := must(erupt.NewModel(Article{}, "Article",
		erupt.WithOrderBy("id desc"),
		erupt.WithFieldEdit("title", erupt.Edit{InputType: &erupt.InputType{Length: erupt.Ptr[int64](64)}}),
		erupt.WithOperations(
			erupt.Operation{Code: "publish", Title: "Publish", Icon: "fa fa-paper-plane", Form: form,
				IfExpr: "item.status !== 'published'",
				Handler: func(op *erupt.OpContext) (string, error) {
					for _, row := range op.Rows {
						if err := op.Repo.Update(op.Context, row["id"], erupt.Record{"status": "published"}); err != nil {
							return "", err
						}
					}
					return "", nil
				}},
			erupt.Operation{Code: "feature", Title: "Feature", Mode: erupt.RowOperationModeSingle, NoConfirm: true,
				Handler: func(*erupt.OpContext) (string, error) { return "alert('featured')", nil }},
			erupt.Operation{Code: "rebuild", Title: "Rebuild", Mode: erupt.RowOperationModeButton,
				Show:    func(u *erupt.User) bool { return u != nil && u.Account == "root" },
				Handler: func(*erupt.OpContext) (string, error) { return "", nil }},
		)))
	note := must(erupt.NewModel(Note{}, "Note", erupt.WithPower(map[string]bool{"delete": false}), erupt.WithDataProxy(NoteProxy{}),
		erupt.WithFieldCode("ping", erupt.FieldCode{Click: func(_ context.Context, form erupt.M) (erupt.Click, error) {
			return erupt.Click{Eval: fmt.Sprint("pong:", form["text"])}, nil
		}})))

	port := os.Getenv("PORT")
	node := must(erupt.NewNode(erupt.Config{Name: "conformance", AccessToken: os.Getenv("ERUPT_ACCESS_TOKEN"),
		Servers: []string{os.Getenv("ERUPT_SERVER")}, Address: "http://127.0.0.1:" + port}))
	check(node.Register(category, erupt.NewMemoryRepository(
		erupt.Record{"name": "Tech", "parent": nil}, erupt.Record{"name": "Python", "parent": 1}, erupt.Record{"name": "Life", "parent": nil})))
	check(node.Register(article, erupt.NewMemoryRepository()))
	check(node.Register(note, erupt.NewMemoryRepository()))
	check(node.ListenAndServe("127.0.0.1:" + port))
}

func must[T any](v T, err error) T {
	check(err)
	return v
}

func check(err error) {
	if err != nil {
		log.Fatal(err)
	}
}
