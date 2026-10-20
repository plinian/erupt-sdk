package erupt

import (
	"context"
	"errors"
	"sort"
	"strings"
	"sync"
)

// Record is one row, keyed by field name.
type Record = map[string]any

// Cond is one search condition. Field is checked against the model before a repository sees it, so it may
// be used as an identifier; Value is already coerced (a two-element []any for RANGE, a []any for IN).
type Cond struct {
	Field string
	Op    string // EQ NEQ GT GTE LT LTE LIKE NOT_LIKE RANGE IN NOT_IN NULL NOT_NULL
	Value any
}

// Order sorts by one field.
type Order struct {
	Field string
	Desc  bool
}

// Filter is SQL a @Vis view or a DataProxy's BeforeFetch adds to a table page, ANDed as written; with
// Params, each '?' in SQL is bound to one of them.
type Filter struct {
	SQL    string
	Params []any
}

// Query is what a table page asks a repository for. Filters come from a @Vis view and DataProxy.BeforeFetch
// and must be ANDed to the conditions; a repository that cannot apply them must refuse the query with an error.
type Query struct {
	Conditions []Cond
	Sort       []Order
	Filters    []Filter
	Offset     int
	Limit      int
}

// Repository puts an erupt model on any storage. Get returns nil, nil for a missing record. Return
// Fail(...) for an error the user should read; any other error answers 500. Page must apply Query.Filters
// or refuse a query that has some, never ignore them.
type Repository interface {
	Page(ctx context.Context, q Query) (total int64, records []Record, err error)
	Get(ctx context.Context, pk any) (Record, error)
	Add(ctx context.Context, record Record) error
	Update(ctx context.Context, pk any, record Record) error
	Delete(ctx context.Context, pks []any) error
}

// Binder is implemented by a repository that needs its model; Register calls it.
type Binder interface {
	Bind(m *Model) error
}

// MemoryRepository keeps records in memory, in insertion order. Safe for concurrent use.
type MemoryRepository struct {
	mu      sync.RWMutex
	model   *Model
	rows    map[any]Record
	order   []any
	seq     int64
	pending []Record
}

// NewMemoryRepository seeds records; each gets the next primary key when the repository is registered.
func NewMemoryRepository(seed ...Record) *MemoryRepository {
	return &MemoryRepository{rows: map[any]Record{}, pending: seed}
}

func (r *MemoryRepository) Bind(m *Model) error {
	r.model = m
	for _, record := range r.pending {
		if err := r.Add(context.Background(), record); err != nil {
			return err
		}
	}
	r.pending = nil
	return nil
}

func (r *MemoryRepository) Page(_ context.Context, q Query) (int64, []Record, error) {
	if len(q.Filters) > 0 {
		return 0, nil, errors.New("MemoryRepository cannot apply SQL filters (a view filter, BeforeFetch)")
	}
	r.mu.RLock()
	var rows []Record
	for _, key := range r.order {
		row := r.rows[key]
		if matchAll(row, q.Conditions) {
			rows = append(rows, copyRecord(row))
		}
	}
	r.mu.RUnlock()
	sort.SliceStable(rows, func(i, j int) bool {
		for _, o := range q.Sort {
			c := compareNullsLast(rows[i][o.Field], rows[j][o.Field])
			if o.Desc {
				c = -c
			}
			if c != 0 {
				return c < 0
			}
		}
		return false
	})
	total := int64(len(rows))
	if q.Offset >= len(rows) {
		return total, []Record{}, nil
	}
	end := len(rows)
	if q.Limit > 0 && q.Offset+q.Limit < end {
		end = q.Offset + q.Limit
	}
	return total, rows[q.Offset:end], nil
}

func (r *MemoryRepository) Get(_ context.Context, pk any) (Record, error) {
	r.mu.RLock()
	defer r.mu.RUnlock()
	if row, ok := r.rows[normalizeKey(pk)]; ok {
		return copyRecord(row), nil
	}
	return nil, nil
}

func (r *MemoryRepository) Add(_ context.Context, record Record) error {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.seq++
	row := copyRecord(record)
	row[r.model.pk] = r.seq
	r.rows[r.seq] = row
	r.order = append(r.order, r.seq)
	return nil
}

func (r *MemoryRepository) Update(_ context.Context, pk any, record Record) error {
	r.mu.Lock()
	defer r.mu.Unlock()
	if row, ok := r.rows[normalizeKey(pk)]; ok {
		for k, v := range record {
			if k != r.model.pk {
				row[k] = v
			}
		}
	}
	return nil
}

func (r *MemoryRepository) Delete(_ context.Context, pks []any) error {
	r.mu.Lock()
	defer r.mu.Unlock()
	for _, pk := range pks {
		key := normalizeKey(pk)
		if _, ok := r.rows[key]; !ok {
			continue
		}
		delete(r.rows, key)
		for i, k := range r.order {
			if k == key {
				r.order = append(r.order[:i], r.order[i+1:]...)
				break
			}
		}
	}
	return nil
}

func copyRecord(r Record) Record {
	out := make(Record, len(r))
	for k, v := range r {
		out[k] = v
	}
	return out
}

// compareNullsLast puts missing values after every value (before them when descending).
func compareNullsLast(a, b any) int {
	switch {
	case a == nil && b == nil:
		return 0
	case a == nil:
		return 1
	case b == nil:
		return -1
	}
	c, _ := compare(a, b)
	return c
}

func matchAll(row Record, conds []Cond) bool {
	for _, c := range conds {
		if !match(row[c.Field], c) {
			return false
		}
	}
	return true
}

func match(value any, c Cond) bool {
	switch c.Op {
	case "NULL":
		return value == nil
	case "NOT_NULL":
		return value != nil
	}
	if value == nil {
		return false
	}
	switch c.Op {
	case "EQ":
		return equal(value, c.Value)
	case "NEQ":
		return !equal(value, c.Value)
	case "LIKE", "NOT_LIKE":
		found := strings.Contains(strings.ToLower(str(value)), strings.ToLower(str(c.Value)))
		return found == (c.Op == "LIKE")
	case "IN", "NOT_IN":
		found := false
		for _, v := range c.Value.([]any) {
			if equal(value, v) {
				found = true
				break
			}
		}
		return found == (c.Op == "IN")
	case "RANGE":
		bounds := c.Value.([]any)
		lo, ok1 := compare(value, bounds[0])
		hi, ok2 := compare(value, bounds[1])
		return ok1 && ok2 && lo >= 0 && hi <= 0
	}
	cmp, ok := compare(value, c.Value)
	if !ok {
		return false
	}
	switch c.Op {
	case "GT":
		return cmp > 0
	case "GTE":
		return cmp >= 0
	case "LT":
		return cmp < 0
	case "LTE":
		return cmp <= 0
	}
	return false
}
