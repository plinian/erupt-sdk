<?php

namespace Erupt;

/**
 * A page request handed to a repository. Field names in it have been checked against the model, so a
 * repository may use them as identifiers; values always travel as parameters. `$filters` is the developer's
 * own SQL, of a @Vis view and DataProxy::beforeFetch: a repository must AND every one into its WHERE or refuse the query
 * by throwing, never ignore it.
 */
final class Query
{
    public function __construct(
        /** @var list<Cond> */
        public array $conditions = [],
        /** @var list<array{0: string, 1: bool}> [field, descending] */
        public array $sort = [],
        public int $offset = 0,
        public int $limit = 10,
        /** @var list<array{0: string, 1: list<mixed>}> [sql, params] of a @Vis view and DataProxy::beforeFetch, ANDed as written */
        public array $filters = [],
    ) {
    }
}
