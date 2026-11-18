using System.Speech.Synthesis;

namespace Englishwords.Win.Interop;

/// <summary>
/// 基于 Windows 系统语音合成的单词朗读服务。
/// </summary>
public sealed class SpeechSynthesizerService : IDisposable
{
    private readonly SpeechSynthesizer _synthesizer = new();

    public SpeechSynthesizerService()
    {
        _synthesizer.SetOutputToDefaultAudioDevice();
    }

    public void Speak(string text)
    {
        if (string.IsNullOrWhiteSpace(text)) return;
        _synthesizer.SpeakAsyncCancelAll();
        _synthesizer.SpeakAsync(text);
    }

    public void Dispose() => _synthesizer.Dispose();
}
