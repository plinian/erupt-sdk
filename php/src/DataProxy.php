<?php

namespace Erupt;

/**
 * Hooks around a model's data, as erupt's Java `DataProxy`: extend it, override what you need and name it
 * in `#[Erupt(..., dataProxy: ArticleProxy::class)]`. A record is the array the repository stores, a row the
 * array the browser reads; both come by reference, so change them in place. Throw Fail to refuse with a message.
 */
abstract class DataProxy
{
    /** Default values of the search bar, `$condition[field] = value`. */
    public function searchCondition(array &$condition): void
    {
    }

    /**
     * SQL ANDed to a table page's WHERE, as written: `"status <> 'deleted'"`, or with its values bound,
     * `['owner = ?', [$uid]]`. `$conditions` are the search bar's. Only SQL repositories apply it.
     *
     * @param list<Cond> $conditions
     * @return string|array{0: string, 1: list<mixed>}|null
     */
    public function beforeFetch(array $conditions): string|array|null
    {
        return null;
    }

    /** The rows of a table page, before they are sent. */
    public function afterFetch(array &$rows): void
    {
    }

    /** The values a new record's form opens with. */
    public function addBehavior(array &$record): void
    {
    }

    /** A record read by its key, for the edit form or the detail view. */
    public function editBehavior(array &$record): void
    {
    }

    /** A record about to be added or updated. */
    public function validate(array &$record): void
    {
    }

    public function beforeAdd(array &$record): void
    {
    }

    public function afterAdd(array &$record): void
    {
    }

    public function beforeUpdate(array &$record): void
    {
    }

    public function afterUpdate(array &$record): void
    {
    }

    public function beforeDelete(array &$record): void
    {
    }

    public function afterDelete(array &$record): void
    {
    }
}
