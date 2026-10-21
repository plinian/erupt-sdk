# frozen_string_literal: true

module Erupt
  # What SqlRepository needs from a database: +call(sql, params)+ runs one statement with bound values and
  # returns the rows of a SELECT as hashes keyed by column name; +dialect+ (:sqlite, :postgres, :mysql) picks
  # identifier quotes, placeholders and LIKE. The SDK depends on no driver: the adapters below only call the
  # driver object they are handed, and any other library takes a block:
  #
  #   Erupt::SqlExecutor.new(:postgres) do |sql, params|
  #     ActiveRecord::Base.connection_pool.with_connection { |c| c.raw_connection.exec_params(sql, params).to_a }
  #   end
  class SqlExecutor
    DIALECTS = %i[sqlite postgres mysql].freeze

    attr_reader :dialect

    def initialize(dialect, &run)
      @dialect = dialect.to_sym
      raise ArgumentError, "dialect must be one of #{DIALECTS.join(", ")}" unless DIALECTS.include?(@dialect)

      @run = run or raise ArgumentError, "a block running (sql, params) is required"
    end

    def call(sql, params) = @run.call(sql, params)

    # pg gem: a PG::Connection, or a ConnectionPool of them.
    def self.pg(db) = adapter(:postgres, db) { |c, sql, params| c.exec_params(sql, params).to_a }

    # mysql2 gem: a Mysql2::Client, or a ConnectionPool of them; statements are prepared, so values are bound.
    def self.mysql2(db)
      adapter(:mysql, db) do |c, sql, params|
        statement = c.prepare(sql)
        begin
          statement.execute(*params)&.to_a || []
        ensure
          statement.close
        end
      end
    end

    # sqlite3 gem: a SQLite3::Database, or a ConnectionPool of them.
    def self.sqlite3(db)
      adapter(:sqlite, db) do |c, sql, params|
        statement = c.prepare(sql)
        begin
          statement.execute(*params).map { |row| row.is_a?(Hash) ? row : statement.columns.zip(row).to_h }
        ensure
          statement.close
        end
      end
    end

    # A pool (anything with +with+, like the connection_pool gem) lends a connection per statement; a single
    # connection is used by one thread at a time.
    def self.adapter(dialect, db, &run)
      lock = Mutex.new
      new(dialect) do |sql, params|
        db.respond_to?(:with) ? db.with { |c| run.call(c, sql, params) } : lock.synchronize { run.call(db, sql, params) }
      end
    end
    private_class_method :adapter
  end

  # A table on PostgreSQL, MySQL or SQLite through a SqlExecutor. Column names are the model's field names
  # (quoted, so case sensitive on PostgreSQL); every value is a bound parameter; LIKE escapes with
  # <tt>ESCAPE '!'</tt>, which every database reads the same way. Without a sort, rows come back by primary key
  # ascending. +auto_create+ creates a missing SQLite table: create production tables yourself.
  class SqlRepository < Repository
    QUOTES = { sqlite: %w[" "], postgres: %w[" "], mysql: %w[` `] }.freeze
    OPS = { "EQ" => "=", "NEQ" => "<>", "GT" => ">", "GTE" => ">=", "LT" => "<", "LTE" => "<=" }.freeze
    SQLITE_TYPES = { EditType::NUMBER => "NUMERIC", EditType::BOOLEAN => "INTEGER", EditType::DATE => "DATE",
                     DATE_TIME => "TIMESTAMP", EditType::REFERENCE_TABLE => "INTEGER",
                     EditType::REFERENCE_TREE => "INTEGER" }.freeze

    # Collects bound values and writes the dialect's placeholder for each.
    class Params
      attr_reader :values

      def initialize(dialect)
        @dialect, @values = dialect, []
      end

      def <<(value)
        @values << bindable(value)
        @dialect == :postgres ? "$#{@values.size}" : "?"
      end

      private

      def bindable(value)
        case value
        when true, false then @dialect == :postgres ? value : (value ? 1 : 0)
        when Time, DateTime then value.strftime("%Y-%m-%d %H:%M:%S.%L")
        when Date then value.strftime("%Y-%m-%d")
        else value
        end
      end
    end

    def initialize(executor, table, auto_create: false)
      super()
      raise ArgumentError, "illegal table name '#{table}'" unless IDENTIFIER.match?(table.to_s)
      raise ArgumentError, "auto_create creates SQLite tables only" if auto_create && executor.dialect != :sqlite

      @executor, @table, @auto_create = executor, table.to_s, auto_create
      @dialect = executor.dialect
    end

    def bind(model)
      super
      @columns = model.fields.keys.to_h { |name| [name.downcase, name] }
      return unless @auto_create

      cols = model.fields.each_value.map do |f|
        f.pk? ? "#{q(f.name)} INTEGER PRIMARY KEY AUTOINCREMENT" : "#{q(f.name)} #{SQLITE_TYPES.fetch(f.type, "TEXT")}"
      end
      @executor.call("CREATE TABLE IF NOT EXISTS #{q(@table)} (#{cols.join(", ")})", [])
    end

    def page(query)
      p = Params.new(@dialect)
      total = @executor.call("SELECT COUNT(*) AS n FROM #{q(@table)}#{where(query, p)}", p.values).first
      p = Params.new(@dialect)
      sql = "SELECT * FROM #{q(@table)}#{where(query, p)}"
      order = (query.sort.empty? ? [[model.pk, false]] : query.sort).map { |name, desc| "#{q(name)} #{desc ? "DESC" : "ASC"}" }
      sql += " ORDER BY #{order.join(", ")} LIMIT #{p << query.limit} OFFSET #{p << query.offset}"
      [Integer(total.values.first.to_s, 10), @executor.call(sql, p.values).map { |row| record(row) }]
    end

    def get(pk)
      p = Params.new(@dialect)
      row = @executor.call("SELECT * FROM #{q(@table)} WHERE #{q(model.pk)} = #{p << pk}", p.values).first
      row && record(row)
    end

    def add(record)
      record = store(record)
      p = Params.new(@dialect)
      values = record.values.map { |v| p << v }
      @executor.call("INSERT INTO #{q(@table)} (#{record.keys.map { |k| q(k) }.join(", ")}) VALUES (#{values.join(", ")})", p.values)
    end

    def update(pk, record)
      record = store(record)
      return if record.empty?

      p = Params.new(@dialect)
      sets = record.map { |k, v| "#{q(k)} = #{p << v}" }
      @executor.call("UPDATE #{q(@table)} SET #{sets.join(", ")} WHERE #{q(model.pk)} = #{p << pk}", p.values)
    end

    def delete(pks)
      return if pks.empty?

      p = Params.new(@dialect)
      marks = pks.map { |pk| p << pk }
      @executor.call("DELETE FROM #{q(@table)} WHERE #{q(model.pk)} IN (#{marks.join(", ")})", p.values)
    end

    # A quoted identifier; the closing quote is doubled.
    def q(identifier)
      open, close = QUOTES.fetch(@dialect)
      "#{open}#{identifier.gsub(close, close * 2)}#{close}"
    end

    private

    # Values as columns hold them: a JSON value as its text
    def store(record)
      keys(record).except(model.pk).to_h { |k, v| [k, model.fields[k]&.json? && !v.nil? ? JSON.generate(v) : v] }
    end

    def where(query, p)
      clauses = query.filters.map do |sql, params|
        # the developer's own SQL, as written; with params, each '?' is one of them, bound like every other value
        pieces = params.empty? ? [sql] : sql.split("?", -1)
        raise ArgumentError, "filter: #{pieces.size - 1} '?' for #{params.size} params in #{sql.inspect}" if pieces.size - 1 != params.size

        "(#{pieces.first}#{params.zip(pieces.drop(1)).map { |v, piece| (p << v) + piece }.join})"
      end
      clauses += query.conditions.map do |c|
        col = q(c.field)
        values = Array(c.value)
        case c.op
        when *OPS.keys then "#{col} #{OPS[c.op]} #{p << c.value}"
        when "LIKE", "NOT_LIKE"
          # '!' rather than a backslash: MySQL reads a backslash inside a string literal as an escape itself;
          # ILIKE because PostgreSQL's LIKE is case sensitive, the others' (and the memory repository's) is not
          pattern = "%#{c.value.to_s.gsub(/[!%_]/) { |ch| "!#{ch}" }}%"
          "#{col} #{"NOT " if c.op == "NOT_LIKE"}#{@dialect == :postgres ? "ILIKE" : "LIKE"} #{p << pattern} ESCAPE '!'"
        when "RANGE" then "#{col} BETWEEN #{p << values[0]} AND #{p << values[1]}"
        when "IN", "NOT_IN"
          next(c.op == "IN" ? "1=0" : "1=1") if values.empty?

          "#{col} #{"NOT " if c.op == "NOT_IN"}IN (#{values.map { |v| p << v }.join(", ")})"
        when "NULL" then "#{col} IS NULL"
        when "NOT_NULL" then "#{col} IS NOT NULL"
        else raise ArgumentError, "illegal operator '#{c.op}'"
        end
      end
      clauses.empty? ? "" : " WHERE #{clauses.join(" AND ")}"
    end

    # A driver row as a record: columns matched to fields case-insensitively, values normalized by field type
    # (pg returns text, mysql2 Time / BigDecimal, sqlite3 what was stored).
    def record(row)
      row = row.to_h { |k, v| [@columns.fetch(k.to_s.downcase, k.to_s), v] }
      model.fields.each_value.to_h do |f|
        value = row[f.name]
        [f.name, value.nil? ? nil : normalize(f, value)]
      end
    end

    def normalize(field, value)
      return value.is_a?(String) ? JSON.parse(value) : value if field.json?

      case field.type
      when EditType::BOOLEAN then [true, 1, "1", "t", "true"].include?(value)
      when EditType::DATE then Erupt.parse_time(value).to_date
      when DATE_TIME then Erupt.parse_time(value)
      when EditType::NUMBER, *REFERENCES then Erupt.number(value)
      else field.pk? ? Erupt.number(value) : value
      end
    end
  end
end
