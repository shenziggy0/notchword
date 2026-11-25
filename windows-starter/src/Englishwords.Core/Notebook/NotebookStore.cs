using Englishwords.Core.Lookup;
using Microsoft.Data.Sqlite;

namespace Englishwords.Core.Notebook;

public sealed record NotebookLookup(long Id, string Word, string Source, DateTimeOffset Date);

public sealed record FavoriteExample(string Word, LookupContext Context, string Meaning)
{
    public string Prompt => Context.Selected is null ? Context.Sentence :
        Context.Sentence[..Context.Start] + "_____" + Context.Sentence[(Context.Start + Context.Length)..];
}

public sealed record DailyCount(DateTimeOffset Date, int Count);

public sealed record FrequentWord(string Word, int Count);

public sealed record NotebookStats(
    int Total,
    IReadOnlyList<DailyCount> Daily,
    IReadOnlyList<FrequentWord> Frequent);

/// <summary>
/// 笔记本本地持久化（<c>%LOCALAPPDATA%\Englishwords\user.sqlite</c>），
/// 表结构与 macOS 版保持 100% 兼容（<c>PRAGMA user_version = 2</c>）。
/// </summary>
public sealed class NotebookStore : IDisposable
{
    private readonly string _dbPath;
    private readonly SemaphoreSlim _gate = new(1, 1);
    private SqliteConnection? _connection;

    public NotebookStore(string dbPath)
    {
        _dbPath = dbPath;
    }

    public async Task RecordLookupAsync(
        string word,
        string source,
        LookupTrigger trigger,
        DateTimeOffset? date = null,
        CancellationToken cancellationToken = default)
    {
        var timestamp = (date ?? DateTimeOffset.UtcNow).ToUnixTimeSeconds();
        await PerformAsync(conn =>
        {
            using var cmd = conn.CreateCommand();
            cmd.CommandText = "INSERT INTO lookups(word, source, trigger, created_at) VALUES ($w, $s, $t, $c)";
            cmd.Parameters.AddWithValue("$w", word);
            cmd.Parameters.AddWithValue("$s", source);
            cmd.Parameters.AddWithValue("$t", trigger.ToRawValue());
            cmd.Parameters.AddWithValue("$c", timestamp);
            cmd.ExecuteNonQuery();
            return 0;
        }, cancellationToken).ConfigureAwait(false);
    }

    public async Task SetFavoriteAsync(string word, bool on, CancellationToken cancellationToken = default)
    {
        await PerformAsync(conn =>
        {
            using var cmd = conn.CreateCommand();
            cmd.CommandText = on
                ? "INSERT OR IGNORE INTO favorites(word, created_at) VALUES ($w, unixepoch())"
                : "DELETE FROM favorites WHERE word = $w";
            cmd.Parameters.AddWithValue("$w", word);
            cmd.ExecuteNonQuery();
            return 0;
        }, cancellationToken).ConfigureAwait(false);
    }

    public async Task<IReadOnlyList<string>> GetFavoritesAsync(CancellationToken cancellationToken = default)
    {
        return await PerformAsync(conn =>
        {
            using var cmd = conn.CreateCommand();
            cmd.CommandText = "SELECT word FROM favorites ORDER BY created_at DESC, word";
            using var reader = cmd.ExecuteReader();
            var list = new List<string>();
            while (reader.Read())
            {
                list.Add(reader.GetString(0));
            }
            return (IReadOnlyList<string>)list;
        }, cancellationToken).ConfigureAwait(false);
    }

    public async Task<IReadOnlyList<NotebookLookup>> GetHistoryAsync(int limit = 200, CancellationToken cancellationToken = default)
    {
        return await PerformAsync(conn =>
        {
            using var cmd = conn.CreateCommand();
            cmd.CommandText = "SELECT id, word, source, created_at FROM lookups ORDER BY created_at DESC, id DESC LIMIT $limit";
            cmd.Parameters.AddWithValue("$limit", Math.Max(0, limit));
            using var reader = cmd.ExecuteReader();
            var list = new List<NotebookLookup>();
            while (reader.Read())
            {
                list.Add(new NotebookLookup(
                    reader.GetInt64(0),
                    reader.GetString(1),
                    reader.GetString(2),
                    DateTimeOffset.FromUnixTimeSeconds(reader.GetInt64(3))));
            }
            return (IReadOnlyList<NotebookLookup>)list;
        }, cancellationToken).ConfigureAwait(false);
    }

