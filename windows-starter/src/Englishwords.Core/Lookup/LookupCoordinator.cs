using Englishwords.Core.Config;
using Englishwords.Core.Dictionary;
using Englishwords.Core.Translate;

namespace Englishwords.Core.Lookup;

/// <summary>
/// 查询编排器：统一承接热键、划词、区域 OCR 与笔记本点击请求。
/// <para>
/// 每次有效提交递增 <c>_generation</c>，确保慢返回或已取消的旧请求不会覆盖当前面板状态。
/// </para>
/// </summary>
public sealed class LookupCoordinator
{
    private readonly DictionaryStore _store;
    private readonly ITranslating _translator;
    private readonly Preferences _preferences;
    private readonly StarDictLibrary _starDictionaries;

    private readonly object _sync = new();
    private long _generation;
    private CancellationTokenSource? _activeCts;

    public event Action<LookupState>? StateChanged;

    public LookupCoordinator(
        DictionaryStore store,
        ITranslating translator,
        Preferences preferences,
        StarDictLibrary starDictionaries)
    {
        _store = store;
        _translator = translator;
        _preferences = preferences;
        _starDictionaries = starDictionaries;
    }

    /// <summary>
    /// 提交查询请求。若为被动入口且被过滤规则拒绝，返回 <c>false</c> 且不打断当前查询。
    /// </summary>
    public bool Submit(LookupRequest request)
    {
        var classification = TextFilter.Classify(request.Text);
        if (classification is TextClassification.Rejected rejected && request.Trigger.IsPassive())
        {
            return false;
        }

        Cancel();

        long currentGen;
        CancellationToken token;
        lock (_sync)
        {
            currentGen = _generation;
            _activeCts = new CancellationTokenSource();
            token = _activeCts.Token;
        }

        if (classification is TextClassification.Rejected explicitRejected)
        {
            if (request.Trigger == LookupTrigger.Region && explicitRejected.Reason == RejectReason.Empty)
            {
                StateChanged?.Invoke(new LookupState.Failure(request, "未识别到文字"));
                return true;
            }

            var msg = request.Note is not null
                ? $"{explicitRejected.Reason.ToMessage()}\n{request.Note}"
                : explicitRejected.Reason.ToMessage();
            StateChanged?.Invoke(new LookupState.Failure(request, msg));
            return true;
        }

        StateChanged?.Invoke(new LookupState.Loading(request));

        _ = Task.Run(async () =>
        {
            try
            {
                var state = await ResolveAsync(request, classification, token).ConfigureAwait(false);
                if (token.IsCancellationRequested) return;

                lock (_sync)
                {
                    if (currentGen != _generation) return;
                }

                StateChanged?.Invoke(state);
            }
            catch (OperationCanceledException)
            {
                // 取消请求静默结束，不展示错误
            }
            catch (TranslationException ex) when (ex.Kind == TranslationErrorKind.Cancelled)
            {
                // 取消翻译静默结束
            }
        }, token);

        return true;
    }

    /// <summary>
    /// 取消当前在途查询并使旧 generation 失效。
    /// </summary>
    public void Cancel()
    {
        lock (_sync)
        {
            _generation++;
            _activeCts?.Cancel();
            _activeCts?.Dispose();
            _activeCts = null;
        }
    }

    private async Task<LookupState> ResolveAsync(
        LookupRequest request,
        TextClassification classification,
        CancellationToken ct)
    {
        return classification switch
        {
            TextClassification.Rejected rejected => new LookupState.Failure(request, rejected.Reason.ToMessage()),
            TextClassification.Sentence sentence => await TranslateAsync(sentence.Value, request, TextKind.Sentence, request.Note, null, ct).ConfigureAwait(false),
            TextClassification.Word word => await ResolveWordAsync(word.Value, request, ct).ConfigureAwait(false),
            _ => new LookupState.Failure(request, "未知输入类型")
        };
    }

    private async Task<LookupState> ResolveWordAsync(string word, LookupRequest request, CancellationToken ct)
    {
        var morphology = await _store.GetMorphologyAsync(word, ct).ConfigureAwait(false);
        ct.ThrowIfCancellationRequested();

        if (request.Mode == LookupMode.Translate)
        {
            return await TranslateAsync(word, request, TextKind.Word, request.Note, morphology, ct).ConfigureAwait(false);
        }

        var notes = new List<string>();
        if (!string.IsNullOrWhiteSpace(request.Note)) notes.Add(request.Note);

        foreach (var source in _preferences.DictionarySources.Where(s => s.Enabled))
        {
            ct.ThrowIfCancellationRequested();
            try
            {
                Entry? entry = null;
                switch (source.Kind)
                {
                    case DictionarySourceKind.Builtin:
                        var outcome = await _store.LookupAsync(word, ct).ConfigureAwait(false);
                        if (outcome.Error is not null) throw outcome.Error;
                        entry = outcome.Entry;
                        break;

                    case DictionarySourceKind.Stardict:
                        entry = await _starDictionaries.LookupAsync(word, source, ct).ConfigureAwait(false);
                        break;
                }

                if (entry is not null)
                {
                    var note = notes.Count == 0 ? null : string.Join("\n", notes);
                    return new LookupState.Result(request, LookupResult.FromWord(word, entry, morphology, note));
                }
            }
            catch (OperationCanceledException)
            {
                throw;
            }
            catch (Exception ex)
            {
                notes.Add(ex.Message);
            }
        }

        var combinedNote = notes.Count == 0 ? null : string.Join("\n", notes);
        return await TranslateAsync(word, request, TextKind.Word, combinedNote, morphology, ct).ConfigureAwait(false);
    }

    private async Task<LookupState> TranslateAsync(
        string text,
        LookupRequest request,
        TextKind kind,
        string? note,
        Morphology? morphology,
        CancellationToken ct)
    {
        try
        {
            var result = await _translator.TranslateAsync(
                new TranslationRequest(text, "en", _preferences.TargetLanguage), ct).ConfigureAwait(false);

            var mapped = LookupResult.FromTranslation(
                text,
                kind,
                result.Text,
                result.ProviderName,
                kind == TextKind.Word ? morphology : null,
                note);

            return new LookupState.Result(request, mapped);
        }
        catch (Exception ex) when (ex is OperationCanceledException || TranslationException.IsCancellation(ex))
        {
            throw new OperationCanceledException(ct);
        }
        catch (Exception ex)
        {
            var message = ex.Message;
            if (!string.IsNullOrWhiteSpace(note))
            {
                message = $"{message}\n{note}";
            }
            return new LookupState.Failure(request, message);
        }
    }
}
