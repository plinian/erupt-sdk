<?php
/**
 * The conformance fixture (conformance/README.md) in PHP. Returns the configured Node; both the request
 * router and the heartbeat launcher build it from here. Storage is the SQLite file in ERUPT_DB, because
 * `php -S` keeps nothing in memory between requests.
 */

namespace Erupt\Examples\Conformance;

use Erupt\Attribute\Erupt;
use Erupt\Attribute\Field;
use Erupt\Attribute\Operation;
use Erupt\DataProxy;
use Erupt\Fail;
use Erupt\Node;
use Erupt\OperationContext;
use Erupt\PdoRepository;

require_once __DIR__ . '/../../autoload.php';

#[Erupt('Category')]
final class Category
{
    #[Field(pk: true)] public int $id;
    #[Field('Name', search: true)] public string $name;
    #[Field('Parent')] public ?int $parent;
}

#[Erupt('Publish Options')]
final class PublishForm
{
    #[Field('Note', notNull: true)] public string $note;
}

#[Erupt('Article', orderBy: 'id desc')]
final class Article
{
    #[Field(pk: true)] public int $id;
    #[Field('Title', search: true, notNull: true, sortable: true, edit: ['inputType' => ['length' => 64]])] public string $title;
    #[Field('Status', choices: ['draft' => 'Draft', 'published' => 'Published'], search: true)] public string $status;
    #[Field('Views', sortable: true)] public int $views;
    #[Field('Featured', search: true)] public bool $featured;
    #[Field('Publish Date', type: 'DATE', search: true)] public \DateTimeImmutable $publish_date;
    #[Field('Review At')] public \DateTimeImmutable $review_at;
    #[Field('Body', type: 'TEXTAREA', table: false)] public string $body;
    #[Field('Category', search: true)] public ?Category $category;
    #[Field('Topic', tree: 'parent')] public ?Category $topic;

    #[Operation('Publish', icon: 'fa fa-paper-plane', form: PublishForm::class, ifExpr: "item.status !== 'published'")]
    public static function publish(OperationContext $op): void
    {
        foreach ($op->rows as $row) {
            $op->repo->update($row['id'], ['status' => 'published']);
        }
    }

    #[Operation('Feature', mode: 'SINGLE', confirm: false)]
    public static function feature(OperationContext $op): string
    {
        return "alert('featured')";
    }

    #[Operation('Rebuild', mode: 'BUTTON', show: 'isRoot')]
    public static function rebuild(OperationContext $op): void
    {
    }

    public static function isRoot(?array $user): bool
    {
        return ($user['account'] ?? null) === 'root';
    }
}

final class NoteProxy extends DataProxy
{
    public function addBehavior(array &$record): void
    {
        $record['text'] = 'new';
    }

    public function validate(array &$record): void
    {
        if (($record['text'] ?? null) === 'forbidden') {
            throw new Fail('forbidden text');
        }
    }
}

#[Erupt('Note', power: ['delete' => false], dataProxy: NoteProxy::class)]
final class Note
{
    #[Field(pk: true)] public int $id;
    #[Field('Text')] public string $text;
    #[Field('Ping', type: 'BUTTON', click: 'ping')] public ?string $ping;

    public static function ping(array $form): array
    {
        return ['eval' => 'pong:' . ($form['text'] ?? '')];
    }
}

$pdo = new \PDO('sqlite:' . getenv('ERUPT_DB'));
return (new Node('conformance', (string) getenv('ERUPT_ACCESS_TOKEN'), (string) getenv('ERUPT_SERVER'),
    'http://127.0.0.1:' . getenv('PORT')))
    ->register(Category::class, new PdoRepository($pdo, 'category'))
    ->register(Article::class, new PdoRepository($pdo, 'article'))
    ->register(Note::class, new PdoRepository($pdo, 'note'));