    public Task SaveExampleAsync(string word, LookupContext context, string meaning,
        CancellationToken cancellationToken = default)
    {
        if (context.Selected is not { } selected || TextFilter.Classify(selected) is not TextClassification.Word ||
            string.IsNullOrWhiteSpace(word) || string.IsNullOrWhiteSpace(meaning))
            throw new ArgumentException("无法保存此原句");
        return PerformAsync(conn =>
        {
            using var transaction = conn.BeginTransaction();
            using var cmd = conn.CreateCommand();
            cmd.Transaction = transaction;
            cmd.CommandText = """
                INSERT OR IGNORE INTO favorites VALUES ($word, unixepoch());
                INSERT INTO favorite_examples (word, sentence, word_start, word_length, meaning, saved_at)
                VALUES ($word, $sentence, $start, $length, $meaning, unixepoch())
                ON CONFLICT(word, sentence, word_start) DO UPDATE SET
                  word_length=excluded.word_length, meaning=excluded.meaning, saved_at=excluded.saved_at;
                """;
            cmd.Parameters.AddWithValue("$word", word);
            cmd.Parameters.AddWithValue("$sentence", context.Sentence);
            cmd.Parameters.AddWithValue("$start", context.Start);
            cmd.Parameters.AddWithValue("$length", context.Length);
            cmd.Parameters.AddWithValue("$meaning", meaning);
            cmd.ExecuteNonQuery();
            transaction.Commit();
            return 0;
        }, cancellationToken);
    }

    public Task<IReadOnlyList<FavoriteExample>> GetExamplesAsync(string word, CancellationToken cancellationToken = default)
        => PerformAsync<IReadOnlyList<FavoriteExample>>(conn =>
        {
            using var cmd = conn.CreateCommand();
            cmd.CommandText = """
                SELECT sentence, word_start, word_length, meaning
                FROM favorite_examples WHERE word = $word ORDER BY saved_at DESC, sentence, word_start
                """;
            cmd.Parameters.AddWithValue("$word", word);
            using var reader = cmd.ExecuteReader();
            var results = new List<FavoriteExample>();
            while (reader.Read())
                results.Add(new(word, new LookupContext(reader.GetString(0), reader.GetInt32(1), reader.GetInt32(2)),
                                reader.GetString(3)));
            return results;
        }, cancellationToken);

    public Task<IReadOnlyList<string>> GetReviewWordsAsync(DateTimeOffset? now = null,
        CancellationToken cancellationToken = default)
        => PerformAsync<IReadOnlyList<string>>(conn =>
        {
            var date = (now ?? DateTimeOffset.Now).LocalDateTime.Date;
            var start = date.AddDays(-6);
            var end = date.AddDays(1);
            using var cmd = conn.CreateCommand();
            cmd.CommandText = """
                SELECT word, created_at FROM lookups WHERE created_at >= $start AND created_at < $end
                AND trigger IN ('hotkey', 'translate', 'menu', 'clipboard', 'region', 'subtitle')
                """;
            cmd.Parameters.AddWithValue("$start", new DateTimeOffset(start).ToUnixTimeSeconds());
            cmd.Parameters.AddWithValue("$end", new DateTimeOffset(end).ToUnixTimeSeconds());
            using var reader = cmd.ExecuteReader();
            var records = new List<(string Word, DateTimeOffset Date)>();
            while (reader.Read())
                records.Add((reader.GetString(0), DateTimeOffset.FromUnixTimeSeconds(reader.GetInt64(1))));
            return records.GroupBy(row => row.Word)
                .Select(group => (Word: group.Key, Days: group.Select(row => row.Date.LocalDateTime.Date).Distinct().Count(),
                                  Count: group.Count(), Latest: group.Max(row => row.Date)))
                .Where(row => row.Days > 1).OrderByDescending(row => row.Days).ThenByDescending(row => row.Count)
                .ThenByDescending(row => row.Latest).ThenBy(row => row.Word, StringComparer.Ordinal)
                .Take(3).Select(row => row.Word).ToArray();
        }, cancellationToken);

    public async Task<NotebookStats> GetStatsAsync(DateTimeOffset? now = null, CancellationToken cancellationToken = default)
    {
        var anchor = (now ?? DateTimeOffset.Now).LocalDateTime.Date;
        // 逐日分别取本地零点偏移，避免跳夏令时的那一周出现 1 小时偏差。
        var days = Enumerable.Range(0, 8)
            .Select(i => anchor.AddDays(i - 6))
            .Select(day => new DateTimeOffset(day, TimeZoneInfo.Local.GetUtcOffset(day)))
            .ToArray();

        return await PerformAsync(conn =>
        {
            int total;
            using (var totalCmd = conn.CreateCommand())
            {
                totalCmd.CommandText = "SELECT count(*) FROM lookups";
                total = Convert.ToInt32(totalCmd.ExecuteScalar() ?? 0);
            }

            var frequent = new List<FrequentWord>();
            using (var freqCmd = conn.CreateCommand())
            {
                freqCmd.CommandText = "SELECT word, count(*) FROM lookups GROUP BY word ORDER BY count(*) DESC, word LIMIT 20";
                using var reader = freqCmd.ExecuteReader();
                while (reader.Read())
                {
                    frequent.Add(new FrequentWord(reader.GetString(0), reader.GetInt32(1)));
                }
            }

            var daily = new List<DailyCount>(7);
            for (var i = 0; i < days.Length - 1; i++)
            {
                using var dayCmd = conn.CreateCommand();
                dayCmd.CommandText = "SELECT count(*) FROM lookups WHERE created_at >= $start AND created_at < $end";
                dayCmd.Parameters.AddWithValue("$start", days[i].ToUnixTimeSeconds());
                dayCmd.Parameters.AddWithValue("$end", days[i + 1].ToUnixTimeSeconds());
                var count = Convert.ToInt32(dayCmd.ExecuteScalar() ?? 0);
                daily.Add(new DailyCount(days[i], count));
            }

            return new NotebookStats(total, daily, frequent);
        }, cancellationToken).ConfigureAwait(false);
    }

