// The conformance fixture (conformance/README.md) in TypeScript.
import { Fail, field, MemoryRepository, model, Node, operation } from "../src/index.js";

const Category = model("Category", {
  id: field.pk(),
  name: field.input("Name", { search: true }),
  parent: field.number("Parent"),
});

const PublishForm = model("PublishForm", {
  note: field.input("Note", { notNull: true }),
}, { title: "Publish Options" });

const Article = model("Article", {
  id: field.pk(),
  title: field.input("Title", { search: true, notNull: true, sortable: true, edit: { inputType: { length: 64 } } }),
  status: field.choice("Status", { draft: "Draft", published: "Published" }, { search: true }),
  views: field.number("Views", { sortable: true }),
  featured: field.boolean("Featured", { search: true }),
  publish_date: field.date("Publish Date", { search: true }),
  review_at: field.dateTime("Review At"),
  body: field.textarea("Body", { table: false }),
  category: field.ref(Category, "Category", { search: true }),
  topic: field.ref(Category, "Topic", { tree: "parent" }),
}, {
  orderBy: "id desc",
  operations: {
    publish: operation("Publish", { icon: "fa fa-paper-plane", form: PublishForm, ifExpr: "item.status !== 'published'" },
      async (op) => {
        for (const row of op.rows) await op.repo.update(row.id, { status: "published" });
      }),
    feature: operation("Feature", { mode: "SINGLE", confirm: false }, () => "alert('featured')"),
    rebuild: operation("Rebuild", { mode: "BUTTON", show: (user) => user?.account === "root" }, () => undefined),
  },
});

const Note = model("Note", {
  id: field.pk(),
  text: field.input("Text"),
  ping: field.button("Ping", (form) => ({ eval: `pong:${form.text}` })),
}, {
  power: { delete: false },
  dataProxy: {
    addBehavior(record) {
      record.text = "new";
    },
    validate(record) {
      if (record.text === "forbidden") throw new Fail("forbidden text");
    },
  },
});

const env = process.env;
const node = new Node("conformance", env.ERUPT_ACCESS_TOKEN!, env.ERUPT_SERVER!, { address: `http://127.0.0.1:${env.PORT}` });
node.register(Category, new MemoryRepository([{ name: "Tech", parent: null }, { name: "Python", parent: 1 }, { name: "Life", parent: null }]));
node.register(Article, new MemoryRepository());
node.register(Note, new MemoryRepository());
await node.serve(Number(env.PORT), "127.0.0.1");
