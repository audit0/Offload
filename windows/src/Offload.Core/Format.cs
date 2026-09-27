using System.Globalization;

namespace Offload.Core;

public static class Format
{
    /// <summary>Размер на диске — десятичными единицами, как в Проводнике на Mac: 24.5 ГБ.
    ///
    /// Точность везде одна: до 100 — один знак после точки, от 100 — целые. Иначе рядом стояли бы
    /// «4.81 ГБ», «24.5 ГБ» и «168.01 ГБ», и суммы на одном экране читались бы вразнобой.</summary>
    public static string Bytes(long count) => Size(count, 1000);

    /// <summary>Оперативная память считается двоичными единицами: 16 ГБ, а не 17.2.</summary>
    public static string Memory(ulong count) => Size(count > long.MaxValue ? long.MaxValue : (long)count, 1024);

    static readonly string[] Units = ["Б", "КБ", "МБ", "ГБ", "ТБ", "ПБ"];

    internal static string Size(long count, double @base)
    {
        string sign = count < 0 ? "−" : "";
        double value = Math.Abs((double)count);
        int unit = 0;
        while (value >= @base && unit < Units.Length - 1)
        {
            value /= @base;
            unit++;
        }
        // Округление могло дать ровно base («999.96 МБ» → «1000.0») — тогда это уже следующая единица.
        if (unit < Units.Length - 1 && Math.Round(value * 10, MidpointRounding.AwayFromZero) / 10 >= @base)
        {
            value /= @base;
            unit++;
        }
        string text;
        if (unit == 0 || value >= 100)
        {
            text = ((long)Math.Round(value, MidpointRounding.AwayFromZero)).ToString(CultureInfo.InvariantCulture);
        }
        else
        {
            double rounded = Math.Round(value * 10, MidpointRounding.AwayFromZero) / 10;
            text = rounded == Math.Round(rounded)
                ? ((long)rounded).ToString(CultureInfo.InvariantCulture)
                : rounded.ToString("0.0", CultureInfo.InvariantCulture);
        }
        return $"{sign}{text} {Units[unit]}";
    }

    /// <summary>«сейчас», «вчера», «3 дня назад», «2 месяца назад». Дата в будущем (часы файла
    /// чуть впереди системных) показывается как «сейчас», а не «через 0 секунд».</summary>
    public static string Relative(DateTime date, DateTime? now = null)
    {
        var current = (now ?? DateTime.UtcNow).ToUniversalTime();
        var then = date.ToUniversalTime();
        if (then > current) then = current;
        var span = current - then;
        if (span.TotalSeconds < 60) return "сейчас";
        if (span.TotalMinutes < 60)
        {
            int minutes = (int)span.TotalMinutes;
            return $"{minutes} {Plural.Ru(minutes, "минуту", "минуты", "минут")} назад";
        }
        if (span.TotalHours < 24)
        {
            int hours = (int)span.TotalHours;
            return $"{hours} {Plural.Ru(hours, "час", "часа", "часов")} назад";
        }
        int days = (int)span.TotalDays;
        if (days == 1) return "вчера";
        if (days == 2) return "позавчера";
        if (days < 7) return $"{days} {Plural.Ru(days, "день", "дня", "дней")} назад";
        if (days < 30)
        {
            int weeks = days / 7;
            return $"{weeks} {Plural.Ru(weeks, "неделю", "недели", "недель")} назад";
        }
        if (days < 365)
        {
            int months = Math.Max(1, days / 30);
            return $"{months} {Plural.Ru(months, "месяц", "месяца", "месяцев")} назад";
        }
        int years = days / 365;
        return $"{years} {Plural.Ru(years, "год", "года", "лет")} назад";
    }
}

public static class Plural
{
    /// <summary>1 объект, 3 объекта, 5 объектов.</summary>
    public static string Ru(long count, string one, string few, string many)
    {
        long hundreds = Math.Abs(count) % 100;
        long tens = hundreds % 10;
        if (hundreds is >= 11 and <= 14) return many;
        if (tens == 1) return one;
        if (tens is >= 2 and <= 4) return few;
        return many;
    }
}
