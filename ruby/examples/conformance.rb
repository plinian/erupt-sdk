# frozen_string_literal: true

# The conformance fixture (conformance/README.md) in Ruby.
$LOAD_PATH.unshift(File.expand_path("../lib", __dir__))
require "erupt"

class Category
  extend Erupt::Model
  erupt "Category"
  field :id, pk: true
  field :name, "Name", search: true
  field :parent, "Parent", Integer
end

class PublishForm
  extend Erupt::Model
  erupt "Publish Options"
  field :note, "Note", not_null: true
end

class Article
  extend Erupt::Model
  erupt "Article", order_by: "id desc"
  field :id, pk: true
  field :title, "Title", search: true, not_null: true, sortable: true, edit: { inputType: { length: 64 } }
  field :status, "Status", choices: { draft: "Draft", published: "Published" }, search: true
  field :views, "Views", Integer, sortable: true
  field :featured, "Featured", :boolean, search: true
  field :publish_date, "Publish Date", Date, search: true
  field :review_at, "Review At", Time
  field :body, "Body", type: Erupt::EditType::TEXTAREA, table: false
  field :category, "Category", Category, search: true
  field :topic, "Topic", Category, tree: :parent

  operation :publish, "Publish", icon: "fa fa-paper-plane", form: PublishForm, if_expr: "item.status !== 'published'" do |op|
    op.rows.each { |row| op.repo.update(row["id"], status: "published") }
  end

  operation :feature, "Feature", mode: Erupt::RowOperationMode::SINGLE, confirm: false do
    "alert('featured')"
  end

  operation :rebuild, "Rebuild", mode: Erupt::RowOperationMode::BUTTON, show: ->(user) { user&.fetch("account") == "root" } do
    nil
  end
end

class NoteProxy < Erupt::DataProxy
  def add_behavior(record)
    record["text"] = "new"
  end

  def validate(record)
    raise Erupt::Fail, "forbidden text" if record["text"] == "forbidden"
  end
end

class Note
  extend Erupt::Model
  erupt "Note", power: { delete: false }, data_proxy: NoteProxy
  field :id, pk: true
  field :text, "Text"
end

node = Erupt::Node.new("conformance", ENV.fetch("ERUPT_ACCESS_TOKEN"), ENV.fetch("ERUPT_SERVER"),
                       address: "http://127.0.0.1:#{ENV.fetch("PORT")}")
node.register(Category, Erupt::MemoryRepository.new([{ name: "Tech", parent: nil }, { name: "Python", parent: 1 },
                                                      { name: "Life", parent: nil }]))
node.register(Article, Erupt::MemoryRepository.new)
node.register(Note, Erupt::MemoryRepository.new)
node.serve(host: "127.0.0.1", port: Integer(ENV.fetch("PORT")))
