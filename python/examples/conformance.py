"""The conformance fixture (conformance/README.md) in Python."""
import datetime
import os

from erupt import DataProxy, Fail, Field, MemoryRepository, Node, erupt, operation


@erupt("Category")
class Category:
    id: int = Field(pk=True)
    name: str = Field("Name", search=True)
    parent: int = Field("Parent")


@erupt("Publish Options")
class PublishForm:
    note: str = Field("Note", not_null=True)


@erupt("Article", order_by="id desc")
class Article:
    id: int = Field(pk=True)
    title: str = Field("Title", search=True, not_null=True, sortable=True, edit={"inputType": {"length": 64}})
    status: str = Field("Status", choices={"draft": "Draft", "published": "Published"}, search=True)
    views: int = Field("Views", sortable=True)
    featured: bool = Field("Featured", search=True)
    publish_date: datetime.date = Field("Publish Date", search=True)
    review_at: datetime.datetime = Field("Review At")
    body: str = Field("Body", type="TEXTAREA", table=False)
    category: Category = Field("Category", search=True)
    topic: Category = Field("Topic", tree="parent")

    @operation("Publish", icon="fa fa-paper-plane", form=PublishForm, if_expr="item.status !== 'published'")
    def publish(op):
        for row in op.rows:
            op.repo.update(row["id"], {"status": "published"})

    @operation("Feature", mode="SINGLE", confirm=False)
    def feature(op):
        return "alert('featured')"

    @operation("Rebuild", mode="BUTTON", show=lambda user: bool(user) and user.get("account") == "root")
    def rebuild(op):
        pass


class NoteProxy(DataProxy):
    def add_behavior(self, record):
        record["text"] = "new"

    def validate(self, record):
        if record.get("text") == "forbidden":
            raise Fail("forbidden text")


@erupt("Note", power={"delete": False}, data_proxy=NoteProxy)
class Note:
    id: int = Field(pk=True)
    text: str = Field("Text")
    ping = Field("Ping", type="BUTTON", click=lambda form: {"eval": f"pong:{form.get('text')}"})


if __name__ == "__main__":
    node = Node("conformance", os.environ["ERUPT_ACCESS_TOKEN"], os.environ["ERUPT_SERVER"], address=f"http://127.0.0.1:{os.environ['PORT']}")
    node.register(Category, MemoryRepository([{"name": "Tech", "parent": None}, {"name": "Python", "parent": 1},
                                              {"name": "Life", "parent": None}]))
    node.register(Article, MemoryRepository())
    node.register(Note, MemoryRepository())
    node.serve(host="127.0.0.1", port=int(os.environ["PORT"]))
