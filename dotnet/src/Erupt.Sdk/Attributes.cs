namespace Erupt;

/// <summary>
/// Declares a class as an erupt model. <see cref="Name"/> defaults to the class name and is what the server
/// addresses (<c>node.Name</c>); <see cref="OrderBy"/> is the default table order, applied by the node
/// (<c>"views desc, id"</c>); <see cref="DataProxy"/> lists <see cref="IDataProxy"/> classes, run in this order around
/// every read and write of the model.
/// </summary>
[AttributeUsage(AttributeTargets.Class)]
public sealed class EruptModelAttribute(string title) : Attribute
{
    public string Title { get; } = title;

    public string? Name { get; set; }

    public string? OrderBy { get; set; }

    public Type[] DataProxy { get; set; } = [];
}

/// <summary>The primary key. The repository assigns it; it is never part of the form.</summary>
[AttributeUsage(AttributeTargets.Property)]
public sealed class PkAttribute : Attribute
{
    /// <summary>Field name on the wire; defaults to the snake_case property name.</summary>
    public string? Name { get; set; }
}

/// <summary>
/// One column. The title labels both the table column and the form input. The edit type follows the property
/// type (string INPUT, numbers NUMBER, bool BOOLEAN, DateOnly DATE, DateTime DATE_TIME, another
/// <see cref="EruptModelAttribute"/> class a reference, <see cref="ChoiceAttribute"/>s a CHOICE, or a MULTI_CHOICE on a
/// collection) unless
/// <see cref="Type"/> is set.
/// </summary>
[AttributeUsage(AttributeTargets.Property)]
public sealed class FieldAttribute(string title = "") : Attribute
{
    public string Title { get; } = title;

    /// <summary>Field name on the wire; defaults to the snake_case property name.</summary>
    public string? Name { get; set; }

    /// <summary>The edit type; <see cref="EditType.AUTO"/> infers it from the property type.</summary>
    public EditType Type { get; set; } = EditType.AUTO;

    /// <summary>Offered in the search bar.</summary>
    public bool Search { get; set; }

    public bool NotNull { get; set; }

    public bool Sortable { get; set; }

    /// <summary>Shown as a table column.</summary>
    public bool Table { get; set; } = true;

    /// <summary>Shown in the add / edit form.</summary>
    public bool Form { get; set; } = true;

    /// <summary>
    /// In the build only, like a JPA <c>@Transient</c> field: a layout field (DIVIDE, CALLOUT, EMPTY, GROUP by a raw
    /// edit type) that has no column and is never read or written.
    /// </summary>
    public bool Virtual { get; set; }

    /// <summary>
    /// The referenced model, for a property that holds a primary key (e.g. <c>long?</c>), or a list of them for a
    /// CHECKBOX / TAB_TREE.
    /// </summary>
    public Type? Ref { get; set; }

    /// <summary>Field of the referenced model shown for a reference.</summary>
    public string Label { get; set; } = "name";

    /// <summary>Parent field of the referenced model: turns the reference picker into a tree.</summary>
    public string? Tree { get; set; }
}

/// <summary>One option of a CHOICE field, in declaration order.</summary>
[AttributeUsage(AttributeTargets.Property, AllowMultiple = true)]
public sealed class ChoiceAttribute(string value, string label) : Attribute
{
    public string Value { get; } = value;

    public string Label { get; } = label;
}
