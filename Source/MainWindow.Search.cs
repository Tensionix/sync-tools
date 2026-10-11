using System;
using Avalonia.Controls;
using AudionSyncTools.Core;
using AudionSyncTools.Views;

namespace AudionSyncTools;

/// <summary>
/// Ctrl+F and Alt+F7: the search window (Views\SearchWindow.cs). One window for the program: asked
/// for again, it comes to the front and takes the place of the active panel. From its table the
/// active panel goes to the folder of a found file and stands on it.
/// </summary>
public partial class MainWindow
{
    SearchWindow? _search;

    void OpenSearch()
    {
        if (_search is null)
        {
            _search = new SearchWindow(Icon, _settings) { Place = () => (_active.SourceKey, _active.Path) };
            _search.GoTo += ShowFound;
            _search.Feed += (key, path, title, files) =>
            {
                if (_settingsOpen) ToggleSettings(false);
                _active.ShowFound(key, path, title, files);
                Activate();
                _active.FocusList();
            };
            _search.Closed += (_, _) => _search = null;
            // A window of its own, not one held above the main: the panel it sends to a file must not hide behind it.
            _search.Show();
        }
        else
        {
            if (_search.WindowState == WindowState.Minimized) _search.WindowState = WindowState.Normal;
            _search.Activate();
        }
        _search.FollowPanel();
    }

    /// <summary>ПЕРЕЙТИ К ФАЙЛУ: the active panel opens the folder of the file - whatever it showed before - and stands on the file.</summary>
    void ShowFound(string key, string root, Found file)
    {
        var folder = root;
        foreach (var step in file.Folder.Split('/', StringSplitOptions.RemoveEmptyEntries)) folder = Sources.Child(folder, step);
        if (_settingsOpen) ToggleSettings(false);
        _active.Go(key, folder, file.Name);
        Activate();
        _active.FocusList();
    }
}