    private async Task<T> PerformAsync<T>(Func<SqliteConnection, T> action, CancellationToken cancellationToken)
    {
        await _gate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            // 建库、迁移与 SQLite 读写均放到后台线程，避免阻塞 WPF UI 线程（卡顿过久会被系统摘掉低级钩子）。
            return await Task.Run(() => action(EnsureOpen()), cancellationToken).ConfigureAwait(false);
        }
        finally
        {
            _gate.Release();
        }
    }

    private SqliteConnection EnsureOpen()
    {
        if (_connection is not null) return _connection;

        var dir = Path.GetDirectoryName(_dbPath);
        if (!string.IsNullOrEmpty(dir)) Directory.CreateDirectory(dir);

        var builder = new SqliteConnectionStringBuilder
        {
            DataSource = _dbPath,
            Mode = SqliteOpenMode.ReadWriteCreate,
            Pooling = false
        };

        var conn = new SqliteConnection(builder.ToString());
        conn.Open();

        try
        {
            using (var busyCmd = conn.CreateCommand())
            {
                busyCmd.CommandText = "PRAGMA busy_timeout = 1000; PRAGMA foreign_keys = ON;";
                busyCmd.ExecuteNonQuery();
            }

            using var transaction = conn.BeginTransaction(deferred: false);
            int version;
            using (var verCmd = conn.CreateCommand())
            {
                verCmd.Transaction = transaction;
                verCmd.CommandText = "PRAGMA user_version;";
                version = Convert.ToInt32(verCmd.ExecuteScalar() ?? 0);
            }

            if (version == 0)
            {
                using var migCmd = conn.CreateCommand();
                migCmd.Transaction = transaction;
                migCmd.CommandText = """
                    CREATE TABLE lookups (
                        id INTEGER PRIMARY KEY,
                        word TEXT NOT NULL,
                        source TEXT NOT NULL,
                        trigger TEXT NOT NULL,
                        created_at INTEGER NOT NULL
                    );
                    CREATE INDEX lookups_created_at ON lookups(created_at);
                    CREATE INDEX lookups_word ON lookups(word);
                    CREATE TABLE favorites (
                        word TEXT PRIMARY KEY,
                        created_at INTEGER NOT NULL
                    ) WITHOUT ROWID;
                    """;
                migCmd.ExecuteNonQuery();
            }
            else if (version is not (1 or 2))
            {
                throw new InvalidOperationException("此版本无法读取较新的笔记本格式");
            }

            if (version < 2)
            {
                using var migrate = conn.CreateCommand();
                migrate.Transaction = transaction;
                migrate.CommandText = """
                    CREATE TABLE favorite_examples (
                        word          TEXT NOT NULL REFERENCES favorites(word) ON DELETE CASCADE,
                        sentence      TEXT NOT NULL,
                        word_start    INTEGER NOT NULL CHECK (word_start >= 0),
                        word_length   INTEGER NOT NULL CHECK (word_length > 0),
                        meaning       TEXT NOT NULL,
                        saved_at      INTEGER NOT NULL,
                        video_ref     TEXT,
                        video_seconds REAL,
                        PRIMARY KEY (word, sentence, word_start),
                        CHECK ((video_ref IS NULL AND video_seconds IS NULL) OR
                               (video_ref IS NOT NULL AND video_seconds IS NOT NULL AND video_seconds >= 0))
                    ) WITHOUT ROWID;
                    PRAGMA user_version = 2;
                    """;
                migrate.ExecuteNonQuery();
            }
            transaction.Commit();
            _connection = conn;
            return conn;
        }
        catch
        {
            conn.Dispose();
            throw;
        }
    }

    public void Dispose()
    {
        // 等待在途查询结束后再释放连接，然后再释放信号量。
        _gate.Wait();
        try
        {
            _connection?.Dispose();
            _connection = null;
        }
        finally
        {
            _gate.Release();
            _gate.Dispose();
        }
    }
}
