<?php

namespace Erupt\Attribute;

/**
 * Declares a class as an erupt model.
 *
 * `name` defaults to the class's short name and is what the server addresses (`node.Name`); `power`
 * switches features off (`['delete' => false]`); `orderBy` is the default table order, applied by the
 * node (`'views desc, id'`); `dataProxy` is one Erupt\DataProxy or a list of them (classes or instances), run
 * around every read and write of the model; `raw` holds raw `@Erupt` attributes merged onto the defaults
 * (`['layout' => ['pageSize' => 30]]`, see Erupt\Types\Annotations). A `vis` entry also takes the node-side
 * `filter` (one SQL string or a list, ANDed as written) and `orderBy` (as the model's), applied when the table
 * is read for that view and kept out of the build.
 */
#[\Attribute(\Attribute::TARGET_CLASS)]
final class Erupt
{
    public function __construct(
        public string $title = '',
        public ?string $name = null,
        public array $power = [],
        public ?string $orderBy = null,
        public array $raw = [],
        /** @var class-string<\Erupt\DataProxy>|\Erupt\DataProxy|list<class-string<\Erupt\DataProxy>|\Erupt\DataProxy> */
        public string|object|array $dataProxy = [],
    ) {
    }
}
