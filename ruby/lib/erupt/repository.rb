# frozen_string_literal: true

module Erupt
  # One search condition. +op+: EQ NEQ GT GTE LT LTE LIKE NOT_LIKE RANGE IN NOT_IN NULL NOT_NULL.
  Cond = Struct.new(:field, :op, :value)

  # What a repository is asked for; +sort+ is <tt>[[field, descending], ...]</tt>; +filters+ is
  # <tt>[[sql, params], ...]</tt> of a @Vis view and DataProxy#before_fetch, to be ANDed as written: a repository that cannot
  # apply them must refuse the query (raise), never ignore them.
  Query = Struct.new(:conditions, :sort, :filters, :offset, :limit, keyword_init: true) do
    def initialize(conditions: [], sort: [], filters: [], offset: 0, limit: 10) = super
  end

  # Storage adapter: implement these five methods to put a model on any storage. A record is a Hash keyed by
  # field name. A repository only sees field names the node has already checked against the model, so it may
  # use them as identifiers; values always travel as parameters. +page+ must apply the query's +filters+ or
  # raise.
  class Repository
    attr_reader :model

    def bind(model)
      @model = model
    end

    # Returns <tt>[total, records]</tt>.
    def page(query) = raise(NotImplementedError)
    def get(pk) = raise(NotImplementedError)
    def add(record) = raise(NotImplementedError)
    def update(pk, record) = raise(NotImplementedError)
    def delete(pks) = raise(NotImplementedError)

    private

    def keys(record) = record.to_h { |k, v| [k.to_s, v] }
  end

  # Records in memory, for tests and demos.
  class MemoryRepository < Repository
    def initialize(records = [])
      super()
      @lock = Mutex.new
      @rows = {}
      @seq = 0
      @pending = records
    end

    def bind(model)
      super
      @pending.each { |record| add(record) }
    end

    def page(query)
      raise ArgumentError, "MemoryRepository cannot apply SQL filters (a view filter, before_fetch)" unless query.filters.empty?

      rows = @lock.synchronize { @rows.values.select { |r| query.conditions.all? { |c| match?(r[c.field], c) } } }
      rows = rows.each_with_index.sort do |(a, i), (b, j)|
        query.sort.lazy.map { |name, desc| compare(a[name], b[name]) * (desc ? -1 : 1) }.find(&:nonzero?) || i <=> j
      end
      [rows.size, rows.drop(query.offset).first(query.limit).map { |r, _| r.dup }]
    end

    def get(pk) = @lock.synchronize { @rows[pk]&.dup }

    def add(record)
      @lock.synchronize { @rows[@seq += 1] = keys(record).merge(model.pk => @seq) }
    end

    def update(pk, record)
      @lock.synchronize { @rows[pk]&.merge!(keys(record).except(model.pk)) }
    end

    def delete(pks)
      @lock.synchronize { pks.each { |pk| @rows.delete(pk) } }
    end

    private

    # nil sorts last; false before true
    def compare(a, b)
      return (a.nil? ? 1 : 0) - (b.nil? ? 1 : 0) if a.nil? || b.nil?

      a, b = [a, b].map { |v| v == true ? 1 : v == false ? 0 : v }
      (a <=> b) || 0
    end

    def match?(value, cond)
      expect = cond.value
      case cond.op
      when "NULL" then value.nil?
      when "NOT_NULL" then !value.nil?
      else !value.nil? && match_value?(value, cond.op, expect)
      end
    end

    def match_value?(value, op, expect)
      value = JSON.generate(value) if value.is_a?(Array) || value.is_a?(Hash) # a JSON value is matched as its text
      case op
      when "EQ" then value == expect
      when "NEQ" then value != expect
      when "LIKE" then value.to_s.downcase.include?(expect.to_s.downcase)
      when "NOT_LIKE" then !value.to_s.downcase.include?(expect.to_s.downcase)
      when "IN" then expect.include?(value)
      when "NOT_IN" then !expect.include?(value)
      when "RANGE" then compare(expect[0], value) <= 0 && compare(value, expect[1]) <= 0
      when "GT" then compare(value, expect).positive?
      when "GTE" then compare(value, expect) >= 0
      when "LT" then compare(value, expect).negative?
      when "LTE" then compare(value, expect) <= 0
      else false
      end
    end
  end
end
