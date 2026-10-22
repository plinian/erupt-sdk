<?php

namespace Erupt\Attribute;

/**
 * One column. `title` labels both the table column and the form input. The edit type follows the
 * property type (string INPUT, int / float NUMBER, bool BOOLEAN, DateTimeInterface DATE_TIME) unless
 * `type` is given; `choices` makes a CHOICE. A property typed with another #[Erupt] class (or `ref`)
 * references one of its records: the repository stores the referenced primary key, the UI shows
 * `label`; `tree` names the referenced model's parent field and turns the picker into a tree. `table` /
 * `form` hide the field from the table / the form. `view` / `edit` are raw `@View` / `@Edit` attributes.
 * A property typed `array` holds a JSON array (MULTI_CHOICE, its options in `choices`), `object` / `stdClass`
 * a JSON object (KEY_VALUE): stored as JSON text by SQL repositories. `virtual` declares a form-only element
 * (DIVIDE, CALLOUT, EMPTY, GROUP, and every BUTTON) that is in the build but never read or written. CHECKBOX /
 * TAB_TREE with `ref` hold the picked records of that model, stored as the JSON list of their keys.
 * `fetch` / `onchange` / `complete` / `click` name a static method of the model class that the node runs when
 * the server invokes the field: fetch(array $form) the options of a CHOICE / MULTI_CHOICE (value => label) or
 * the tags of a TAGS (a list), onchange(array $form) ['formData' => ..., 'editExpr' => ...], complete(array $form,
 * string $typed) the suggestions of an AUTO_COMPLETE, click(array $form) ['eval' => ..., 'formData' => ...,
 * 'editExpr' => ...] of a BUTTON. Throw Fail to refuse with a message.
 */
#[\Attribute(\Attribute::TARGET_PROPERTY)]
final class Field
{
    public function __construct(
        public string $title = '',
        public ?string $type = null,
        public bool $pk = false,
        public bool $search = false,
        public bool $notNull = false,
        public bool $sortable = false,
        public bool $table = true,
        public bool $form = true,
        public ?array $choices = null,
        public ?string $ref = null,
        public string $label = 'name',
        public ?string $tree = null,
        public array $view = [],
        public array $edit = [],
        public bool $virtual = false,
        public ?string $fetch = null,
        public ?string $onchange = null,
        public ?string $complete = null,
        public ?string $click = null,
    ) {
    }
}
