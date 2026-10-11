using System;
using System.ComponentModel;
using System.IO;
using Avalonia.Media;

namespace AudionSyncTools.Core;

/// <summary>One line of a file panel: a drive, a folder or a file - local or of a remote.</summary>
public sealed class FileRow : INotifyPropertyChanged
{
    public string Name { get; init; } = "";
    public bool IsDir { get; init; }
    public long Size { get; init; } = -1;
    public DateTime? Modified { get; init; }
    public IBrush Colour { get; set; } = Brushes.White;

    /// <summary>The TYPE column, as in Total Commander: the extension, for sorting and reading only.</summary>
    public string Ext => IsDir ? "" : Path.GetExtension(Name).TrimStart('.').ToLowerInvariant();

    public string Display => Name;
    public string SizeText => IsDir ? "" : Format.Size(Size);
    /// <summary>One shape of the date for every row: shortening fresh dates was tried and the column read like noise.</summary>
    public string DateText => Format.Date(Modified);

    bool _checked;
    public bool Checked
    {
        get => _checked;
        set
        {
            if (_checked == value) return;
            _checked = value;
            Changed(nameof(Checked));
            Changed(nameof(Mark));
            Changed(nameof(ShowFolder));
        }
    }

    /// <summary>Glyph of the mark column: filled when the row is marked.</summary>
    public string Mark => _checked ? "●" : "";

    /// <summary>The narrow first column: a folder glyph, replaced by the orange mark dot once the row is marked.</summary>
    public bool ShowFolder => IsDir && !_checked;

    void Changed(string name) => PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(name));

    public event PropertyChangedEventHandler? PropertyChanged;
}
