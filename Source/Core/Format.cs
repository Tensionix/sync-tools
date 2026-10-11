using System;
using System.Globalization;

namespace AudionSyncTools.Core;

public static class Format
{
    static readonly CultureInfo Ru = CultureInfo.GetCultureInfo("ru-RU");

    /// <summary>
    /// SETTINGS · РАЗМЕРЫ · В БАЙТАХ: exact numbers, as in the TC status line -
    /// a few bytes of difference between two folders show another version.
    /// </summary>
    public static bool ExactBytes { get; set; }

    /// <summary>Exact digits whatever the mode: Shift+Space in the panel status line.</summary>
    public static string Exact(long bytes) => string.Format(Ru, "{0:N0}", Math.Max(0, bytes));

    /// <summary>Same units and rounding as Format-AbkSize in Sync Tools; exact digits in byte mode.</summary>
    public static string Size(long bytes)
    {
        if (bytes < 0) return "";
        return ExactBytes ? string.Format(Ru, "{0:N0}", bytes) : Short(bytes);
    }

    /// <summary>КБ, МБ, ГБ whatever the mode: the free space of a disk is an estimate, not a thing to compare byte by byte.</summary>
    public static string Short(long bytes)
    {
        if (bytes < 0) return "";
        bool ru = Lang.Code == "ru";
        if (bytes >= 1L << 30) return string.Format(Ru, ru ? "{0:N1} ГБ" : "{0:N1} GB", bytes / (double)(1L << 30));
        if (bytes >= 1L << 20) return string.Format(Ru, ru ? "{0:N0} МБ" : "{0:N0} MB", bytes / (double)(1L << 20));
        if (bytes >= 1L << 10) return string.Format(Ru, ru ? "{0:N0} КБ" : "{0:N0} KB", bytes / (double)(1L << 10));
        return bytes + (ru ? " Б" : " B");
    }

    /// <summary>
    /// One date shape for every row. Sync Tools tried shortening fresh dates
    /// and the column read like noise; one format compares at a glance.
    /// </summary>
    public static string Date(DateTime? value)
    {
        if (value is not { } when || when.Year < 1990) return "";
        return when.ToString("dd.MM.yyyy HH:mm", Ru);
    }
}
