using System.Text.Json.Nodes;

namespace Erupt;

/// <summary>
/// Hooks around a model's data, as erupt's Java <c>DataProxy</c>: implement what you need and name the class in
/// <see cref="EruptModelAttribute.DataProxy"/>. A record is the <see cref="Record"/> the repository receives, a row
/// the JSON object the browser reads; change them in place. Throw <see cref="EruptFailure"/> to refuse with a message.
/// </summary>
public interface IDataProxy
{
    /// <summary>Default values of the search bar, <c>condition[field] = value</c>.</summary>
    void SearchCondition(Record condition) { }

    /// <summary>
    /// SQL ANDed to a table page's WHERE, as written: <c>"status &lt;&gt; 'deleted'"</c>, or with its values bound,
    /// <c>new SqlFilter("owner = ?", uid)</c>. <paramref name="conditions"/> are the search bar's. Only SQL
    /// repositories apply it; <see cref="MemoryRepository"/> refuses it.
    /// </summary>
    SqlFilter? BeforeFetch(IReadOnlyList<Cond> conditions) => null;

    /// <summary>The rows of a table page, before they are sent.</summary>
    void AfterFetch(IReadOnlyList<JsonObject> rows) { }

    /// <summary>The values a new record's form opens with.</summary>
    void AddBehavior(Record record) { }

    /// <summary>A record read by its key, for the edit form or the detail view.</summary>
    void EditBehavior(Record record) { }

    /// <summary>A record about to be added or updated.</summary>
    void Validate(Record record) { }

    void BeforeAdd(Record record) { }

    void AfterAdd(Record record) { }

    void BeforeUpdate(Record record) { }

    void AfterUpdate(Record record) { }

    void BeforeDelete(Record record) { }

    void AfterDelete(Record record) { }
}
