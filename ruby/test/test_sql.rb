# frozen_string_literal: true

require_relative "test_helper"
require "tmpdir"

class Post
  extend Erupt::Model
  erupt "Post"
  field :id, pk: true
  field :title, "Title", search: true
  field :views, "Views", Integer
  field :live, "Live", :boolean
  field :day, "Day", Date
  field :at, "At", Time
end

class SqlRepositoryTest < Minitest::Test
  # Records statements the way a driver receives them; answers like pg does (text, upper-case columns).
  def fake(dialect)
    log = []
    executor = Erupt::SqlExecutor.new(dialect) do |sql, params|
      log << [sql, params]
      if sql.start_with?("SELECT COUNT")
        [{ "N" => "2" }]
      elsif sql.start_with?("SELECT")
        [{ "ID" => "1", "TITLE" => "a", "VIEWS" => "3.0", "LIVE" => "t", "DAY" => "2026-01-05", "AT" => "2026-01-05 10:30:00.000" }]
      else
        []
      end
    end
    repo = Erupt::SqlRepository.new(executor, "post")
    repo.bind(Post.erupt_model)
    [repo, log]
  end

  def test_dialects
    {
      postgres: ['SELECT * FROM "post" WHERE "title" ILIKE $1 ESCAPE \'!\' AND "views" IN ($2, $3) AND "live" = $4 ' \
                 'ORDER BY "id" ASC LIMIT $5 OFFSET $6', ["%a!%!!!_%", 1, 2, true, 10, 0]],
      mysql: ["SELECT * FROM `post` WHERE `title` LIKE ? ESCAPE '!' AND `views` IN (?, ?) AND `live` = ? " \
              "ORDER BY `id` ASC LIMIT ? OFFSET ?", ["%a!%!!!_%", 1, 2, 1, 10, 0]],
      sqlite: ['SELECT * FROM "post" WHERE "title" LIKE ? ESCAPE \'!\' AND "views" IN (?, ?) AND "live" = ? ' \
               'ORDER BY "id" ASC LIMIT ? OFFSET ?', ["%a!%!!!_%", 1, 2, 1, 10, 0]]
    }.each do |dialect, expected|
      repo, log = fake(dialect)
      conditions = [Erupt::Cond.new("title", "LIKE", "a%!_"), Erupt::Cond.new("views", "IN", [1, 2]), Erupt::Cond.new("live", "EQ", true)]
      total, rows = repo.page(Erupt::Query.new(conditions: conditions))
      assert_equal expected, log[1], dialect
      assert_equal 2, total
      # upper-case columns and text values are normalized by field type
      assert_equal({ "id" => 1, "title" => "a", "views" => 3, "live" => true, "day" => Date.new(2026, 1, 5),
                     "at" => Time.new(2026, 1, 5, 10, 30) }, rows.first)
    end
  end

  def test_writes
    repo, log = fake(:mysql)
    repo.add(title: "x", live: false, day: Date.new(2026, 1, 5), at: Time.new(2026, 1, 5, 10, 30, Rational(123, 1000)), id: 9)
    repo.update(1, title: "y", id: 9)
    repo.update(1, id: 9)
    repo.delete([1, 2])
    repo.delete([])
    assert_equal [
      ["INSERT INTO `post` (`title`, `live`, `day`, `at`) VALUES (?, ?, ?, ?)", ["x", 0, "2026-01-05", "2026-01-05 10:30:00.123"]],
      ["UPDATE `post` SET `title` = ? WHERE `id` = ?", ["y", 1]],
      ["DELETE FROM `post` WHERE `id` IN (?, ?)", [1, 2]]
    ], log
  end

  def test_conditions
    repo, log = fake(:postgres)
    conditions = [Erupt::Cond.new("day", "RANGE", [Date.new(2026, 1, 1), Date.new(2026, 2, 1)]), Erupt::Cond.new("views", "NOT_IN", []),
                  Erupt::Cond.new("title", "NOT_LIKE", "x"), Erupt::Cond.new("at", "NULL"), Erupt::Cond.new("views", "IN", [])]
    repo.page(Erupt::Query.new(conditions: conditions, sort: [["views", true], ["title", false]], offset: 20, limit: 5))
    assert_equal ['SELECT * FROM "post" WHERE "day" BETWEEN $1 AND $2 AND 1=1 AND "title" NOT ILIKE $3 ESCAPE \'!\' AND "at" IS NULL ' \
                  'AND 1=0 ORDER BY "views" DESC, "title" ASC LIMIT $4 OFFSET $5', ["2026-01-01", "2026-02-01", "%x%", 5, 20]], log[1]
  end

  def test_filters
    repo, log = fake(:postgres)
    filters = [["owner = ? OR ? = 'all'", ["u", "x"]], ["done = 0", []]]
    repo.page(Erupt::Query.new(conditions: [Erupt::Cond.new("views", "EQ", 1)], filters: filters))
    where = 'WHERE (owner = $1 OR $2 = \'all\') AND (done = 0) AND "views" = $3'
    assert_equal [["SELECT COUNT(*) AS n FROM \"post\" #{where}", ["u", "x", 1]],
                  ["SELECT * FROM \"post\" #{where} ORDER BY \"id\" ASC LIMIT $4 OFFSET $5", ["u", "x", 1, 10, 0]]], log
    assert_raises(ArgumentError) { repo.page(Erupt::Query.new(filters: [["owner = ? OR ?", ["u"]]])) }
  end

  def test_identifiers_are_quoted_and_checked
    assert_equal "`we``ird`", fake(:mysql).first.q("we`ird")
    assert_equal '"we""ird"', fake(:postgres).first.q('we"ird')
    executor = Erupt::SqlExecutor.new(:sqlite) { [] }
    assert_raises(ArgumentError) { Erupt::SqlRepository.new(executor, "post; DROP TABLE x") }
    assert_raises(ArgumentError) { Erupt::SqlExecutor.new(:db2) { [] } }
    assert_raises(ArgumentError) { Erupt::SqlRepository.new(Erupt::SqlExecutor.new(:mysql) { [] }, "post", auto_create: true) }
  end

  def test_pool_lends_a_connection_per_statement
    conn = Object.new
    def conn.exec_params(sql, params) = [{ "sql" => sql, "params" => params }]
    pool = Object.new
    pool.define_singleton_method(:with) { |&block| (@lent = @lent.to_i + 1) && block.call(conn) }
    pool.define_singleton_method(:lent) { @lent }
    assert_equal [{ "sql" => "SELECT 1", "params" => [] }], Erupt::SqlExecutor.pg(pool).call("SELECT 1", [])
    assert_equal 1, pool.lent
  end

  def repositories
    repos = { memory: Erupt::MemoryRepository.new }
    if SQLITE3
      db = SQLite3::Database.new(File.join(Dir.mktmpdir, "sql.db"))
      repos[:sqlite] = Erupt::SqlRepository.new(Erupt::SqlExecutor.sqlite3(db), "post", auto_create: true)
    end
    repos
  end

  def test_repositories_agree
    repositories.each do |kind, repo|
      repo.bind(Post.erupt_model)
      [["100% pure", 3, true], ["wow!", 1, false], ["a_b", nil, false]].each do |title, views, live|
        repo.add(title: title, views: views, live: live, day: Date.new(2026, 1, 5), at: Time.new(2026, 1, 5, 10, 30))
      end
      titles = ->(*conds) { repo.page(Erupt::Query.new(conditions: conds)).last.map { |r| r["title"] } }
      cond = ->(*args) { Erupt::Cond.new(*args) }
      assert_equal ["100% pure", "wow!", "a_b"], titles.call, "#{kind}: default order is primary key ascending"
      assert_equal ["100% pure"], titles.call(cond.call("title", "LIKE", "%")), kind
      assert_equal ["wow!"], titles.call(cond.call("title", "LIKE", "!")), kind
      assert_equal ["a_b"], titles.call(cond.call("title", "LIKE", "_")), kind
      assert_equal ["100% pure"], titles.call(cond.call("title", "LIKE", "PURE")), "#{kind}: LIKE ignores case"
      assert_equal ["wow!"], titles.call(cond.call("live", "EQ", false), cond.call("views", "NOT_NULL")), kind
      assert_equal ["100% pure"], titles.call(cond.call("views", "GT", 2)), kind
      assert_equal ["wow!", "a_b", "100% pure"], repo.page(Erupt::Query.new(sort: [["title", true]])).last.map { |r| r["title"] }, kind
      row = repo.get(1)
      assert_equal [true, Date.new(2026, 1, 5), Time.new(2026, 1, 5, 10, 30)], row.values_at("live", "day", "at"), kind
      repo.update(1, title: "renamed")
      assert_equal "renamed", repo.get(1)["title"], kind
      repo.delete([1, 2])
      assert_equal ["a_b"], titles.call, kind
      assert_nil repo.get(1), kind
    end
  end
end
